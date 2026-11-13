import Foundation

/// An extension as a file: a `.ext` package, a folder the system shows as one file, holding
/// `manifest.json` and what it names (docs/writing-extensions.md).
///
/// There are two kinds (`ExtensionManifest.Kind`):
/// - **App extensions** run in GL-Link on one iPhone or Mac: a script, run by `ScriptExtension`.
///   The app installs one by copying it into its own storage, and removes it by deleting that
///   copy; nothing is compiled into the app.
/// - **Router extensions** run on a router, and every device paired with it shows them. The
///   app reads their manifest only to say where they belong.
///
/// ```
/// GlassyBattery.ext/
///   manifest.json
///   main.js
///   signature.json     once it's signed (`Signature.swift`)
/// ```
///
/// To travel as one file it's packed into a `.glext` (`ExtensionArchive`).
public struct ExtensionPackage: Sendable {
    public static let pathExtension = "ext"
    /// The extension API this app runs. A package written for a newer one is refused.
    public static let hostAPI = 1
    /// The most a package may hold, all its files together.
    public static let maxSize = 16 << 20
    public static let maxFiles = 2000

    public let url: URL
    public let manifest: ExtensionManifest
    /// Its files, as paths inside the package, sorted; `signature.json` left out.
    public let files: [String]
    /// Who signed it, if anyone. A package whose signature doesn't match its files isn't read
    /// at all (`ExtensionError.badSignature`).
    public let signature: SignatureState

    /// Reads and checks a package; doesn't run anything.
    public init(at url: URL) throws {
        guard url.pathExtension.lowercased() == Self.pathExtension else { throw ExtensionError.notAPackage }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ExtensionError.notAPackage
        }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else {
            throw ExtensionError.noManifest
        }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            throw ExtensionError.badManifest(Self.describe(error))
        }
        try manifest.validate()
        if manifest.kind == .app,
           !FileManager.default.fileExists(atPath: url.appendingPathComponent(manifest.main).path) {
            throw ExtensionError.noScript(manifest.main)
        }
        self.url = url
        self.manifest = manifest
        files = try Self.listFiles(in: url)
        signature = try Self.verifySignature(in: url, files: files)
    }

    /// Every file in a package folder, as "/"-separated paths, sorted by their bytes.
    /// `signature.json` and anything whose name starts with a dot (`.DS_Store`, `.git`) are
    /// left out: they're neither signed, packed nor installed. A link, or a name outside
    /// letters, digits and `._@+-` and spaces, is refused, so a package can't point outside
    /// itself and reads the same on every system.
    static func listFiles(in root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { throw ExtensionError.notAPackage }
        var out: [String] = []
        var total = 0
        while let path = walker.nextObject() as? String {
            let attributes = try fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            let type = attributes[.type] as? FileAttributeType
            if path.split(separator: "/").last?.hasPrefix(".") == true {
                if type == .typeDirectory { walker.skipDescendants() }
                continue
            }
            switch type {
            case .typeDirectory: continue
            case .typeRegular: break
            default: throw ExtensionError.badFile(path, "it’s a link or a special file")
            }
            guard Self.isSafe(path) else {
                throw ExtensionError.badFile(path, "file names use letters, digits, spaces and ._@+- only")
            }
            if path == Self.signatureFile { continue }
            total += (attributes[.size] as? Int) ?? 0
            out.append(path)
            guard out.count <= maxFiles, total <= maxSize else { throw ExtensionError.tooLarge }
        }
        return out.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// A path inside a package: no "..", no empty or dot-led parts, a plain character set.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 200 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.hasPrefix(".") && $0.range(of: #"^[A-Za-z0-9._@+ -]+$"#, options: .regularExpression) != nil
        }
    }

    /// The script the manifest names.
    public func script() throws -> String {
        try String(contentsOf: url.appendingPathComponent(manifest.main), encoding: .utf8)
    }

    /// Whether it runs in this app: an app extension for this platform.
    public var runsHere: Bool { manifest.kind == .app && manifest.platforms.contains(.current) }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "“\(key.stringValue)” is missing"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            "“\(c.codingPath.map(\.stringValue).joined(separator: "."))” has the wrong kind of value"
        case DecodingError.dataCorrupted: "it isn’t valid JSON"
        default: error.localizedDescription
        }
    }
}

public struct ExtensionManifest: Codable, Equatable, Sendable {
    /// Where an extension runs, and so who sees it.
    public enum Kind: String, Codable, Sendable {
        /// On a router, always on; shown on every device paired with it.
        case router
        /// In GL-Link on one device, while it runs; only that device has it.
        case app

        public var title: String { self == .router ? "Router Extension" : "App Extension" }
    }

    /// What it needs elsewhere to be of use.
    public struct Requires: Codable, Equatable, Sendable {
        /// Router extensions, by id, that this app extension reads from.
        public var router: [String]?
    }

