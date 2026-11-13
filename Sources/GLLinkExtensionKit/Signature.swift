import Foundation
import CryptoKit

/// Who a package comes from, and that it's whole (docs/extensions.md, "Trust").
///
/// A signed package holds `signature.json`:
///
/// ```json
/// {"v": 1,
///  "key": "<the publisher's ed25519 public key, base64>",
///  "files": {"main.js": "<sha256, hex>", "manifest.json": "…"},
///  "signature": "<ed25519 over the text below, base64>"}
/// ```
///
/// What's signed is this text, UTF-8, the files sorted by the bytes of their paths:
///
/// ```
/// gllink-ext-signature-v1
/// <sha256 hex>  <path>
/// <sha256 hex>  <path>
/// ```
///
/// The text is rebuilt from the files that are there, so a changed, added or removed file
/// breaks the signature. A signature says who published a package, not that it's safe: the
/// app pins the key per extension (an update must carry the same one), and the catalog says
/// which key belongs to which extension.
public enum SignatureState: Equatable, Sendable {
    case unsigned
    case signed(ExtensionPublicKey)

    public var key: ExtensionPublicKey? {
        if case .signed(let key) = self { key } else { nil }
    }
}

/// A publisher's public key: 32 bytes of ed25519.
public struct ExtensionPublicKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: Data

    /// From base64, as it's written in `signature.json` and the catalog.
    public init?(_ text: String) {
        guard let raw = Data(base64Encoded: text), raw.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { return nil }
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = ExtensionPublicKey(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ed25519 public key"))
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    public var text: String { raw.base64EncodedString() }
    public var description: String { text }

    /// Short enough to read out and compare: "3F2A 91C4 0B7E 55D1".
    public var fingerprint: String {
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }

    public func verifies(_ signature: Data, of data: Data) -> Bool {
        (try? Curve25519.Signing.PublicKey(rawRepresentation: raw))?.isValidSignature(signature, for: data) ?? false
    }
}

/// A publisher's private key. Whoever holds it can publish updates to that publisher's
/// extensions, so it stays on the author's machine (`gllink-ext keygen`).
public struct ExtensionSigningKey: Sendable {
    private let key: Curve25519.Signing.PrivateKey

    public init() { key = Curve25519.Signing.PrivateKey() }

    /// From base64 of its 32-byte seed, as `gllink-ext keygen` writes it.
    public init?(_ text: String) {
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        self.key = key
    }

    public var text: String { key.rawRepresentation.base64EncodedString() }
    public var publicKey: ExtensionPublicKey { ExtensionPublicKey(key.publicKey.rawRepresentation.base64EncodedString())! }

    public func sign(_ data: Data) -> Data {
        // Signing with a valid key doesn't fail.
        (try? key.signature(for: data)) ?? Data()
    }
}

struct SignatureFile: Codable {
    var v: Int
    var key: ExtensionPublicKey
    var files: [String: String]
    var signature: String
}

extension ExtensionPackage {
    public static let signatureFile = "signature.json"
    private static let signedHeader = "gllink-ext-signature-v1\n"

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashes(in root: URL, files: [String]) throws -> [(path: String, hash: String)] {
        try files.map { ($0, sha256(try Data(contentsOf: root.appendingPathComponent($0)))) }
    }

    private static func signedText(_ hashes: [(path: String, hash: String)]) -> Data {
        Data((signedHeader + hashes.map { "\($0.hash)  \($0.path)\n" }.joined()).utf8)
    }

    /// Reads `signature.json`, if there is one, and checks it against the files that are there.
    static func verifySignature(in root: URL, files: [String]) throws -> SignatureState {
        let url = root.appendingPathComponent(signatureFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return .unsigned }
        guard let file = try? JSONDecoder().decode(SignatureFile.self, from: Data(contentsOf: url)), file.v == 1,
              let signature = Data(base64Encoded: file.signature) else {
            throw ExtensionError.badSignature("signature.json can’t be read")
        }
        let now = try hashes(in: root, files: files)
        guard file.key.verifies(signature, of: signedText(now)) else {
            // Say which file, where the list that was signed tells.
            let current = Dictionary(uniqueKeysWithValues: now.map { ($0.path, $0.hash) })
            if let changed = current.keys.sorted().first(where: { file.files[$0] != nil && file.files[$0] != current[$0] }) {
                throw ExtensionError.badSignature("“\(changed)” is different")
            }
            if let added = current.keys.sorted().first(where: { file.files[$0] == nil }) {
                throw ExtensionError.badSignature("“\(added)” was added")
            }
            if let removed = file.files.keys.sorted().first(where: { current[$0] == nil }) {
                throw ExtensionError.badSignature("“\(removed)” is missing")
            }
            throw ExtensionError.badSignature("the signature doesn’t match its key")
        }
        return .signed(file.key)
    }

    /// Signs the package where it is, writing `signature.json`, and reads it again.
    public func signed(with key: ExtensionSigningKey) throws -> ExtensionPackage {
        let now = try Self.hashes(in: url, files: files)
        let file = SignatureFile(v: 1, key: key.publicKey,
                                 files: Dictionary(uniqueKeysWithValues: now.map { ($0.path, $0.hash) }),
                                 signature: key.sign(Self.signedText(now)).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: url.appendingPathComponent(Self.signatureFile))
        return try ExtensionPackage(at: url)
    }

    /// Whether this may replace `installed`, which has the same id. A signed extension is
    /// only ever updated by its own publisher: the update gets the installed one's secrets
    /// and its switch, so "the same id" isn't enough. An unsigned one (an author's own, on
    /// the way to being shared) can be replaced by anything.
    public func checkReplaces(_ installed: ExtensionPackage) throws {
        guard let pinned = installed.signature.key else { return }
        guard signature == .signed(pinned) else { throw ExtensionError.otherPublisher(manifest.name) }
    }

    /// Copies the package's own files (and its signature) to `target`, which must not exist.
    /// Stray files beside them, such as `.git`, stay behind.
    public func copy(to target: URL) throws -> ExtensionPackage {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var all = files
        if signature != .unsigned { all.append(Self.signatureFile) }
        for path in all {
            let to = target.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url.appendingPathComponent(path), to: to)
        }
        return try ExtensionPackage(at: target)
    }
}

/// A version: numbers with dots, compared number by number ("1.10" is after "1.9").
public struct ExtensionVersion: Comparable, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        guard text.count <= 20, text.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        parts = text.split(separator: ".").compactMap { Int($0) }
    }

    public static func < (a: ExtensionVersion, b: ExtensionVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let (x, y) = (i < a.parts.count ? a.parts[i] : 0, i < b.parts.count ? b.parts[i] : 0)
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ExtensionVersion, b: ExtensionVersion) -> Bool { !(a < b) && !(b < a) }
}

/// "https://github.com/owner/name": where a shared extension's source is, in the open.
public struct GitHubRepo: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init?(_ text: String) {
        guard text.range(of: #"^https://github\.com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil,
              !text.hasSuffix(".git"), !text.hasSuffix("/.."), !text.hasSuffix("/.") else { return nil }
        let parts = text.split(separator: "/")
        owner = String(parts[parts.count - 2])
        name = String(parts[parts.count - 1])
    }

    public var url: String { "https://github.com/\(owner)/\(name)" }
    /// Where its releases' files are served from.
    public var downloads: String { url + "/releases/download/" }
}
