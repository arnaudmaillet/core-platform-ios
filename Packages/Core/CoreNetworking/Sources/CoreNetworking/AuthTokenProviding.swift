/// Supplies a currently-valid access token for outgoing RPCs, refreshing
/// behind the scenes when needed. Implemented by the auth feature's
/// SessionManager; consumed by `AuthInterceptor`.
public protocol AuthTokenProviding: Sendable {
    /// Returns a token safe to attach right now, or nil when unauthenticated.
    /// Implementations own expiry checking and single-flight refresh.
    func validAccessToken() async throws -> String?
}
