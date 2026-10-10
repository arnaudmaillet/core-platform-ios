import Connect
import Foundation
import SwiftProtobuf

/// In-process fake of the BFF edge: a `HTTPClientInterface` that answers
/// Connect-protocol unary POSTs from a route table of typed handlers, with
/// binary-protobuf bodies — the same bytes a real Connect server would send.
/// Inject it into `ProtocolClient` and every generated client works against
/// it unmodified, deterministically and offline.
public final class MockBFF: HTTPClientInterface, @unchecked Sendable {
    private typealias RawHandler = @Sendable (Data, Headers) -> Result<Data, ConnectError>

    public struct RecordedRequest: Sendable {
        public let path: String
        public let headers: Headers
    }

    private let lock = NSLock()
    private var routes: [String: RawHandler] = [:]
    private var recorded: [RecordedRequest] = []
    private var conditions: SimulatedConditions = .none
    private var guardsEdge = false
    private var networkFaults: MockNetworkFaults?

    public init() {}

    /// Network realism: artificial latency and injected failures, applied to
    /// every subsequent unary call. Safe to swap mid-flight (e.g. a test that
    /// degrades the network between two requests).
    public var simulatedConditions: SimulatedConditions {
        get { lock.withLock { conditions } }
        set { lock.withLock { conditions = newValue } }
    }

    /// Offline, outages and lost acks (#790), shared with the upload transport
    /// and the realtime server so the whole mock network fails together.
    public var faults: MockNetworkFaults? {
        get { lock.withLock { networkFaults } }
        set { lock.withLock { networkFaults = newValue } }
    }

    /// Whether calls go through `MockEdgePolicy` first — a guest's call to a
    /// member route is then refused with `unauthenticated`, as at the fleet's
    /// edge. Off by default: package tests feed generated clients through the
    /// unauthenticated client on purpose. The app turns it on in mock mode.
    public var enforcesEdgePolicy: Bool {
        get { lock.withLock { guardsEdge } }
        set { lock.withLock { guardsEdge = newValue } }
    }

    /// Every path with a registered handler — for checking a route table
    /// (`MockEdgePolicy`) against what is actually served.
    public var routedPaths: Set<String> {
        lock.withLock { Set(routes.keys) }
    }

    /// Every unary request received, in order — for asserting on paths and
    /// headers (e.g. that the auth interceptor attached the bearer token).
    public var recordedRequests: [RecordedRequest] {
        lock.withLock { recorded }
    }

    /// Registers a typed handler for an RPC path (e.g. "/auth.v1.AuthService/Login").
    public func register<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        path: String,
        handler: @escaping @Sendable (Request) -> Result<Response, ConnectError>
    ) {
        register(path: path) { (request: Request, _: Headers) in handler(request) }
    }

    /// Headers-aware variant, for the rare handler that reads a side-channel
    /// request header (e.g. the Phase-1 `x-map-filter` the geo mock honors
    /// while the real contract has no filter field).
    public func register<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        path: String,
        handler: @escaping @Sendable (Request, Headers) -> Result<Response, ConnectError>
    ) {
        let raw: RawHandler = { body, headers in
            let request: Request
            do {
                request = try Request(serializedBytes: body)
            } catch {
                return .failure(ConnectError(code: .invalidArgument, message: "undecodable request: \(error)"))
            }
            switch handler(request, headers) {
            case .success(let response):
                do {
                    return .success(try response.serializedData())
                } catch {
                    return .failure(ConnectError(code: .internalError, message: "unencodable response: \(error)"))
                }
            case .failure(let error):
                return .failure(error)
            }
        }
        lock.withLock { routes[path] = raw }
    }

    // MARK: - HTTPClientInterface

    @discardableResult
    public func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        let path = request.url.path
        let (handler, conditions, guardsEdge, faults) = lock.withLock {
            recorded.append(RecordedRequest(path: path, headers: request.headers))
            return (routes[path], self.conditions, self.guardsEdge, self.networkFaults)
        }

        // ⚠️ OFFLINE FAILS FAST, before latency and before the handler: a real
        // URLSession call with no network answers at once, and writes nothing.
        // ⚠️ The URLError in `exception` is what makes it read as offline
        // (#794): Connect attaches one to every real transport failure, and a
        // bare `unavailable` is a server's answer (`NetworkFailure`).
        if faults?.isOffline == true {
            let offline = HTTPResponse(
                code: .unavailable,
                headers: [:],
                message: nil,
                trailers: [:],
                error: ConnectError(
                    code: .unavailable,
                    message: "The Internet connection appears to be offline.",
                    exception: URLError(.notConnectedToInternet)
                ),
                tracingInfo: nil
            )
            DispatchQueue.global().async { onResponse(offline) }
            return Cancelable(cancel: {})
        }

        var response: HTTPResponse
        if guardsEdge, let refusal = MockEdgePolicy.refusal(path: path, headers: request.headers) {
            response = HTTPResponse(
                code: refusal.code,
                headers: [:],
                message: nil,
                trailers: [:],
                error: refusal,
                tracingInfo: nil
            )
        } else if let failure = conditions.failure(matching: path) {
            response = HTTPResponse(
                code: failure.code,
                headers: [:],
                message: nil,
                trailers: [:],
                error: ConnectError(code: failure.code, message: failure.message),
                tracingInfo: nil
            )
        } else if let handler {
            switch handler(request.message ?? Data(), request.headers) {
            case .success(let body):
                response = HTTPResponse(
                    code: .ok,
                    headers: ["content-type": ["application/proto"]],
                    message: body,
                    trailers: [:],
                    error: nil,
                    tracingInfo: .init(httpStatus: 200)
                )
            case .failure(let error):
                response = HTTPResponse(
                    code: error.code,
                    headers: [:],
                    message: nil,
                    trailers: [:],
                    error: error,
                    tracingInfo: nil
                )
            }
        } else {
            response = HTTPResponse(
                code: .unimplemented,
                headers: [:],
                message: nil,
                trailers: [:],
                error: ConnectError(code: .unimplemented, message: "MockBFF: no route for \(path)"),
                tracingInfo: nil
            )
        }

        // ACK LOSS: the handler ran — the write is applied — and the answer
        // never arrives. What a retried send duplicates on.
        if response.code == .ok, faults?.losesAck(for: path) == true {
            response = HTTPResponse(
                code: .deadlineExceeded,
                headers: [:],
                message: nil,
                trailers: [:],
                error: ConnectError(code: .deadlineExceeded, message: "simulated lost response"),
                tracingInfo: nil
            )
        }

        // Deliver asynchronously like a real transport would, after any
        // simulated latency.
        let delay = conditions.randomLatency()
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { onResponse(response) }
        } else {
            DispatchQueue.global().async { onResponse(response) }
        }
        return Cancelable(cancel: {})
    }

    public func stream(
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) -> RequestCallbacks<Data> {
        fatalError("MockBFF does not support streams yet (arrives with the realtime milestone)")
    }
}
