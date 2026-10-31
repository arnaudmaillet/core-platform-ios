import Testing
import UIKit
@testable import CoreNavigation
import DesignSystem

/// One close, one screen (#1144): a close names its screen, closes it only,
/// and never twice.
@MainActor
struct StackArbiterTests {
    private func stack(_ count: Int) -> (UINavigationController, [UIViewController]) {
        let screens = (0..<count).map { _ in UIViewController() }
        let navigation = UINavigationController()
        navigation.setViewControllers(screens, animated: false)
        return (navigation, screens)
    }

    /// The screen on top leaves; closing it again does nothing more.
    @Test func closingTheTopScreenPopsItOnce() {
        let (navigation, screens) = stack(3)
        #expect(screens[2].closeScreen(animated: false) == .closed)
        #expect(navigation.viewControllers == Array(screens[0...1]))
        #expect(screens[2].closeScreen(animated: false) == .alreadyGone)
        #expect(navigation.viewControllers == Array(screens[0...1]), "the screen under it stays")
    }

    /// A close after an `await`, once the viewer pushed another screen: the
    /// screen is taken out alone, the new one stays on top.
    @Test func closingAScreenBelowTheTopTakesOnlyIt() {
        let (navigation, screens) = stack(3)
        #expect(navigation.arbiter.close(screens[1], animated: false) == .closed)
        #expect(navigation.viewControllers == [screens[0], screens[2]])
    }

    /// The viewer already went back: a late close changes nothing.
    @Test func aScreenThatLeftIsNotClosedAgain() {
        let (navigation, screens) = stack(2)
        navigation.popViewController(animated: false)
        let other = UIViewController()
        navigation.pushViewController(other, animated: false)
        #expect(screens[1].closeScreen(animated: false) == .alreadyGone)
        #expect(navigation.viewControllers == [screens[0], other], "the screen pushed since stays")
    }

    @Test func theRootIsNeverPopped() {
        let (navigation, screens) = stack(1)
        #expect(navigation.arbiter.close(screens[0], animated: false) == .alreadyGone)
        #expect(navigation.viewControllers == screens)
    }

    /// Two closes in one turn — a double tap on Back: the first one's pop is
    /// pending at once, before any coordinator exists, so the second is
    /// dropped and one screen leaves.
    @Test func twoClosesInOneTurnCloseOneScreen() async {
        let (navigation, screens) = stack(3)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        #expect(screens[2].closeScreen() == .closed)
        #expect(navigation.arbiter.isPending)
        #expect(screens[1].closeScreen() == .dropped)
        for _ in 0..<600 where navigation.arbiter.isPending {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!navigation.arbiter.isPending)
        #expect(navigation.viewControllers == Array(screens[0...1]))
    }

    /// `dismiss(presented:)` dismisses only the one presented: a late call
    /// for a picker already gone never closes its presenter.
    @Test func aLateDismissNeverClosesThePresenter() {
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        window.rootViewController?.present(presenter, animated: false)
        let picker = UIViewController()
        // Not presented (cancelled, swiped down): nothing happens.
        presenter.dismiss(presented: picker, animated: false)
        #expect(window.rootViewController?.presentedViewController === presenter, "the presenter stays")
    }

    private func shownWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    /// A screen inside a sheet's stack closes the SHEET, through the one
    /// that presented it. (A package test host never completes a modal, so
    /// only the synchronous answer is checked — see the
    /// `test-host-modal-never-completes` note.)
    @Test func aScreenInASheetClosesTheSheet() {
        let window = shownWindow()
        defer { window.isHidden = true }
        let root = window.rootViewController!
        let content = UIViewController()
        let sheet = UINavigationController(rootViewController: content)
        root.present(sheet, animated: false)
        #expect(content.closePresentation(animated: false))
    }

    /// A screen in no presentation — a tab's own stack, a sheet already gone
    /// — closes nothing, where `dismiss(animated:)` would have closed what
    /// the screen's ancestor presents.
    @Test func aScreenInNoPresentationClosesNothing() {
        let window = shownWindow()
        defer { window.isHidden = true }
        let root = window.rootViewController!
        let next = UIViewController()
        root.present(next, animated: false)
        let gone = UIViewController()
        #expect(!gone.closePresentation(animated: false))
        #expect(gone.closeScreen(animated: false) == .alreadyGone)
        #expect(root.presentedViewController === next, "the sheet opened since stays")
    }

    /// A gesture closes now or not at all: behind a running transition it is
    /// dropped, where a tap is asked again once the transition ends.
    @Test func aGestureIsDroppedBehindARunningTransition() async {
        let (navigation, screens) = stack(2)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let pushed = UIViewController()
        navigation.pushViewController(pushed, animated: true)
        for _ in 0..<100 where navigation.transitionCoordinator == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(navigation.transitionCoordinator != nil, "the push is running")
        #expect(pushed.closeScreen(whenBusy: .drop) == .dropped)
        #expect(pushed.closeScreen() == .deferred)
        #expect(navigation.viewControllers == screens + [pushed], "nothing closed yet")
    }
}
