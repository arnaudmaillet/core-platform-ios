import UIKit

/// A tab root whose first tab hands a rightward swipe to the shell's drawer
/// (#1739, the owner 2026-10-25).
///
/// For You, Messages and Profile are horizontally paged tabs. On the FIRST
/// one there is nothing to page back to, so a rightward swipe anywhere on it
/// opens the notifications drawer — through the root's pager, which declines
/// that drag (`yieldsDrag`, `yieldsRightwardDragOnFirstPage`), and behind
/// every horizontal scroller of the page (`SideDrawerContainerViewController
/// .OpenRegion.anywhere`). Elsewhere — another tab, a root that does not adopt
/// this (Explore's map) — a rightward swipe is never the drawer's; the bell
/// still opens it.
@MainActor
public protocol DrawerSwipeHosting: AnyObject {
    /// Whether a rightward swipe on this root may open the drawer now: it is
    /// showing its first tab.
    var opensDrawerOnRightwardSwipe: Bool { get }
}
