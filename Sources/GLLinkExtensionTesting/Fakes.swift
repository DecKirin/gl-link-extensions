import Foundation
import GLLinkExtensionKit

// For an extension's own tests: run its real package in GL-Link's runtime, with routers and a
// network you make up (docs/writing-extensions.md, "Testing").
//
// ```swift
// let context = FakeContext()
// context.routers = [RouterInfo(id: UUID(), name: "Mudi 7", model: nil,
//                               battery: BatteryReading(level: 85, charging: true), updated: Date())]
// let ext = ScriptExtension(package: try ExtensionPackage(at: url), context: context,
//                           network: FakeNetwork(http: { _ in (200, "{}") }))
// ext.start()
// try await eventually("it says so") { ext.status == "Watching 1 battery." }
// ```

/// The app, as an extension sees it: the routers you set, a count of refreshes, and secrets
/// kept in memory.
@MainActor
public final class FakeContext: ExtensionContext {
    public var routers: [RouterInfo] = []
    public var refreshes = 0
    public var secrets: [String: String] = [:]

    public init() {}

    public func refresh() async { refreshes += 1 }
    public func loadSecrets() -> [String: String] { secrets }
    public func saveSecrets(_ secrets: [String: String]) { self.secrets = secrets }
}

/// Answers HTTP from a closure, and hands out sockets that record what's sent and answer
/// through `reply`. The runtime has already held the request to the manifest's `network`.
public final class FakeNetwork: ExtensionNetwork, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _sockets: [FakeSocket] = []
    private let http: @Sendable (URLRequest) -> (Int, String)
    private let reply: @Sendable ([String: Any]) -> [String]

    /// - Parameters:
    ///   - http: the status and body for a request.
    ///   - reply: the messages a socket answers with, for one the script sent (as JSON).
    public init(http: @escaping @Sendable (URLRequest) -> (Int, String),
                reply: @escaping @Sendable ([String: Any]) -> [String] = { _ in [] }) {
        self.http = http
        self.reply = reply
    }

    /// Every request the script made, in order.
    public var requests: [URLRequest] { lock.withLock { _requests } }
    /// Every socket it opened, in order.
    public var sockets: [FakeSocket] { lock.withLock { _sockets } }

    public func fetch(_ request: URLRequest, allows: @escaping @Sendable (URL) -> Bool) async throws -> (Int, Data) {
        lock.withLock { _requests.append(request) }
        let (status, body) = http(request)
        return (status, Data(body.utf8))
    }

    public func socket(_ url: URL, allows: @escaping @Sendable (URL) -> Bool) -> any ExtensionSocket {
        let s = FakeSocket(url: url, reply: reply)
        lock.withLock { _sockets.append(s) }
        return s
    }
}

/// A WebSocket that goes nowhere: it keeps what the script sent, and answers from `reply`.
public final class FakeSocket: ExtensionSocket, @unchecked Sendable {
    public let url: URL
    private let reply: @Sendable ([String: Any]) -> [String]
    private let lock = NSLock()
    private var _sent: [[String: Any]] = []
    private var _closed = false
    private var incoming: AsyncThrowingStream<String, Error>.AsyncIterator
    private let input: AsyncThrowingStream<String, Error>.Continuation

    init(url: URL, reply: @escaping @Sendable ([String: Any]) -> [String]) {
        self.url = url
        self.reply = reply
        let (stream, input) = AsyncThrowingStream<String, Error>.makeStream()
        self.input = input
        incoming = stream.makeAsyncIterator()
    }

    /// The JSON messages the script sent, in order. Text that isn't a JSON object is kept
    /// as `["text": …]`.
    public var sent: [[String: Any]] { lock.withLock { _sent } }
    public var isClosed: Bool { lock.withLock { _closed } }

    /// A message from the other end, as if the server had sent it.
    public func push(_ text: String) { input.yield(text) }

    public func send(_ text: String) async throws {
        let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? ["text": text]
        lock.withLock { _sent.append(message) }
        for answer in reply(message) { input.yield(answer) }
    }

    public func receive() async throws -> String {
        guard let next = try await incoming.next() else { throw URLError(.networkConnectionLost) }
        return next
    }

    public func close() {
        lock.withLock { _closed = true }
        input.finish(throwing: URLError(.networkConnectionLost))
    }
}

/// Thrown by `eventually` when what it waited for didn't happen.
public struct TimedOut: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "timed out waiting for \(what)" }
}

/// Waits until `check` holds: a script works in promises and timers, so its effects arrive a
/// moment after the call that caused them.
@MainActor
public func eventually(_ what: String, timeout: Double = 3, _ check: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !check() {
        if Date() > end { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
