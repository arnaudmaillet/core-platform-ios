import AuthInterface
import UIKit

/// The auth feature's entry point, resolved by the composition root and
/// consumed through `AuthFeatureBuilding` by the app shell.
@MainActor
public struct AuthFeatureBuilder: AuthFeatureBuilding {
    private let sessionManager: SessionManager

    public init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    public func makeLoginViewController() -> UIViewController {
        LoginFlowCoordinator(loginService: sessionManager).start()
    }
}
