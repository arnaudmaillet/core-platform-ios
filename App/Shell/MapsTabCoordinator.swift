import CoreNavigation
import UIKit

/// Owns the Maps tab. A placeholder empty canvas for now — reserves the tab and
/// its own navigation stack so the real Maps feature can slot in later behind a
/// `MapsFeatureBuilding` seam without touching the shell's tab wiring.
@MainActor
final class MapsTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private(set) lazy var tab = UITab(
        title: "Maps",
        image: UIImage(systemName: "map"),
        identifier: AppTab.maps.rawValue
    ) { [navigationController] _ in navigationController }

    func start() {
        let canvas = UIViewController()
        canvas.title = "Maps"
        canvas.view.backgroundColor = .systemBackground
        navigationController.viewControllers = [canvas]
    }
}
