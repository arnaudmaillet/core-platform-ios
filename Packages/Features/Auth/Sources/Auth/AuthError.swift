import Connect

/// Auth failures surfaced to callers and the UI, normalized from transport
/// errors at the repository boundary.
public enum AuthError: Error, Equatable, Sendable {
    case notAuthenticated
    case invalidCredentials
    /// The refresh token was rejected (expired, revoked, or reuse-detected);
    /// the local session has been cleared and the user must sign in again.
    case sessionExpired
    case transport(message: String)

    static func loginFailure(_ error: ConnectError) -> AuthError {
        switch error.code {
        case .unauthenticated, .permissionDenied:
            .invalidCredentials
        default:
            .transport(message: error.message ?? "code \(error.code)")
        }
    }
}
