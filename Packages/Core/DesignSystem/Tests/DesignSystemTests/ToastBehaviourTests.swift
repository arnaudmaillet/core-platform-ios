import Testing
import UIKit
@testable import DesignSystem

/// The toast's own behaviour (#954): how long it stays, what pauses it, the
/// close button and the action, the swipe, VoiceOver, Reduce Motion and the
/// interactive glass.
///
/// Time is a hand-driven `ToastClock`; every process-wide switch a test sets
/// (`ToastClock.current`, Reduce Motion's defaults, the assistive-technology
/// probe) is set and put back synchronously, with no `await` in between.
@MainActor
@Suite(.serialized)
struct ToastBehaviourTests {

    /// A toast in a visible window, on a manual clock; all taken down within
    /// the test.
    private func hosting(
        reducesMotion: Bool = false,
        assistiveTechnology: Bool = false,
        _ body: (UIView, (TimeInterval) -> Void) throws -> Void
    ) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, advance) = ToastClock.manual()
        let previousClock = ToastClock.current
        let previousProbe = ToastView.isAssistiveTechnologyRunning
        let previousDefaults = MotionPreference.defaults
        let suite = UserDefaults(suiteName: "ToastBehaviourTests")!
        suite.removePersistentDomain(forName: "ToastBehaviourTests")
        suite.set(reducesMotion, forKey: MotionPreference.key)
        ToastClock.current = clock
        ToastView.isAssistiveTechnologyRunning = { assistiveTechnology }
        MotionPreference.defaults = suite
        defer {
            ToastClock.current = previousClock
            ToastView.isAssistiveTechnologyRunning = previousProbe
            MotionPreference.defaults = previousDefaults
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(window.rootViewController!.view, advance)
    }

    private func toast(
        _ message: String = "Saved", style: ToastView.Style = .confirmation,
        action: ToastView.Action? = nil, position: ToastPosition = .bottom, in container: UIView
    ) -> ToastView {
        ToastView.present(
            message, symbol: nil, style: style, action: action, position: position, in: container
        )
    }

    // MARK: - How long

    @Test func aShortConfirmationStaysFourSeconds() {
        #expect(ToastView.duration(for: .confirmation, message: "Copied", hasAction: false, assistiveTechnologyRunning: false) == 4)
    }

    /// 2 s + 0.3 s a word, once that is past the 4 s floor.
    @Test func aLongerMessageStaysLonger() {
        let message = "one two three four five six seven eight nine ten"
        let duration = ToastView.duration(for: .warning, message: message, hasAction: false, assistiveTechnologyRunning: false)
        #expect(abs((duration ?? 0) - (2 + 0.3 * 10)) < 0.001)
    }

    /// A failure stays until closed, acted on or replaced.
    @Test func aFailureNeverLeavesOnItsOwn() {
        #expect(ToastView.duration(for: .failure, message: "Couldn't copy", hasAction: false, assistiveTechnologyRunning: false) == nil)
    }

    /// WCAG 2.2.1: with VoiceOver or Switch Control, an action does not time
    /// out.
    @Test func anActionWaitsForAssistiveTechnology() {
        #expect(ToastView.duration(for: .confirmation, message: "Sent", hasAction: true, assistiveTechnologyRunning: true) == nil)
        #expect(ToastView.duration(for: .confirmation, message: "Sent", hasAction: true, assistiveTechnologyRunning: false) == 4)
        #expect(ToastView.duration(for: .confirmation, message: "Sent", hasAction: false, assistiveTechnologyRunning: true) == 4)
    }

    // MARK: - The countdown

    @Test func itLeavesWhenItsTimeRunsOut() {
        hosting { container, advance in
            let shown = toast(in: container)
            advance(3.9)
            #expect(!shown.isDismissing)
            advance(0.2)
            #expect(shown.isDismissing)
        }
    }

    /// A finger on it holds the time; lifting it resumes with what was left.
    @Test func aFingerHoldsTheTime() {
        hosting { container, advance in
            let shown = toast(in: container)
            advance(3)
            shown.countdown?.hold(.touch)
            advance(10)
            #expect(!shown.isDismissing)
            shown.countdown?.release(.touch)
            advance(0.9)
            #expect(!shown.isDismissing)
            advance(0.2)
            #expect(shown.isDismissing)
        }
    }

    /// Every hold must be released before it runs again.
    @Test func everyHoldMustBeReleased() {
        hosting { container, advance in
            let shown = toast(in: container)
            shown.countdown?.hold(.voiceOverFocus)
            shown.countdown?.hold(.sceneInactive)
            shown.countdown?.release(.voiceOverFocus)
            advance(10)
            #expect(!shown.isDismissing)
            shown.countdown?.release(.sceneInactive)
            advance(4.1)
            #expect(shown.isDismissing)
        }
    }

    /// VoiceOver's focus on it holds it.
    @Test func voiceOverFocusHoldsTheTime() {
        hosting { container, advance in
            let shown = toast(in: container)
            shown.accessibilityElementDidBecomeFocused()
            advance(10)
            #expect(!shown.isDismissing)
            shown.accessibilityElementDidLoseFocus()
            advance(4.1)
            #expect(shown.isDismissing)
        }
    }

    // MARK: - Close and action

    /// A failure carries a close button, and no countdown.
    @Test func aFailureHasACloseButton() throws {
        try hosting { container, advance in
            let shown = toast("Couldn't copy", style: .failure, in: container)
            #expect(shown.countdown == nil)
            let close = try #require(shown.closeButton)
            advance(60)
            #expect(!shown.isDismissing)
            close.sendActions(for: .primaryActionTriggered)
            #expect(shown.isDismissing)
        }
    }

    /// The action runs once, and the toast leaves.
    @Test func theActionRunsOnceAndTheToastLeaves() throws {
        try hosting { container, _ in
            var runs = 0
            let shown = toast("Couldn't send", style: .failure, action: ToastView.Action("Retry") { runs += 1 }, in: container)
            #expect(shown.closeButton == nil, "one trailing control: the action")
            let button = try #require(shown.actionButton)
            button.sendActions(for: .primaryActionTriggered)
            button.sendActions(for: .primaryActionTriggered)
            #expect(runs == 1)
            #expect(shown.isDismissing)
        }
    }

    // MARK: - The swipe

    /// Toward the toast's own edge, and toward its side when it has one.
    @Test func eachPositionSwipesTowardItsEdge() {
        #expect(ToastView.swipeDirections(for: .bottom, rightToLeft: false) == .init(vertical: 1, horizontal: 0))
        #expect(ToastView.swipeDirections(for: .top, rightToLeft: false) == .init(vertical: -1, horizontal: 0))
        #expect(ToastView.swipeDirections(for: .bottomLeading, rightToLeft: false) == .init(vertical: 1, horizontal: -1))
        #expect(ToastView.swipeDirections(for: .topTrailing, rightToLeft: false) == .init(vertical: -1, horizontal: 1))
        #expect(ToastView.swipeDirections(for: .bottomLeading, rightToLeft: true) == .init(vertical: 1, horizontal: 1))
    }

    /// A pull toward the edge is followed; the other way it stretches, and
    /// never past the limit.
    @Test func theWrongWayRubberBands() {
        #expect(ToastView.followed(80, direction: 1) == 80)
        let stretched = ToastView.followed(-80, direction: 1)
        #expect(stretched < 0 && stretched > -ToastView.Metrics.rubberBandLimit)
        let sideways = ToastView.followed(300, direction: 0)
        #expect(sideways > 0 && sideways < ToastView.Metrics.rubberBandLimit)
    }

    /// On distance or speed toward the edge; never away from it.
    @Test func aSwipeDismissesOnDistanceOrSpeed() {
        let down = ToastView.SwipeDirections(vertical: 1, horizontal: 0)
        #expect(ToastView.dismisses(translation: CGPoint(x: 0, y: 60), velocity: .zero, directions: down))
        #expect(ToastView.dismisses(translation: CGPoint(x: 0, y: 10), velocity: CGPoint(x: 0, y: 900), directions: down))
        #expect(!ToastView.dismisses(translation: CGPoint(x: 0, y: -80), velocity: CGPoint(x: 0, y: -900), directions: down))
        #expect(!ToastView.dismisses(translation: CGPoint(x: 200, y: 0), velocity: .zero, directions: down))
        let leading = ToastView.SwipeDirections(vertical: 1, horizontal: -1)
        #expect(ToastView.dismisses(translation: CGPoint(x: -60, y: 0), velocity: .zero, directions: leading))
    }

    // MARK: - VoiceOver

    /// One element: the text, the action, a way to dismiss.
    @Test func itIsOneAccessibilityElement() {
        hosting { container, _ in
            let shown = toast("Couldn't send", style: .failure, action: .init("Retry") {}, in: container)
            #expect(shown.isAccessibilityElement)
            #expect(shown.accessibilityLabel == "Couldn't send")
            #expect(shown.accessibilityCustomActions?.map(\.name) == ["Retry", "Dismiss"])
        }
    }

    /// The escape gesture dismisses it.
    @Test func escapeDismisses() {
        hosting { container, _ in
            let shown = toast("Couldn't copy", style: .failure, in: container)
            #expect(shown.accessibilityPerformEscape())
            #expect(shown.isDismissing)
        }
    }

    /// A failure is announced with high priority; anything else, default.
    @Test func aFailureIsAnnouncedFirst() {
        let failure = ToastView.announcement("Couldn't copy", style: .failure)
        let success = ToastView.announcement("Copied")
        let key = NSAttributedString.Key.accessibilitySpeechAnnouncementPriority
        #expect(failure.attribute(key, at: 0, effectiveRange: nil) as? UIAccessibilityPriority == .high)
        #expect(success.attribute(key, at: 0, effectiveRange: nil) as? UIAccessibilityPriority == .default)
    }

    // MARK: - Motion and glass

    /// Under Reduce Motion it does not slide: the glass materialises in place.
    @Test func reduceMotionRemovesTheSlide() {
        hosting(reducesMotion: true) { container, _ in
            #expect(toast(in: container).entranceTravel == 0)
        }
        hosting(reducesMotion: false) { container, _ in
            #expect(toast(in: container).entranceTravel > 0)
        }
    }

    /// Interactive Liquid Glass, and never a transform or an alpha on the
    /// glass or the bubble that holds it.
    @Test func theGlassIsInteractiveAndNeverFadedOrMoved() {
        hosting { container, _ in
            let shown = toast(in: container)
            #expect((shown.glassView.effect as? UIGlassEffect)?.isInteractive == true)
            #expect(shown.isUserInteractionEnabled)
            #expect(shown.alpha == 1 && shown.glassView.alpha == 1)
            #expect(shown.transform == .identity && shown.glassView.transform == .identity)
        }
    }

    // MARK: - Feedback

    /// A warning: its style and its haptic.
    @Test func aWarningPairsItsStyleAndHaptic() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        let previous = Feedback.playHaptic
        var played: [UINotificationFeedbackGenerator.FeedbackType] = []
        Feedback.playHaptic = { played.append($0) }
        defer {
            Feedback.playHaptic = previous
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let shown = Feedback.warning("Saved without its sound", from: screen)
        #expect(shown.style == .warning)
        #expect(played == [.warning])
    }
}
