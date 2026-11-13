import XCTest
@testable import GLLinkExtensionKit
import GLLinkExtensionTesting

/// A package in a temporary folder.
func makePackage(_ manifest: [String: Any], script: String = "", name: String = "Test.ext") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
    try script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    return dir
}

func manifest(_ permissions: [String: Any] = [:], platforms: [String] = ["ios", "macos"]) -> [String: Any] {
    ["id": "com.example.test", "name": "Test", "version": "1.0", "summary": "A test.",
     "platforms": platforms, "host_api": 1, "permissions": permissions]
}

// MARK: - Packages

final class PackageTests: XCTestCase {
    func testReadsAValidPackage() throws {
        let p = try ExtensionPackage(at: makePackage(manifest(["routers": ["battery"], "network": ["127.0.0.1"]])))
        XCTAssertEqual(p.manifest.id, "com.example.test")
        XCTAssertEqual(p.manifest.main, "main.js")
        XCTAssertEqual(p.manifest.permissions.routers, [.battery])
        XCTAssertTrue(p.runsHere)
    }

    func testRefusesBadPackages() throws {
        func error(_ m: [String: Any], name: String = "Test.ext") -> ExtensionError? {
            do { _ = try ExtensionPackage(at: makePackage(m, name: name)); return nil } catch { return error as? ExtensionError }
        }
        XCTAssertEqual(error(manifest(), name: "Test.zip"), .notAPackage)
        var m = manifest(); m["id"] = "Not DNS"
        XCTAssertNotNil(error(m))
        m = manifest(); m["host_api"] = 99
        XCTAssertEqual(error(m), .newerHost(99))
        m = manifest(); m["main"] = "../escape.js"
        XCTAssertNotNil(error(m))
        XCTAssertNotNil(error(manifest(["network": ["http://not a host"]])))
        XCTAssertNotNil(error(manifest(["files": ["relative/path"]])))
    }

    func testKinds() throws {
        // Before kinds were named, every package was an app extension.
        XCTAssertEqual(try ExtensionPackage(at: makePackage(manifest())).manifest.kind, .app)

        var router: [String: Any] = ["id": "com.example.dish", "kind": "router", "name": "Dish", "version": "1.0",
                                     "host_api": 1, "exec": "dish",
                                     "permissions": ["lan": ["192.168.100.1:9200"], "notify": true]]
        let p = try ExtensionPackage(at: makePackage(router))
        XCTAssertEqual(p.manifest.kind, .router)
        XCTAssertFalse(p.runsHere, "a router extension never runs in the app")
        XCTAssertEqual(p.manifest.permissions.descriptions,
                       ["Connect to 192.168.100.1:9200 on the router’s network", "Send you alerts"])
        router["exec"] = nil
        XCTAssertThrowsError(try ExtensionPackage(at: makePackage(router)), "a router extension names its program")

        var app = manifest()
        app["requires"] = ["router": ["com.example.dish"]]
        XCTAssertEqual(try ExtensionPackage(at: makePackage(app)).manifest.requires?.router, ["com.example.dish"])
        app["requires"] = ["router": ["Not An Id"]]
        XCTAssertThrowsError(try ExtensionPackage(at: makePackage(app)))
    }

    func testNetworkRules() {
        let loop = NetworkRule("127.0.0.1")!
        XCTAssertTrue(loop.allows(URL(string: "http://127.0.0.1:48620/v1/health")!))
        XCTAssertTrue(loop.allows(URL(string: "ws://127.0.0.1:48621")!))
        XCTAssertFalse(loop.allows(URL(string: "http://127.0.0.2/")!))
        XCTAssertFalse(loop.allows(URL(string: "file:///etc/passwd")!))
        let port = NetworkRule("192.168.8.1:9443")!
        XCTAssertTrue(port.allows(URL(string: "https://192.168.8.1:9443/v1")!))
        XCTAssertFalse(port.allows(URL(string: "https://192.168.8.1/v1")!))
        let wild = NetworkRule("*.example.com")!
        XCTAssertTrue(wild.allows(URL(string: "https://api.example.com/")!))
        XCTAssertFalse(wild.allows(URL(string: "https://example.com.evil.net/")!))
    }
}

// MARK: - The runtime

