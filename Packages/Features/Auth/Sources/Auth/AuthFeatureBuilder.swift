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

    public init(
        sessionManager: SessionManager,
        profileSetup: (any AccountProfileSetup)? = nil,
        homeCountry: @escaping @Sendable () async -> String = { Locale.current.region?.identifier ?? "" },
        federated: (any FederatedSignInProviding)? = nil
    ) {
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
            profileSetup: profileSetup,
            homeCountry: homeCountry
        )
    }

    public func makeLoginViewController() -> UIViewController {
        makeFlow().start()
    }

    public func makeSignInViewController(prompt: String?, onClose: @escaping () -> Void) -> UIViewController {
        makeFlow().start(prompt: prompt, onClose: onClose)
    }
}
