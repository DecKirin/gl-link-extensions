import Foundation
import GLLinkExtensionKit

// gllink-ext: the tool for writing GL-Link extensions (docs/writing-extensions.md).
// It checks, signs and runs packages with the code the app itself uses.

let usage = """
gllink-ext: write, check, run, sign and share GL-Link extensions

  new <Name> [--id com.you.name] [--platforms ios,macos]
        A new extension, Name.ext, that already runs.
  check <Name.ext | file.glext>
        What GL-Link would say about it, and what you'd want to know before sharing.
  run <Name.ext> [--routers routers.json]
        Run its script here, in GL-Link's own runtime, against sample routers.
        While it runs:  a <id> taps an action · r sends "routers" again · q quits.
  keygen
        Make your publisher key (kept in ~/.gllink-ext/key; never share it).
  key
        Show your public key and its fingerprint.
  build <Name.ext> [-o folder] [--unsigned]
        Sign and pack it into one file: Name-1.0.0.glext.
  verify <Name.ext | file.glext> [--publisher <public key>]
        Whether it's whole, and who signed it.
  install <Name.ext | file.glext>
        Open it in GL-Link on this Mac, which asks before installing.
  publish <Name.ext> [--repo https://github.com/you/repo] [-o folder] [--dry-run]
        Build it, attach it to a GitHub release (needs gh), and write its marketplace entry.
  market check <entries folder | entry.json> [--previous folder] [--offline]
        Check marketplace entries: each one's download, SHA-256, publisher and manifest.
  market index <entries folder> [-o folder]
        Write index.json, and index.json.sig with the marketplace key.
  types
        Print gllink.d.ts, the script API for editors.

Keys: --key <file> on any command, or GLLINK_EXT_KEY (the key itself), in place of ~/.gllink-ext/key.
"""

struct Failure: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gllink-ext: \(message)\n".utf8))
    exit(1)
}

func note(_ text: String) { print(text) }

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())

