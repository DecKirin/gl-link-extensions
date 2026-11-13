import Foundation
import GLLinkExtensionKit

// `gllink-ext run`: an extension's script in the app's own runtime (`ScriptExtension`), with
// sample routers in place of paired ones. Its network and files are real, and held to the
// manifest as in the app; its secrets last only as long as the run.

@MainActor
final class SampleContext: ExtensionContext {
    var routers: [RouterInfo]
    private var secrets: [String: String] = [:]

    init(routers: [RouterInfo]) { self.routers = routers }

    func refresh() async {
        routers = routers.map { var r = $0; r.updated = Date(); return r }
    }

    func loadSecrets() -> [String: String] { secrets }
    func saveSecrets(_ secrets: [String: String]) { self.secrets = secrets }

    static let sample = [
        RouterInfo(id: UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001")!, name: "Mudi 7",
                   model: RouterModel(id: "e5800", code: "GL-E5800", name: "Mudi 7", symbol: "router.e5800"),
                   battery: BatteryReading(level: 85, charging: true), updated: Date()),
        RouterInfo(id: UUID(uuidString: "6F1C0000-0000-4000-8000-000000000002")!, name: "Home",
                   model: RouterModel(id: "be14000", code: "GL-BE14000", name: "Flint 4", symbol: "router.be14000"),
                   battery: nil, updated: Date()),
    ]

    /// `[{"name": "Mudi 7", "battery": {"level": 85, "charging": true},
    ///    "model": {"id": "e5800", "code": "GL-E5800", "name": "Mudi 7", "symbol": "router.e5800"}}]`
    static func read(_ url: URL) throws -> [RouterInfo] {
        guard let list = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
            throw Failure(message: "\(url.lastPathComponent) must be a list of routers")
        }
        return list.enumerated().map { i, o in
            let battery = (o["battery"] as? [String: Any]).map {
                BatteryReading(level: $0["level"] as? Int ?? 0, charging: $0["charging"] as? Bool ?? false)
            }
            let model = (o["model"] as? [String: Any]).map {
                RouterModel(id: $0["id"] as? String ?? "", code: $0["code"] as? String ?? "",
                            name: $0["name"] as? String ?? "", symbol: $0["symbol"] as? String)
            }
            return RouterInfo(id: UUID(uuidString: String(format: "6F1C0000-0000-4000-8000-%012d", i + 1))!,
                              name: o["name"] as? String ?? "Router \(i + 1)", model: model, battery: battery, updated: Date())
        }
    }
}

@MainActor
func runScript() throws {
    let routersFile = option("--routers")
    let package = try loadPackage(next("package"))
    guard package.manifest.kind == .app else {
        throw Failure(message: "“\(package.manifest.name)” is a router extension; `run` runs app extensions")
    }
    guard package.runsHere else {
        throw Failure(message: "“\(package.manifest.name)” is for the \(package.manifest.platforms.map(\.title).joined(separator: " and ")); `run` runs on a Mac")
    }
    let context = SampleContext(routers: try routersFile.map { try SampleContext.read(fileURL($0)) } ?? SampleContext.sample)
    let ext = ScriptExtension(package: package, context: context)
    describe(package)
    note("Running. a <id> taps an action · r sends “routers” again · q quits.\n")

    var shown = (status: "", rows: [ScriptExtension.Row](), actions: [ScriptExtension.Action](), log: 0)
    func report() {
        if ext.log.count < shown.log { shown.log = 0 }
        for line in ext.log.dropFirst(shown.log) { note("log      \(line)") }
        shown.log = ext.log.count
        if ext.status != shown.status {
            shown.status = ext.status
            note("status   \(ext.status)")
        }
        if ext.rows != shown.rows {
            shown.rows = ext.rows
            for row in ext.rows { note("row      \(row.title): \(row.value)") }
            if ext.rows.isEmpty { note("row      (none)") }
        }
        if ext.actions != shown.actions {
            shown.actions = ext.actions
            for a in ext.actions { note("action   \(a.id): \(a.title)\(a.confirm.map { "  (asks: \($0))" } ?? "")") }
        }
    }

    ext.start()
    report()
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { report() } }
    RunLoop.main.add(timer, forMode: .common)

    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if data.isEmpty { handle.readabilityHandler = nil; return }
                for line in lines {
                    let words = line.split(separator: " ", maxSplits: 1).map(String.init)
                    switch words.first {
                    case "q", "quit":
                        ext.stop()
                        report()
                        exit(0)
                    case "r":
                        context.routers = context.routers.map { var r = $0; r.updated = Date(); return r }
                        ext.routersChanged()
                    case "a":
                        if let action = ext.actions.first(where: { $0.id == words.last }) {
                            ext.perform(action)
                        } else {
                            note("no action “\(words.count > 1 ? words[1] : "")”")
                        }
                    default: break
                    }
                }
            }
        }
    }
    RunLoop.main.run()
}
