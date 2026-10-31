import UIKit

/// The presentation half of "one call closes one screen" (#1144); the push
/// half is CoreNavigation's `StackArbiter`. Here, below CoreNavigation, so a
/// sheet anywhere in the app — DesignSystem's own included — closes through
/// it rather than through a raw `dismiss(animated:)`.
public extension UIViewController {
    /// Closes the presentation THIS screen is part of — the sheet's whole
    /// stack when it sits in one — only while it is still presented and not
    /// already leaving. A sheet's Close, Done or Cancel: a second tap while
    /// the first dismissal runs does nothing, and `completion` runs once.
    /// Returns whether a dismissal was started.
    ///
    /// ⚠️ NOT `dismiss(animated:)` ON A SCREEN THAT MAY HAVE GONE. A
    /// controller presenting nothing hands `dismiss` to its presenter: a late
    /// call from a sheet already closed closes the screen under it.
    @discardableResult
    func closePresentation(animated: Bool = true, completion: (() -> Void)? = nil) -> Bool {
        var presented: UIViewController = self
        while let parent = presented.parent { presented = parent }
        guard let presenter = presented.presentingViewController,
              presenter.presentedViewController === presented, !presented.isBeingDismissed else {
            return false
        }
        presenter.dismiss(animated: animated, completion: completion)
        return true
    }

    /// Dismisses `presented` only while it is the one this controller
    /// presents. ⚠️ `dismiss` on a controller presenting nothing dismisses
    /// that controller itself — a picker's late completion once closed the
    /// conversation that presented it.
    func dismiss(presented: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard presentedViewController === presented, !presented.isBeingDismissed else { return }
        dismiss(animated: animated, completion: completion)
    }
}
