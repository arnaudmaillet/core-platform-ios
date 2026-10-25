import CoreModels
import CoreNavigation
import FeedInterface
import DesignSystem
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
final class ForYouTabCoordinator: TabCoordinator, GlyphTab {
    let glyph = TabGlyph.forYou
    /// Whether For You has something new — its glyph's badge (#1191).
    private(set) var hasUnread = false
    var onUnreadChange: (() -> Void)?
    /// The tab's wish for a dark bar changed (`wantsDarkTabBar`).
    var onTabBarStyleChange: (() -> Void)?

    /// The notifications drawer slid the shell aside (true) or closed: Shots
    /// pauses behind it (#1703).
    func setSetAside(_ setAside: Bool) {
        (navigationController.viewControllers.first as? any ForYouSectorPaging)?.setSetAside(setAside)
    }

    /// The tab bar goes dark over the For You tab's Shots (#1697, #1703) —
    /// not over Feed.
    var wantsDarkTabBar: Bool {
        (navigationController.viewControllers.first as? any ForYouSectorPaging)?.isShowingShots ?? true
    }
    var childCoordinators: [Coordinator] = []
    let navigationController: UINavigationController = ChevronBackNavigationController()

    private let container: AppContainer
    /// The shell's bell, minted into this header's leading edge.
    private let notificationsBell: NotificationsBell

    private(set) lazy var tab = UITab(
        title: "For You",
        image: TabGlyph.forYou.image(selected: false, badged: false),
        identifier: AppTab.forYou.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer, notificationsBell: NotificationsBell) {
        self.container = container
        self.notificationsBell = notificationsBell
    }

    /// The header's balance badge — the same object the Explore header wears,
    /// so the number, the claim countdown and the sheet cannot drift between
    /// the two. Held for the coordinator's life, which is the process's.
    private var walletBadge: WalletBadgeInstaller?

    func start() {
        // The tab is the Feed | Shots sector (#1703, #1705), landing on Shots
        // (the full-screen posts). The shell's bell leads both pages; Feed
        // wears the shell's points badge, Shots its own.
        let sector = container.feedFeature.makeForYouSectorViewController { [weak self] presentation in
            self?.apply(presentation)
        }
        navigationController.viewControllers = [sector]
        // ⚠️ LOADED WITHOUT BEING SHOWN (#748). The tab item's badge comes from
        // Feed's counts, bound and loaded in its `viewDidLoad` — reached
        // through the sector's, which loads both pages. Never opened, it never
        // counted, and the badge stayed blank until For You was selected.
        // Loaded a beat later, off the launch's first frame.
        DispatchQueue.main.async { [weak sector] in sector?.loadViewIfNeeded() }
        // The tab bar is Shots' dark over Shots only (#1703): Feed wears the
        // app's.
        (sector as? any ForYouSectorPaging)?.onPageChange = { [weak self] in self?.onTabBarStyleChange?() }
        // A guest gets neither the bell nor the balance (#1146, the owner
        // 2026-10-14). This stack is rebuilt on every change of viewer
        // (`MainTabCoordinator.viewerDidChange`), so a sign-up brings both.
        guard container.memberGate.isMember else {
            walletBadge = nil
            return
        }
        (sector as? any HeaderAccessoryHosting)?.setLeadingAccessoryItem(notificationsBell.makeItem())
        // ⚠️ Installed through the SCREEN, not onto its `navigationItem`: each
        // page composes its own trailing run, so an item written from out
        // here would be erased by it.
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController,
            makeSheet: { [unowned container] in container.makeWalletSheet() }
        ) { [weak sector] item in
            (sector as? (any HeaderAccessoryHosting))?.setTrailingAccessoryItem(item)
        }
    }

    /// The tab item follows how much is waiting on the screen's rows — its
    /// title is always "For You" (#1423).
    ///
    /// ⚠️ **The `UITab` is built lazily and its title/image are `var`s on the
    /// live object**, so this must not re-create it — `tabs` is assigned once
    /// in `MainTabCoordinator` and a replacement item would never reach the bar.
    /// Touching `tab` here is also what forces the lazy build if the shell has
    /// not asked for it yet, which is harmless: the provider closure only runs
    /// when the tab is selected.
    private func apply(_ presentation: ForYouTabPresentation) {
        // The owner's glyph (#1191), and no count: the badge variant says
        // there is something new.
        tab.badgeValue = nil
        let unread = presentation.badgeCount > 0
        if unread != hasUnread {
            hasUnread = unread
            onUnreadChange?()
        }
    }
}
