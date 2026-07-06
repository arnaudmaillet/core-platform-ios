import Foundation

/// The client's view of an authenticated session, mirroring the auth.v1
/// token model: a short-lived edge access token plus an opaque, single-use
/// refresh token that is rotated on every refresh.
public struct AuthSession: Sendable, Codable, Equatable {
    public let accountID: AccountID
    public let sessionID: SessionID
    public var accessToken: String
    /// Instant after which `accessToken` must not be attached to requests.
    public var accessTokenExpiry: Date
    /// Opaque single-use handle. Never attach to requests; only exchange it
    /// via Refresh. Presenting a rotated value revokes the session generation.
    public var refreshToken: String

    public init(
        accountID: AccountID,
        sessionID: SessionID,
        accessToken: String,
        accessTokenExpiry: Date,
        refreshToken: String
    ) {
        self.accountID = accountID
        self.sessionID = sessionID
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshToken = refreshToken
    }
}
