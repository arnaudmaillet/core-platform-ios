import CoreNavigation
import UIKit

/// Owns the Notifications tab. Placeholder until the notification feature is
/// built (the notification.v1 stream lands here).
@MainActor
final class NotificationsTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    func start() {
        let placeholder = PlaceholderViewController(
            title: "Notifications",
            systemImage: "bell",
            message: "Your activity will show up here."
        )
        navigationController.viewControllers = [placeholder]
        navigationController.tabBarItem = UITabBarItem(
            title: "Activity",
            image: UIImage(systemName: "bell"),
            selectedImage: UIImage(systemName: "bell.fill")
        )
    }
}
