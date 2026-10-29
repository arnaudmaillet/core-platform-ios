import Foundation
import Network
import Testing
@testable import CoreRealtime

/// A real WebSocket server on 127.0.0.1, in process: the production transport
/// talks to it over a real socket, so these tests see what the device sees.
private final class LoopbackWebSocketServer: @unchecked Sendable {
    /// What the server does with a connection once the upgrade went through.
    enum Behavior {
        /// Answers every ping with a pong, as a healthy gateway does.
        case answersPings
        /// Takes the upgrade and then says nothing, ever.
        case silent
        /// Takes the upgrade and hangs up straight away.
        case hangsUp
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackWebSocketServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(behavior: Behavior) throws {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = behavior == .answersPings
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state, behavior == .hangsUp {
                    connection.cancel()
                }
            }
            connection.start(queue: self.queue)
            if behavior != .hangsUp { Self.drain(connection) }
        }
        listener.start(queue: queue)
    }

    /// Keeps reading so the stack processes frames (and auto-replies pings).
    private static func drain(_ connection: NWConnection) {
        connection.receiveMessage { _, _, _, error in
            if error == nil { drain(connection) }
        }
    }

    /// Why the listener never gave a port.
    enum ListenerError: Error, CustomStringConvertible {
        case failed(NWError)
        case noPortAfter(seconds: Double)

        var description: String {
            switch self {
            case .failed(let error): "the loopback listener failed: \(error)"
            case .noPortAfter(let seconds): "the loopback listener had no port after \(seconds) s"
            }
        }
    }

    /// The bound port, once the listener is up (time-bounded).
    ///
    /// ⚠️ **A SLOW LISTENER IS NOT A REFUSED SOCKET (#1846).** This gave up
    /// after 2 s and threw `URLError(.cannotConnectToHost)`. On a loaded CI
    /// runner the listener took longer, and the test failed with a `-1004`
    /// that read as the transport's, though `connect` never throws. It now
    /// waits as long as the runner needs, and its error says it is the
    /// server's, never the transport's.
    func port(within seconds: Double = 30) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .failed(let error) = listener.state { throw ListenerError.failed(error) }
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ListenerError.noPortAfter(seconds: seconds)
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { connections }
        open.forEach { $0.cancel() }
    }
}

/// Everything the transport yielded, in order, and whether its stream ended.
private final class TransportEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RealtimeTransportEvent] = []
    private var ended = false

    var sawConnected: Bool {
        lock.withLock { events.contains { if case .connected = $0 { true } else { false } } }
    }

    var sawDisconnected: Bool {
        lock.withLock { events.contains { if case .disconnected = $0 { true } else { false } } }
    }

    var isFinished: Bool { lock.withLock { ended } }

    func record(_ stream: AsyncStream<RealtimeTransportEvent>) -> Task<Void, Never> {
        Task {
            for await event in stream {
                lock.withLock { events.append(event) }
            }
            lock.withLock { ended = true }
        }
    }
}

/// Polls `condition` every 10 ms for at most `seconds`.
private func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let tries = Int(seconds * 100)
    for _ in 0..<tries {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func makeTransport(port: UInt16) throws -> URLSessionWebSocketTransport {
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/realtime"))
    return URLSessionWebSocketTransport(url: url, session: URLSession(configuration: .ephemeral))
}

/// ⚠️ CONNECTED MEANS THE SOCKET ANSWERED (#792): the production transport
/// yields `.connected` only once a ping came back — never on `resume()` alone.
///
/// THE CONTRACT (#1846): `connect` returns the stream and does not throw; a
/// refused, hung-up or silent socket is a `.disconnected` that ends it. An
/// error thrown before `connect` is the test server's (`ListenerError`),
/// never the transport's.
struct URLSessionWebSocketTransportTests {
    @Test func aServerThatAnswersThePingIsConnected() async throws {
        let server = try LoopbackWebSocketServer(behavior: .answersPings)
        defer { server.stop() }
        let transport = try makeTransport(port: try await server.port())
        let log = TransportEventLog()
        let recording = log.record(try await transport.connect(edgeToken: "edge-token"))

        #expect(await within(10) { log.sawConnected }, "a pong came back, yet no .connected")
        #expect(!log.sawDisconnected)

        await transport.disconnect()
        #expect(await within(10) { log.isFinished })
        recording.cancel()
    }

    @Test func aServerThatNeverAnswersThePingIsNotConnected() async throws {
        let server = try LoopbackWebSocketServer(behavior: .silent)
        defer { server.stop() }
        let transport = try makeTransport(port: try await server.port())
        let log = TransportEventLog()
        let recording = log.record(try await transport.connect(edgeToken: "edge-token"))

        // The upgrade went through, but nothing answers: still not connected
        // after a generous wait.
        #expect(await within(1.5) { log.sawConnected } == false, "connected without a pong")

        // Hanging up ends the attempt as a failure, never as a connection.
        await transport.disconnect()
        #expect(await within(10) { log.isFinished }, "the stream outlived its socket")
        #expect(!log.sawConnected)
        #expect(log.sawDisconnected)
        recording.cancel()
    }

    @Test func aServerThatHangsUpAfterTheUpgradeIsNotConnected() async throws {
        let server = try LoopbackWebSocketServer(behavior: .hangsUp)
        defer { server.stop() }
        let transport = try makeTransport(port: try await server.port())
        let log = TransportEventLog()
        let recording = log.record(try await transport.connect(edgeToken: "edge-token"))

        #expect(await within(10) { log.isFinished }, "the stream outlived its socket")
        #expect(!log.sawConnected)
        #expect(log.sawDisconnected)
        recording.cancel()
    }

    @Test func nothingListeningIsAFailureNotAConnection() async throws {
        // Borrow a free port, then close it so nothing answers there.
        let borrowed = try LoopbackWebSocketServer(behavior: .silent)
        let port = try await borrowed.port()
        borrowed.stop()

        let transport = try makeTransport(port: port)
        let log = TransportEventLog()
        let recording = log.record(try await transport.connect(edgeToken: "edge-token"))

        #expect(await within(10) { log.isFinished }, "the stream outlived a refused socket")
        #expect(!log.sawConnected)
        #expect(log.sawDisconnected)
        recording.cancel()
    }
}
