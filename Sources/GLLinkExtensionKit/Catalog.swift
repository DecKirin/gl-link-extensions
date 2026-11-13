import Foundation

/// The marketplace: a list of shared extensions, each with its public source on GitHub
/// (docs/extensions.md, "The marketplace").
///
/// It's two files in a public repository: `index.json` (this) and `index.json.sig`, an
/// ed25519 signature of those bytes by the marketplace key, in base64. The app carries the
/// public half (`Catalog.marketplaceKey`), so a list that someone else wrote is refused.
///
/// The list names, for every extension, the publisher's key, the file to download and its
/// SHA-256. What's downloaded must match all three before the person is even asked.
public struct Catalog: Codable, Sendable {
    public var v: Int
    /// When it was made, ISO 8601.
    public var updated: String?
    public var extensions: [CatalogEntry]

    public init(v: Int = 1, updated: String? = nil, extensions: [CatalogEntry]) {
        self.v = v
        self.updated = updated
        self.extensions = extensions
    }

    /// Where the app reads the list: this repository.
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/DecKirin/gl-link-extensions/main/index.json")!
    /// The marketplace's public key. Its private half signs `index.json` (`gllink-ext market index`).
    /// Fingerprint C59B 2884 D975 2577.
    public static let marketplaceKey = ExtensionPublicKey("05HoqfrR4USWU+rF3zNsj/ud2Uq56rC9mhSyGnzGFKM=")

    /// The list, if `signature` (base64) is the marketplace's over exactly these bytes and
    /// every entry holds up.
    public static func verified(_ data: Data, signature: String, key: ExtensionPublicKey?) throws -> Catalog {
        guard let key else { throw ExtensionError.catalog("this build has no marketplace key") }
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.verifies(sig, of: data) else {
            throw ExtensionError.catalog("it isn’t signed by the marketplace")
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw ExtensionError.catalog("it can’t be read")
        }
        guard catalog.v == 1 else { throw ExtensionError.catalog("it needs a newer GL-Link") }
        for entry in catalog.extensions { try entry.validate() }
        return catalog
    }

    /// The bytes that get signed and served: the same for the same entries.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// One shared extension: what its manifest says, and where to get exactly that.
public struct CatalogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ExtensionManifest.Kind
    public var name: String
    public var version: String
    public var summary: String
    public var symbol: String?
    public var platforms: [Platform]
    public var hostAPI: Int
    public var author: String
    /// Its public source: "https://github.com/owner/repo".
    public var repo: String
    /// The `.glext`, a file of one of that repository's releases.
    public var download: String
    /// Of the `.glext`, hex.
    public var sha256: String
    public var size: Int
    /// The publisher's key. The package must be signed with it, and so must every later version.
    public var key: ExtensionPublicKey
    public var permissions: Permissions

    enum CodingKeys: String, CodingKey {
        case id, kind, name, version, summary, symbol, platforms, author, repo, download, sha256, size, key, permissions
        case hostAPI = "host_api"
    }

    /// What `gllink-ext publish` writes for a packed, signed extension.
    public init(package: ExtensionPackage, archive: Data, download: String) throws {
        let m = package.manifest
        guard let key = package.signature.key else { throw ExtensionError.catalog("“\(m.name)” isn’t signed") }
        guard let repo = m.repo else {
            throw ExtensionError.catalog("the manifest of “\(m.name)” has no “repo”: a shared extension’s source is public on GitHub")
        }
        id = m.id; kind = m.kind; name = m.name; version = m.version; summary = m.summary; symbol = m.symbol
        platforms = m.platforms; hostAPI = m.hostAPI; permissions = m.permissions
        author = m.author ?? GitHubRepo(repo)?.owner ?? ""
        self.repo = repo
        self.download = download
        sha256 = ExtensionPackage.sha256(archive)
        size = archive.count
        self.key = key
        try validate()
    }

    /// The rules every entry keeps, whoever wrote the list.
    public func validate() throws {
        func bad(_ why: String) -> ExtensionError { .catalog("“\(id)” \(why)") }
        guard id.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw ExtensionError.catalog("“\(id)” isn’t an extension id")
        }
        guard ExtensionVersion(version) != nil else { throw bad("has a version that isn’t numbers with dots") }
        guard (1...40).contains(name.count), (1...60).contains(author.count) else { throw bad("needs a name and an author") }
        guard let repo = GitHubRepo(repo) else { throw bad("has no public GitHub repository") }
        // Only a release of its own repository: the file's history is then in the open too.
        guard download.hasPrefix(repo.downloads), download.hasSuffix("." + ExtensionArchive.pathExtension),
              let url = URL(string: download), url.host == "github.com", !download.contains(".."),
              url.query == nil, url.fragment == nil else {
            throw bad("must download a .glext from a release of \(repo.url)")
        }
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw bad("has no SHA-256") }
        guard (1...ExtensionPackage.maxSize).contains(size) else { throw bad("has a size that can’t be") }
    }

    public var downloadURL: URL { URL(string: download)! }

    /// Whether a downloaded file is the one this entry names: its bytes, its publisher, and
    /// the manifest the list showed.
    public func check(_ archive: Data, package: ExtensionPackage) throws {
        func bad(_ why: String) -> ExtensionError { .catalog("the download of “\(name)” \(why)") }
        guard ExtensionPackage.sha256(archive) == sha256 else { throw bad("isn’t the file the catalog lists") }
        guard package.signature == .signed(key) else { throw bad("isn’t signed by its publisher") }
        let m = package.manifest
        guard m.id == id, m.version == version, m.kind == kind else { throw bad("is a different extension or version") }
        guard m.permissions == permissions, m.platforms == platforms else { throw bad("asks for something else than the catalog shows") }
        guard m.repo == repo else { throw bad("names another repository") }
    }

    /// Whether this is newer than an installed version.
    public func isNewer(than installed: String) -> Bool {
        guard let mine = ExtensionVersion(version), let theirs = ExtensionVersion(installed) else { return false }
        return mine > theirs
    }
}
