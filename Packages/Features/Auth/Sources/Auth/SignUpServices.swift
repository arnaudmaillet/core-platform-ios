import Foundation

/// What the sign-up steps ask of the session — `SessionManager`'s, faked in
/// tests (guest mode B4, #449).
public protocol CodeSignUpPerforming: Sendable {
    func startVerification(_ channel: VerificationChannel, to destination: String, locale: String) async throws -> VerificationChallenge
    func signIn(challengeID: String, code: String) async throws -> CodeSignIn
    func signUp(challengeID: String, code: String, details: SignUpDetails) async throws -> SignUpOutcome
    func completeSignUp(_ pending: PendingAccount) async throws
}

extension SessionManager: CodeSignUpPerforming {}

/// A handle, as the server would take it.
public enum HandleCheck: Equatable, Sendable {
    /// Free; `normalized` is how it would be stored (lower-cased).
    case available(normalized: String)
    case taken
    /// Not a valid handle — `reason` says why, in the server's words.
    case invalid(reason: String)
    /// No answer (offline): the step lets the person try, and creating says.
    case unknown
}

/// The profile a new account needs before it is the app's member — answered
/// by the app (`profile.v1`), which the Auth feature does not import.
public protocol AccountProfileSetup: Sendable {
    func checkHandle(_ handle: String) async -> HandleCheck
    /// `profile.v1.CreateProfile`, with the PENDING account's own token: the
    /// app's session is still the guest's until `completeSignUp`.
    func createProfile(for account: PendingAccount, handle: String, displayName: String) async throws
}

/// The privacy policy a sign-up agrees to, by version — what `SignUp`
/// records with the consent. Bumped with the policy.
public enum PrivacyPolicy {
    public static let version = "2026-10-01"
}
