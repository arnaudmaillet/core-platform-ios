/// Supplies a currently-valid access token for outgoing RPCs, refreshing
/// behind the scenes when needed. Implemented by the auth feature's
/// SessionManager; consumed by `AuthInterceptor`.
public protocol AuthTokenProviding: Sendable {
    /// Returns a token safe to attach right now, or nil when unauthenticated.
    /// Implementations own expiry checking and single-flight refresh.
    func validAccessToken() async throws -> String?
}

/// A token that could not be had because the NETWORK failed — not because the
/// session is invalid (#791). The auth interceptor reports such a failure as
/// `unavailable`, so a call made offline reads as offline, never as signed out.
public protocol NetworkUnavailabilityDescribing: Error {
    var isNetworkUnavailable: Bool { get }
}
