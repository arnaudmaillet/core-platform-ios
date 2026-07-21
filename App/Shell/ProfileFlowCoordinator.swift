import CoreNavigation
import ProfileInterface
import UIKit

/// Pushes the signed-in viewer's profile onto the Maps tab's navigation stack —
/// the destination of the Maps nav-bar avatar button (which replaced the
/// Profile tab). Notifications no longer live here: the bell moved to the Maps
/// header beside the avatar, so the pushed profile carries only the native back
/// button and its own account chrome.
///
/// The profile view controller is built per push and released on pop —
/// freshness lives in the repositories and image cache, not in a retained view
/// controller.
@MainActor
final class ProfileFlowCoordinator: Coordinator {
    var childCoordinators: [Coordinator] = []

    private let container: AppContainer
    private let onLogout: () -> Void

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
    }

    /// Nothing to build up front; the profile is assembled per `push` call.
    func start() {}

    /// Pushes the viewer's own profile onto `navigationController` (the Maps
    /// tab's stack). Guarded to the stack root — the avatar that triggers this
    /// only lives on the Maps root's nav bar, so a profile is never stacked on a
    /// profile.
    func push(onto navigationController: UINavigationController) {
        guard navigationController.viewControllers.count == 1,
              navigationController.presentedViewController == nil else { return }

        let profileViewController = container.profileFeature.makeCurrentUserProfileViewController(onLogout: onLogout)
        navigationController.pushViewController(profileViewController, animated: true)
    }
}
