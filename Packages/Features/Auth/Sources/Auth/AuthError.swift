import Connect
import CoreNetworking
import Foundation

/// Auth failures surfaced to callers and the UI, normalized from transport
/// errors at the repository boundary.
public enum AuthError: Error, Equatable, Sendable {
    case notAuthenticated
    case invalidCredentials
    /// The refresh token was rejected (expired, revoked, or reuse-detected);
    /// the local session has been cleared and the user must sign in again.
    case sessionExpired
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
    /// The network did not answer — no route, or a timeout (#791). Apart from
    /// `transport` (any other failure, a server error included) so a call made
    /// offline reads as offline and nothing else does.
    case offline
    /// A one-time code that was wrong, expired, or already used.
    case invalidCode
    /// Under the minimum age to hold an account (13; 16 in some countries —
    /// AUT-6005). Nothing was created or kept.
    case underMinimumAge
    /// An Apple / Google id_token the server refused (bad, expired, its nonce
    /// used — AUT-5008 — or without an email). A new sign-in fixes it.
    case identityRejected
    /// A two-step code (authenticator or backup) that didn't match (AUT-5017).
    /// The sign-in can try again.
    case wrongSecondStepCode
    /// Too many wrong two-step codes (AUT-5018): the account's codes are
    /// locked for a while.
    case secondStepLocked
    /// The sign-in waited too long for its code, or it was already used
    /// (AUT-5021): sign in again.
    case secondStepExpired

    static func loginFailure(_ error: ConnectError) -> AuthError {
        switch error.code {
        case .unauthenticated, .permissionDenied:
            .invalidCredentials
        default:
            .transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    static func secondStepFailure(_ error: ConnectError) -> AuthError {
        let message = error.message ?? ""
        if message.contains("AUT-5021") { return .secondStepExpired }
        if message.contains("AUT-5018") || error.code == .resourceExhausted { return .secondStepLocked }
        if message.contains("AUT-5017") || error.code == .unauthenticated { return .wrongSecondStepCode }
        return .transport(message: message.isEmpty ? "code \(error.code)" : message, failure: NetworkFailure(error))
    }
}

extension AuthError: NetworkFailureCarrying {
    /// `offline` already says it (#791); a `transport` says what it kept.
    public var networkFailure: NetworkFailure? {
        switch self {
        case .offline: .offline
        case .transport(_, let failure): failure
        default: nil
        }
    }
}

/// A sign-in waiting for its second factor (`auth.v1.LoginResponse.mfa_token`,
/// #383): opaque, single use, and valid for `expiresIn` seconds.
public struct SecondStepChallenge: Equatable, Sendable {
    public let token: String
    public let expiresIn: TimeInterval

    public init(token: String, expiresIn: TimeInterval) {
        self.token = token
        self.expiresIn = expiresIn
    }
}

/// How a password sign-in ended.
public enum LoginOutcome: Equatable, Sendable {
    /// The session is the app's.
    case signedIn
    /// Two-step sign-in is on: the holder's code finishes it.
    case needsSecondStep(SecondStepChallenge)
}

extension AuthError: NetworkUnavailabilityDescribing {
    /// Only `offline`: a server error during a refresh is not the network's
    /// (#791).
    public var isNetworkUnavailable: Bool { self == .offline }
}
