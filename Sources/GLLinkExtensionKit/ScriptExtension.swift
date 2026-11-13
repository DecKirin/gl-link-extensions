import Foundation
import JavaScriptCore
import Observation

/// One installed extension, running: its script in a JavaScriptCore context of its own, which
/// reaches the app only through the `gllink` object below, and only as far as its manifest's
/// permissions say. Started and stopped while the app runs; stopping drops the whole context,
/// with its timers and sockets, so turning one off or removing it leaves nothing behind.
///
/// What the script sees (docs/extensions.md, "Writing an extension"):
///
/// ```js
/// gllink.routers()                 // [{id, name, updated, battery?: {level, charging},
///                                  //   model?: {id, code, name, symbol}}]
/// gllink.on("routers" | "stop", fn)
/// gllink.refresh()                 // Promise: read the routers again
/// gllink.status(text)              // the line under its name in Settings
/// gllink.show([{title, value}])    // rows under it
/// gllink.readFile(path)            // text, or null
/// gllink.resource(path, "base64"?)  // a file in its own package: text (or base64), or null
/// gllink.actions([{id, title, role?, confirm?}])  // buttons under it in Settings
/// gllink.on("action", fn)          // one was tapped: fn(id)
/// gllink.secrets.get(key) / .set(key, value or null)
/// gllink.connect(url)              // a WebSocket: send(text), close(), onmessage, onclose
/// gllink.app                       // {platform, bundleID, version}
/// fetch(url, {method, headers, body})   // {status, ok, text(), json()}
/// setTimeout, setInterval, clearTimeout, clearInterval, console
/// ```
@MainActor
@Observable
public final class ScriptExtension: Identifiable {
    public struct Row: Equatable, Identifiable, Sendable {
        public var title: String
        public var value: String
        public var id: String { title }

        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    /// A button the extension puts under it in Settings → Extensions: whatever it does, the
    /// script does when `perform` tells it.
    public struct Action: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        /// Drawn as destructive.
        public var destructive: Bool
        /// Asked before it's done, when set.
        public var confirm: String?

        public init(id: String, title: String, destructive: Bool = false, confirm: String? = nil) {
            self.id = id
            self.title = title
            self.destructive = destructive
            self.confirm = confirm
        }
    }

    public let package: ExtensionPackage
    public nonisolated var id: String { package.manifest.id }
    public var manifest: ExtensionManifest { package.manifest }

    public private(set) var isRunning = false
    /// The line under its name: set by the script, or why it stopped.
    public private(set) var status = "Off"
    /// Rows the script shows under its switch.
    public private(set) var rows: [Row] = []
    /// Buttons it offers.
    public private(set) var actions: [Action] = []
    /// What it printed, the newest last.
    public private(set) var log: [String] = []

    @ObservationIgnored private let context: any ExtensionContext
    @ObservationIgnored private let network: any ExtensionNetwork
    @ObservationIgnored private var js: JSContext?
    @ObservationIgnored private var native: JSValue?
    @ObservationIgnored private var timers: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var sockets: [Int: any ExtensionSocket] = [:]
    @ObservationIgnored private var socketTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private lazy var secrets: [String: String] = context.loadSecrets()
    private let rules: [NetworkRule]
    private let files: Set<String>

    private static let logLimit = 200

    public init(package: ExtensionPackage, context: any ExtensionContext,
                network: any ExtensionNetwork = URLSessionNetwork()) {
        self.package = package
        self.context = context
        self.network = network
        rules = (package.manifest.permissions.network ?? []).compactMap(NetworkRule.init)
        files = Set((package.manifest.permissions.files ?? []).map(Self.expand))
    }

    // MARK: - Running

