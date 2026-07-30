import CoreNavigation
import FeedInterface
import UIKit

/// Owns the For You tab: the curated discovery grid as a root destination, on
/// its own navigation stack.
///
/// This took over the bar slot the Feed button used to hold. The difference is
/// the whole point of the change: that slot was an *action* — its selection was
/// vetoed and the timeline was pushed onto whatever tab you were on — whereas
/// this is an ordinary root tab with a stack of its own. The feed did not go
/// away; it moved behind a tile tap (see `ForYouViewController.openFeed`), and
/// the timeline remains reachable as a route through `FeedFlowCoordinator`.
///
/// Built once and retained for the session, like the Profile tab: a tab root
/// cannot be rebuilt on every visit without throwing away scroll position and
/// loaded pages on every tab switch.
@MainActor
final class ForYouTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    private(set) lazy var tab = UITab(
        title: "For You",
        image: UIImage(systemName: "sparkles"),
        identifier: AppTab.forYou.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        navigationController.viewControllers = [container.feedFeature.makeForYouViewController()]
    }
}
