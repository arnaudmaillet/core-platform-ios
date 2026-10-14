import Foundation

/// External identity providers offered on the method-selection screen.
/// Selecting one routes to a federated flow (no backend support yet —
/// surfaced as unavailable).
///
/// Apple and Google only (guest mode, decision 2): Sign in with Apple is the
/// equivalent login guideline 4.8 requires next to Google.
enum IdentityProvider: CaseIterable, Sendable {
    case apple
    case google

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }
}

/// The explicit sign-in methods listed on the first screen, in display
/// order: federated providers first, then the credential flows.
enum SignInMethod: Equatable, Sendable {
    case provider(IdentityProvider)
    case email
    case phone
    /// One of the account's passkeys (#551): sign-in only, offered when the
    /// app has an authenticator to ask.
    case passkey

    static let all: [SignInMethod] =
        IdentityProvider.allCases.map(SignInMethod.provider) + [.email, .phone]

    /// The rows the first screen lists: the passkey FIRST when there is one
    /// to ask (#840 — passkeys are promoted), then the providers, then codes.
    static func offered(passkeys: Bool) -> [SignInMethod] {
        (passkeys ? [.passkey] : []) + IdentityProvider.allCases.map(SignInMethod.provider) + [.email, .phone]
    }

    var displayName: String {
        switch self {
        case .provider(let provider): "Continue with \(provider.displayName)"
        case .email: "Continue with email"
        case .phone: "Continue with phone"
        case .passkey: "Sign in with a passkey"
        }
    }
}
