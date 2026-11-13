import XCTest
@testable import GLLinkExtensionKit

// Signing, packing and the marketplace's list: what lets a package travel and still be trusted.

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func error(_ body: () throws -> Void) -> ExtensionError? {
    do { try body(); return nil } catch { return error as? ExtensionError }
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

final class SignatureTests: XCTestCase {
    func testASignedPackageNamesItsPublisher() throws {
        let key = ExtensionSigningKey()
        let package = try ExtensionPackage(at: makePackage(manifest()))
        XCTAssertEqual(package.signature, .unsigned)
        XCTAssertEqual(package.files, ["main.js", "manifest.json"])

        let signed = try package.signed(with: key)
        XCTAssertEqual(signed.signature, .signed(key.publicKey))
        XCTAssertEqual(signed.files, ["main.js", "manifest.json"], "the signature isn’t one of its files")
        // The key survives being written down.
        XCTAssertEqual(ExtensionSigningKey(key.text)?.publicKey, key.publicKey)
        XCTAssertEqual(ExtensionPublicKey(key.publicKey.text), key.publicKey)
        XCTAssertEqual(key.publicKey.fingerprint.count, 19)
    }

    func testAnyChangeBreaksTheSignature() throws {
        let key = ExtensionSigningKey()
        func signedPackage() throws -> URL {
            let url = try makePackage(manifest(), script: "gllink.status('hi')")
            try write("a", to: url.appendingPathComponent("icons/a.svg"))
            _ = try ExtensionPackage(at: url).signed(with: key)
            return url
        }

        var url = try signedPackage()
        try write("gllink.status('changed')", to: url.appendingPathComponent("main.js"))
        XCTAssertEqual(error { _ = try ExtensionPackage(at: url) }, .badSignature("“main.js” is different"))

        url = try signedPackage()
        try write("b", to: url.appendingPathComponent("icons/b.svg"))
        XCTAssertEqual(error { _ = try ExtensionPackage(at: url) }, .badSignature("“icons/b.svg” was added"))

        url = try signedPackage()
        try FileManager.default.removeItem(at: url.appendingPathComponent("icons/a.svg"))
        XCTAssertEqual(error { _ = try ExtensionPackage(at: url) }, .badSignature("“icons/a.svg” is missing"))

        // Someone else's key over the same files isn't the publisher's signature.
        url = try signedPackage()
        let file = url.appendingPathComponent("signature.json")
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: key.publicKey.text, with: ExtensionSigningKey().publicKey.text)
        try write(text, to: file)
        XCTAssertEqual(error { _ = try ExtensionPackage(at: url) }, .badSignature("the signature doesn’t match its key"))

        // Dot files are nobody's business: not signed, so not a change.
        url = try signedPackage()
        try write("x", to: url.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try ExtensionPackage(at: url).signature, .signed(key.publicKey))
    }

    func testAPackageCantPointOutsideItself() throws {
        let url = try makePackage(manifest())
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("passwd"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertEqual(error { _ = try ExtensionPackage(at: url) }, .badFile("passwd", "it’s a link or a special file"))

        XCTAssertTrue(ExtensionPackage.isSafe("icons/router.e5800.svg"))
        for path in ["../x", "a/../x", "/etc/passwd", "a//b", ".hidden", "a/.b", "a\\b", "名.js", ""] {
            XCTAssertFalse(ExtensionPackage.isSafe(path), path)
        }
    }

    func testOnlyItsPublisherUpdatesASignedExtension() throws {
        let (mine, theirs) = (ExtensionSigningKey(), ExtensionSigningKey())
        func package(_ key: ExtensionSigningKey?) throws -> ExtensionPackage {
            let p = try ExtensionPackage(at: makePackage(manifest()))
            return try key.map { try p.signed(with: $0) } ?? p
        }
        let installed = try package(mine)
        XCTAssertNoThrow(try package(mine).checkReplaces(installed))
        XCTAssertEqual(error { try package(theirs).checkReplaces(installed) }, .otherPublisher("Test"))
        XCTAssertEqual(error { try package(nil).checkReplaces(installed) }, .otherPublisher("Test"))
        // An author's own unsigned copy gives way to anything.
        XCTAssertNoThrow(try package(theirs).checkReplaces(try package(nil)))
        XCTAssertNoThrow(try package(nil).checkReplaces(try package(nil)))
    }

    func testVersionsCompareByNumber() throws {
        XCTAssertLessThan(try XCTUnwrap(ExtensionVersion("1.9")), try XCTUnwrap(ExtensionVersion("1.10")))
        XCTAssertEqual(ExtensionVersion("1.0"), ExtensionVersion("1.0.0"))
        XCTAssertLessThan(try XCTUnwrap(ExtensionVersion("1.2.3")), try XCTUnwrap(ExtensionVersion("2")))
        for bad in ["", "v1", "1.0-beta", "1..2", "1.2.3.4.5", "one"] { XCTAssertNil(ExtensionVersion(bad), bad) }
        var m = manifest(); m["version"] = "latest"
        XCTAssertEqual(error { _ = try ExtensionPackage(at: makePackage(m)) },
                       .badManifest("“version” must be numbers with dots, like 1.2.0"))
    }

    func testAnUpdateSaysWhatItAsksForAnew() {
        let old = Permissions(routers: [.battery])
        let new = Permissions(routers: [.battery], network: ["api.example.com"])
        XCTAssertEqual(new.added(to: old), ["Connect to api.example.com"])
        XCTAssertEqual(old.added(to: new), [])
    }

    func testLintWarnsAboutWhatWouldSurprise() throws {
        var m = manifest(["routers": ["battery"], "netwrok": ["example.com"], "network": ["*.com"]])
        m["permisions"] = [:]
        let lint = ExtensionLint(try ExtensionPackage(at: makePackage(m, script: "gllink.readFile('/etc/hosts')")))
        XCTAssertTrue(lint.warnings.contains { $0.contains("“permisions” isn’t a field") }, "\(lint.warnings)")
        XCTAssertTrue(lint.warnings.contains { $0.contains("“permissions.netwrok” isn’t a permission") })
        XCTAssertTrue(lint.warnings.contains { $0.contains("“*.com” reaches every site") })
        XCTAssertTrue(lint.warnings.contains { $0.contains("gllink.readFile(") })
        XCTAssertTrue(lint.warnings.contains { $0.contains("no “repo”") })
    }
}

final class ArchiveTests: XCTestCase {
    func testAPackedPackageComesBackWhole() throws {
        let key = ExtensionSigningKey()
        let url = try makePackage(manifest(), script: String(repeating: "gllink.status('hello');\n", count: 200))
        try write("<svg/>", to: url.appendingPathComponent("icons/a.svg"))
        try write("", to: url.appendingPathComponent("empty.txt"))
        try write("x", to: url.appendingPathComponent(".git/config"))
        let package = try ExtensionPackage(at: url).signed(with: key)

        let archive = try ExtensionArchive.pack(package)
        XCTAssertLessThan(archive.count, 2000, "the script is deflated")
        let back = try ExtensionArchive.unpack(archive, into: scratch())
        XCTAssertEqual(back.files, ["empty.txt", "icons/a.svg", "main.js", "manifest.json"])
        XCTAssertEqual(back.signature, .signed(key.publicKey))
        XCTAssertEqual(back.manifest, package.manifest)
        XCTAssertEqual(try back.script(), try package.script())
    }

    func testReadsWhatZipWrites() throws {
        // `zip -r Hello.zip Hello.ext`: one top folder, deflated, with folder entries.
        let url = try makePackage(manifest(), script: String(repeating: "// a comment\n", count: 100), name: "Hello.ext")
        let out = scratch().appendingPathExtension("glext")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = url.deletingLastPathComponent()
        zip.arguments = ["-q", "-r", out.path, "Hello.ext"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let package = try ExtensionArchive.inspect(try Data(contentsOf: out))
        XCTAssertEqual(package.manifest.id, "com.example.test")
        XCTAssertEqual(package.files, ["main.js", "manifest.json"])
    }

    func testRefusesWhatIsntOne() throws {
        XCTAssertEqual(error { _ = try ExtensionArchive.read(Data("not a zip at all, just some text".utf8)) },
                       .badArchive("it isn’t a zip"))
        // A damaged file is caught by its checksum.
        let package = try ExtensionPackage(at: makePackage(manifest(), script: "gllink.status('one')"))
        var archive = try ExtensionArchive.pack(package)
        let at = try XCTUnwrap(archive.range(of: Data("'one'".utf8))).lowerBound
        archive[at + 1] = UInt8(ascii: "0")
        XCTAssertEqual(error { _ = try ExtensionArchive.read(archive) }, .badArchive("“main.js” is damaged"))
        // A zip with no manifest.
        XCTAssertEqual(ExtensionArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class CatalogTests: XCTestCase {
    private let publisher = ExtensionSigningKey()
    private let repo = "https://github.com/someone/gl-link-thing"

    private func shared(version: String = "1.2.0", repo: String? = nil) throws -> (ExtensionPackage, Data) {
        var m = manifest(["routers": ["battery"]])
        m["version"] = version
        m["repo"] = repo ?? self.repo
        m["author"] = "Someone"
        let package = try ExtensionPackage(at: makePackage(m)).signed(with: publisher)
        return (package, try ExtensionArchive.pack(package))
    }

    func testAnEntryIsWhatItsPackageSays() throws {
        let (package, archive) = try shared()
        let entry = try CatalogEntry(package: package, archive: archive, download: repo + "/releases/download/v1.2.0/Test-1.2.0.glext")
        XCTAssertEqual(entry.author, "Someone")
        XCTAssertEqual(entry.key, publisher.publicKey)
        XCTAssertNoThrow(try entry.check(archive, package: try ExtensionArchive.inspect(archive)))
        XCTAssertTrue(entry.isNewer(than: "1.1.9"))
        XCTAssertFalse(entry.isNewer(than: "1.2"))

        // Another file under the same name, even from the same publisher, isn't the one listed.
        let (_, other) = try shared(version: "1.2.1")
        XCTAssertEqual(error { try entry.check(other, package: try ExtensionArchive.inspect(other)) },
                       .catalog("the download of “Test” isn’t the file the catalog lists"))
    }

    func testAnEntryDownloadsOnlyFromItsOwnPublicRepository() throws {
        let (package, archive) = try shared()
        func entry(_ download: String) -> ExtensionError? {
            error { _ = try CatalogEntry(package: package, archive: archive, download: download) }
        }
        XCTAssertNil(entry(repo + "/releases/download/v1.2.0/Test-1.2.0.glext"))
        for download in ["https://evil.example.com/Test-1.2.0.glext",
                         "https://github.com/someone-else/gl-link-thing/releases/download/v1/Test.glext",
                         repo + "/releases/download/v1/../../../../other/repo/releases/download/v1/Test.glext",
                         repo + "/releases/download/v1.2.0/Test.zip",
                         repo + "/archive/main.glext"] {
            XCTAssertEqual(entry(download), .catalog("“com.example.test” must download a .glext from a release of \(repo)"), download)
        }
        // No repository, no entry: what's shared has its source in the open.
        var m = manifest(); m["repo"] = "https://gitlab.com/someone/thing"
        XCTAssertEqual(error { _ = try ExtensionPackage(at: makePackage(m)) },
                       .badManifest("“repo” must be https://github.com/owner/name"))
        // Nor an unsigned one.
        let unsigned = try ExtensionPackage(at: makePackage(manifest()))
        XCTAssertEqual(error { _ = try CatalogEntry(package: unsigned, archive: archive, download: "") },
                       .catalog("“Test” isn’t signed"))
    }

    func testTheAppTakesOnlyTheMarketplacesList() throws {
        let market = ExtensionSigningKey()
        let (package, archive) = try shared()
        let entry = try CatalogEntry(package: package, archive: archive, download: repo + "/releases/download/v1.2.0/Test-1.2.0.glext")
        let data = try Catalog(updated: "2026-11-13T00:00:00Z", extensions: [entry]).encoded()
        let signature = market.sign(data).base64EncodedString() + "\n"

        let catalog = try Catalog.verified(data, signature: signature, key: market.publicKey)
        XCTAssertEqual(catalog.extensions, [entry])

        // Changed after signing, signed by someone else, or not at all.
        let changed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "someone/", with: "someone-else/").utf8)
        let refused = ExtensionError.catalog("it isn’t signed by the marketplace")
        XCTAssertEqual(error { _ = try Catalog.verified(changed, signature: signature, key: market.publicKey) }, refused)
        XCTAssertEqual(error { _ = try Catalog.verified(data, signature: signature, key: self.publisher.publicKey) }, refused)
        XCTAssertEqual(error { _ = try Catalog.verified(data, signature: "", key: market.publicKey) }, refused)
        XCTAssertEqual(error { _ = try Catalog.verified(data, signature: signature, key: nil) },
                       .catalog("this build has no marketplace key"))
    }
}
