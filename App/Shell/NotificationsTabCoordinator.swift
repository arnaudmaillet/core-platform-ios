import CoreNavigation
import NotificationsInterface
import UIKit

/// Owns the Notifications (Activity) tab: the viewer's activity feed, whose
/// rows route to the relevant post or profile.
@MainActor
final class NotificationsTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let notificationsViewController = container.notificationsFeature.makeNotificationsViewController()
        navigationController.viewControllers = [notificationsViewController]
        // The VC sets its own title ("Activity"), which UIKit proxies onto the
        // tab bar item; match it here so the tab reads consistently.
        navigationController.tabBarItem = UITabBarItem(
            title: "Activity",
            image: UIImage(systemName: "bell"),
            selectedImage: UIImage(systemName: "bell.fill")
        )
        refreshBadge()
    }

    /// Updates the tab's unread badge from the server count. Best-effort and
    /// idempotent — safe to call on start and on every tab switch.
    func refreshBadge() {
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            navigationController.tabBarItem.badgeValue = count > 0 ? String(count) : nil
        }
    }
}
