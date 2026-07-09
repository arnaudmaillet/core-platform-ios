import UIKit

/// The tabs of the app shell, in bar order. The search tab is rendered detached
/// at the trailing edge by the system (see `SearchTabCoordinator`'s `UISearchTab`),
/// giving the grouped layout `| Maps  Feed  Messages  Profile |  Search |` with no
/// custom bar. Activity is not a tab — it lives inside the Profile tab.
///
/// Backed by a stable string identifier (not an ordinal), so reordering the bar
/// never silently repoints a route.
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

    /// Switches the selected tab (a no-op if already selected).
    func selectTab(_ tab: AppTab)
}
