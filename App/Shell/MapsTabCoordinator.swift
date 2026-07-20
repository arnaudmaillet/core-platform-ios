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

    /// The post-creation entry point: a top-left "+" that opens the compose
    /// flow. Stateless (unlike the avatar, which carries image + unread state,
    /// so the shell injects it) — the tap just fires the `.upload` route, which
    /// the resolver presents as the compose sheet. Constructed here so the tap
    /// is owned by the coordinator, not the map surface; the Maps package stays
    /// navigation-agnostic. iOS 26 renders bar items in a glass bubble natively,
    /// so no custom chrome is needed to match the header aesthetic.
    private lazy var createPostButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.container.router.route(to: .upload)
            }
        )
        item.accessibilityLabel = "Create Post"
        return item
    }()

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
        // The post-creation "+" sits opposite the avatar, top-left.
        mapViewController.navigationItem.leftBarButtonItem = createPostButtonItem
        navigationController.viewControllers = [mapViewController]
    }
}
