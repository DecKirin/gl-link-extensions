import Foundation
import Compression

/// A package as one file, to download, send and upload: a `.glext`, which is a zip of the
/// package's files (`manifest.json` at its root), its `signature.json` included.
///
/// A plain zip, so any tool can make or look into one. Reading takes what `zip` and Finder's
/// Compress write too: a single top folder (`Name.ext/`) is looked through, and `__MACOSX`
/// and dot files are skipped.
public enum ExtensionArchive {
    public static let pathExtension = "glext"

    // MARK: - Packing

    /// The package's files, and its signature if it has one, as a zip.
    public static func pack(_ package: ExtensionPackage) throws -> Data {
        var names = package.files
        if package.signature != .unsigned { names.append(ExtensionPackage.signatureFile) }
        names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }

        var out = Data()
        var directory = Data()
        for name in names {
            let data = try Data(contentsOf: package.url.appendingPathComponent(name))
            let packed = deflate(data)
            let body = packed ?? data
            let offset = out.count
            // version 2.0, UTF-8 names, deflate or stored, 1980-01-01 00:00 so builds repeat.
            var fields = Data()
            fields.le16(20); fields.le16(0x0800); fields.le16(packed == nil ? 0 : 8)
            fields.le16(0); fields.le16(0x0021)
            fields.le32(crc32(data)); fields.le32(UInt32(body.count)); fields.le32(UInt32(data.count))
            fields.le16(UInt16(name.utf8.count)); fields.le16(0)

            out.le32(0x0403_4b50); out.append(fields); out.append(Data(name.utf8)); out.append(body)

            directory.le32(0x0201_4b50); directory.le16(0x0314); directory.append(fields)
            directory.le16(0); directory.le16(0); directory.le16(0)
            directory.le32(0o100644 << 16); directory.le32(UInt32(offset))
            directory.append(Data(name.utf8))
        }
        let start = out.count
        out.append(directory)
        out.le32(0x0605_4b50); out.le16(0); out.le16(0)
        out.le16(UInt16(names.count)); out.le16(UInt16(names.count))
        out.le32(UInt32(directory.count)); out.le32(UInt32(start)); out.le16(0)
        return out
    }

    // MARK: - Unpacking

    /// Unpacks into `folder/<name>.ext`, then reads and checks it as any package, its signature
    /// included. Nothing is written outside that folder.
    public static func unpack(_ data: Data, into folder: URL, name: String = "Package") throws -> ExtensionPackage {
        let entries = try read(data)
        let target = folder.appendingPathComponent("\(name).\(ExtensionPackage.pathExtension)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for (path, body) in entries {
            let to = target.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: to)
        }
        return try ExtensionPackage(at: target)
    }

    /// Reads and checks a packed extension without leaving anything behind.
    public static func inspect(_ data: Data) throws -> ExtensionPackage {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("glext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try unpack(data, into: scratch)
    }

    /// The files in a zip, by their path inside the package.
    static func read(_ data: Data) throws -> [(path: String, data: Data)] {
        func bad(_ why: String) -> ExtensionError { .badArchive(why) }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // The end record: in the last 64 KB, before an optional comment.
        guard bytes.count >= 22 else { throw bad("it isn’t a zip") }
        var end = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 0xFFFF)
        while end >= stop, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= stop else { throw bad("it isn’t a zip") }
        let count = u16(end + 10)
        var at = u32(end + 16)
        guard count <= ExtensionPackage.maxFiles * 2, count != 0xFFFF else { throw bad("it holds too many files") }

        var found: [(path: String, data: Data)] = []
        var total = 0
        for _ in 0..<count {
            guard at + 46 <= bytes.count, u32(at) == 0x0201_4b50 else { throw bad("its list of files is damaged") }
            let flags = u16(at + 8), method = u16(at + 10)
            let crc = UInt32(u32(at + 16)), packedSize = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            let mode = u32(at + 38) >> 16, local = u32(at + 42)
            guard at + 46 + nameLength <= bytes.count else { throw bad("its list of files is damaged") }
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extra + comment

            if name.hasSuffix("/") { continue }                                  // a folder
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if parts.contains(where: { $0.hasPrefix(".") && $0 != ".." }) || parts.first == "__MACOSX" { continue }
            guard flags & 1 == 0 else { throw bad("it’s encrypted") }
            guard mode & 0o170000 != 0o120000 else { throw ExtensionError.badFile(name, "it’s a link or a special file") }
            total += size
            guard total <= ExtensionPackage.maxSize, found.count < ExtensionPackage.maxFiles else { throw ExtensionError.tooLarge }

            guard local + 30 <= bytes.count, u32(local) == 0x0403_4b50 else { throw bad("“\(name)” is damaged") }
            let from = local + 30 + u16(local + 26) + u16(local + 28)
            guard from + packedSize <= bytes.count else { throw bad("“\(name)” is damaged") }
            let packed = Data(bytes[from..<(from + packedSize)])
            let body: Data
            switch method {
            case 0:
                guard packedSize == size else { throw bad("“\(name)” is damaged") }
                body = packed
            case 8:
                guard let plain = inflate(packed, size: size) else { throw bad("“\(name)” is damaged") }
                body = plain
            default: throw bad("“\(name)” is compressed in a way GL-Link doesn’t read")
            }
            guard crc32(body) == crc else { throw bad("“\(name)” is damaged") }
            found.append((name, body))
        }

        // `zip -r Name.ext.zip Name.ext` and Finder put everything in one top folder.
        if !found.contains(where: { $0.path == "manifest.json" }),
           let top = found.first?.path.split(separator: "/").first.map({ $0 + "/" }),
           found.allSatisfy({ $0.path.hasPrefix(top) }) {
            found = found.map { (String($0.path.dropFirst(top.count)), $0.data) }
        }
        var seen = Set<String>()
        for (path, _) in found {
            guard ExtensionPackage.isSafe(path) else {
                throw ExtensionError.badFile(path, "file names use letters, digits, spaces and ._@+- only")
            }
            guard seen.insert(path.lowercased()).inserted else { throw bad("“\(path)” is there twice") }
        }
        guard seen.contains("manifest.json") else { throw ExtensionError.noManifest }
        return found
    }

    // MARK: - Deflate and CRC

    /// Raw deflate, or nil when it wouldn't be smaller.
    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 && n < data.count ? Data(out[..<n]) : nil
    }

    /// Raw deflate back to exactly `size` bytes, or nil.
    private static func inflate(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return data.isEmpty || data.count <= 8 ? Data() : nil }
        guard !data.isEmpty else { return nil }
        // One more than expected, so data that unpacks to more is caught, not cut.
        var out = [UInt8](repeating: 0, count: size + 1)
        let n = data.withUnsafeBytes { src in
            compression_decode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n == size ? Data(out[..<size]) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
