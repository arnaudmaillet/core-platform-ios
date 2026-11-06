import UIKit

/// A screen's trailing items (#1420), kept as plain forwards since toasts left
/// the bar (#2143).
///
/// They existed so that a screen editing its list while bar toasts were up
/// would not adopt the toasts' items. No toast is ever a bar item now, so they
/// read and write `navigationItem` itself; inlining them at their ~25 call
/// sites is a mechanical follow-up.
public extension UIViewController {
    /// The screen's trailing items: the bar's.
    var ownTrailingBarItems: [UIBarButtonItem] {
        navigationItem.rightBarButtonItems ?? []
    }

    /// Sets the screen's trailing items on the bar.
    func setOwnTrailingBarItems(_ items: [UIBarButtonItem]?, animated: Bool) {
        navigationItem.setRightBarButtonItems(items, animated: animated)
    }
}
