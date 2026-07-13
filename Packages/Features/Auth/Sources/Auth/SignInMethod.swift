import Foundation

/// External identity providers offered on the method-selection screen.
/// Selecting one routes to a federated flow (no backend support yet —
/// surfaced as unavailable).
enum IdentityProvider: CaseIterable, Sendable {
    case apple
    case google
    case microsoft

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .microsoft: "Microsoft"
        }
    }
}

/// The explicit sign-in methods listed on the first screen, in display
/// order: federated providers first, then the credential flows.
enum SignInMethod: Equatable, Sendable {
    case provider(IdentityProvider)
    case email
    case phone

    static let all: [SignInMethod] =
        IdentityProvider.allCases.map(SignInMethod.provider) + [.email, .phone]

    var displayName: String {
        switch self {
        case .provider(let provider): "Continue with \(provider.displayName)"
        case .email: "Login with Email"
        case .phone: "Login with Phone"
        }
    }
}
