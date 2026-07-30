import UIKit

/// The buttons of the app shell's bar, in bar order. The search tab is rendered
/// detached at the trailing edge by the system (see `SearchTabCoordinator`'s
/// `UISearchTab`), giving the grouped layout
/// `| Maps  For You  Messages  Profile |  Search |` with no custom bar.
///
/// **Every case here is now a real selectable root.** Slot 1 used to be `.feed`,
/// a bar button that was not a *place*: its selection was vetoed and the
/// timeline was pushed onto whichever tab you were on. It is now `.forYou`, an
/// ordinary tab with its own stack; the timeline moved behind a tile tap on
/// that grid and stays reachable as `AppRoute.feed` (see `FeedFlowCoordinator`).
///
/// Backed by a stable string identifier (not an ordinal), so reordering the bar
/// never silently repoints a route.
///
/// ⚠️ Declaration order IS bar order, and `-select-tab <n>` indexes
/// `allCases` — indices are unchanged by the Feed→For You swap (both sit at 1),
/// but `-select-tab 1` now SELECTS a tab where it used to trigger a push.
enum AppTab: String, CaseIterable {
    case maps
    case forYou
    case messages
    case profile
    case search
}

/// The navigation surface the `RouteResolver` drives: which tab is showing and
/// where to push. Implemented by `MainTabCoordinator`; held weakly by the
/// resolver so a torn-down shell (e.g. after logout) simply stops answering.
@MainActor
protocol AppNavigating: AnyObject {
    /// The navigation controller of the currently selected tab — the stack a
    /// routed destination is pushed onto (per the "push on the current tab"
    /// rule), and the presenter for modal routes.
    var activeNavigationController: UINavigationController? { get }

    /// Switches the selected tab (a no-op if already selected).
    func selectTab(_ tab: AppTab)

    /// Opens the timeline feed: dismisses anything presented, then pushes the
    /// retained feed onto the currently selected tab's stack. No longer has a
    /// bar button behind it — this is what `AppRoute.feed` resolves to (deep
    /// links, push payloads), and it is deliberately kept: the For You grid
    /// opens a *seeded* feed, which is a different construction of the same
    /// screen, not a replacement for the open-ended timeline.
    func openFeed()
}
