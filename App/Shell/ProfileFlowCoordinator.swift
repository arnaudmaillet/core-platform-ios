import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit

/// Pushes the signed-in viewer's profile onto the Maps tab's navigation stack —
/// the destination of the Maps nav-bar avatar button (which replaced the
/// Profile tab). Profile and Notifications are composed here at the shell
/// layer, as the former Profile tab did, so the two packages stay decoupled: a
/// bell in the profile's nav bar pushes the notifications feed onto the same
/// stack, and the native edge-swipe returns to the map.
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
        // Activity lives inside Profile: the bell goes on the *leading* side —
        // the Profile VC owns the trailing item (its account overflow menu) and
        // resets it in viewDidLoad, which would clobber anything we set there.
        // The Profile VC keeps `leftItemsSupplementBackButton`, so the bell sits
        // beside the back button rather than replacing it — the swipe-to-map
        // gesture stays live.
        profileViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "bell"),
            primaryAction: UIAction { [weak self, weak profileViewController] _ in
                guard let self, let navigationController = profileViewController?.navigationController else { return }
                navigationController.pushViewController(
                    container.notificationsFeature.makeNotificationsViewController(),
                    animated: true
                )
            }
        )
        navigationController.pushViewController(profileViewController, animated: true)
    }
}
