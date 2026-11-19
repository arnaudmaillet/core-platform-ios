import CoreModels
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
    let navigationController: UINavigationController = ArbitratedNavigationController()

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
    /// The image is the owner's glyph (#1191); its selected face is set by
    /// the shell (`MainTabCoordinator.refreshTabGlyphs`, #1197).
    private(set) lazy var tab: UITab = {
        let tab = UITab(
            title: "Explore",
            image: TabGlyph.explore.image(selected: false, badged: false),
            identifier: AppTab.explore.rawValue
        ) { [navigationController] _ in navigationController }
        return tab
    }()

    /// Search, at the very edge of the trailing group.
    ///
    /// It lives here rather than in the bar because the bar's detached trailing
    /// item is the "+" menu now (`CreateTabItem`). Constructed by the
    /// coordinator so the tap is owned by navigation and the Maps package stays
    /// navigation-agnostic — exactly as the header "+" that stood opposite it
    /// used to be.
    private lazy var searchButtonItem: UIBarButtonItem = BarItems.icon(
        id: BarItems.SharedID.search, image: UIImage(systemName: "magnifyingglass"), label: "Search"
    ) { [weak self] in
        self?.container.router.route(to: .search)
    }

    // NO BALANCE ON THE MAP (#2336, the owner 2026-11-12): the likes balance
    // shows where likes are spent or earned, and nothing is spent on the map —
    // a tap opens the post, which wears the balance itself. So this
    // coordinator builds no `WalletBadgeInstaller`; a screen pushed onto this
    // stack (a post, a profile, the search results) brings its own badge, and
    // the shared identifier lets UIKit take it in and out of the bar cleanly.

    /// The screen wearing the bar items, for the reinstall.
    private weak var mapViewController: UIViewController?

    /// Signed in or out: the map's people (dock, Friends / Following rows)
    /// belong to the viewer, and this stack is not rebuilt for that.
    func viewerDidChange() {
        (mapViewController as? any MapViewerRefreshing)?.viewerDidChange()
        installBarItems()
    }

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
        // ⚠️ THE BELL MOVED TO THE LEADING EDGE and the "+" is gone — the
        // compose screen it opened has been removed from the product. The
        // balance that stood inboard of the search went too (#2336): the
        // header now reads `[bell] … [search]`.
        // ⚠️ NO TITLE IN THE BAR. "Maps" (the tab's name then; "Explore" now)
        // was written here for a while (the controller is navigation-agnostic,
        // so the coordinator was the one place to write it); it went with For
        // You's on 2026-09-22 — the two roots' headers carry their controls and
        // nothing else, and the tab bar already says the word.
        // The chevron on every screen pushed from here stays bare — see the
        // same line on the other roots for the widths it protects.
        mapViewController.navigationItem.backButtonDisplayMode = .minimal
        navigationController.viewControllers = [mapViewController]
        // The guest without location's way out leads the bar (#1907): it comes
        // and goes with the map's offer.
        (mapViewController as? any GuestLocationOffering)?.onGuestLocationOfferChange = { [weak self] _ in
            self?.applyBarItems()
        }
        installBarItems()
        // No `-open-wallet` here any more: the map wears no badge (#2336), and
        // For You presents the sheet at launch.
    }

    /// The header for the viewer now: a member's `[bell] … [search]`, a
    /// guest's `… [search]` alone (#1146, the owner 2026-10-14: no bell for a
    /// guest). No balance for either (#2336). Run at start and on every
    /// sign-up and sign-out, so the items come and go without a relaunch.
    private func installBarItems() {
        applyBarItems()
    }

    /// "Allow location" (#1907): the location glyph and the title in one
    /// bubble the bar draws (`BarItems.labeled`); a tap asks, or opens
    /// Settings once denied.
    private func allowLocationItem(for offering: (any GuestLocationOffering)?) -> UIBarButtonItem {
        let (item, label) = BarItems.labeled(
            id: Self.allowLocationItemID, title: "Allow location", image: UIImage(systemName: "location.fill")
        ) { [weak offering] in offering?.allowGuestLocation() }
        label.accessibilityHint = "Shows posts around you"
        return item
    }

    static let allowLocationItemID = "explore.allow-location"

    private func applyBarItems() {
        guard let map = mapViewController else { return }
        // The trailing group through the toasts' door (#1420, #1679): under a
        // bar toast these are the items that come back.
        guard container.memberGate.isMember else {
            // `[Allow location] … [search]` while the guest's location is not
            // allowed (#1907); the leading slot is empty otherwise.
            let offering = map as? any GuestLocationOffering
            let items = offering?.offersGuestLocation == true ? [allowLocationItem(for: offering)] : []
            if map.navigationItem.leftBarButtonItems?.map(\.identifier) != items.map(\.identifier) {
                // ⚠️ `viewIfLoaded`: reading `view` would load the map here, and
                // its `viewDidLoad` re-enters this method with the real offer —
                // which this call, computed before, would then overwrite.
                map.navigationItem.setLeftBarButtonItems(items, animated: map.viewIfLoaded?.window != nil)
            }
            map.setOwnTrailingBarItems([searchButtonItem], animated: false)
            return
        }
        map.navigationItem.leftBarButtonItem = notificationsButtonItem
        // ⚠️ `[0]` IS THE SCREEN EDGE: search takes the corner the bell used
        // to hold, alone — no balance on the map (#2336). No Shop door (#1494,
        // the owner 2026-10-21): the Rewards sheet's Shop tile and the stake
        // menu open it.
        map.setOwnTrailingBarItems([searchButtonItem], animated: false)
    }
}
