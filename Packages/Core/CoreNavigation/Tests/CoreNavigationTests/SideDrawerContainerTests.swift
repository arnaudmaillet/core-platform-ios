import Testing
import UIKit
@testable import CoreNavigation

/// The side drawer container's state machine: opening and closing, the
/// tracking path the gestures drive, which gestures are live when, and the
/// appearance callbacks the drawer child is promised.
///
/// Settles run unanimated (`animated: false`), so each state is reached in the
/// same turn and read straight back; the spring itself is UIKit's.
///
/// ⚠️ Each test hosts its OWN window and takes it down before returning — a
/// visible window released with a per-test suite instance crashes the next CA
/// flush (`visible-window-suite-release-crash`).
@Suite(.serialized)
@MainActor
struct SideDrawerContainerTests {
    /// Counts the appearance callbacks a child receives.
    private final class AppearanceProbe: UIViewController {
        var willAppear = 0, didAppear = 0, willDisappear = 0, didDisappear = 0
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); willAppear += 1 }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); didAppear += 1 }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); willDisappear += 1 }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); didDisappear += 1 }
    }

    private func hosting(
        _ body: (SideDrawerContainerViewController, AppearanceProbe, AppearanceProbe) throws -> Void
    ) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let main = AppearanceProbe()
        let drawer = AppearanceProbe()
        let container = SideDrawerContainerViewController(main: main, drawer: drawer)
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(container, main, drawer)
    }

    @Test func startsClosedWithTheMainScreenCoveringEverything() {
        hosting { container, main, drawer in
            #expect(container.phase == .closed)
            #expect(container.progress == 0)
            #expect(container.mainScreenOffset == 0)
            #expect(!container.drawerIsRevealed)
            #expect(!container.mainScreenIsAccessibilityHidden)
            // The drawer's view is not even loaded until it is first revealed.
            #expect(!drawer.isViewLoaded)
            // The main screen's appearance is forwarded by hand.
            #expect(main.willAppear == 1)
        }
    }

    @Test func openSlidesTheMainScreenByTheDrawerWidth() {
        hosting { container, _, drawer in
            container.open(animated: false)
            #expect(container.phase == .open)
            #expect(container.isOpen)
            #expect(container.progress == 1)
            #expect(container.mainScreenOffset == container.drawerWidth)
            #expect(container.drawerWidth == 338)
            #expect(container.drawerIsRevealed)
            // VoiceOver reads the drawer, not the covered screen.
            #expect(container.mainScreenIsAccessibilityHidden)
            #expect(drawer.willAppear == 1)
            #expect(drawer.didAppear == 1)
        }
    }

    @Test func closeRestoresTheMainScreenAndRunsItsCompletion() {
        hosting { container, _, drawer in
            container.open(animated: false)
            var completed = 0
            container.close(animated: false) { completed += 1 }
            #expect(container.phase == .closed)
            #expect(container.mainScreenOffset == 0)
            #expect(!container.drawerIsRevealed)
            #expect(!container.mainScreenIsAccessibilityHidden)
            #expect(completed == 1)
            #expect(drawer.willDisappear == 1)
            #expect(drawer.didDisappear == 1)
            // Closing a closed drawer still answers.
            container.close(animated: false) { completed += 1 }
            #expect(completed == 2)
        }
    }

    @Test func aDragFollowsTheFingerAndAShortReleaseFallsBack() {
        hosting { container, _, drawer in
            let width = container.drawerWidth
            container.beginTracking()
            #expect(container.phase == .tracking)
            // A peek starts the drawer's appearance but does not finish it.
            #expect(drawer.willAppear == 1)
            #expect(drawer.didAppear == 0)

            container.updateTracking(translation: width * 0.3)
            #expect(abs(container.progress - 0.3) < 0.0001)
            #expect(abs(container.mainScreenOffset - width * 0.3) < 0.01)

            container.endTracking(velocity: 0, animated: false)
            #expect(container.phase == .closed)
            // A peek that never settled open never "appeared".
            #expect(drawer.didAppear == 0)
            #expect(drawer.didDisappear == 1)
        }
    }

    @Test func aFlickOpensFromAShortDragAndClosesFromALongOne() {
        hosting { container, _, _ in
            let width = container.drawerWidth
            container.beginTracking()
            container.updateTracking(translation: width * 0.2)
            container.endTracking(velocity: 900, animated: false)
            #expect(container.phase == .open)

            container.beginTracking()
            container.updateTracking(translation: -width * 0.2)
            #expect(abs(container.progress - 0.8) < 0.0001)
            container.endTracking(velocity: -900, animated: false)
            #expect(container.phase == .closed)
        }
    }

    @Test func draggingPastOpenRubberBandsAndSettlesBackToOpen() {
        hosting { container, _, _ in
            container.open(animated: false)
            let width = container.drawerWidth
            container.beginTracking()
            container.updateTracking(translation: 300)
            #expect(container.progress > 1)
            #expect(container.progress < 1 + SideDrawerMotion.overshootLimit)
            #expect(container.mainScreenOffset > width)
            container.endTracking(velocity: 0, animated: false)
            #expect(container.phase == .open)
            #expect(container.mainScreenOffset == width)
        }
    }

    // MARK: - Blur (#561)

    /// The main screen blurs with its slide: none at rest, half at half, full
    /// open — and it shrinks back with the finger.
    @Test func theMainScreenBlursWithItsSlide() {
        hosting { container, _, _ in
            let width = container.drawerWidth
            #expect(container.mainScreenBlurStrength == 0, "none at rest")
            container.beginTracking()
            container.updateTracking(translation: width * 0.5)
            let half = SideDrawerContainerViewController.blurStrength(forProgress: 0.5)
            #expect(abs(container.mainScreenBlurStrength - half) < 0.0001)
            container.updateTracking(translation: width)
            #expect(abs(container.mainScreenBlurStrength - SideDrawerContainerViewController.blurStrength(forProgress: 1)) < 0.0001)
            container.updateTracking(translation: width * 0.2)
            #expect(abs(container.mainScreenBlurStrength - SideDrawerContainerViewController.blurStrength(forProgress: 0.2)) < 0.0001,
                    "dragged back, it shrinks")
            container.endTracking(velocity: 0, animated: false)
            #expect(container.mainScreenBlurStrength == 0, "closed: none")
        }
    }

    /// The strength is the reveal, clamped: full past open (the rubber band),
    /// none at all with Reduce Transparency.
    @Test func theBlurStaysFullPastOpenAndOffWithReduceTransparency() {
        #expect(SideDrawerContainerViewController.blurStrength(forProgress: 0, reducesTransparency: false) == 0)
        #expect(SideDrawerContainerViewController.blurStrength(forProgress: 0.5, reducesTransparency: false) == 0.5)
        #expect(SideDrawerContainerViewController.blurStrength(forProgress: 1, reducesTransparency: false) == 1)
        #expect(SideDrawerContainerViewController.blurStrength(forProgress: 1.08, reducesTransparency: false) == 1)
        #expect(SideDrawerContainerViewController.blurStrength(forProgress: 0.7, reducesTransparency: true) == 0)
        hosting { container, _, _ in
            container.open(animated: false)
            container.beginTracking()
            container.updateTracking(translation: 300) // the rubber band
            #expect(container.progress > 1)
            #expect(container.mainScreenBlurStrength == SideDrawerContainerViewController.blurStrength(forProgress: 1))
            container.endTracking(velocity: 0, animated: false)
        }
    }

    /// Rapid opens and closes, animated, interrupting each other: the blur
    /// lands where the drawer does and nothing throws on the way.
    @Test func rapidOpenAndCloseLandsTheBlurWithTheDrawer() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let container = SideDrawerContainerViewController(main: UIViewController(), drawer: UIViewController())
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        for _ in 0..<5 {
            container.open()
            try await Task.sleep(for: .milliseconds(60))
            container.close()
            try await Task.sleep(for: .milliseconds(60))
        }
        container.open()
        for _ in 0..<60 where container.phase != .open { try await Task.sleep(for: .milliseconds(25)) }
        #expect(container.phase == .open)
        #expect(container.mainScreenBlurStrength == SideDrawerContainerViewController.blurStrength(forProgress: 1),
                "landed with the spring, no pop")
    }

    @Test func aCancelledDragReturnsWhereItBegan() {
        hosting { container, _, _ in
            container.open(animated: false)
            container.beginTracking()
            container.updateTracking(translation: -container.drawerWidth * 0.7)
            container.cancelTracking(animated: false)
            #expect(container.phase == .open)
        }
    }

    /// The edge swipe is live only while the drawer is closed AND the host
    /// allows it; the close gestures only while it is open.
    @Test func gesturesAreGatedByPhaseAndByTheHost() {
        hosting { container, _, _ in
            var hostAllows = true
            container.canOpenInteractively = { hostAllows }

            #expect(container.edgeOpenIsAllowed)
            #expect(!container.closeGesturesAreArmed)
            #expect(!container.gestureRecognizerShouldBegin(container.closePan))
            // Only a rightward, mostly horizontal drag becomes the swipe.
            #expect(SideDrawerContainerViewController.isRightwardSwipe(dx: 12, dy: 3))
            #expect(!SideDrawerContainerViewController.isRightwardSwipe(dx: 5, dy: 14))
            #expect(!SideDrawerContainerViewController.isRightwardSwipe(dx: -12, dy: 0))

            hostAllows = false // a pushed screen, a sheet up…
            #expect(!container.edgeOpenIsAllowed)
            #expect(!container.gestureRecognizerShouldBegin(container.edgePan))

            hostAllows = true
            container.open(animated: false)
            #expect(!container.edgeOpenIsAllowed, "the edge is inside an open drawer")
            #expect(container.closeGesturesAreArmed)

            container.beginTracking()
            #expect(!container.edgeOpenIsAllowed, "nothing starts under a finger")
            container.endTracking(velocity: -900, animated: false)
            #expect(container.edgeOpenIsAllowed)
        }
    }

    /// Drags on the main screen wait for the edge swipe to fail (a pager or a
    /// map at the edge never steals it); drags in the drawer wait for the drag
    /// back. Taps and presses are never made to wait.
    @Test func competingDragsWaitForTheDrawersOwnGestures() {
        hosting { container, main, drawer in
            container.open(animated: false)
            let mainPager = UIPanGestureRecognizer()
            main.view.addGestureRecognizer(mainPager)
            let drawerScroll = UIPanGestureRecognizer()
            drawer.view.addGestureRecognizer(drawerScroll)
            let press = UILongPressGestureRecognizer()
            main.view.addGestureRecognizer(press)

            #expect(container.gestureRecognizer(container.edgePan, shouldBeRequiredToFailBy: mainPager))
            #expect(!container.gestureRecognizer(container.edgePan, shouldBeRequiredToFailBy: drawerScroll))
            #expect(!container.gestureRecognizer(container.edgePan, shouldBeRequiredToFailBy: press))
            // A window-level recogniser (UIKit's system gesture gate) is not ours to delay.
            let windowGate = UIPanGestureRecognizer()
            container.view.window?.addGestureRecognizer(windowGate)
            #expect(!container.gestureRecognizer(container.edgePan, shouldBeRequiredToFailBy: windowGate))
            #expect(container.gestureRecognizer(container.closePan, shouldBeRequiredToFailBy: drawerScroll))
            #expect(!container.gestureRecognizer(container.closePan, shouldBeRequiredToFailBy: mainPager))
        }
    }

    @Test func openIsIdempotentAndTheStatusBarFollowsTheDrawer() {
        hosting { container, main, drawer in
            #expect(container.childForStatusBarStyle === main)
            container.open(animated: false)
            container.open(animated: false)
            #expect(drawer.didAppear == 1)
            #expect(container.childForStatusBarStyle === drawer)
            container.close(animated: false)
            #expect(container.childForStatusBarStyle === main)
        }
    }
}
