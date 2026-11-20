import AuthInterface
import UIKit

/// The auth feature's entry point, resolved by the composition root and
/// consumed through `AuthFeatureBuilding` by the app shell.
@MainActor
public struct AuthFeatureBuilder: AuthFeatureBuilding {
    /// Everything the sign-in flow needs, handed in by the composition root
    /// (#2375): the app wires every one of them, so each is required and
    /// forgetting one fails to compile.
    public struct Dependencies {
        /// The session: codes, sign-in, sign-up and their completion.
        public var sessionManager: SessionManager
        /// The new account's profile (`profile.v1`), written when a sign-up
        /// completes.
        public var profileSetup: any AccountProfileSetup
        /// The new account's home country.
        public var homeCountry: @Sendable () async -> String
        /// Sign in with Apple's sheet ("Continue with Apple").
        public var federated: any FederatedSignInProviding
        /// The device's passkeys (#551), made when a flow starts: "Sign in
        /// with a passkey" on the first screen.
        public var passkeys: @MainActor () -> any PasskeyAuthorizing
        /// The legal line's pages (#1811), the same as Settings → Support and
        /// Legal's.
        public var legalLinks: AuthLegalLinks

        public init(
            sessionManager: SessionManager,
            profileSetup: any AccountProfileSetup,
            homeCountry: @escaping @Sendable () async -> String,
            federated: any FederatedSignInProviding,
            passkeys: @escaping @MainActor () -> any PasskeyAuthorizing,
            legalLinks: AuthLegalLinks
        ) {
            self.sessionManager = sessionManager
            self.profileSetup = profileSetup
            self.homeCountry = homeCountry
            self.federated = federated
            self.passkeys = passkeys
            self.legalLinks = legalLinks
        }
    }

    private let sessionManager: SessionManager
    private let profileSetup: any AccountProfileSetup
    private let homeCountry: @Sendable () async -> String
    private let federated: any FederatedSignInProviding
    private let passkeys: @MainActor () -> any PasskeyAuthorizing
    private let legalLinks: AuthLegalLinks

    public init(dependencies: Dependencies) {
        sessionManager = dependencies.sessionManager
        profileSetup = dependencies.profileSetup
        homeCountry = dependencies.homeCountry
        federated = dependencies.federated
        passkeys = dependencies.passkeys
        legalLinks = dependencies.legalLinks
    }

    private func makeFlow() -> LoginFlowCoordinator {
        LoginFlowCoordinator(
            // Codes are the only way in since passwords went (#840).
            signUp: sessionManager,
            federated: federated,
            passkeys: passkeys(),
            profileSetup: profileSetup,
            homeCountry: homeCountry,
            legalLinks: legalLinks
        )
    }

    public func makeLoginViewController() -> UIViewController {
        makeFlow().start()
    }

    /// The gated action's `prompt` is not shown (#1908, the owner): the
    /// sheet has no title and no reason line.
    public func makeSignInViewController(prompt: String?) -> UIViewController {
        makeFlow().start()
    }
}
