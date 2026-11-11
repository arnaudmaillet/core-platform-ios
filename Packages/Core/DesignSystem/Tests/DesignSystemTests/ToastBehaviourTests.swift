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
        action: ToastView.Action? = nil, in container: UIView
    ) -> ToastView {
        ToastView.present(message, symbol: nil, style: style, action: action, in: container)
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

    /// A failure leaves on the common timer (#1448, replacing #954's "until
    /// closed"); with an action, not while assistive technology runs.
    @Test func aFailureLeavesOnTheCommonTimer() {
        #expect(ToastView.duration(for: .failure, message: "Couldn't copy", hasAction: false, assistiveTechnologyRunning: false) == 4)
        let long = "Couldn't ask to follow one two three four five six"
        let duration = ToastView.duration(for: .failure, message: long, hasAction: false, assistiveTechnologyRunning: false)
        #expect(abs((duration ?? 0) - (2 + 0.3 * 10)) < 0.001)
        #expect(ToastView.duration(for: .failure, message: "Couldn't send", hasAction: true, assistiveTechnologyRunning: false) == 4)
        #expect(ToastView.duration(for: .failure, message: "Couldn't send", hasAction: true, assistiveTechnologyRunning: true) == nil)
        #expect(ToastView.duration(for: .loading, message: "Posting", hasAction: false, assistiveTechnologyRunning: false) == nil)
    }

    /// A `.long` toast stays at least `longDuration` (#1459); the rest of the
    /// rule is unchanged — a longer message can still ask for more, and
    /// assistive technology still holds a toast with an action.
    @Test func aLongToastStaysLonger() {
        func duration(_ message: String, action: Bool = false, length: ToastView.Length) -> TimeInterval? {
            ToastView.Content(
                message: message, symbol: nil, style: .failure,
                action: action ? ToastView.Action("Retry") {} : nil, undoable: nil, id: nil, length: length
            ).duration
        }
        #expect(ToastView.longDuration == 10)
        #expect(duration("Couldn't publish your post", length: .standard) == 4)
        #expect(duration("Couldn't publish your post", length: .long) == 10)
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        #expect(abs((duration(words, length: .long) ?? 0) - (2 + 0.3 * 30)) < 0.001, "a longer message lost its time")
        let previous = ToastView.isAssistiveTechnologyRunning
        ToastView.isAssistiveTechnologyRunning = { true }
        defer { ToastView.isAssistiveTechnologyRunning = previous }
        #expect(duration("Couldn't publish your post", action: true, length: .long) == nil)
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

    /// A failure leaves on its own like the others (#1448): a countdown, no
    /// close button.
    @Test func aFailureLeavesOnItsOwnWithNoCloseButton() throws {
        try hosting { container, advance in
            let shown = toast("Couldn't copy", style: .failure, in: container)
            #expect(shown.countdown != nil)
            #expect(shown.closeButton == nil)
            advance(3.9)
            #expect(!shown.isDismissing)
            advance(0.2)
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

    /// A pull toward the edge is followed; the other way it stretches, and
    /// never past the limit.
    @Test func theWrongWayRubberBands() {
        #expect(ToastView.followed(80, direction: 1) == 80)
        let stretched = ToastView.followed(-80, direction: 1)
        #expect(stretched < 0 && stretched > -ToastView.Metrics.rubberBandLimit)
        let sideways = ToastView.followed(300, direction: 0)
        #expect(sideways > 0 && sideways < ToastView.Metrics.rubberBandLimit)
    }

    /// Up, on distance or speed (#2143: every toast hangs from the top);
    /// never down, never sideways.
    @Test func aSwipeUpDismissesOnDistanceOrSpeed() {
        #expect(ToastView.dismisses(translation: CGPoint(x: 0, y: -60), velocity: .zero))
        #expect(ToastView.dismisses(translation: CGPoint(x: 0, y: -10), velocity: CGPoint(x: 0, y: -900)))
        #expect(!ToastView.dismisses(translation: CGPoint(x: 0, y: 80), velocity: CGPoint(x: 0, y: 900)))
        #expect(!ToastView.dismisses(translation: CGPoint(x: 200, y: 0), velocity: CGPoint(x: 900, y: 0)))
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

    /// THE UNFOLD (#2285): the capsule starts as a circle round its mark,
    /// as tall as it will be, centred where it will stand — and with no
    /// transform on the row or on anything in it: the content is never
    /// scaled, and the capsule never slides.
    @Test func theUnfoldStartsAtTheMarksCircle() throws {
        try hosting { container, _ in
            let shown = ToastView.present(
                "Notifications muted", symbol: "bell.slash.fill", style: .confirmation,
                action: .init("View") {}, in: container
            )
            let start = try #require(shown.unfoldedFrom, "no unfold")
            let height = shown.bounds.height
            #expect(abs(start.capsule.width - height) < 0.5, "not a circle: \(start.capsule.size)")
            #expect(abs(start.capsule.height - height) < 0.5, "the height changed: \(start.capsule.height) → \(height)")
            #expect(abs(height - ToastView.Metrics.minimumHeight) < 0.5)
            #expect(abs(start.capsule.midX - container.bounds.midX) < 0.5, "not centred")
            #expect(abs(start.capsule.minY - shown.frame.minY) < 0.5, "it slid")
            let mark = try #require(start.mark)
            let offCentre = abs(mark.midX - start.capsule.width / 2)
            let offMiddle = abs(mark.midY - height / 2)
            #expect(offCentre < 0.5, "the mark is off the circle's middle: \(mark)")
            #expect(offMiddle < 0.5, "the mark is off the circle's middle: \(mark)")
            #expect(shown.bounds.width > start.capsule.width + 50, "it did not open to its width")
            #expect(shown.debugRow.transform == .identity)
            #expect(shown.debugRow.arrangedSubviews.allSatisfy { $0.transform == .identity }, "a piece was scaled")
        }
    }

    /// A loader's toast unfolds round its loader, centred in the circle.
    @Test func aLoadingToastUnfoldsRoundItsLoader() throws {
        try hosting { container, _ in
            let shown = ToastView.present("Posting…", symbol: nil, style: .loading, id: "post", in: container)
            let start = try #require(shown.unfoldedFrom)
            let mark = try #require(start.mark)
            #expect(abs(mark.midX - start.capsule.width / 2) < 0.5, "the loader is off the circle's middle")
            #expect(shown.debugMark is AppLoaderView)
        }
    }

    /// THE FOLD (#2285): the way back — the capsule ends as the circle round
    /// its mark, in the same place; then it is removed.
    @Test func theFoldEndsAtTheMarksCircle() throws {
        try hosting { container, _ in
            let shown = ToastView.present(
                "Couldn't send", symbol: "exclamationmark.circle.fill", style: .failure,
                action: .init("Retry") {}, in: container
            )
            container.layoutIfNeeded()
            let resting = shown.frame
            shown.dismiss(animated: true)
            #expect(shown.isDismissing)
            #expect(shown.superview === container, "removed before its fold")
            let end = try #require(shown.foldedTo, "no fold")
            let side = resting.height
            #expect(abs(end.capsule.width - side) < 0.5, "not the circle: \(end.capsule.size)")
            #expect(abs(end.capsule.height - side) < 0.5, "not the circle: \(end.capsule.size)")
            #expect(abs(end.capsule.midX - resting.midX) < 0.5, "it moved sideways")
            #expect(abs(end.capsule.minY - resting.minY) < 0.5, "it slid")
            let mark = try #require(end.mark)
            #expect(abs(mark.midX - end.capsule.width / 2) < 0.5, "the mark did not slide back to the middle")
            #expect(shown.glassView.effect == nil, "the glass did not dissolve")
            #expect(shown.debugRow.transform == .identity)
        }
    }

    /// THE WHOLE CONTENT BLURS (#2285): a change blurs the old mark, words
    /// and action away and the new ones in — the disc and the action too,
    /// not only the words.
    @Test func aChangeBlursTheMarkTheWordsAndTheAction() throws {
        try hosting { container, _ in
            _ = ToastView.present(
                "Notifications muted", symbol: "bell.slash.fill", style: .confirmation,
                undoable: .init(commit: {}, undo: {}), in: container
            )
            container.layoutIfNeeded()
            let failed = ToastView.present(
                "Couldn't follow @ava", symbol: "exclamationmark.circle.fill", style: .failure,
                action: .init("Retry") {}, in: container
            )
            let motion = try #require(failed.lastChangeMotion)
            #expect(!motion.crossFades)
            #expect(motion.blurredOut == [.mark, .text, .control], "blurred away: \(motion.blurredOut)")
            #expect(motion.blurredIn == [.mark, .text, .control], "blurred in: \(motion.blurredIn)")
        }
    }

    /// An update by `id` (loading → done) keeps the capsule and uses the
    /// same blur: the loader blurs away, the disc comes out of the blur.
    @Test func anUpdateByIDBlursInTheSameCapsule() throws {
        try hosting { container, _ in
            let loading = ToastView.present("Posting…", symbol: nil, style: .loading, id: "post", in: container)
            container.layoutIfNeeded()
            let posted = ToastView.present("Posted", symbol: "checkmark.circle.fill", style: .confirmation, id: "post", in: container)
            #expect(posted === loading)
            #expect(container.subviews.compactMap { $0 as? ToastView } == [posted])
            let motion = try #require(posted.lastChangeMotion)
            #expect(motion.blurredOut.contains(.mark), "the loader did not blur away: \(motion)")
            #expect(motion.blurredIn.contains(.mark), "the disc did not blur in: \(motion)")
            #expect(motion.blurredIn.contains(.text))
        }
    }

    /// Under Reduce Motion: no unfold — no width animation, the capsule at
    /// its width from the start, the glass materialising in place — and a
    /// change is a cross-fade, not a blur.
    @Test func reduceMotionHasNoUnfoldAndCrossFades() throws {
        try hosting(reducesMotion: true) { container, _ in
            let first = ToastView.present("Notifications muted", symbol: "bell.slash.fill", style: .confirmation, in: container)
            #expect(first.unfoldedFrom == nil, "it unfolded under Reduce Motion")
            #expect(first.bounds.width > first.bounds.height + 50, "not at its width from the start")
            container.layoutIfNeeded()
            let second = ToastView.present("Notifications on", symbol: "bell.fill", style: .confirmation, in: container)
            let motion = try #require(second.lastChangeMotion)
            #expect(motion.crossFades)
            #expect(motion.blurredIn.isEmpty, "it blurred under Reduce Motion")
            #expect(motion.blurredOut.isEmpty, "it blurred under Reduce Motion")
            second.dismiss(animated: true)
            #expect(second.foldedTo == nil, "it folded under Reduce Motion")
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
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let played = HapticRecorder.recording {
            let shown = Feedback.warning("Saved without its sound", from: screen)
            #expect(shown.style == .warning)
        }
        #expect(played == [.warning])
    }
}
