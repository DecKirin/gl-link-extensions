import XCTest
@testable import GLLinkExtensionKit

// MARK: - Fakes

@MainActor
final class FakeContext: ExtensionContext {
    var routers: [RouterInfo] = []
    var refreshes = 0
    var secrets: [String: String] = [:]

    func refresh() async { refreshes += 1 }
    func loadSecrets() -> [String: String] { secrets }
    func saveSecrets(_ secrets: [String: String]) { self.secrets = secrets }
}

/// Answers HTTP from a closure, and hands out sockets that record what's sent and answer
/// through `reply`.
final class FakeNetwork: ExtensionNetwork, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var sockets: [FakeSocket] = []
    let http: @Sendable (URLRequest) -> (Int, String)
    let reply: @Sendable ([String: Any]) -> [String]

    init(http: @escaping @Sendable (URLRequest) -> (Int, String),
         reply: @escaping @Sendable ([String: Any]) -> [String] = { _ in [] }) {
        self.http = http
        self.reply = reply
    }

    func fetch(_ request: URLRequest, allows: @escaping @Sendable (URL) -> Bool) async throws -> (Int, Data) {
        lock.withLock { requests.append(request) }
        let (status, body) = http(request)
        return (status, Data(body.utf8))
    }

    func socket(_ url: URL, allows: @escaping @Sendable (URL) -> Bool) -> any ExtensionSocket {
        let s = FakeSocket(url: url, reply: reply)
        lock.withLock { sockets.append(s) }
        return s
    }
}

final class FakeSocket: ExtensionSocket, @unchecked Sendable {
    let url: URL
    let reply: @Sendable ([String: Any]) -> [String]
    private let lock = NSLock()
    private var _sent: [[String: Any]] = []
    private(set) var isClosed = false
    private var incoming: AsyncThrowingStream<String, Error>.AsyncIterator
    private let input: AsyncThrowingStream<String, Error>.Continuation

    init(url: URL, reply: @escaping @Sendable ([String: Any]) -> [String]) {
        self.url = url
        self.reply = reply
        let (stream, input) = AsyncThrowingStream<String, Error>.makeStream()
        self.input = input
        incoming = stream.makeAsyncIterator()
    }

    var sent: [[String: Any]] { lock.withLock { _sent } }

    func send(_ text: String) async throws {
        let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        lock.withLock { _sent.append(message) }
        for answer in reply(message) { input.yield(answer) }
    }

    func receive() async throws -> String {
        guard let next = try await incoming.next() else { throw URLError(.networkConnectionLost) }
        return next
    }

    func close() {
        lock.withLock { isClosed = true }
        input.finish(throwing: URLError(.networkConnectionLost))
    }
}

