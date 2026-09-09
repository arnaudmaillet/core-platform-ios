import UIKit

/// Swapping one navigation bar layout for another, as a dissolve.
///
/// # Why this exists
///
/// Bar items are not individually animatable — assigning `leftBarButtonItems`,
/// `rightBarButtonItems` or `titleView` is instantaneous, and there is no
/// per-item transition to ride. The honest way to make one set of bar contents
/// become another is therefore to dissolve the WHOLE BAR between the two
/// states, which is also what UIKit does for its own title changes.
///
/// ⚠️ THIS IS THE ALTERNATIVE TO `UISearchController` IN A NAVIGATION BAR, and
/// the reason it is worth naming. A search controller owns its own
/// activation animation: on iOS 26 it collapses the active field into the
/// navigation bar's glass PLATTER, and that platter is not the app's to
/// remove, resize or opt out of. Measured frame by frame on the search screen,
/// through every placement (`.stacked`, `.integrated`, `.integratedButton`,
/// `.integratedCentered`), with and without a placeholder, with the text field
/// hidden and with the search bar hidden: the platter's width animation
/// survives all of it.
///
/// A bar swapped by hand has no such animation to fight. The resting state is
/// an ordinary `UIBarButtonItem` — a bubble that hugs its glyph, because that
/// is what a bar button is — and the searching state is a bare
/// `UISearchTextField` in the title slot. The dissolve carries one to the
/// other. `MessagesInboxViewController` has done it this way since the inbox
/// was built, and it is the behaviour the search screen was measured against.
///
/// Extracted at the third caller (the inbox, the profile's relationship lists,
/// and now search), which is where this codebase moves a duplicate into
/// `DesignSystem` — the same road `PersonListCell` and `PagedTabBar` took.
@MainActor
public extension UIViewController {

    /// Applies `change` to the navigation item inside a cross-dissolve of the
    /// bar. Falls back to applying it outright when there is no bar to dissolve
    /// — a modally presented screen, or one whose controller has gone.
    func morphNavigationBar(duration: TimeInterval = 0.26, _ change: @escaping () -> Void) {
        guard let bar = navigationController?.navigationBar else {
            change()
            return
        }
        UIView.transition(with: bar, duration: duration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: change)
    }

    /// Makes the bar opaque, or hands it back to the system's default.
    ///
    /// The bar is translucent by default and a list runs under it, which is
    /// right until the bar becomes a search FIELD — at which point rows sliding
    /// behind the text are just noise.
    ///
    /// ⚠️ Nils rather than "configure with default background": the three
    /// appearance slots are overrides, and setting them to a fresh default
    /// pins the bar to that default instead of returning it to whatever the
    /// screen (or the app) had configured.
    func setNavigationBarOpaque(_ opaque: Bool) {
        guard opaque else {
            navigationItem.standardAppearance = nil
            navigationItem.scrollEdgeAppearance = nil
            navigationItem.compactAppearance = nil
            return
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
    }
}
