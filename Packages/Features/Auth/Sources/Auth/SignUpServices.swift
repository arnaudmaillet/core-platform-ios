import Foundation

/// What the sign-up steps ask of the session — `SessionManager`'s, faked in
/// tests (guest mode B4, #449; Apple and Google, #507).
public protocol SignUpPerforming: Sendable {
    func startVerification(_ channel: VerificationChannel, to destination: String, locale: String) async throws -> VerificationChallenge
    func startFederatedSignIn() async throws -> String
    func signIn(_ credential: SignInCredential) async throws -> CodeSignIn
    func signUp(_ credential: SignInCredential, details: SignUpDetails) async throws -> SignUpOutcome
    func completeSignUp(_ pending: PendingAccount) async throws
}

extension SessionManager: SignUpPerforming {}

/// A native provider's sign-in sheet (Sign in with Apple): an id_token
/// minted for `nonce`, and the name the person shared, if any.
@MainActor
public protocol FederatedSignInProviding {
    func signIn(with provider: FederatedProvider, nonce: String) async throws -> FederatedSignInResult
}

public struct FederatedSignInResult: Equatable, Sendable {
    public let idToken: String
    /// Apple shares the name once, at the first sign-in: it seeds the
    /// profile's name.
    public let displayName: String?

    public init(idToken: String, displayName: String?) {
        self.idToken = idToken
        self.displayName = displayName
    }
}

/// The person closed the provider's sheet: nothing to say.
public struct FederatedSignInCancelled: Error {
    public init() {}
}

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