@MainActor
func eventually(_ what: String, timeout: Double = 3, _ check: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !check() {
        if Date() > end { XCTFail("timed out waiting for \(what)"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

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

// MARK: - GlassyBattery.ext

/// The real package in extensions/, against a fake BatteryBridge.
@MainActor
final class GlassyBatteryTests: XCTestCase {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("extensions/GlassyBattery.ext")

    /// A BatteryBridge that hands out a new token on each registration, and has custom icons
    /// or not.
    static func bridge(icons: Bool) -> FakeNetwork {
        let registrations = Counter()
        return FakeNetwork(http: { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case (_, "/v1/health"): return (200, #"{"api":1,"app":"GlassyBattery","version":"test"}"#)
            case ("POST", "/v1/register"):
                return (201, #"{"clientID":"c1","status":"active","token":"gbb_\#(registrations.next())"}"#)
            case ("PUT", let path) where path.hasPrefix("/v1/icons/") && icons:
                return (200, #"{"icon":{"name":"x","format":"svg","bytes":1}}"#)
            default: return (404, #"{"error":{"code":"no_such_route","message":"Unknown endpoint"}}"#)
            }
        }, reply: { message in
            switch message["op"] as? String {
            case "hello": [#"{"event":"ready","client":{}}"#]
            case "upsert": [#"{"event":"ack","ref":"\#(message["ref"] ?? "")"}"#]
            default: []
            }
        })
    }

    static func routers() -> (FakeContext, UUID) {
        let mudi = UUID()
        let context = FakeContext()
        context.routers = [
            RouterInfo(id: mudi, name: "Mudi 7",
                       model: RouterModel(id: "e5800", code: "GL-E5800", name: "Mudi 7", symbol: "router.e5800"),
                       battery: BatteryReading(level: 85, charging: true), updated: Date()),
            RouterInfo(id: UUID(), name: "Home",
                       model: RouterModel(id: "be14000", code: "GL-BE14000", name: "Flint 4", symbol: "router.be14000"),
                       battery: nil, updated: Date()),
        ]
        return (context, mudi)
    }

    static func upserts(_ socket: FakeSocket) -> [[String: Any]] {
        socket.sent.filter { $0["op"] as? String == "upsert" }.compactMap { $0["device"] as? [String: Any] }
    }

    func testListsRoutersWithTheirModelsIcon() async throws {
        let network = Self.bridge(icons: true)
        let (context, mudi) = Self.routers()
        let ext = ScriptExtension(package: try ExtensionPackage(at: Self.package), context: context, network: network)
        ext.start()

        try await eventually("the router sent with its icon") {
            network.sockets.first.map { Self.upserts($0).contains { $0["customIcon"] != nil } } == true
        }
        let socket = try XCTUnwrap(network.sockets.first)
        XCTAssertEqual(socket.sent[0]["op"] as? String, "hello")
        XCTAssertEqual(socket.sent[0]["token"] as? String, "gbb_1")
        XCTAssertEqual(socket.sent[0]["onDisconnect"] as? String, "remove")
        XCTAssertEqual(context.secrets["token"], "gbb_1")

        // The model's icon, uploaded once, from the package: a plain SVG.
        let puts = network.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.map { $0.url?.path }, ["/v1/icons/router.e5800"], "only the router with a battery")
        XCTAssertEqual(puts.first?.value(forHTTPHeaderField: "Authorization"), "Bearer gbb_1")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(puts.first?.httpBody)) as? [String: String]
        XCTAssertEqual(body?["format"], "svg")
        let svg = String(decoding: try XCTUnwrap(Data(base64Encoded: body?["data"] ?? "")), as: UTF8.self)
        XCTAssertTrue(svg.hasPrefix("<svg"), "the glyph alone, not the symbol template")

        let device = try XCTUnwrap(Self.upserts(socket).last)
        XCTAssertEqual(device["id"] as? String, mudi.uuidString)
        XCTAssertEqual(device["name"] as? String, "Mudi 7")
        XCTAssertEqual(device["type"] as? String, "generic")
        XCTAssertEqual(device["icon"] as? String, "wifi.router.fill")
        XCTAssertEqual(device["customIcon"] as? String, "router.e5800")
        XCTAssertEqual(device["level"] as? Int, 85)
        XCTAssertEqual(device["charging"] as? Bool, true)
        XCTAssertEqual(device["model"] as? String, "GL-E5800")
        XCTAssertTrue(Self.upserts(socket).allSatisfy { $0["id"] as? String == mudi.uuidString }, "the Flint has no battery")
        try await eventually("the status") { ext.status == "Showing Mudi 7 in GlassyBattery." }
        XCTAssertEqual(ext.rows, [.init(title: "Mudi 7", value: "85% ⚡︎")])
        XCTAssertEqual(ext.actions.map(\.id), ["reset"])

        // A new reading goes out; an unchanged one doesn't.
        let before = Self.upserts(socket).count
        context.routers[0].battery = BatteryReading(level: 84, charging: false)
        ext.routersChanged()
        ext.routersChanged()
        try await eventually("the new level") { Self.upserts(socket).count == before + 1 }
        XCTAssertEqual(Self.upserts(socket).last?["level"] as? Int, 84)

        // Called something else: the model's name goes with its code.
        context.routers[0].name = "Travel"
        ext.routersChanged()
        try await eventually("the renamed router") { Self.upserts(socket).last?["name"] as? String == "Travel" }
        XCTAssertEqual(Self.upserts(socket).last?["model"] as? String, "Mudi 7 · GL-E5800")

        // Unpaired: taken out.
        context.routers.removeFirst()
        ext.routersChanged()
        try await eventually("the removal") { socket.sent.last?["op"] as? String == "remove" }
        XCTAssertEqual(socket.sent.last?["id"] as? String, mudi.uuidString)

        // Turned off: the stream closes, which takes everything out of GlassyBattery.
        ext.stop()
        XCTAssertTrue(socket.isClosed)
        XCTAssertEqual(ext.actions, [])
    }

    func testAGlassyBatteryWithoutCustomIconsGetsTheSymbol() async throws {
        let network = Self.bridge(icons: false)
        let (context, _) = Self.routers()
        let ext = ScriptExtension(package: try ExtensionPackage(at: Self.package), context: context, network: network)
        ext.start()
        try await eventually("the router sent") { network.sockets.first.map { !Self.upserts($0).isEmpty } == true }
        let device = try XCTUnwrap(network.sockets.first.flatMap { Self.upserts($0).last })
        XCTAssertEqual(device["icon"] as? String, "wifi.router.fill")
        XCTAssertNil(device["customIcon"])
        ext.stop()
    }

    func testResetConnectionSignsInAgain() async throws {
        let network = Self.bridge(icons: true)
        let (context, mudi) = Self.routers()
        let ext = ScriptExtension(package: try ExtensionPackage(at: Self.package), context: context, network: network)
        ext.start()
        try await eventually("connected") { network.sockets.first.map { !Self.upserts($0).isEmpty } == true }
        let first = try XCTUnwrap(network.sockets.first)
        let reset = try XCTUnwrap(ext.actions.first { $0.id == "reset" })
        XCTAssertNotNil(reset.confirm, "it asks first")

        ext.perform(reset)
        try await eventually("a second connection") {
            network.sockets.count == 2 && Self.upserts(network.sockets[1]).contains { $0["customIcon"] != nil }
        }
        XCTAssertTrue(first.isClosed, "the old stream is closed")
        let second = network.sockets[1]
        XCTAssertEqual(second.sent[0]["token"] as? String, "gbb_2", "a new token")
        XCTAssertEqual(context.secrets["token"], "gbb_2")
        XCTAssertEqual(Self.upserts(second).last?["id"] as? String, mudi.uuidString)
        XCTAssertEqual(network.requests.filter { $0.httpMethod == "PUT" }.count, 2, "the icon uploaded again")
        // The old socket closing doesn't end the new connection.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(network.sockets.count, 2)
        XCTAssertFalse(second.isClosed)
        ext.stop()
    }
}

/// The quick start in docs/writing-extensions.md, as it's printed there.
@MainActor
final class HelloTests: XCTestCase {
    func testTheQuickStartRuns() async throws {
        let url = GlassyBatteryTests.package.deletingLastPathComponent().appendingPathComponent("Hello.ext")
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
