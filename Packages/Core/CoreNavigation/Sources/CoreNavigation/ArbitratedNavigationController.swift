import DesignSystem
import UIKit

/// A chevron-back stack whose back button closes through its arbiter (#1144).
///
/// UIKit's own back button pops whatever is on top, and a second tap while
/// the first pop runs pops again: two quick taps on Download Your Data landed
/// on Settings, two screens down, in one 0.3 s transition (simulator,
/// 2026-10-31). The back button pops through `popViewController(animated:)`,
/// which this stack hands to its arbiter: the tap closes the screen on top,
/// a second tap finds the close pending and is dropped, and a tap during a
/// back swipe never closes a second screen.
///
/// ⚠️ NOT `navigationItem.backAction`. It was, and on iOS 27.2 a `backAction`
/// makes the bar draw a back button of its own: on every tab's ROOT, and
/// beside a screen's own leading chevron (the feed wore two) — the owner's
/// device, 2026-10-31. The iOS 27.0 simulator did not draw it.
open class ArbitratedNavigationController: ChevronBackNavigationController {
    override open func popViewController(animated: Bool) -> UIViewController? {
        StackArbiter.pop(in: self, animated: animated) { super.popViewController(animated: animated) }
    }
}

public extension StackArbiter {
    /// For a stack's `popViewController(animated:)` override: the pop of the
    /// screen on top goes through the arbiter (`close`, a tap's `.retry`), so
    /// a second pop while the first lands is dropped rather than taking out
    /// the screen below. The arbiter's own pop, and a pop at the root, go
    /// straight to UIKit (`viaSuper`). Nil when nothing was popped now.
    static func pop(
        in navigation: UINavigationController, animated: Bool, viaSuper: () -> UIViewController?
    ) -> UIViewController? {
        let arbiter = navigation.arbiter
        guard !arbiter.isIssuingPop, navigation.viewControllers.count > 1,
              let top = navigation.topViewController
        else { return viaSuper() }
        return arbiter.close(top, animated: animated) == .closed ? top : nil
    }
}
