import Foundation

/// Where an extension's `fetch` and `gllink.connect` go: URLSession in the app, a fake in tests.
/// The runtime checks the manifest's `network` rules before it gets here, and hands over
/// `allows`, the same check, for where a server redirects to: a redirect to a host the
/// manifest doesn't name isn't followed, and the script gets the 3xx answer itself.
public protocol ExtensionNetwork: Sendable {
    /// The status and body.
    func fetch(_ request: URLRequest, allows: @escaping @Sendable (URL) -> Bool) async throws -> (Int, Data)
    func socket(_ url: URL, allows: @escaping @Sendable (URL) -> Bool) -> any ExtensionSocket
}

/// Stops a request at a redirect the extension may not follow.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allows: @Sendable (URL) -> Bool

    init(allows: @escaping @Sendable (URL) -> Bool) { self.allows = allows }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
}

/// A WebSocket, text frames only.
public protocol ExtensionSocket: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next message; throws once the socket has closed.
    func receive() async throws -> String
    func close()
}

public struct URLSessionNetwork: ExtensionNetwork {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    public func fetch(_ request: URLRequest, allows: @escaping @Sendable (URL) -> Bool) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard(allows: allows))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func socket(_ url: URL, allows: @escaping @Sendable (URL) -> Bool) -> any ExtensionSocket {
        let task = session.webSocketTask(with: url)
        task.delegate = RedirectGuard(allows: allows)
        task.resume()
        return URLSessionSocket(task: task)
    }
}

private final class URLSessionSocket: ExtensionSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