/// Takes `--name value` out of the arguments.
func option(_ names: String...) -> String? {
    guard let i = arguments.firstIndex(where: names.contains) else { return nil }
    guard i + 1 < arguments.count else { fail("\(arguments[i]) needs a value") }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

func next(_ what: String) -> String {
    guard !arguments.isEmpty else { fail("which \(what)? See `gllink-ext help`.") }
    return arguments.removeFirst()
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

// MARK: - Keys

let keyOption = option("--key")
let defaultKeyURL = fileURL("~/.gllink-ext/key")

func loadKey() -> ExtensionSigningKey? {
    if let keyOption {
        guard let text = try? String(contentsOf: fileURL(keyOption), encoding: .utf8), let key = ExtensionSigningKey(text) else {
            fail("\(keyOption) isn’t a key made by `gllink-ext keygen`")
        }
        return key
    }
    if let text = ProcessInfo.processInfo.environment["GLLINK_EXT_KEY"], !text.isEmpty {
        guard let key = ExtensionSigningKey(text) else { fail("GLLINK_EXT_KEY isn’t a key made by `gllink-ext keygen`") }
        return key
    }
    guard let text = try? String(contentsOf: defaultKeyURL, encoding: .utf8) else { return nil }
    guard let key = ExtensionSigningKey(text) else { fail("\(defaultKeyURL.path) isn’t a key made by `gllink-ext keygen`") }
    return key
}

func requireKey() -> ExtensionSigningKey {
    guard let key = loadKey() else { fail("no publisher key yet: run `gllink-ext keygen`") }
    return key
}

// MARK: - Packages

/// A package from a folder or a `.glext`; the second is unpacked into `scratch`.
func loadPackage(_ path: String) throws -> ExtensionPackage {
    var url = fileURL(path)
    if url.pathExtension == ExtensionArchive.pathExtension {
        return try ExtensionArchive.unpack(try Data(contentsOf: url), into: scratch())
    }
    // `gllink-ext check .` inside the package.
    if url.pathExtension != ExtensionPackage.pathExtension, url.lastPathComponent == "." || path == "." {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
    return try ExtensionPackage(at: url)
}

func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gllink-ext-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func describe(_ package: ExtensionPackage) {
    let m = package.manifest
    note("\(m.name) \(m.version)  (\(m.id))")
    note("  \(m.kind.title)" + (m.platforms.isEmpty ? "" : " for the \(m.platforms.map(\.title).joined(separator: " and "))"))
    note("  Can:")
    for line in m.permissions.descriptions { note("    • \(line)") }
    switch package.signature {
    case .unsigned: note("  Not signed.")
    case .signed(let key): note("  Signed by \(key.fingerprint)  (\(key.text))")
    }
}

func fileName(_ m: ExtensionManifest) -> String {
    let name = m.name.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "\(name.isEmpty ? "Extension" : name)-\(m.version).\(ExtensionArchive.pathExtension)"
}

/// Signs a copy of the package (the source stays as it is) and packs it.
func build(_ source: ExtensionPackage, key: ExtensionSigningKey?) throws -> (package: ExtensionPackage, archive: Data) {
    let stage = scratch().appendingPathComponent(source.url.lastPathComponent, isDirectory: true)
    var copy = try source.copy(to: stage)
    if let key {
        copy = try copy.signed(with: key)
    } else {
        try? FileManager.default.removeItem(at: stage.appendingPathComponent(ExtensionPackage.signatureFile))
        copy = try ExtensionPackage(at: stage)
    }
    return (copy, try ExtensionArchive.pack(copy))
}

func download(_ url: URL) throws -> Data {
    var result: Result<Data, Error> = .failure(Failure(message: "no answer"))
    let done = DispatchSemaphore(value: 0)
    // No credentials: what can't be fetched this way isn't public.
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: url) { data, response, error in
        if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
            result = .success(data)
        } else {
            let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" }
            result = .failure(Failure(message: error?.localizedDescription ?? status ?? "no answer"))
        }
        done.signal()
    }.resume()
    done.wait()
    return try result.get()
}

@discardableResult
func shell(_ tool: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    do { try process.run() } catch { return 127 }
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - Commands

func run() throws {
    let command = arguments.isEmpty ? "help" : arguments.removeFirst()
    switch command {
    case "help", "-h", "--help":
        note(usage)

    case "types":
        print(Templates.types, terminator: "")

    case "new":
        let name = next("name")
        guard (1...40).contains(name.count), name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 -]*$"#, options: .regularExpression) != nil else {
            fail("a name is 1–40 letters, digits, spaces and hyphens")
        }
        let slug = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        let id = option("--id") ?? "com.example.\(slug)"
        let platforms = (option("--platforms") ?? "ios,macos").split(separator: ",").map(String.init)
        let folder = fileURL(name.replacingOccurrences(of: " ", with: "") + ".ext")
        guard !FileManager.default.fileExists(atPath: folder.path) else { fail("\(folder.lastPathComponent) is already there") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = ["manifest.json": Templates.manifest(id: id, name: name, platforms: platforms),
                     "main.js": Templates.script, "gllink.d.ts": Templates.types, "jsconfig.json": Templates.jsconfig,
                     "README.md": Templates.readme.replacingOccurrences(of: "NAME", with: name.replacingOccurrences(of: " ", with: ""))]
        for (file, text) in files { try text.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        _ = try ExtensionPackage(at: folder)
        note("Made \(folder.lastPathComponent). Next:")
        note("  gllink-ext run \(folder.lastPathComponent)        run it here")
        note("  gllink-ext install \(folder.lastPathComponent)    open it in GL-Link")

    case "check":
        let package = try loadPackage(next("package"))
        describe(package)
        let lint = ExtensionLint(package)
        for warning in lint.warnings { note("  warning: \(warning)") }
        note(lint.warnings.isEmpty ? "OK." : "OK, with \(lint.warnings.count) warning\(lint.warnings.count == 1 ? "" : "s").")

    case "keygen":
        let url = keyOption.map(fileURL) ?? defaultKeyURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            fail("\(url.path) is already there. It’s the only way to update what you’ve published: keep it.")
        }
        let key = ExtensionSigningKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: Data((key.text + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else { fail("couldn’t write \(url.path)") }
        note("Your publisher key is in \(url.path). Back it up, and never share it:")
        note("whoever has it can publish updates to your extensions.")
        note("Public key:   \(key.publicKey.text)")
        note("Fingerprint:  \(key.publicKey.fingerprint)")

    case "key":
        let key = requireKey()
        note("Public key:   \(key.publicKey.text)")
        note("Fingerprint:  \(key.publicKey.fingerprint)")

    case "build":
        let unsigned = flag("--unsigned")
        let out = option("-o", "--out").map(fileURL)
        let source = try loadPackage(next("package"))
        let built = try build(source, key: unsigned ? nil : requireKey())
        for warning in ExtensionLint(source).warnings { note("warning: \(warning)") }
        let folder = out ?? source.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(built.package.manifest))
        try built.archive.write(to: file)
        note("\(file.path)")
        note("  \(built.archive.count) bytes · SHA-256 \(ExtensionPackage.sha256(built.archive))")
        note(built.package.signature.key.map { "  Signed by \($0.fingerprint)" } ?? "  Not signed.")

    case "verify":
        let expected = option("--publisher")
        let package = try loadPackage(next("package"))
        describe(package)
        if let expected {
            guard let key = ExtensionPublicKey(expected) else { fail("--publisher takes a public key") }
            guard package.signature == .signed(key) else { fail("it isn’t signed by that key") }
            note("Signed by that key.")
        } else if package.signature == .unsigned {
            fail("it isn’t signed")
        }

    case "install":
        let source = try loadPackage(next("package"))
        let built = try build(source, key: loadKey())
        // Kept where GL-Link can read it after this tool has gone.
        let file = scratch().appendingPathComponent(fileName(built.package.manifest))
        try built.archive.write(to: file)
        guard shell("open", [file.path]) == 0 else {
            fail("couldn’t open \(file.path). Is GL-Link installed on this Mac? Open the file with it by hand.")
        }
        note("Opened \(file.lastPathComponent) in GL-Link, which asks before installing it.")

    case "publish":
        let dry = flag("--dry-run")
        let out = option("-o", "--out").map(fileURL)
        let repoOption = option("--repo")
        let source = try loadPackage(next("package"))
        let built = try build(source, key: requireKey())
        let m = built.package.manifest
        guard let repoText = m.repo else {
            fail("the manifest needs “repo”: \"https://github.com/you/repo\". A shared extension’s source is public on GitHub.")
        }
        if let repoOption, repoOption != repoText { fail("--repo and the manifest’s “repo” differ; the manifest’s is what’s signed") }
        guard let repo = GitHubRepo(repoText) else { fail("“repo” must be https://github.com/owner/name") }
        let folder = out ?? source.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(m))
        // "Hello-1.0.0": the extension's name is in the tag, so one repository can hold several.
        let tag = file.deletingPathExtension().lastPathComponent
        try built.archive.write(to: file)
        let entry = try CatalogEntry(package: built.package, archive: built.archive, download: repo.downloads + "\(tag)/\(file.lastPathComponent)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let entryFile = folder.appendingPathComponent("\(m.id).json")
        try (encoder.encode(entry) + Data("\n".utf8)).write(to: entryFile)
        note("Built \(file.path)")
        if dry {
            note("Dry run: not released. To release it yourself:")
            note("  gh release create \(tag) '\(file.path)' --repo \(repo.owner)/\(repo.name) --title '\(m.name) \(m.version)'")
        } else {
            let status = shell("gh", ["release", "create", tag, file.path, "--repo", "\(repo.owner)/\(repo.name)",
                                      "--title", "\(m.name) \(m.version)", "--notes", m.summary])
            guard status == 0 else {
                fail(status == 127 ? "publishing needs GitHub’s gh (brew install gh). The entry is in \(entryFile.path)."
                                   : "gh couldn’t make release \(tag) in \(repo.url). The entry is in \(entryFile.path).")
            }
            note("Released \(tag) in \(repo.url).")
        }
        note("Marketplace entry: \(entryFile.path)")
        note("To list it, open a pull request that adds it as entries/\(m.id).json to")
        note("  https://github.com/DecKirin/gl-link-extensions")

    case "market":
        try market()

    default:
        fail("there’s no “\(command)”. See `gllink-ext help`.")
    }
}

func entries(in path: String) throws -> [(file: URL, entry: CatalogEntry)] {
    let url = fileURL(path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { fail("\(path) isn’t there") }
    let files = isDir.boolValue
        ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        : [url]
    return try files.map { file in
        do {
            let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(contentsOf: file))
            try entry.validate()
            guard file.lastPathComponent == "\(entry.id).json" else {
                throw Failure(message: "must be named \(entry.id).json")
            }
            return (file, entry)
        } catch let error as Failure {
            throw Failure(message: "\(file.lastPathComponent): \(error.message)")
        } catch {
            throw Failure(message: "\(file.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }
}

func market() throws {
    switch next("market command: check or index") {
    case "check":
        let offline = flag("--offline")
        let previous = try option("--previous").map { try entries(in: $0) } ?? []
        let list = try entries(in: next("entries folder"))
        var failed = 0
        for (file, entry) in list {
            do {
                // A publisher's key stays: whoever takes over an id can't ship as them.
                if let old = previous.first(where: { $0.entry.id == entry.id }), old.entry.key != entry.key {
                    throw Failure(message: "its publisher key changed (was \(old.entry.key.fingerprint)); a maintainer must agree to that")
                }
                if let old = previous.first(where: { $0.entry.id == entry.id }), !entry.isNewer(than: old.entry.version),
                   old.entry != entry {
                    throw Failure(message: "changed without a newer version than \(old.entry.version)")
                }
                if !offline {
                    let archive = try download(entry.downloadURL)
                    try entry.check(archive, package: try ExtensionArchive.inspect(archive))
                }
                note("ok      \(file.lastPathComponent)  \(entry.name) \(entry.version) by \(entry.author)")
            } catch {
                failed += 1
                let why = (error as? Failure)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
                note("FAILED  \(file.lastPathComponent)  \(why)")
            }
        }
        if failed > 0 { fail("\(failed) of \(list.count) entries failed") }
        note("\(list.count) entr\(list.count == 1 ? "y" : "ies") OK\(offline ? " (downloads not checked)" : "").")

    case "index":
        let out = option("-o", "--out").map(fileURL)
        let source = next("entries folder")
        let list = try entries(in: source).map(\.entry)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard Set(list.map(\.id)).count == list.count else { fail("two entries share an id") }
        let key = requireKey()
        let data = try Catalog(updated: ISO8601DateFormatter().string(from: Date()), extensions: list).encoded()
        let folder = out ?? fileURL(source).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("index.json"))
        try Data((key.sign(data).base64EncodedString() + "\n").utf8).write(to: folder.appendingPathComponent("index.json.sig"))
        note("Wrote index.json (\(list.count) extensions) and index.json.sig in \(folder.path)")
        note("Signed by \(key.publicKey.fingerprint)  (\(key.publicKey.text))")
        if let app = Catalog.marketplaceKey, app != key.publicKey {
            note("warning: that isn’t the marketplace key GL-Link carries (\(app.fingerprint)); the app will refuse this index")
        }

    default:
        fail("market has check and index. See `gllink-ext help`.")
    }
}

do {
    if arguments.first == "run" {
        arguments.removeFirst()
        try MainActor.assumeIsolated { try runScript() }
    } else {
        try run()
    }
} catch let error as Failure {
    fail(error.message)
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}
