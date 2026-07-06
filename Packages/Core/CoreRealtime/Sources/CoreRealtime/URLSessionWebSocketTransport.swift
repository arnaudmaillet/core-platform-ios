import Foundation

/// Production transport: `URLSessionWebSocketTask` against the realtime
/// gateway, edge token in the upgrade request per the realtime.v1 handshake
/// contract (verified once; frames are never re-authenticated).
public final class URLSessionWebSocketTransport: RealtimeTransport, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent> {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(edgeToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
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