    /// Reverse DNS, lowercase: "com.example.thing".
    public var id: String
    /// `app` when left out: the only kind before kinds were named.
    public var kind: Kind
    public var name: String
    public var version: String
    /// One sentence for Settings → Extensions.
    public var summary: String
    /// An SF Symbol for it.
    public var symbol: String?
    /// Where an app extension runs. Empty for a router extension.
    public var platforms: [Platform]
    /// The extension API it was written for.
    public var hostAPI: Int
    /// An app extension's script, relative to the package.
    public var main: String
    /// A router extension's program, in `bin/<target>/`.
    public var exec: String?
    public var permissions: Permissions
    public var requires: Requires?
    /// Who wrote it, as they'd like to be named.
    public var author: String?
    /// Its public source: "https://github.com/owner/repo". The marketplace needs one.
    public var repo: String?

    static let known: Set<String> = ["id", "kind", "name", "version", "summary", "symbol", "platforms", "main",
                                     "exec", "permissions", "requires", "author", "repo", "host_api",
                                     "memory_mb", "config", "$schema"]

    enum CodingKeys: String, CodingKey {
        case id, kind, name, version, summary, symbol, platforms, main, exec, permissions, requires, author, repo
        case hostAPI = "host_api"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .app
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        platforms = try c.decodeIfPresent([Platform].self, forKey: .platforms) ?? []
        hostAPI = try c.decode(Int.self, forKey: .hostAPI)
        main = try c.decodeIfPresent(String.self, forKey: .main) ?? "main.js"
        exec = try c.decodeIfPresent(String.self, forKey: .exec)
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? Permissions()
        requires = try c.decodeIfPresent(Requires.self, forKey: .requires)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
    }

    func validate() throws {
        func bad(_ why: String) -> ExtensionError { .badManifest(why) }
        guard id.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil, id.count <= 100 else {
            throw bad("“id” must be reverse DNS in lowercase, like com.example.thing")
        }
        guard (1...40).contains(name.count) else { throw bad("“name” must be 1–40 characters") }
        guard ExtensionVersion(version) != nil else { throw bad("“version” must be numbers with dots, like 1.2.0") }
        if let author, !(1...60).contains(author.count) { throw bad("“author” must be 1–60 characters") }
        if let repo, GitHubRepo(repo) == nil { throw bad("“repo” must be https://github.com/owner/name") }
        guard hostAPI >= 1 else { throw bad("“host_api” must be 1 or more") }
        guard hostAPI <= ExtensionPackage.hostAPI else { throw ExtensionError.newerHost(hostAPI) }
        switch kind {
        case .app:
            guard !platforms.isEmpty else { throw bad("“platforms” names no platform") }
            guard !main.hasPrefix("/"), !main.split(separator: "/").contains(".."), main.hasSuffix(".js") else {
                throw bad("“main” must be a .js file inside the package")
            }
        case .router:
            guard let exec, !exec.isEmpty, !exec.contains("/") else {
                throw bad("a router extension names its program in “exec”, a file name in bin/<target>/")
            }
        }
        for id in requires?.router ?? [] where id.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) == nil {
            throw bad("“requires.router” names “\(id)”, which isn’t an extension id")
        }
        for rule in permissions.network ?? [] where NetworkRule(rule) == nil {
            throw bad("“\(rule)” isn’t a host, *.domain or host:port")
        }
        for path in permissions.files ?? [] where !(path.hasPrefix("/") || path.hasPrefix("~/")) {
            throw bad("“\(path)” must be a full path, or start with ~/")
        }
    }
}

public enum Platform: String, Codable, Sendable {
    case ios, macos

    public static var current: Platform {
        #if os(macOS)
        .macos
        #else
        .ios
        #endif
    }

    public var title: String { self == .ios ? "iPhone and iPad" : "Mac" }
}

/// What an extension may reach. Anything not named here, it can't. An app extension uses
/// `routers`, `network` and `files`; a router extension the rest (docs/extensions.md, "Permissions").
public struct Permissions: Codable, Equatable, Sendable {
    /// What it may read of the routers. Their names and ids come with either.
    public var routers: [RouterField]?
    /// Hosts it may reach over HTTP and WebSocket: "127.0.0.1", "192.168.8.1:9443",
    /// "*.example.com".
    public var network: [String]?
    /// Files it may read, by full path or from the home folder ("~/…"). On the Mac the app's
    /// sandbox must allow them too.
    public var files: [String]?

    // A router extension's.
    /// Hosts or CIDRs on the router's own networks.
    public var lan: [String]?
    /// Hosts out on the internet.
    public var internet: [String]?
    /// A port it accepts connections on, on the LAN only.
    public var listen: Int?
    /// Device nodes: "tty:ttyUSB*", "usb:0403:6001".
    public var devices: [String]?
    /// Router data it reads: system, battery, cellular, wifi, wan, clients.
    public var read: [String]?
    /// Parts of the router it changes.
    public var control: [String]?
    /// Raises alerts, and so notifications.
    public var notify: Bool?
    /// Reads every entity, every other extension's included.
    public var export: Bool?
    /// Reads texts.
    public var sms: Bool?

