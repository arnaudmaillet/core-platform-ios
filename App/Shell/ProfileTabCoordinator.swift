import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit

/// Owns the Profile tab: the signed-in viewer's own profile, which also hosts
/// the Log Out affordance and — folded in from the former Activity tab — the
/// notifications feed, reached via a bell in the nav bar. Composed here at the
/// shell layer so the Profile and Notifications packages stay decoupled.
@MainActor
final class ProfileTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    private let onLogout: () -> Void

    private(set) lazy var tab = UITab(
        title: "Profile",
        image: UIImage(systemName: "person.crop.circle"),
        identifier: AppTab.profile.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
    }

    func start() {
        let profileViewController = container.profileFeature.makeCurrentUserProfileViewController(onLogout: onLogout)
        // Activity lives inside Profile now: a bell in the nav bar opens the
        // notifications feed, and the unread count surfaces on the Profile tab
        // badge so it stays visible from the bar. It goes on the *leading* side —
        // the Profile VC owns the trailing item (its account overflow menu) and
        // resets it in viewDidLoad, which would clobber anything we set there.
        profileViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "bell"),
            primaryAction: UIAction { [weak self] _ in self?.showActivity() }
        )
        navigationController.viewControllers = [profileViewController]
        refreshBadge()
    }

    private func showActivity() {
        let activity = container.notificationsFeature.makeNotificationsViewController()
        navigationController.pushViewController(activity, animated: true)
    }

    /// Updates the Profile tab's unread badge from the server count. Best-effort
    /// and idempotent — safe to call on start and on every tab switch.
    func refreshBadge() {
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            tab.badgeValue = count > 0 ? String(count) : nil
        }
    }
}
