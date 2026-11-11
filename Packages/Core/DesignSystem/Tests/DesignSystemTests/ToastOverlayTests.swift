import Testing
import UIKit
@testable import DesignSystem

/// The scene-level toast overlay (#954), the only host since #2143: the band
/// it spans, the ONE place it puts a toast — under the top bar of the screen
/// in view (`ToastAnchor`) — following that anchor while the toast is up, a
/// toast outliving the screen it was fired from, and the window taking a
/// touch only on a toast.
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
        ToastOverlay.makeForTests = { _ in overlay }
        defer {
            ToastOverlay.makeForTests = previousMake
            overlay.toasts.forEach { $0.dismiss(animated: false) }
            overlay.window.isHidden = true
            overlay.window.layoutIfNeeded()
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        // The toasts' haptics are recorded, never played.
        _ = try HapticRecorder.recording { try body(window, overlay) }
    }

    // MARK: - The band

    /// From the foot of the status band to the safe area bottom: never the
    /// status bar, whose appearance a window over it would take.
    @Test func theBandRunsFromTheStatusBandToTheSafeAreaBottom() {
        let band = ToastOverlay.band(in: bounds, safeArea: safeArea)
        #expect(band == CGRect(x: 0, y: 62, width: 402, height: 874 - 34 - 62))
    }

    // MARK: - The anchor (#2143)

    /// A screen in a stack whose bar shows: the bar's bottom edge.
    @Test func aVisibleBarIsTheAnchor() {
        let screen = UIViewController()
        let stack = UINavigationController(rootViewController: screen)
        hosting(stack) { window, _ in
            let bar = stack.navigationBar
            let foot = bar.convert(bar.bounds, to: window).maxY
            #expect(foot > window.safeAreaInsets.top)
            #expect(ToastAnchor.anchorY(in: window) == foot)
        }
    }

    /// A large title: the bar's foot, expanded, and again once collapsed —
    /// whatever its height, the toast hangs under it.
    @Test func aLargeTitleIsFollowedExpandedAndCollapsed() {
        let screen = UIViewController()
        screen.navigationItem.title = "Messages"
        screen.navigationItem.largeTitleDisplayMode = .always
        let stack = UINavigationController(rootViewController: screen)
        stack.navigationBar.prefersLargeTitles = true
        hosting(stack) { window, _ in
            let bar = stack.navigationBar
            let expanded = bar.convert(bar.bounds, to: window).maxY
            #expect(ToastAnchor.anchorY(in: window) == expanded)
            screen.navigationItem.largeTitleDisplayMode = .never
            stack.view.setNeedsLayout()
            window.layoutIfNeeded()
            let collapsed = bar.convert(bar.bounds, to: window).maxY
            #expect(ToastAnchor.anchorY(in: window) == collapsed)
            #expect(collapsed < expanded, "the bar never collapsed: the test proves nothing")
        }
    }

    /// A screen with its own top chrome: under that chrome while it shows,
    /// the bar again once it hides.
    @Test func ownTopChromeIsTheAnchorWhileItShows() {
        let screen = AnchoringScreen()
        let stack = UINavigationController(rootViewController: screen)
        hosting(stack) { window, _ in
            screen.chrome.frame = CGRect(x: 0, y: 200, width: 402, height: 40)
            screen.view.addSubview(screen.chrome)
            #expect(ToastAnchor.anchorY(in: window) == screen.chrome.convert(screen.chrome.bounds, to: window).maxY)
            screen.chrome.isHidden = true
            let bar = stack.navigationBar
            #expect(ToastAnchor.anchorY(in: window) == bar.convert(bar.bounds, to: window).maxY)
        }
    }

    /// No bar and no chrome: the top safe area — under the status bar and
    /// the Dynamic Island.
    @Test func withNothingOnTopTheSafeAreaIsTheAnchor() {
        let screen = UIViewController()
        let stack = UINavigationController(rootViewController: screen)
        stack.setNavigationBarHidden(true, animated: false)
        hosting(stack) { window, _ in
            #expect(ToastAnchor.anchorY(in: window) == window.bounds.minY + window.safeAreaInsets.top)
        }
    }

    /// Fired from the app's root, a custom container around the screens (the
    /// notifications drawer's): the anchor is the bar of the screen showing
    /// inside it.
    @Test func aCustomContainerIsLookedThrough() {
        let stack = UINavigationController(rootViewController: UIViewController())
        let container = UIViewController()
        hosting(container) { window, _ in
            container.addChild(stack)
            stack.view.frame = container.view.bounds
            container.view.addSubview(stack.view)
            stack.didMove(toParent: container)
            window.layoutIfNeeded()
            let bar = stack.navigationBar
            #expect(ToastAnchor.anchorY(in: window) == bar.convert(bar.bounds, to: window).maxY)
        }
    }

    /// A drawer that takes most of the container but not all of it (the
    /// notifications drawer, the shell it pushed aside still showing at the
    /// edge): the anchor is the drawer's bar, never the status bar under it.
    @Test func aDrawerTakingMostOfTheScreenIsLookedThrough() {
        let drawer = UINavigationController(rootViewController: UIViewController())
        let shell = UIViewController()
        let container = UIViewController()
        hosting(container) { window, _ in
            for (child, frame) in [
                (shell, CGRect(x: 342, y: 0, width: 402, height: 874)),
                (drawer, CGRect(x: 0, y: 0, width: 342, height: 874)),
            ] {
                container.addChild(child)
                child.view.frame = frame
                container.view.addSubview(child.view)
                child.didMove(toParent: container)
            }
            window.layoutIfNeeded()
            let bar = drawer.navigationBar
            #expect(ToastAnchor.anchorY(in: window) == bar.convert(bar.bounds, to: window).maxY)
        }
    }

    /// A sheet at a medium detent leaves the top of the screen behind in
    /// view: the toast stays there, over neither the sheet nor its content.
    /// A large one covers it: the toast goes into the sheet. (Decided on the
    /// tops: a package test host never completes a presentation,
    /// `test-host-modal-never-completes`.)
    @Test func aMediumSheetKeepsTheScreenBehindALargeOneTakesIt() {
        let anchors: [CGFloat] = [116, 140, 160]
        func holder(_ tops: [CGFloat?]) -> Int {
            ToastAnchor.holder(presentationTops: tops) { anchors[$0] }
        }
        #expect(holder([nil, 437]) == 0, "a medium sheet took the toast")
        #expect(holder([nil, 72]) == 1, "a large sheet left the toast behind it")
        #expect(holder([nil, 437, 72]) == 2, "a large sheet over a medium one left it behind")
        #expect(holder([nil, 72, 437]) == 1, "a medium sheet over a large one took it")
        #expect(holder([nil, nil]) == 0, "a presentation not on screen took it")
        // Just clear of the room a toast needs: behind.
        #expect(holder([nil, 116 + ToastAnchor.roomAboveSheet]) == 0)
    }

    /// A large sheet with no bar: its grabber's area; with one, its bar.
    @Test func aSheetWithoutABarHangsItUnderItsGrabber() {
        let screen = UIViewController()
        hosting(screen) { window, _ in
            let anchor = ToastAnchor.anchorY(of: screen, in: window, sheetTop: 80)
            #expect(anchor == 80 + ToastAnchor.grabberRoom)
        }
        let stack = UINavigationController(rootViewController: UIViewController())
        hosting(stack) { window, _ in
            let bar = stack.navigationBar
            let anchor = ToastAnchor.anchorY(of: stack.topViewController, in: window, sheetTop: 0.5)
            #expect(anchor == bar.convert(bar.bounds, to: window).maxY)
        }
    }

    // MARK: - Feedback through the overlay

    /// A toast is drawn in the overlay, not in the screen, and hangs its gap
    /// under the bar — never in it.
    @Test func aToastHangsUnderTheBar() {
        let screen = UIViewController()
        let stack = UINavigationController(rootViewController: screen)
        hosting(stack) { window, overlay in
            let toast = Feedback.success("Copied", from: screen)
            #expect(toast.superview === overlay.container)
            #expect(!screen.view.subviews.contains { $0 is ToastView })
            #expect(!(screen.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is ToastView })
            #expect(!overlay.window.isHidden)
            toast.debugSettle()
            let bar = stack.navigationBar
            let foot = bar.convert(bar.bounds, to: window).maxY
            #expect(overlay.placedAnchorY == foot)
            let frame = toast.frame.offsetBy(dx: overlay.window.frame.minX, dy: overlay.window.frame.minY)
            #expect(abs(frame.minY - (foot + ToastView.Metrics.topGap)) < 0.5)
            #expect(abs(frame.midX - window.bounds.midX) < 0.5)
        }
    }

    /// ⚠️ The point of the overlay: a pop takes the screen away, not its
    /// toast — which then hangs under the bar of the screen now on top.
    @Test func aToastOutlivesThePopOfItsScreenAndFollowsTheBar() {
        let root = UIViewController()
        root.navigationItem.title = "Root"
        root.navigationItem.largeTitleDisplayMode = .always
        let stack = UINavigationController(rootViewController: root)
        stack.navigationBar.prefersLargeTitles = true
        hosting(stack) { window, overlay in
            let pushed = UIViewController()
            pushed.navigationItem.largeTitleDisplayMode = .never
            stack.pushViewController(pushed, animated: false)
            window.layoutIfNeeded()
            let toast = Feedback.info("Hidden from this feed", from: pushed)
            let pushedFoot = overlay.placedAnchorY
            stack.popViewController(animated: false)
            window.layoutIfNeeded()
            overlay.follow(animated: false)
            #expect(toast.superview === overlay.container)
            #expect(!toast.isDismissing)
            #expect(!overlay.window.isHidden)
            let bar = stack.navigationBar
            #expect(overlay.placedAnchorY == bar.convert(bar.bounds, to: window).maxY)
            #expect(overlay.placedAnchorY > pushedFoot, "the root's large title is no lower: the test proves nothing")
        }
    }

    /// Following the anchor: a step a frame can take moves the toast at
    /// once; a bigger one is animated; a jump further than `farAway` is a
    /// cross-fade — the glass dissolves on its way and comes back.
    @Test func theToastFollowsItsAnchorByHowFarItWent() {
        let screen = AnchoringScreen()
        hosting(screen) { window, overlay in
            screen.chrome.frame = CGRect(x: 0, y: 100, width: 402, height: 40)
            screen.view.addSubview(screen.chrome)
            let toast = Feedback.info("Saved", from: screen)
            toast.debugSettle()
            #expect(overlay.placedAnchorY == 140)

            screen.chrome.frame.origin.y += 8
            overlay.follow()
            #expect(overlay.placedAnchorY == 148)
            #expect(abs(toast.frame.minY + overlay.window.frame.minY - (148 + ToastView.Metrics.topGap)) < 0.5)

            screen.chrome.frame.origin.y += 40
            overlay.follow()
            #expect(overlay.placedAnchorY == 188)
            #expect(!toast.debugIsCrossFading, "a slide was a cross-fade")
            #expect(toast.glassView.effect != nil, "a slide dissolved the glass")

            screen.chrome.frame.origin.y += ToastOverlay.farAway + 10
            overlay.follow()
            #expect(overlay.placedAnchorY == 188 + ToastOverlay.farAway + 10)
            #expect(toast.debugIsCrossFading, "a jump across the screen was not a cross-fade")
        }
    }

    /// A rotation re-places the band: as wide as the window.
    @Test func aRotationReplacesTheBand() {
        let screen = UIViewController()
        hosting(screen) { window, overlay in
            _ = Feedback.info("Saved", from: screen)
            window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
            window.layoutIfNeeded()
            overlay.follow(animated: false)
            #expect(overlay.window.frame.width == 874)
            #expect(overlay.window.frame == ToastOverlay.band(in: window.bounds, safeArea: window.safeAreaInsets))
        }
    }

    // MARK: - One at a time

    /// One result toast: a second replaces the first, which leaves.
    @Test func oneResultToastReplacesAnother() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            let first = Feedback.info("One", from: screen)
            let second = Feedback.info("Two", from: screen)
            #expect(first.isDismissing)
            #expect(ToastView.stack(in: overlay.container) == [second])
            // ⚠️ The replacement keeps the window up: the one it pushed out
            // leaves first, and an empty window hides itself.
            #expect(second.superview === overlay.container)
            #expect(!overlay.window.isHidden)
        }
    }

    /// A condition holds the top line; a result fired meanwhile hangs just
    /// under it, and nothing replaces the condition.
    @Test func aConditionAndAResultTakeALineEach() {
        let screen = UIViewController()
        hosting(screen) { _, overlay in
            let offline = Feedback.condition("Offline", symbol: "wifi.slash", id: "connectivity", from: screen)
            let saved = Feedback.success("Saved", from: screen)
            let sent = Feedback.success("Sent", from: screen)
            #expect(!offline.isDismissing)
            #expect(saved.isDismissing)
            #expect(ToastView.stack(in: overlay.container) == [offline, sent])
            offline.debugSettle()
            sent.debugSettle()
            #expect(sent.frame.minY >= offline.frame.maxY + ToastView.stackGap - 0.5, "the result overlaps the condition")
            offline.dismiss(animated: false)
            sent.debugSettle()
            #expect(abs(sent.frame.minY - offline.frame.minY) < 0.5, "the result did not take the top line back")
        }
    }

    /// Retry fires the next toast from its action: the next toast shows, in
    /// the overlay, with the window up.
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
            #expect(ToastView.stack(in: overlay.container).map(\.message) == ["Sent"])
        }
    }

    /// The window is up only while it holds a toast — hidden a turn after
    /// its last one leaves, so a toast taking over another's capsule (which
    /// removes it first) never blinks the window out for a frame.
    @Test func theWindowHidesWithItsLastToast() async {
        let screen = UIViewController()
        let window = UIWindow(frame: bounds)
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let overlay = ToastOverlay(window: ToastOverlayWindow(frame: bounds), appWindow: window)
        // Its own clock, captured by the toast as it is made and put back
        // before any `await`: another suite's hand-driven clock must not run
        // this toast out (`global-test-state-await-trap`).
        let previousMake = ToastOverlay.makeForTests
        let previousClock = ToastClock.current
        ToastOverlay.makeForTests = { _ in overlay }
        ToastClock.current = ToastClock.manual().0
        _ = HapticRecorder.recording { _ = Feedback.info("Saved", from: screen) }
        ToastOverlay.makeForTests = previousMake
        ToastClock.current = previousClock
        #expect(!overlay.window.isHidden)
        overlay.toasts.forEach { $0.dismiss(animated: false) }
        #expect(!overlay.window.isHidden, "hidden in the turn its toast left")
        for _ in 0..<50 where !overlay.window.isHidden { await Task.yield() }
        #expect(overlay.window.isHidden)
        overlay.window.isHidden = true
        window.rootViewController = nil
        window.isHidden = true
        window.layoutIfNeeded()
    }

    /// A toast taking over another's capsule keeps the window up through
    /// the turn after: the one it replaced left first.
    @Test func aTakeOverNeverHidesTheWindow() async {
        let screen = UIViewController()
        let window = UIWindow(frame: bounds)
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let overlay = ToastOverlay(window: ToastOverlayWindow(frame: bounds), appWindow: window)
        // Its own clock, as above.
        let previousMake = ToastOverlay.makeForTests
        let previousClock = ToastClock.current
        ToastOverlay.makeForTests = { _ in overlay }
        ToastClock.current = ToastClock.manual().0
        _ = HapticRecorder.recording {
            _ = Feedback.info("Notifications muted", symbol: "bell.slash.fill", from: screen)
            overlay.window.layoutIfNeeded()
            _ = Feedback.info("Notifications on", symbol: "bell.fill", from: screen)
        }
        ToastOverlay.makeForTests = previousMake
        ToastClock.current = previousClock
        let toastsUp = overlay.toasts.count
        let hiddenNow = overlay.window.isHidden
        for _ in 0..<10 { await Task.yield() }
        let hiddenAfter = overlay.window.isHidden
        #expect(toastsUp == 1 && !hiddenNow && !hiddenAfter, "toasts \(toastsUp), hidden now \(hiddenNow), after a turn \(hiddenAfter)")
        overlay.toasts.forEach { $0.dismiss(animated: false) }
        overlay.window.isHidden = true
        window.rootViewController = nil
        window.isHidden = true
        window.layoutIfNeeded()
    }

    /// A toast fired while the one up is closing turns its close around
    /// (#2285): one toast in the overlay, and the window stays up through
    /// the turn after — the closing one was removed first.
    @Test func aCloseTurnedAroundKeepsOneToastAndTheWindowUp() async {
        let screen = UIViewController()
        let window = UIWindow(frame: bounds)
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let overlay = ToastOverlay(window: ToastOverlayWindow(frame: bounds), appWindow: window)
        // Its own clock, as above.
        let previousMake = ToastOverlay.makeForTests
        let previousClock = ToastClock.current
        ToastOverlay.makeForTests = { _ in overlay }
        ToastClock.current = ToastClock.manual().0
        var closing: ToastView?
        _ = HapticRecorder.recording {
            closing = Feedback.info("Notifications muted", symbol: "bell.slash.fill", from: screen)
            overlay.window.layoutIfNeeded()
            closing?.dismiss(animated: true)
            _ = Feedback.info("Notifications on", symbol: "bell.fill", from: screen)
        }
        ToastOverlay.makeForTests = previousMake
        ToastClock.current = previousClock
        let messages = overlay.toasts.map(\.message)
        let closingGone = closing?.superview == nil
        for _ in 0..<10 { await Task.yield() }
        let hiddenAfter = overlay.window.isHidden
        #expect(messages == ["Notifications on"], "on the line: \(messages)")
        #expect(closingGone, "the closing toast is still there")
        #expect(!hiddenAfter, "the window hid with the close it turned around")
        overlay.toasts.forEach { $0.dismiss(animated: false) }
        overlay.window.isHidden = true
        window.rootViewController = nil
        window.isHidden = true
        window.layoutIfNeeded()
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

/// A screen with its own top chrome (`ToastAnchoring`).
private final class AnchoringScreen: UIViewController, ToastAnchoring {
    let chrome = UIView()
    var toastAnchorView: UIView? { chrome }
}
