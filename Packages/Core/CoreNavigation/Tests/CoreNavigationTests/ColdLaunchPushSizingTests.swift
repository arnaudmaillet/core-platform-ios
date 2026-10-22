import Testing
import UIKit
@testable import CoreNavigation

/// A route at cold launch pushes into a stack its window has not laid out
/// yet (#1633): the stack is sized first, so the screen pushed onto it
/// lays out at the window's width rather than at zero.
@MainActor
struct ColdLaunchPushSizingTests {
    /// A scene's window: it sizes its root's view when it lays out, the
    /// pass the launch route ran ahead of. (A bare `UIWindow` in the test
    /// host sizes its root on assignment only.)
    private final class SceneLikeWindow: UIWindow {
        override func layoutSubviews() {
            super.layoutSubviews()
            rootViewController?.view.frame = bounds
        }
    }

    /// A freshly installed shell, as the app has it before the window's first
    /// layout pass: a tab bar controller holding a stack, everything at zero
    /// size with the window's layout still to come — measured at cold launch
    /// in the app, where `setRoot` swapped the launch screen out without
    /// laying out.
    private func freshShell() -> (UIWindow, UINavigationController) {
        let window = SceneLikeWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let stack = UINavigationController(rootViewController: UIViewController())
        let tabs = UITabBarController()
        tabs.viewControllers = [stack]
        window.rootViewController = tabs
        window.isHidden = false
        tabs.view.frame = .zero
        stack.view.frame = .zero
        window.setNeedsLayout()
        return (window, stack)
    }

    @Test func aStackTheWindowHasNotLaidOutTakesTheWindowsSize() {
        let (window, stack) = freshShell()
        defer { window.isHidden = true }
        // The state the launch route met: everything at zero size.
        #expect(stack.view.bounds.isEmpty)

        stack.layOutWindowIfUnsized()

        #expect(stack.view.bounds.size == window.bounds.size)
    }

    @Test func aScreenPushedAtLaunchLaysOutAtTheWindowsWidth() {
        let (window, stack) = freshShell()
        defer { window.isHidden = true }
        let pushed = UIViewController()

        stack.layOutWindowIfUnsized()
        stack.pushViewController(pushed, animated: true)
        stack.view.layoutIfNeeded()

        #expect(pushed.view.bounds.width == window.bounds.width)
    }

    @Test func aStackAlreadySizedIsLeftAlone() {
        let (window, stack) = freshShell()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let size = stack.view.bounds.size

        stack.layOutWindowIfUnsized()

        #expect(stack.view.bounds.size == size)
        #expect(!size.equalTo(.zero))
    }
}
