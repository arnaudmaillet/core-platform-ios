import CoreNavigation
import DesignSystem
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
    private let notificationsButtonItem: UIBarButtonItem

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
            bouncingImage: UIImage(systemName: "plus"),
            accessibilityLabel: "Create Post"
        ) { [weak self] in
            self?.container.router.route(to: .upload)
        }
        return item
    }()

    init(container: AppContainer, notificationsButtonItem: UIBarButtonItem) {
        self.container = container
        self.notificationsButtonItem = notificationsButtonItem
    }

    func start() {
        let mapViewController = container.mapsFeature.makeMapViewController()
        // The Notifications (bell) entry point lives here — and only here: a
        // navigationItem belongs to this one view controller, so no other tab
        // can show it and nothing needs conditional hiding. It is injected by
        // the shell (it carries unread state) so the Maps package stays
        // Notifications-agnostic.
        //
        // The avatar that used to sit to its right is gone: Profile is a root
        // tab now, and two entry points to one destination is one too many. The
        // bell is alone in the trailing slot, so the fixedSpace that used to
        // keep the two in separate glass bubbles went with it — on its own it
        // would only push the bell inboard.
        mapViewController.navigationItem.rightBarButtonItems = [notificationsButtonItem]
        // The post-creation "+" sits opposite the bell, top-left.
        mapViewController.navigationItem.leftBarButtonItem = createPostButtonItem
        navigationController.viewControllers = [mapViewController]
    }
}