    public func start() {
        guard !isRunning else { return }
        guard package.runsHere else {
            status = (manifest.kind == .router ? ExtensionError.routerExtension(manifest.name)
                      : ExtensionError.notForThisPlatform(manifest.platforms)).localizedDescription
            return
        }
        let script: String
        do { script = try package.script() } catch {
            status = "Couldn’t read its script."
            return
        }
        guard let js = JSContext() else { return }
        js.name = manifest.name
        js.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "error"
            MainActor.assumeIsolated { self?.print("error", text) }
        }
        self.js = js
        isRunning = true
        status = "Running"
        let native = makeNative(in: js)
        self.native = native
        js.evaluateScript(Self.prelude, withSourceURL: URL(string: "gllink://prelude.js"))?.call(withArguments: [native])
        js.evaluateScript(script, withSourceURL: package.url.appendingPathComponent(manifest.main))
    }

    public func stop() {
        guard isRunning else { return }
        emit("stop")
        for task in timers.values { task.cancel() }
        for task in socketTasks.values { task.cancel() }
        for socket in sockets.values { socket.close() }
        timers = [:]
        sockets = [:]
        socketTasks = [:]
        native = nil
        js = nil
        isRunning = false
        rows = []
        actions = []
        status = "Off"
    }

    /// One of its actions was tapped (and confirmed, if it asks).
    public func perform(_ action: Action) {
        guard isRunning, actions.contains(action) else { return }
        emit("action", action.id)
    }

    /// The routers changed: tells the script, if it listens.
    public func routersChanged() {
        guard isRunning, manifest.permissions.routers != nil else { return }
        emit("routers")
    }

    private func emit(_ name: String, _ argument: Any? = nil) {
        _ = native?.objectForKeyedSubscript("emit")?.call(withArguments: [name, argument ?? NSNull()])
    }

    private func print(_ level: String, _ text: String) {
        log.append(level == "log" ? text : "\(level): \(text)")
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    // MARK: - What the script can call

    /// The native half of `gllink`; the prelude wraps it.
    private func makeNative(in js: JSContext) -> JSValue {
        let native = JSValue(newObjectIn: js)!
        func define(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            MainActor.assumeIsolated { self?.print(level, text) }
        }
        define("log", log)

        let routers: @convention(block) () -> Any = { [weak self] in
            MainActor.assumeIsolated { self?.routerObjects() ?? [] }
        }
        define("routers", routers)

        let refresh: @convention(block) () -> JSValue? = { [weak self] in
            MainActor.assumeIsolated {
                self?.promise { resolve, _ in
                    guard let self else { return }
                    Task { @MainActor in
                        if self.manifest.permissions.routers != nil { await self.context.refresh() }
                        resolve(NSNull())
                    }
                }
            }
        }
        define("refresh", refresh)

        let status: @convention(block) (String) -> Void = { [weak self] text in
            MainActor.assumeIsolated { self?.status = String(text.prefix(200)) }
        }
        define("status", status)

        let show: @convention(block) (JSValue) -> Void = { [weak self] value in
            let list = value.toArray() as? [[String: Any]] ?? []
            let rows = list.prefix(20).map {
                Row(title: String(describing: $0["title"] ?? ""), value: String(describing: $0["value"] ?? ""))
            }
            MainActor.assumeIsolated { self?.rows = rows }
        }
        define("show", show)

        let actions: @convention(block) (JSValue) -> Void = { [weak self] value in
            let list = value.toArray() as? [[String: Any]] ?? []
            let actions = list.prefix(8).compactMap { o -> Action? in
                guard let id = o["id"] as? String, let title = o["title"] as? String, !id.isEmpty, !title.isEmpty else { return nil }
                return Action(id: id, title: String(title.prefix(40)), destructive: o["role"] as? String == "destructive",
                              confirm: (o["confirm"] as? String).map { String($0.prefix(300)) })
            }
            MainActor.assumeIsolated { self?.actions = actions }
        }
        define("actions", actions)

        let resource: @convention(block) (String, String) -> Any = { [weak self] path, encoding in
            MainActor.assumeIsolated { () -> Any in
                guard let self, let data = self.resource(path) else { return NSNull() }
                return encoding == "base64" ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
            }
        }
        define("resource", resource)

        let readFile: @convention(block) (String) -> Any = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self, self.files.contains(Self.expand(path)) else {
                    self?.print("error", "readFile(\(path)): not in the manifest’s files")
                    return NSNull()
                }
                return (try? String(contentsOfFile: Self.expand(path), encoding: .utf8)) ?? NSNull()
            }
        }
        define("readFile", readFile)

        let secretGet: @convention(block) (String) -> Any = { [weak self] key in
            MainActor.assumeIsolated { () -> Any in self?.secrets[key] ?? NSNull() }
        }
        define("secretGet", secretGet)
        let secretSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.secrets[key] = value.isNull || value.isUndefined ? nil : value.toString()
                self.context.saveSecrets(self.secrets)
            }
        }
        define("secretSet", secretSet)

        let timer: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] fn, ms, repeats in
            MainActor.assumeIsolated { self?.addTimer(fn, ms: ms, repeats: repeats) ?? 0 }
        }
        define("timer", timer)
        let cancelTimer: @convention(block) (Int) -> Void = { [weak self] id in
            MainActor.assumeIsolated { self?.timers.removeValue(forKey: id)?.cancel() }
        }
        define("cancelTimer", cancelTimer)

        let fetch: @convention(block) (String, String, JSValue, JSValue) -> JSValue? = { [weak self] url, method, headers, body in
            let headers = headers.toDictionary() as? [String: Any] ?? [:]
            let body = body.isNull || body.isUndefined ? nil : body.toString()
            return MainActor.assumeIsolated { self?.fetch(url, method: method, headers: headers, body: body) }
        }
        define("fetch", fetch)

        let socketOpen: @convention(block) (String) -> Int = { [weak self] url in
            MainActor.assumeIsolated { self?.openSocket(url) ?? 0 }
        }
        define("socketOpen", socketOpen)
        let socketSend: @convention(block) (Int, String) -> JSValue? = { [weak self] id, text in
            MainActor.assumeIsolated {
                self?.promise { resolve, reject in
                    guard let socket = self?.sockets[id] else { return reject("the socket is closed") }
                    Task { @MainActor in
                        do { try await socket.send(text); resolve(NSNull()) } catch { reject(error.localizedDescription) }
                    }
                }
            }
        }
        define("socketSend", socketSend)
        let socketClose: @convention(block) (Int) -> Void = { [weak self] id in
            MainActor.assumeIsolated { self?.closeSocket(id, reason: "closed") }
        }
        define("socketClose", socketClose)

        native.setObject(["platform": Platform.current.rawValue,
                          "bundleID": Bundle.main.bundleIdentifier ?? "",
                          "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""],
                         forKeyedSubscript: "app" as NSString)
        return native
    }

    /// The routers as the manifest lets the script see them.
    private func routerObjects() -> [[String: Any]] {
        guard let fields = manifest.permissions.routers else {
            print("error", "routers(): the manifest asks for no router data")
            return []
        }
        return context.routers.map { r in
            var o: [String: Any] = ["id": r.id.uuidString, "name": r.name,
                                    "updated": r.updated.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()]
            if fields.contains(.battery), let b = r.battery {
                o["battery"] = ["level": b.level, "charging": b.charging]
            }
            if fields.contains(.model), let m = r.model {
                o["model"] = ["id": m.id, "code": m.code, "name": m.name, "symbol": m.symbol as Any? ?? NSNull()] as [String: Any]
            }
            return o
        }
    }

    /// A file inside its own package, up to 1 MB; nil outside it, or missing.
    private func resource(_ path: String) -> Data? {
        let root = package.url.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/"),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1 << 20 else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func addTimer(_ fn: JSValue, ms: Double, repeats: Bool) -> Int {
        let id = nextID
        nextID += 1
        let interval = Duration.milliseconds(max(ms, repeats ? 10 : 0))
        timers[id] = Task { @MainActor [weak self] in
            repeat {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self?.timers[id] != nil else { return }
                fn.call(withArguments: [])
            } while repeats
            self?.timers[id] = nil
        }
        return id
    }

    private func allowed(_ url: URL) -> Bool { rules.contains { $0.allows(url) } }

    /// The same check, for the network to ask about redirects off the main actor.
    private var allows: @Sendable (URL) -> Bool {
        let rules = rules
        return { url in rules.contains { $0.allows(url) } }
    }

    private func fetch(_ text: String, method: String, headers: [String: Any], body: String?) -> JSValue? {
        promise { [weak self] resolve, reject in
            guard let self else { return }
            guard let url = URL(string: text), self.allowed(url) else {
                self.print("error", "fetch(\(text)): not in the manifest’s network")
                return reject("\(text) isn’t in the extension’s network permissions")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method.uppercased()
            for (k, v) in headers { request.setValue(String(describing: v), forHTTPHeaderField: k) }
            request.httpBody = body.map { Data($0.utf8) }
            Task { @MainActor in
                do {
                    let (status, data) = try await self.network.fetch(request, allows: self.allows)
                    resolve(["status": status, "body": String(decoding: data, as: UTF8.self)])
                } catch {
                    reject(error.localizedDescription)
                }
            }
        }
    }

    private func openSocket(_ text: String) -> Int {
        let id = nextID
        nextID += 1
        guard let url = URL(string: text), allowed(url) else {
            print("error", "connect(\(text)): not in the manifest’s network")
            // Closed at once, so the script's onclose runs as for any failure.
            Task { @MainActor [weak self] in self?.deliver(id, "close", "not permitted") }
            return id
        }
        let socket = network.socket(url, allows: allows)
        sockets[id] = socket
        socketTasks[id] = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    self?.deliver(id, "message", text)
                }
            } catch {
                self?.closeSocket(id, reason: error.localizedDescription)
            }
        }
        return id
    }

    private func closeSocket(_ id: Int, reason: String) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        socketTasks.removeValue(forKey: id)?.cancel()
        socket.close()
        deliver(id, "close", reason)
    }

    private func deliver(_ id: Int, _ type: String, _ data: String) {
        _ = native?.objectForKeyedSubscript("socketEvent")?.call(withArguments: [id, type, data])
    }

    /// A JS promise the closure settles, now or later, on the main actor.
    private func promise(_ body: (_ resolve: @escaping (Any) -> Void, _ reject: @escaping (String) -> Void) -> Void) -> JSValue? {
        guard let js else { return nil }
        var resolveFn: JSValue?
        var rejectFn: JSValue?
        let promise = JSValue(newPromiseIn: js) { resolve, reject in
            resolveFn = resolve
            rejectFn = reject
        }
        body({ value in _ = resolveFn?.call(withArguments: [value]) },
             { message in _ = rejectFn?.call(withArguments: [JSValue(newErrorFromMessage: message, in: js) as Any]) })
        return promise
    }

    /// "~/…" in the person's real home folder: on the Mac, not the app's container.
    static func expand(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return home + path.dropFirst()
    }

    // MARK: - The prelude

    /// Builds the script's globals on the native object.
    private static let prelude = #"""
    (function (native) {
      "use strict";
      const handlers = {};
      const sockets = {};
      const text = (args) => args.map((a) => (typeof a === "object" ? JSON.stringify(a) : String(a))).join(" ");
      globalThis.console = {
        log: (...a) => native.log("log", text(a)),
        info: (...a) => native.log("log", text(a)),
        warn: (...a) => native.log("warning", text(a)),
        error: (...a) => native.log("error", text(a)),
      };
      globalThis.setTimeout = (fn, ms) => native.timer(fn, Number(ms) || 0, false);
      globalThis.setInterval = (fn, ms) => native.timer(fn, Number(ms) || 0, true);
      globalThis.clearTimeout = globalThis.clearInterval = (id) => native.cancelTimer(Number(id) || 0);
      globalThis.fetch = async (url, options = {}) => {
        const r = await native.fetch(String(url), options.method || "GET", options.headers || {},
                                     options.body == null ? null : String(options.body));
        return {
          status: r.status,
          ok: r.status >= 200 && r.status < 300,
          text: async () => r.body,
          json: async () => JSON.parse(r.body),
        };
      };
      class Socket {
        constructor(id) { this.id = id; this.onmessage = null; this.onclose = null; }
        send(data) { return native.socketSend(this.id, String(data)); }
        close() { native.socketClose(this.id); }
      }
      globalThis.gllink = Object.freeze({
        on(name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
        routers: () => native.routers(),
        refresh: () => native.refresh(),
        status: (t) => native.status(String(t)),
        show: (rows) => native.show(Array.isArray(rows) ? rows : []),
        readFile: (path) => native.readFile(String(path)),
        resource: (path, encoding) => native.resource(String(path), encoding === "base64" ? "base64" : "utf8"),
        actions: (list) => native.actions(Array.isArray(list) ? list : []),
        secrets: Object.freeze({
          get: (key) => native.secretGet(String(key)),
          set: (key, value) => native.secretSet(String(key), value == null ? null : String(value)),
        }),
        connect(url) {
          const socket = new Socket(native.socketOpen(String(url)));
          sockets[socket.id] = socket;
          return socket;
        },
        app: Object.freeze(native.app),
      });
      native.emit = (name, arg) => {
        for (const fn of handlers[name] || []) {
          try {
            const r = fn(arg);
            if (r && typeof r.catch === "function") r.catch((e) => console.error(String(e)));
          } catch (e) {
            console.error(String(e));
          }
        }
      };
      native.socketEvent = (id, type, data) => {
        const s = sockets[id];
        if (!s) return;
        if (type === "message") {
          if (s.onmessage) s.onmessage({ data });
        } else {
          delete sockets[id];
          if (s.onclose) s.onclose({ reason: data });
        }
      };
    })
    """#
}
