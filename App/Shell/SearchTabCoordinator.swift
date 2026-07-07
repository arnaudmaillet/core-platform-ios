import CoreNavigation
import SearchInterface
import UIKit

/// Owns the Search tab: people search, whose results route to profiles.
@MainActor
final class SearchTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let searchViewController = container.searchFeature.makeSearchViewController()
        navigationController.viewControllers = [searchViewController]
        // The search VC sets its own title ("Search"), which UIKit proxies onto
        // the tab bar item; match it here so the tab reads consistently.
        navigationController.tabBarItem = UITabBarItem(
            title: "Search",
            image: UIImage(systemName: "magnifyingglass"),
            selectedImage: UIImage(systemName: "magnifyingglass")
        )
    }
}
