import Testing
import UIKit
@testable import CoreNavigation

/// A re-tap on the tab already showing scrolls its root back to the top
/// (#1309) — and nothing else does.
@MainActor
struct TabReselectTests {
    private final class Root: UIViewController, TabReselectScrolling {
        var asked = 0
        func scrollToTopForTabReselect() { asked += 1 }
    }

    @Test func aReTapOnTheRootAsksItToScrollToTop() {
        let root = Root()
        let stack = UINavigationController(rootViewController: root)
        TabReselect.target(tappedSelectedTab: true, stack: stack)?.scrollToTopForTabReselect()
        #expect(root.asked == 1)
    }

    /// Switching to a tab is not a re-tap.
    @Test func aTabSwitchAsksNothing() {
        let stack = UINavigationController(rootViewController: Root())
        #expect(TabReselect.target(tappedSelectedTab: false, stack: stack) == nil)
    }

    /// With a screen pushed, the system pops to the root; the root, out of
    /// sight, is not scrolled by the same tap.
    @Test func aReTapOverAPushedScreenLeavesTheRootAlone() {
        let stack = UINavigationController(rootViewController: Root())
        stack.pushViewController(UIViewController(), animated: false)
        #expect(TabReselect.target(tappedSelectedTab: true, stack: stack) == nil)
    }

    /// A root with nothing to scroll (the map) is simply not asked.
    @Test func aRootThatDoesNotScrollIsNotAsked() {
        let stack = UINavigationController(rootViewController: UIViewController())
        #expect(TabReselect.target(tappedSelectedTab: true, stack: stack) == nil)
    }
}
