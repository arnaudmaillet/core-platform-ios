import UIKit

/// A `PagedTabBar` as the LEADING item of a pushed screen's bottom toolbar —
/// the pushed profile's arrangement (#728), shared with the search results
/// (#881) rather than written twice.
///
/// The toolbar sibling of `SelectorAccessory`. That one hangs the strip in the
/// tab bar's `UITabAccessory`, which belongs to the tab bar controller with no
/// per-screen scope and has to be installed and removed around every
/// appearance. This one rides `toolbarItems`, which UIKit keeps per view
/// controller, so the strip cannot leak onto another screen. What IS shared is
/// the toolbar's VISIBILITY — a stack has one toolbar — and that is the half
/// `show(for:animated:)` and `hide(leaving:animated:)` take care of.
///
/// ⚠️ **`.platter`, AT ITS INTRINSIC WIDTH.** A bar item already sits in a
/// glass platter UIKit draws, so the strip draws none of its own (glass in
/// glass loses the selected segment — see `SelectorHosting`), and it does not
/// fill: the item is as wide as its titles, at the bottom leading corner.
@MainActor
public final class SelectorToolbarItem {
    /// The strip's bar item — what a test finds leading `toolbarItems`.
    public let item: UIBarButtonItem

    public init(strip: PagedTabBar, id: String = "selector.toolbar") {
        strip.hosting = .platter
        strip.fillsWidth = false
        item = BarItems.container(id: id, view: strip)
    }

    /// The screen's `toolbarItems`: the strip at the leading corner, nothing
    /// after it.
    public var toolbarItems: [UIBarButtonItem] { [item, .flexibleSpace()] }

    /// Shows the stack's toolbar for `screen` — from its `viewWillAppear`, so
    /// the bar rides the push or pop that brings the screen in.
    public func show(for screen: UIViewController, animated: Bool) {
        screen.navigationController?.setToolbarHidden(false, animated: animated)
    }

    /// Puts the stack's toolbar away as `screen` leaves — from its
    /// `viewWillDisappear` — unless the screen taking over brings items of its
    /// own (the relations screen, the feed): that screen adopts the shared bar
    /// in its own `viewWillAppear`, and hiding it here would fight it.
    public func hide(leaving screen: UIViewController, animated: Bool) {
        guard let navigation = screen.navigationController,
              navigation.topViewController?.toolbarItems?.isEmpty ?? true
        else { return }
        navigation.setToolbarHidden(true, animated: animated)
    }
}
