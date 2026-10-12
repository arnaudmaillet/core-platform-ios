import Testing
import UIKit
@testable import DesignSystem

/// The scene-level toast overlay (#954): the band it spans, where each of the
/// six positions puts a toast, that a toast outlives the screen it was fired
/// from, and that the window takes a touch only on a toast.
///
/// A package test host has no scene, so the overlay under test is built over
/// a plain window (`ToastOverlay.makeForTests`), set and restored inside each
/// test with no `await` in between (`global-test-state-await-trap`).
@MainActor
@Suite(.serialized)
struct ToastOverlayTests {

    private let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let safeArea = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)

    /// `root` in a visible window, with an overlay of its own; both taken
    /// down within the test.
    private func hosting(
        _ root: UIViewController, _ body: (UIWindow, ToastOverlay) throws -> Void
    ) rethrows {
        let window = UIWindow(frame: bounds)
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        let overlay = ToastOverlay(window: ToastOverlayWindow(frame: bounds), appWindow: window)
        let previousMake = ToastOverlay.makeForTests
        let previousHaptic = Feedback.playHaptic
        ToastOverlay.makeForTests = { _ in overlay }
        Feedback.playHaptic = { _ in }
        defer {
            ToastOverlay.makeForTests = previousMake
            Feedback.playHaptic = previousHaptic
            overlay.toasts.forEach { $0.dismiss(animated: false) }
            overlay.window.isHidden = true
            overlay.window.layoutIfNeeded()
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(window, overlay)
    }

    // MARK: - The band

    /// From the foot of the status band to the screen's floor.
    @Test func theBandRunsFromTheStatusBandToTheFloor() {
        let band = ToastOverlay.band(in: bounds, safeArea: safeArea, screenFloorY: 780, keyboardTopY: nil)
        #expect(band == CGRect(x: 0, y: 62, width: 402, height: 780 - 62))
    }

    /// With no floor measured, the window's safe area bottom.
    @Test func withoutAFloorTheBandEndsAtTheSafeArea() {
        let band = ToastOverlay.band(in: bounds, safeArea: safeArea, screenFloorY: nil, keyboardTopY: nil)
        #expect(abs(band.maxY - (874 - 34)) < 0.001)
    }

    /// The keyboard is a floor too: the higher of the two wins.
    @Test func theKeyboardRaisesTheFloor() {
        let band = ToastOverlay.band(in: bounds, safeArea: safeArea, screenFloorY: 780, keyboardTopY: 540)
        #expect(band.maxY == 540)
        let below = ToastOverlay.band(in: bounds, safeArea: safeArea, screenFloorY: 500, keyboardTopY: 540)
        #expect(below.maxY == 500)
    }

    /// A floor above the status band never makes a negative band.
    @Test func aFloorNeverRisesAboveTheTop() {
        let band = ToastOverlay.band(in: bounds, safeArea: safeArea, screenFloorY: 10, keyboardTopY: nil)
        #expect(band.height == 0)
        #expect(band.minY == 62)
    }

    // MARK: - Feedback through the overlay

    /// A toast is drawn in the overlay, not in the screen, and the overlay's
    /// window stands on the screen's floor.
    @Test func aToastIsDrawnInTheOverlay() {
        let screen = UIViewController()
        hosting(screen) { window, overlay in
            let toast = Feedback.success("Copied", from: screen)
            #expect(toast.superview === overlay.container)
            #expect(!screen.view.subviews.contains { $0 is ToastView })
            #expect(!overlay.window.isHidden)
            let floor = Feedback.floorY(of: screen, above: nil, in: window)
            #expect(overlay.window.frame.maxY == floor)
        }
    }

    /// ⚠️ The point of the overlay: a pop takes the screen away, not its
    /// toast.
    @Test func aToastOutlivesThePopOfItsScreen() {
        let stack = UINavigationController(rootViewController: UIViewController())
        hosting(stack) { window, overlay in
            let pushed = UIViewController()
            stack.pushViewController(pushed, animated: false)
            window.layoutIfNeeded()
            let toast = Feedback.info("Hidden from this feed", from: pushed)
            stack.popViewController(animated: false)
            window.layoutIfNeeded()
            #expect(toast.superview === overlay.container)
            #expect(!overlay.window.isHidden)
        }
    }

    /// After the pop, the floor is the screen now on top: a toast fired on a
    /// pushed screen with no tab accessory moves up over the root's.
    @Test func afterAPopTheFloorIsTheScreenNowOnTop() {
        let root = UIViewController()
        root.additionalSafeAreaInsets.bottom = 120 // the root's accessory
        let stack = UINavigationController(rootViewController: root)
        hosting(stack) { window, overlay in
            let pushed = UIViewController()
            stack.pushViewController(pushed, animated: false)
            window.layoutIfNeeded()
            pushed.additionalSafeAreaInsets.bottom = 0
            _ = Feedback.info("Saved", from: pushed)
            let pushedFloor = overlay.window.frame.maxY
            stack.popViewController(animated: false)
            window.layoutIfNeeded()
            overlay.refloor(animated: false)
            let rootFloor = Feedback.floorY(of: root, above: nil, in: window)
            #expect(overlay.window.frame.maxY == rootFloor)
            #expect(rootFloor < pushedFloor)
        }
    }

    /// A rotation re-places the band: as wide as the window, standing on
    /// the new floor.
    @Test func aRotationReplacesTheBand() {
        let screen = UIViewController()
        hosting(screen) { window, overlay in
            _ = Feedback.info("Saved", from: screen)
            window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
            window.layoutIfNeeded()
            overlay.refloor(animated: false)
            #expect(overlay.window.frame.width == 874)
            #expect(overlay.window.frame.maxY == Feedback.floorY(of: screen, above: nil, in: window))
        }
    }

    /// A composer's top is the floor when the screen names it.
    @Test func aComposerIsTheFloor() {
        let screen = UIViewController()
        hosting(screen) { window, overlay in
            let composer = UIView(frame: CGRect(x: 0, y: 700, width: 402, height: 60))
            screen.view.addSubview(composer)
            _ = Feedback.success("Copied", from: screen, above: composer)
            #expect(overlay.window.frame.maxY == 700)
        }
    }

    // MARK: - Positions

    /// Top toasts hang from the band's top, bottom ones stand on its bottom;
    /// leading and trailing sit at the margins, centre in the middle.
    @Test func eachPositionLandsInItsPlace() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            var placed: [ToastPosition: ToastView] = [:]
            for position in ToastPosition.allCases {
                placed[position] = Feedback.info("Saved", from: screen, at: position)
            }
            overlay.window.layoutIfNeeded()
            let container = overlay.container
            let margin = container.directionalLayoutMargins.leading
            for (position, toast) in placed {
                #expect(toast.superview === container)
                #expect(toast.position == position)
                let frame = toast.frame
                // Mid-entrance: within one travel of its edge.
                if position.isTop {
                    #expect(frame.minY < container.bounds.midY)
                } else {
                    #expect(frame.maxY > container.bounds.midY)
                }
                switch position.alignment {
                case .leading: #expect(abs(frame.minX - margin) < 0.5)
                case .center: #expect(abs(frame.midX - container.bounds.midX) < 0.5)
                case .trailing: #expect(abs(frame.maxX - (container.bounds.maxX - margin)) < 0.5)
                }
            }
        }
    }

    /// Right to left: leading is the right-hand side.
    @Test func leadingFollowsTheLayoutDirection() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            overlay.container.semanticContentAttribute = .forceRightToLeft
            defer { overlay.container.semanticContentAttribute = .unspecified }
            let toast = Feedback.info("Saved", from: screen, at: .bottomLeading)
            overlay.window.layoutIfNeeded()
            #expect(toast.frame.midX > overlay.container.bounds.midX)
        }
    }

    /// A position stacks its toasts and leaves the other positions alone.
    @Test func toastsStackAtTheirOwnPosition() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            let first = Feedback.info("One", from: screen)
            let top = Feedback.info("Top", from: screen, at: .top)
            let second = Feedback.info("Two", from: screen)
            #expect(ToastView.stack(at: .bottom, in: overlay.container) == [first, second])
            #expect(ToastView.stack(at: .top, in: overlay.container) == [top])
        }
    }

    /// ⚠️ A toast that takes another's place keeps the window up: the one it
    /// pushed out leaves first, and an empty window hides itself.
    @Test func aReplacementKeepsTheWindowUp() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            _ = Feedback.info("One", from: screen)
            let second = Feedback.info("Two", from: screen)
            #expect(second.superview === overlay.container)
            #expect(!overlay.window.isHidden)
        }
    }

    /// Retry fires the next toast at the same position, from its action: the
    /// next toast shows, in the overlay, with the window up.
    @Test func anActionCanFireTheNextToast() throws {
        let screen = UIViewController()
        try hosting(screen) { _, overlay in
            var next: ToastView?
            let failure = Feedback.failure("Couldn't send", from: screen, action: ToastView.Action("Retry") {
                next = Feedback.success("Sent", from: screen)
            })
            try #require(failure.actionButton).sendActions(for: .primaryActionTriggered)
            let sent = try #require(next)
            #expect(sent.superview === overlay.container)
            #expect(!sent.isDismissing)
            #expect(!overlay.window.isHidden)
            #expect(ToastView.stack(at: .bottom, in: overlay.container).map(\.message) == ["Sent"])
        }
    }

    /// The window is up only while it holds a toast.
    @Test func theWindowHidesWithItsLastToast() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            let toast = Feedback.info("Saved", from: screen)
            #expect(!overlay.window.isHidden)
            toast.dismiss(animated: false)
            #expect(overlay.window.isHidden)
        }
    }

    // MARK: - Touches

    /// Only a toast takes a touch; the band around it hands every touch to
    /// the app beneath.
    @Test func theWindowTakesATouchOnlyOnAToast() {
        let window = ToastOverlayWindow(frame: bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let toast = UIView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        root.view.addSubview(toast)
        #expect(window.hitTest(CGPoint(x: 150, y: 120), with: nil) === toast)
        #expect(window.hitTest(CGPoint(x: 20, y: 400), with: nil) == nil)
    }

    /// ⚠️ A tap on a toast must not make the overlay the key window: the
    /// app's would stop being it, and the next toast would miss the overlay.
    @Test func theOverlayNeverBecomesKey() {
        #expect(!ToastOverlayWindow(frame: bounds).canBecomeKey)
    }

    // MARK: - Appearance

    /// A screen that pins its own style (the snap feed over a photograph)
    /// gets its toast in that style.
    @Test func theOverlayWearsTheScreensStyle() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            screen.overrideUserInterfaceStyle = .dark
            _ = Feedback.info("Saved", from: screen)
            #expect(overlay.window.overrideUserInterfaceStyle == .dark)
        }
    }

    /// The overlay wears the app window's pinned style.
    @Test func theOverlayWearsTheAppWindowsStyle() {
        let screen = UIViewController()
        hosting(screen) { window, overlay in
            window.overrideUserInterfaceStyle = .dark
            defer { window.overrideUserInterfaceStyle = .unspecified }
            _ = Feedback.info("Saved", from: screen)
            #expect(overlay.window.overrideUserInterfaceStyle == .dark)
        }
    }
}
