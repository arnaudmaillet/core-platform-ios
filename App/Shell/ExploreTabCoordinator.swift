import CoreNavigation
import CoreStorage
import DesignSystem
import MapsInterface
import UIKit

/// Owns the Explore tab: the map surface vended by the Maps feature behind the
/// `MapsFeatureBuilding` seam, on its own navigation stack (Step B pushes/
/// presents the vertical snap feed here).
///
/// **The TAB is "Explore"; the FEATURE is still Maps.** The tab was called
/// "Maps" until 2026-09-26, which named the instrument rather than the job: the
/// screen is where you search and explore posts laid out on a map, not a
/// directions app. Only the shell's words changed — the `Maps` package,
/// `MapsViewController`, `MapsFeatureBuilding` and every `-maps-*` DEBUG launch
/// argument keep their names, because inside the feature it IS a map.
@MainActor
final class ExploreTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    private let notificationsButtonItem: UIBarButtonItem

    /// A compass: exploring, not route-finding.
    ///
    /// ⚠️ **NOT `safari`**, although it is the better-drawn compass. SF Symbols
    /// restricts `safari`/`safari.fill` ("may only be used to refer to Apple's
    /// Safari browser" — `symbol_restrictions.strings` in CoreGlyphs), so a tab
    /// wearing it would read as a link to the browser and break the symbol's
    /// terms. `location.north.circle` is the unrestricted compass needle.
    ///
    /// The filled variant is stated for the selected state. Measured on the
    /// iOS 27 simulator, the bar fills a symbol in EVERY state anyway (the
    /// other tabs pass outlines — `message`, `sparkles` — and show filled
    /// glyphs whether selected or not), so today this changes nothing on
    /// screen; it keeps the selected glyph right if the bar ever stops doing
    /// that. `selectedImage` is iOS 26.1+ and the target is 26.0, hence the
    /// check.
    private(set) lazy var tab: UITab = {
        let tab = UITab(
            title: "Explore",
            image: UIImage(systemName: "location.north.circle"),
            identifier: AppTab.explore.rawValue
        ) { [navigationController] _ in navigationController }
        if #available(iOS 26.1, *) {
            tab.selectedImage = UIImage(systemName: "location.north.circle.fill")
        }
        return tab
    }()

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
        // ⚠️ NO TITLE IN THE BAR. "Maps" (the tab's name then; "Explore" now)
        // was written here for a while (the controller is navigation-agnostic,
        // so the coordinator was the one place to write it); it went with For
        // You's on 2026-09-22 — the two roots' headers carry their controls and
        // nothing else, and the tab bar already says the word.
        // The chevron on every screen pushed from here stays bare — see the
        // same line on the other roots for the widths it protects.
        mapViewController.navigationItem.backButtonDisplayMode = .minimal
        navigationController.viewControllers = [mapViewController]

        // The badge stands where the avatar used to — trailing group, inboard
        // of the bell ([coin] [bell]).
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController,
            makeSheet: { [unowned container] in container.makeWalletSheet() }
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