    public init(routers: [RouterField]? = nil, network: [String]? = nil, files: [String]? = nil) {
        self.routers = routers
        self.network = network
        self.files = files
    }

    public enum RouterField: String, Codable, Sendable {
        /// Level and charging.
        case battery
        /// Model, its code and its symbol.
        case model
    }

    /// What these let it do that `old` didn't, in words: what an update asks for anew.
    public func added(to old: Permissions) -> [String] {
        let before = Set(old.descriptions)
        return descriptions.filter { !before.contains($0) && $0 != "Nothing beyond itself" }
    }

    /// Each permission in words, for the person to agree to before it's installed.
    public var descriptions: [String] {
        var out: [String] = []
        if let routers, !routers.isEmpty {
            let parts = ["names"] + routers.map { $0 == .battery ? "batteries" : "models" }
            out.append("Read your routers’ \(parts.formatted(.list(type: .and)))")
        }
        for rule in network ?? [] {
            out.append(NetworkRule(rule)?.isLoopback == true ? "Connect to other apps on this device (\(rule))"
                                                            : "Connect to \(rule)")
        }
        for path in files ?? [] { out.append("Read \(path)") }
        if let read, !read.isEmpty { out.append("Read the router’s \(read.formatted(.list(type: .and)))") }
        if let control, !control.isEmpty { out.append("Change the router’s \(control.formatted(.list(type: .and)))") }
        for host in lan ?? [] { out.append("Connect to \(host) on the router’s network") }
        for host in internet ?? [] { out.append("Connect to \(host) on the internet") }
        if let listen { out.append("Accept connections on port \(listen), on the router’s network") }
        for device in devices ?? [] { out.append("Use \(device) plugged into the router") }
        if notify == true { out.append("Send you alerts") }
        if export == true { out.append("See everything GL-Link knows") }
        if sms == true { out.append("Read your texts") }
        if out.isEmpty { out.append("Nothing beyond itself") }
        return out
    }
}

/// One `network` entry: a host, or "*." and a domain, with a port or any.
struct NetworkRule: Equatable, Sendable {
    var host: String
    var wildcard: Bool
    var port: Int?

    init?(_ text: String) {
        var rest = Substring(text.lowercased())
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), !rest.hasPrefix("[") {
            guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
            rest = rest[..<colon]
        }
        wildcard = rest.hasPrefix("*.")
        if wildcard { rest = rest.dropFirst(2) }
        guard !rest.isEmpty, rest.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        host = String(rest)
        self.port = port
    }

    var isLoopback: Bool { host == "127.0.0.1" || host == "localhost" }

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
              let h = url.host?.lowercased() else { return false }
        let hostOK = wildcard ? h.hasSuffix("." + host) : h == host
        guard hostOK else { return false }
        guard let port else { return true }
        let defaultPort = ["http": 80, "ws": 80, "https": 443, "wss": 443][scheme]
        return (url.port ?? defaultPort) == port
    }
}

public enum ExtensionError: LocalizedError, Equatable {
    case notAPackage
    case noManifest
    case badManifest(String)
    case noScript(String)
    case newerHost(Int)
    case notForThisPlatform([Platform])
    /// A router extension, opened in the app.
    case routerExtension(String)
    /// A file a package may not hold, and why.
    case badFile(String, String)
    case tooLarge
    /// It's signed, and its files aren't what was signed.
    case badSignature(String)
    /// A `.glext` that can't be unpacked.
    case badArchive(String)
    /// An update signed by someone other than the installed copy's publisher.
    case otherPublisher(String)
    case catalog(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage: "That isn’t a GL-Link extension (a .ext package)."
        case .noManifest: "The extension has no manifest.json."
        case .badManifest(let why): "The extension’s manifest is wrong: \(why)."
        case .noScript(let main): "The extension’s script, \(main), is missing."
        case .newerHost: "This extension needs a newer GL-Link."
        case .notForThisPlatform(let p): "This extension is for the \(p.map(\.title).formatted(.list(type: .or)))."
        case .badFile(let path, let why): "The extension can’t hold “\(path)”: \(why)."
        case .tooLarge: "The extension is too large: more than 16 MB, or more than 2,000 files."
        case .badSignature(let why): "The extension was changed after it was signed: \(why)."
        case .badArchive(let why): "That file isn’t a packed GL-Link extension: \(why)."
        case .otherPublisher(let name):
            "This “\(name)” isn’t from the publisher of the one installed. If you trust it, remove the installed one first, then install this."
        case .catalog(let why): "The extension catalog can’t be used: \(why)."
        case .routerExtension(let name):
            "“\(name)” is a router extension: it runs on a router, and every device paired with that router shows it. It isn’t installed in the app; see a router’s Extensions page in Settings."
        }
    }
}
