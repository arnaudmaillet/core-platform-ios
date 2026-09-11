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

    /// Search, at the very edge of the trailing group.
    ///
    /// It lives here rather than in the bar because the bar's detached trailing
    /// item is the "+" menu now (`CreateTabItem`). Constructed by the
    /// coordinator so the tap is owned by navigation and the Maps package stays
    /// navigation-agnostic — exactly as the header "+" that stood opposite it
    /// used to be.
    private lazy var searchButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in
                self?.container.router.route(to: .search)
            }
        )
        item.accessibilityLabel = "Search"
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
        // ⚠️ THE BELL MOVED TO THE LEADING EDGE and the "+" is gone — the
        // compose screen it opened has been removed from the product. The
        // header now reads `[bell] … [coins][search]`.
        mapViewController.navigationItem.leftBarButtonItem = notificationsButtonItem
        // The tab's own name, in the bar.
        //
        // ⚠️ WRITTEN HERE, NOT IN THE MAPS PACKAGE. `MapsViewController` is
        // deliberately navigation-agnostic — its own comment says the name
        // "lives on `UITab`, not here" — and this coordinator is already the
        // thing writing this navigation item. A coordinator-side write works on
        // this tab and only this tab: the other three roots set their own
        // titles from `viewDidLoad`, which would clobber anything written here.
        mapViewController.navigationItem.title = "Maps"
        // The chevron on every screen pushed from here stays bare — see the
        // same line on the other titled roots for the widths it protects.
        mapViewController.navigationItem.backButtonDisplayMode = .minimal
        navigationController.viewControllers = [mapViewController]

        // The badge stands where the avatar used to — trailing group, inboard
        // of the bell ([coin] [bell]).
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController
        ) { [weak self] item in
            guard let self else { return }
            // ⚠️ `[0]` IS THE SCREEN EDGE: search takes the corner the bell
            // used to hold, and the wallet badge stays inboard of it.
            self.mapViewController?.navigationItem.rightBarButtonItems =
                [self.searchButtonItem, item]
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
