import UIKit

/// A tab's root screen that goes back to its top when the viewer taps the tab
/// they are already on — the iOS convention (#1309).
///
/// The shell asks; each screen decides what its top is, because a paged root
/// has more than one scroll view and only it knows which one is in front.
@MainActor
public protocol TabReselectScrolling: AnyObject {
    /// Scrolls the screen's main content back to its top, animated. A screen
    /// already there does nothing.
    func scrollToTopForTabReselect()
}

/// Who answers a tap on a tab bar item (#1309).
public enum TabReselect {
    /// The root screen to scroll back to its top, or nil.
    ///
    /// Only a RE-tap — the tab already selected — and only on its root: with a
    /// screen pushed, the system's own answer (pop to the root) is the one a
    /// viewer expects from the same tap, and scrolling a root they cannot see
    /// would be a second motion behind it. Nor while the stack is presenting
    /// or mid-transition, when the root is not what is on screen either.
    public static func target(
        tappedSelectedTab: Bool, stack: UINavigationController?
    ) -> (any TabReselectScrolling)? {
        guard tappedSelectedTab, let stack,
              stack.viewControllers.count == 1,
              stack.presentedViewController == nil,
              stack.transitionCoordinator == nil
        else { return nil }
        return stack.viewControllers.first as? any TabReselectScrolling
    }
}
