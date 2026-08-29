import CoreNavigation
import CoreStorage
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
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.container.router.route(to: .upload)
            }
        )
        item.accessibilityLabel = "Create Post"
        return item
    }()

    /// The wallet's toolbar face: coin + balance, pulsing while a claim waits.
    /// Everything around it — the store observation, the claim wake-up, the
    /// width-change reinstall, the sheet — lives in `WalletBadgeInstaller`,
    /// which the For You and Profile headers wear too.
    private var walletBadge: WalletBadgeInstaller?
    /// The screen wearing the bar items, for the reinstall.
    private weak var mapViewController: UIViewController?

    init(container: AppContainer, notificationsButtonItem: UIBarButtonItem) {
        self.container = container
        self.notificationsButtonItem = notificationsButtonItem
    }

    func start() {
        let mapViewController = container.mapsFeature.makeMapViewController()
        self.mapViewController = mapViewController
        // The Notifications (bell) entry point lives here — and only here: a
        // navigationItem belongs to this one view controller, so no other tab
        // can show it and nothing needs conditional hiding. It is injected by
        // the shell (it carries unread state) so the Maps package stays
        // Notifications-agnostic.
        //
        // The avatar that used to sit to its right is gone: Profile is a root
        // tab now, and two entry points to one destination is one too many.
        // The wallet badge now stands where it stood — trailing group, inboard
        // of the bell ([coin] [bell]) — in its own glass bubble via
        // `sharesBackground = false` rather than the fixedSpace the avatar
        // era used.
        // The post-creation "+" sits opposite the pair, top-left.
        mapViewController.navigationItem.leftBarButtonItem = createPostButtonItem
        navigationController.viewControllers = [mapViewController]

        // The badge stands where the avatar used to — trailing group, inboard
        // of the bell ([coin] [bell]).
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController
        ) { [weak self] item in
            guard let self else { return }
            self.mapViewController?.navigationItem.rightBarButtonItems =
                [self.notificationsButtonItem, item]
        }

        #if DEBUG
        // `-open-wallet`: presents the wallet sheet ~1s after launch — the
        // badge opens it on tap, which the sim can't deliver. Pair with
        // `-wallet-claim-ready` (claimable state) or `-wallet-demo-claim`
        // (fires the claim itself).
        if ProcessInfo.processInfo.arguments.contains("-open-wallet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.presentWalletSheet()
            }
        }
        #endif
    }

    private func presentWalletSheet() {
        walletBadge?.presentSheet()
    }
}
