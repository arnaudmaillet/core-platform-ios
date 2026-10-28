import AuthInterface
import UIKit

/// The auth feature's entry point, resolved by the composition root and
/// consumed through `AuthFeatureBuilding` by the app shell.
@MainActor
public struct AuthFeatureBuilder: AuthFeatureBuilding {
    private let sessionManager: SessionManager
    /// The new account's profile (`profile.v1`), from the composition root.
    /// Nil: a sign-up completes without one.
    private let profileSetup: (any AccountProfileSetup)?
    private let homeCountry: @Sendable () async -> String
    /// Sign in with Apple's sheet. Nil keeps "Continue with Apple" unavailable.
    private let federated: (any FederatedSignInProviding)?
    /// The device's passkeys (#551). Nil leaves "Sign in with a passkey" off
    /// the first screen.
    private let passkeys: (@MainActor () -> any PasskeyAuthorizing)?
    /// The legal line's pages (#1811), the same as Settings → Support and
    /// Legal's.
    private let legalLinks: AuthLegalLinks

    public init(
        sessionManager: SessionManager,
        profileSetup: (any AccountProfileSetup)? = nil,
        homeCountry: @escaping @Sendable () async -> String = { Locale.current.region?.identifier ?? "" },
        federated: (any FederatedSignInProviding)? = nil,
        passkeys: (@MainActor () -> any PasskeyAuthorizing)? = nil,
        legalLinks: AuthLegalLinks = AuthLegalLinks()
    ) {
        self.legalLinks = legalLinks
        self.passkeys = passkeys
        self.sessionManager = sessionManager
        self.profileSetup = profileSetup
        self.homeCountry = homeCountry
        self.federated = federated
    }

    private func makeFlow() -> LoginFlowCoordinator {
        LoginFlowCoordinator(
            // Codes are the only way in since passwords went (#840).
            signUp: sessionManager,
            federated: federated,
            passkeys: passkeys?(),
            profileSetup: profileSetup,
            homeCountry: homeCountry,
            legalLinks: legalLinks
        )
    }

    public func makeLoginViewController() -> UIViewController {
        makeFlow().start()
    }

    public func makeSignInViewController(prompt: String?) -> UIViewController {
        makeFlow().start(prompt: prompt)
    }
}
