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
/// ⚠️ THIS FILE SHIPPED WITH NO CALLERS AT ALL, and the doc comment claiming
/// it had three is what hid that. It was extracted while the search screen
/// still swapped its bar, and the extracting commit explicitly left the two
/// existing copies where they were — so it had one caller, not three. The next
/// commit deleted that caller with the swap it belonged to, and nothing was
/// pointed at the file for two more.
///
/// It has two real callers now: `MessagesInboxViewController` and
/// `ProfileRelationshipsViewController`, whose private copies were deleted for
/// it. Extracting is not adopting, and a comment is not a grep.
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
}

/// The size of the glass pill UIKit draws behind a bar button item.
///
/// ⚠️ **44pt, and it is NOT the button's own height.** A bar item nests like
/// this, measured on iPhone 17 Pro / iOS 26.5 by walking up from a "Cancel"
/// label (see `MessagesInboxViewController`'s `-inbox-search-query` audit):
///
///     _UIModernBarButton  h=32.3
///     _UIButtonBarButton  h=36.0   ← the touch target
///     PlatterItemView     h=36.0
///     PlatterGlassView    h=44.0   ← THE PILL THE VIEWER SEES
///     PlatterView         h=44.0
///
/// A custom title view that wants to look like a sibling of the bar's buttons
/// has to match the PILL, not the button. Sizing a search field to 36 was
/// measured against `_UIButtonBarButton` and is why the field sat visibly
/// shorter than the Cancel pill beside it while sharing its centre line
/// exactly — an equal-centres check passes on two pills of different heights,
/// which is how it survived.
public enum NavigationBarMetrics {
    /// The height of a bar button item's glass platter.
    public static let itemPlatterHeight: CGFloat = 44
}

#if DEBUG
@MainActor
public extension UIViewController {
    /// Names every glass platter in the navigation bar with its size.
    ///
    /// The platters are private views, so they are found by class NAME rather
    /// than by type — which is exactly why this is a debug instrument and not
    /// something layout depends on. What it is for is settling questions like
    /// "is this field the same height as that button", which a screenshot
    /// answers slowly and an equal-centres assertion answers wrongly.
    func debugDescribeBarPlatters() -> String {
        guard let bar = navigationController?.navigationBar else { return "no bar" }
        var found: [String] = []
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.hasSuffix("PlatterView") || name.hasSuffix("PlatterGlassView") {
                found.append(String(format: "%@ %.0fx%.0f", name,
                                    view.bounds.width, view.bounds.height))
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return found.isEmpty ? "no platters" : found.joined(separator: ", ")
    }
}
#endif
