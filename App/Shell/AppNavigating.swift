import UIKit

/// The buttons of the app shell's bar, in bar order. The search tab is rendered
/// detached at the trailing edge by the system (see `SearchTabCoordinator`'s
/// `UISearchTab`), giving the grouped layout `| Maps  Feed  Messages |  Search |`
/// with no custom bar, giving `| Maps  Feed  Messages  Profile |  Search |`.
/// Feed is a bar button but not a *place*: selecting it is vetoed and the
/// timeline is pushed onto the current tab's stack instead (see
/// `FeedFlowCoordinator`), so `.feed` here names the bar slot, never a
/// selectable root.
///
/// Backed by a stable string identifier (not an ordinal), so reordering the bar
/// never silently repoints a route.
///
/// ⚠️ Declaration order IS bar order, and `-select-tab <n>` indexes
/// `allCases` — so adding `.profile` in its bar position shifted Search from
/// index 3 to 4. Any note or script pinned to the old numbering needs updating.
enum AppTab: String, CaseIterable {
    case maps
    case feed
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

    /// Switches the selected tab (a no-op if already selected). `.feed` is
    /// rerouted to `openFeed()` — it has no root to select.
    func selectTab(_ tab: AppTab)

    /// Opens the timeline feed: dismisses anything presented, then pushes the
    /// retained feed onto the currently selected tab's stack — the Feed bar
    /// button's action semantics. Idempotent when the feed is already showing.
    func openFeed()
}
