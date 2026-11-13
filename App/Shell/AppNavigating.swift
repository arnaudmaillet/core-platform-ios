import CoreNavigation
import UIKit

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

    /// Closes whatever stands BESIDE the tab stacks rather than on them — the
    /// notifications drawer. Called at the start of every route: a route
    /// lands on a tab stack, and the viewer should see it land.
    func closeOverlays()

    /// Opens the timeline feed: dismisses anything presented, then pushes the
    /// retained feed onto the currently selected tab's stack. No longer has a
    /// bar button behind it — this is what `AppRoute.feed` resolves to (deep
    /// links, push payloads), and it is deliberately kept: the For You grid
    /// opens a *seeded* feed, which is a different construction of the same
    /// screen, not a replacement for the open-ended timeline.
    func openFeed()
}
