import CoreNavigation
import UIKit

/// Owns the Search tab. Placeholder until the search feature is built.
@MainActor
final class SearchTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    func start() {
        let placeholder = PlaceholderViewController(
            title: "Search",
            systemImage: "magnifyingglass",
            message: "Discover people and posts."
        )
        navigationController.viewControllers = [placeholder]
        navigationController.tabBarItem = UITabBarItem(
            title: "Search",
            image: UIImage(systemName: "magnifyingglass"),
            selectedImage: UIImage(systemName: "magnifyingglass")
        )
    }
}