@MainActor
final class RuntimeTests: XCTestCase {
    func testScriptSeesOnlyWhatItAskedFor() async throws {
        let script = """
        const r = gllink.routers();
        gllink.status(`${r.length} ${r[0].name} ${r[0].battery ? r[0].battery.level : "none"} ${r[0].model ? "model" : "no model"}`);
        fetch("https://example.com/").then(() => console.log("fetched"), (e) => console.log("refused"));
        setTimeout(() => gllink.show([{ title: "Later", value: "yes" }]), 30);
        gllink.secrets.set("token", "t1");
        """
        let context = FakeContext()
        context.routers = [RouterInfo(id: UUID(), name: "Mudi 7",
                                      model: RouterModel(id: "e5800", code: "GL-E5800", name: "Mudi 7", symbol: nil),
                                      battery: BatteryReading(level: 85, charging: true), updated: Date())]
        let network = FakeNetwork(http: { _ in (200, "{}") })
        let ext = ScriptExtension(package: try ExtensionPackage(at: makePackage(manifest(["routers": ["battery"]]), script: script)),
                                  context: context, network: network)
        ext.start()
        XCTAssertEqual(ext.status, "1 Mudi 7 85 no model")
        try await eventually("the timer") { ext.rows == [.init(title: "Later", value: "yes")] }
        try await eventually("the refusal") { ext.log.contains("refused") }
        XCTAssertTrue(network.requests.isEmpty, "a host outside the manifest is never reached")
        XCTAssertEqual(context.secrets, ["token": "t1"])

        ext.stop()
        XCTAssertFalse(ext.isRunning)
        XCTAssertEqual(ext.status, "Off")
        XCTAssertEqual(ext.rows, [])
    }

    func testStoppingCancelsTimers() async throws {
        let script = "let n = 0; setInterval(() => { n++; gllink.status(String(n)); }, 10);"
        let ext = ScriptExtension(package: try ExtensionPackage(at: makePackage(manifest(), script: script)),
                                  context: FakeContext(), network: FakeNetwork(http: { _ in (200, "") }))
        ext.start()
        try await eventually("ticks") { Int(ext.status) ?? 0 >= 2 }
        ext.stop()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ext.status, "Off")
        // Started again, it starts from nothing.
        ext.start()
        try await eventually("ticks again") { Int(ext.status) ?? 0 >= 1 }
        ext.stop()
    }

    func testResourcesStayInsideThePackage() throws {
        let url = try makePackage(manifest(), script: """
        gllink.status([gllink.resource("data.txt"), gllink.resource("data.txt", "base64"),
                       gllink.resource("../Test.ext/data.txt"), gllink.resource("/etc/hosts"),
                       gllink.resource("../../escape.txt")].map(String).join("|"));
        gllink.actions([{ id: "go", title: "Go", role: "destructive" }, { title: "No id" }]);
        """)
        try "hi".write(to: url.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "out".write(to: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escape.txt"),
                        atomically: true, encoding: .utf8)
        let ext = ScriptExtension(package: try ExtensionPackage(at: url), context: FakeContext(),
                                  network: FakeNetwork(http: { _ in (200, "") }))
        ext.start()
        XCTAssertEqual(ext.status, "hi|aGk=|hi|null|null")
        XCTAssertEqual(ext.actions, [.init(id: "go", title: "Go", destructive: true, confirm: nil)])
        ext.stop()
    }

    func testDoesNotRunARouterExtension() throws {
        let p = try ExtensionPackage(at: makePackage(["id": "com.example.dish", "kind": "router", "name": "Dish",
                                                      "version": "1.0", "host_api": 1, "exec": "dish"],
                                                     script: "gllink.status('ran')"))
        let ext = ScriptExtension(package: p, context: FakeContext(), network: FakeNetwork(http: { _ in (200, "") }))
        ext.start()
        XCTAssertFalse(ext.isRunning)
        XCTAssertTrue(ext.status.contains("router extension"))
    }

    func testRefusesAnotherPlatformsPackage() throws {
        let other = Platform.current == .macos ? "ios" : "macos"
        let ext = ScriptExtension(package: try ExtensionPackage(at: makePackage(manifest(platforms: [other]), script: "gllink.status('ran')")),
                                  context: FakeContext(), network: FakeNetwork(http: { _ in (200, "") }))
        ext.start()
        XCTAssertFalse(ext.isRunning)
        XCTAssertNotEqual(ext.status, "ran")
    }
}

/// The quick start in docs/writing-extensions.md, as it's printed there.
@MainActor
final class HelloTests: XCTestCase {
    func testTheQuickStartRuns() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extensions/Hello.ext")
        let context = FakeContext()
        context.routers = [
            RouterInfo(id: UUID(), name: "Mudi 7", model: nil, battery: BatteryReading(level: 85, charging: true), updated: Date()),
            RouterInfo(id: UUID(), name: "Flint 4", model: nil, battery: nil, updated: Date()),
        ]
        let ext = ScriptExtension(package: try ExtensionPackage(at: url), context: context,
                                  network: FakeNetwork(http: { _ in (404, "") }))
        ext.start()
        XCTAssertEqual(ext.status, "Watching 1 battery.")
        XCTAssertEqual(ext.rows, [.init(title: "Mudi 7", value: "85% ⚡︎")])

        context.routers[0].battery = BatteryReading(level: 84, charging: false)
        ext.routersChanged()
        XCTAssertEqual(ext.rows, [.init(title: "Mudi 7", value: "84%")])

        ext.perform(try XCTUnwrap(ext.actions.first { $0.id == "read" }))
        try await eventually("read again") { context.refreshes == 1 && ext.status == "Watching 1 battery." }
        ext.stop()
    }
}
