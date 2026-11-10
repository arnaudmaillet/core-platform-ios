import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// A load shows only once the answer takes time (#2270, the owner
/// 2026-11-10: a fast passkey sign-in flashed a blurred button). At once the
/// phase, the refused re-taps, the held width, VoiceOver's busy; the blur
/// and the sheen after `loadGrace`; once drawn, at least `loadMinimum`, the
/// answer — the morph, the caller's completion — waiting for it. Time is a
/// stepped clock: nothing here waits on the wall clock.
@MainActor
struct AppButtonLoadGraceTests {
    private let grace = AppButton.MorphMetrics.loadGrace
    private let minimum = AppButton.MorphMetrics.loadMinimum

    private func hosted(_ button: AppButton) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 80))
        window.addSubview(host)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutIfNeeded()
        return (window, host)
    }

    private func follow(on time: ManualLoadingClock, reduced: Bool = false) -> AppButton {
        let button = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
        button.reducesMotion = { reduced }
        button.loadClock = time.clock
        return button
    }

    private func inkAlpha(_ button: AppButton) -> CGFloat {
        button.configuration?.baseForegroundColor?
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.alpha ?? 1
    }

    /// The owner's numbers (2026-11-10).
    @Test func theGraceIsHalfASecondAndTheMinimumAThird() {
        #expect(grace == 0.5)
        #expect(minimum == 0.3)
    }

    /// At once: the phase, the re-taps refused, the width held, VoiceOver
    /// told it is busy — and nothing drawn.
    @Test func aLoadRefusesReTapsAndSaysBusyAtOnce() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        let width = button.bounds.width
        button.busyLabel = "Following…"

        button.setPhase(.loading, animated: true)
        #expect(button.phase == .loading)
        #expect(!button.acceptsTaps, "a re-tap is taken during the grace")
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 0, "a re-tap reached the action during the grace")
        #expect(abs((button.debugHeldSize?.width ?? 0) - width) < 0.5, "the width is not held at once")
        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityValue == "Following…", "VoiceOver is not told it is busy at once")
        #expect(!button.isLoadShown)
        #expect(!button.debugVeilIsShown, "the load was drawn at once")
    }

    /// Not drawn before the grace — the words sharp, at full ink — drawn
    /// after it.
    @Test func theLoadIsDrawnOnlyAfterTheGrace() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        var shown: [Bool] = []
        button.onLoadShownChange = { shown.append($0) }

        button.setPhase(.loading, animated: true)
        time.advance(grace - 0.02)
        #expect(!button.isLoadShown)
        #expect(!button.debugVeilIsShown, "the load was drawn inside its grace")
        #expect(!button.debugIsUnderStandIn)
        #expect(abs(inkAlpha(button) - 1) < 0.01, "the words faded inside the grace")
        #expect(shown.isEmpty)

        time.advance(0.04)
        #expect(button.isLoadShown)
        #expect(button.debugVeilIsShown, "the load was not drawn after its grace")
        #expect(button.debugIsUnderStandIn)
        #expect(shown == [true])
    }

    /// An answer inside the grace: the load is never drawn, nothing moves
    /// after the press, the caller goes on at once, and nothing is left
    /// scheduled.
    @Test func anAnswerInTheGraceDrawsNoLoad() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        var shown: [Bool] = []
        button.onLoadShownChange = { shown.append($0) }

        button.setPhase(.loading, animated: true)
        time.advance(grace / 2)
        var answered = false
        button.setPhase(.content, animated: true) { answered = true }
        #expect(answered, "the caller waited for a load never drawn")
        #expect(button.phase == .content)
        #expect(button.acceptsTaps)
        #expect(time.pendingCount == 0, "the grace was left scheduled")

        time.advance(1)
        #expect(!button.debugVeilIsShown, "the load was drawn after the answer")
        #expect(shown.isEmpty)
        #expect(!button.events.contains(.blurMorph), "the same content moved after the press")
    }

    /// New content inside the grace (Follow → Following): today's morph,
    /// from the sharp content — and still no load after it.
    @Test func newContentInTheGraceMorphsFromTheSharpContent() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }

        button.setPhase(.loading, animated: true)
        time.advance(grace / 2)
        button.setContent(.title("Following"), selected: true, animated: true)
        #expect(button.events.last == .blurMorph, "the answer did not morph from the sharp content")
        #expect(time.pendingCount == 0, "the grace outlived the answer")
        button.setPhase(.content, animated: true)
        time.advance(1)
        #expect(!button.isLoadShown)
        #expect(button.configuration?.title == "Following")
        #expect(button.isSelected)
    }

    /// Once drawn, the load stays its minimum: an answer at 0.6 s shows at
    /// 0.8 s — the morph and the caller's completion both.
    @Test func aDrawnLoadLastsItsMinimumAndTheAnswerWaits() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        var shown: [Bool] = []
        button.onLoadShownChange = { shown.append($0) }

        button.setPhase(.loading, animated: true)
        time.advance(grace)
        #expect(button.isLoadShown)
        time.advance(0.1)
        button.setContent(.title("Following"), selected: true, animated: true)
        var answered = false
        button.setPhase(.content, animated: true) { answered = true }
        #expect(!answered, "the caller went on before the load's minimum")
        #expect(button.phase == .loading, "the answer showed before the load's minimum")
        #expect(button.debugIsUnderStandIn)
        #expect(!button.acceptsTaps)
        #expect(button.events.last != .blurMorph)

        time.advance(minimum - 0.1 - 0.02)
        #expect(!answered)
        #expect(button.isLoadShown)

        time.advance(0.04)
        #expect(answered, "the caller never went on")
        #expect(button.phase == .content)
        #expect(!button.isLoadShown)
        #expect(button.events.last == .blurMorph, "the end of the load is not today's morph")
        #expect(shown == [true, false])
        #expect(time.pendingCount == 0)
    }

    /// An answer past the minimum: at once, today's morph out of the load.
    @Test func anAnswerPastTheMinimumEndsAtOnce() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        time.advance(grace + minimum + 0.5)
        var answered = false
        button.setPhase(.content, animated: true) { answered = true }
        #expect(answered)
        #expect(button.phase == .content)
        #expect(button.events.last == .blurMorph)
    }

    /// A load taken back up during the minimum's tail stays drawn, and the
    /// earlier caller still hears the end — at the next one.
    @Test func aLoadTakenBackUpInTheTailKeepsItsCaller() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        time.advance(grace)
        var answers = 0
        button.setPhase(.content, animated: true) { answers += 1 }
        button.setPhase(.loading, animated: true)
        time.advance(1)
        #expect(answers == 0, "a replaced end ran while the load went on")
        #expect(button.isLoadShown)
        button.setPhase(.content, animated: true) { answers += 1 }
        #expect(answers == 2)
    }

    /// Reduce Motion: the same grace — the faded words only after it.
    @Test func reduceMotionWaitsTheSameGrace() {
        let time = ManualLoadingClock()
        let button = follow(on: time, reduced: true)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        time.advance(grace - 0.02)
        #expect(abs(inkAlpha(button) - 1) < 0.01, "the words faded inside the grace")
        time.advance(0.04)
        #expect(button.isLoadShown)
        #expect(!button.debugIsUnderStandIn, "a blur under Reduce Motion")
        #expect(abs(inkAlpha(button) - AppButton.MorphMetrics.loadingInkAlpha) < 0.01)
    }

    /// Not animated, both ways at once: no grace, no minimum.
    @Test func aChangeNotAnimatedIsImmediate() {
        let time = ManualLoadingClock()
        let button = follow(on: time)
        button.setPhase(.loading, animated: false)
        #expect(button.isLoadShown)
        var answered = false
        button.setPhase(.content, animated: false) { answered = true }
        #expect(answered)
        #expect(!button.isLoadShown)
        #expect(time.pendingCount == 0)
    }

    /// A locked button refuses taps without looking it, and VoiceOver hears
    /// it dimmed.
    @Test func aLockedButtonRefusesTapsWithoutGreying() {
        let button = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Continue with email"))
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        button.isLocked = true
        #expect(!button.acceptsTaps)
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 0)
        #expect(button.configuration?.baseForegroundColor != .tertiaryLabel, "a lock greyed the button")
        #expect(button.accessibilityTraits.contains(.notEnabled))
        button.isLocked = false
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 1)
    }
}
