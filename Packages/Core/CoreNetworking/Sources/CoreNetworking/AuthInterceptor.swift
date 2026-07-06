import Connect
import Foundation

/// Attaches `Authorization: Bearer <edge token>` to every unary RPC on the
/// authenticated client. Auth-service RPCs (login/refresh) must go through the
/// unauthenticated client instead — routing them here would recurse into the
/// token provider's own refresh.
public final class AuthInterceptor: UnaryInterceptor, Sendable {
    private let tokenProvider: AuthTokenProviding

    public init(tokenProvider: AuthTokenProviding) {
        self.tokenProvider = tokenProvider
    }

    @Sendable
    public func handleUnaryRequest<Message: ProtobufMessage>(
        _ request: HTTPRequest<Message>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Message>, ConnectError>) -> Void
    ) {
        let tokenProvider = tokenProvider
        Task {
            do {
                guard let token = try await tokenProvider.validAccessToken() else {
                    proceed(.success(request))
                    return
                }
                var headers = request.headers
                headers["Authorization"] = ["Bearer \(token)"]
                proceed(.success(HTTPRequest(
                    url: request.url,
                    headers: headers,
                    message: request.message,
                    method: request.method,
                    trailers: request.trailers,
                    idempotencyLevel: request.idempotencyLevel
                )))
            } catch {
                proceed(.failure(ConnectError(
                    code: .unauthenticated,
                    message: "token refresh failed: \(error)"
                )))
            }
        }
    }
}
