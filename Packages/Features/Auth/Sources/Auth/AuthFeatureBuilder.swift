import AuthInterface
import UIKit

/// The auth feature's entry point, resolved by the composition root and
/// consumed through `AuthFeatureBuilding` by the app shell.
@MainActor
public struct AuthFeatureBuilder: AuthFeatureBuilding {
    private let sessionManager: SessionManager
    /// The new account's profile (`profile.v1`), from the composition root.
    /// Nil: "email" and "phone" keep the password / unavailable paths.
    private let profileSetup: (any AccountProfileSetup)?
    private let homeCountry: @Sendable () async -> String

    public init(
        sessionManager: SessionManager,
        profileSetup: (any AccountProfileSetup)? = nil,
        homeCountry: @escaping @Sendable () async -> String = { Locale.current.region?.identifier ?? "" }
    ) {
        self.sessionManager = sessionManager
        self.profileSetup = profileSetup
        self.homeCountry = homeCountry
    }

    private func makeFlow() -> LoginFlowCoordinator {
        LoginFlowCoordinator(
            loginService: sessionManager,
            // Codes and sign-up need a place to make the profile: without
            // one, the flow keeps its password path.
            signUp: profileSetup == nil ? nil : sessionManager,
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
