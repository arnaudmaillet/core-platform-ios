import CoreNavigation
import SearchInterface
import UIKit

/// Owns the Search tab: people search, whose results route to profiles.
///
/// Vends a `UISearchTab` rather than a plain `UITab`: the system gives the
/// search role a pinned, detached placement at the trailing edge of the bar,
/// which is what produces the `| … |  Search |` split natively — no custom bar.
@MainActor
final class SearchTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    private(set) lazy var tab: UITab = UISearchTab { [navigationController] _ in
        navigationController
    }

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let searchViewController = container.searchFeature.makeSearchViewController()
        navigationController.viewControllers = [searchViewController]
    }
}
