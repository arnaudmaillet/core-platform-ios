import Connect
import Foundation
import SwiftProtobuf

/// In-process fake of the BFF edge: a `HTTPClientInterface` that answers
/// Connect-protocol unary POSTs from a route table of typed handlers, with
/// binary-protobuf bodies — the same bytes a real Connect server would send.
/// Inject it into `ProtocolClient` and every generated client works against
/// it unmodified, deterministically and offline.
public final class MockBFF: HTTPClientInterface, @unchecked Sendable {
    private typealias RawHandler = @Sendable (Data) -> Result<Data, ConnectError>

    public struct RecordedRequest: Sendable {
        public let path: String
        public let headers: Headers
    }

    private let lock = NSLock()
    private var routes: [String: RawHandler] = [:]
    private var recorded: [RecordedRequest] = []

    public init() {}

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
        let raw: RawHandler = { body in
            let request: Request
            do {
                request = try Request(serializedBytes: body)
            } catch {
                return .failure(ConnectError(code: .invalidArgument, message: "undecodable request: \(error)"))
            }
            switch handler(request) {
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
        let handler = lock.withLock {
            recorded.append(RecordedRequest(path: path, headers: request.headers))
            return routes[path]
        }

        let response: HTTPResponse
        if let handler {
            switch handler(request.message ?? Data()) {
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

        // Deliver asynchronously like a real transport would.
        DispatchQueue.global().async { onResponse(response) }
        return Cancelable(cancel: {})
    }

    public func stream(
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) -> RequestCallbacks<Data> {
        fatalError("MockBFF does not support streams yet (arrives with the realtime milestone)")
    }
}
