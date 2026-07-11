import CoreNavigation
import MapsInterface
import UIKit

/// Owns the Maps tab: the map surface vended by the Maps feature behind the
/// `MapsFeatureBuilding` seam, on its own navigation stack (Step B pushes/
/// presents the vertical snap feed here).
@MainActor
final class MapsTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    private let profileButtonItem: UIBarButtonItem

    private(set) lazy var tab = UITab(
        title: "Maps",
        image: UIImage(systemName: "map"),
        identifier: AppTab.maps.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer, profileButtonItem: UIBarButtonItem) {
        self.container = container
        self.profileButtonItem = profileButtonItem
    }

    func start() {
        let mapViewController = container.mapsFeature.makeMapViewController()
        // The Profile entry point lives here — and only here — as the viewer's
        // avatar: a navigationItem belongs to this one view controller, so no
        // other tab can show it and nothing needs conditional hiding. Injected
        // by the shell so the Maps package stays Profile-agnostic.
        mapViewController.navigationItem.rightBarButtonItem = profileButtonItem
        navigationController.viewControllers = [mapViewController]
    }
}
