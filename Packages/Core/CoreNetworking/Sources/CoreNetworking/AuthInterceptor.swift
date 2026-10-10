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
        // A call that names its own bearer keeps it: creating a new account's
        // profile runs with THAT account's token while the app's session is
        // still the guest's (`AccountProfileSetupService`).
        if request.headers.keys.contains(where: { $0.lowercased() == "authorization" }) {
            proceed(.success(request))
            return
        }
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
                // ⚠️ OFFLINE IS NOT SIGNED OUT (#791). Every failure to get a
                // token used to read as `unauthenticated` — the same answer an
                // expired session gives — so a call made with no network
                // looked like an auth failure to every screen above.
                proceed(.failure(ConnectError(
                    code: Self.code(forTokenFailure: error),
                    message: "token refresh failed: \(error)"
                )))
            }
        }
    }

    /// `unavailable` when the network failed, `unauthenticated` otherwise.
    static func code(forTokenFailure error: Error) -> Code {
        if let described = error as? NetworkUnavailabilityDescribing, described.isNetworkUnavailable {
            return .unavailable
        }
        if let connect = error as? ConnectError, connect.code == .unavailable || connect.code == .deadlineExceeded {
            return connect.code
        }
        if error is URLError { return .unavailable }
        return .unauthenticated
    }
}
