import Foundation

/// Production transport: `URLSessionWebSocketTask` against the realtime
/// gateway, edge token presented on the upgrade per the realtime.v1 handshake
/// contract (verified once; frames are never re-authenticated).
///
/// The gateway takes the token as a query parameter (`?access_token=…`), not
/// an Authorization header — browsers can't set headers on a WebSocket
/// handshake, so gateways standardize on the query param.
public final class URLSessionWebSocketTransport: RealtimeTransport, @unchecked Sendable {
    private let url: URL
    private let tokenQueryItem: String
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    public init(url: URL, tokenQueryItem: String = "access_token", session: URLSession = .shared) {
        self.url = url
        self.tokenQueryItem = tokenQueryItem
        self.session = session
    }

    public func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent> {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: tokenQueryItem, value: edgeToken))
        components?.queryItems = queryItems
        let connectURL = components?.url ?? url

        let task = session.webSocketTask(with: connectURL)
        lock.withLock { self.task = task }

        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeTransportEvent.self)
        task.resume()
        continuation.yield(.connected)

        Task {
            while true {
                do {
                    let message = try await task.receive()
                    if case .data(let data) = message {
                        continuation.yield(.message(data))
                    }
                } catch {
                    continuation.yield(.disconnected(reason: error.localizedDescription))
                    continuation.finish()
                    break
                }
            }
        }
        return stream
    }

    public func send(_ data: Data) async throws {
        guard let task = lock.withLock({ task }) else { throw URLError(.networkConnectionLost) }
        try await task.send(.data(data))
    }

    public func disconnect() async {
        lock.withLock { task }?.cancel(with: .normalClosure, reason: nil)
        lock.withLock { task = nil }
    }
}
