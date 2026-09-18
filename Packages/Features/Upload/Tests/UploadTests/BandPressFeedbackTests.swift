import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// Every button of the editing tools gives under the finger and ticks on a tap;
/// the two rulers grow while held. The mechanism is DesignSystem's
/// `PressFeedback` and is tested there — what is pinned here is that each tool
/// WEARS it, on every element a finger can press, and that the rulers keep
/// their tick under the finger while grown.
///
/// ⚠️ **THE DECISION, NOT THE DRAWING.** A press lives in the render tree only,
/// so what is read is what the feedback decided: pressed, then released as a
/// tap. `sendActions(for:)` runs the very actions `attach` registered — and the
/// control's own action beside them, which is why the tools here are left with
/// no callbacks to call.
///
/// ⚠️ **"SPRANG" IS NOT ASKED, "TAP" IS.** Whether anything moved depends on
/// Reduce Motion, which these tools read off the device (the editor has no seam
/// for it), and a test must not pass or fail with a setting on the machine that
/// ran it. `PressFeedbackTests` covers both sides of that setting with it
/// stated.
@MainActor
struct BandPressFeedbackTests {
    /// Presses and taps every control, and says which ones did not answer.
    private func everyControlAnswers(
        _ controls: [UIControl], expected: Int, _ name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(controls.count == expected, "\(name): \(controls.count) controls, not \(expected)",
                sourceLocation: sourceLocation)
        var silent: [String] = []
        for (index, control) in controls.enumerated() {
            let label = control.accessibilityLabel ?? "#\(index)"
            guard let feedback = PressFeedback.attached(to: control) else {
                silent.append("\(label): nothing attached")
                continue
            }
            control.sendActions(for: .touchDown)
            let pressed = feedback.isPressed
            control.sendActions(for: .touchUpInside)
            guard pressed, case .released(tap: true, _) = feedback.debugEvents.last else {
                silent.append("\(label): \(feedback.debugEvents)")
                continue
            }
        }
        #expect(silent.isEmpty, "\(name) — these did not give and tick: \(silent)",
                sourceLocation: sourceLocation)
    }

    // MARK: - The band's tools

    /// The turn, the mirror and the fill/fit glyph, then every shape.
    @Test func everyButtonOfTheCropToolsGivesAndTicks() {
        let tools = MediaCropToolsView()
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaCropToolsView.height)
        tools.layoutIfNeeded()

        everyControlAnswers(tools.debugPressables, expected: 3 + CropRatio.allCases.count, "crop")
    }

    /// ⚠️ **THE CARD GIVES, NOT THE CLEAR BUTTON OVER IT.** A filter card is a
    /// picture and a caption under a transparent button; a press that moved
    /// the button would move nothing anyone can see.
    @Test func everyLookCardGivesAndTicksAndTheCardIsWhatMoves() throws {
        let row = MediaFilterRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: MediaFilterRowView.height)
        row.layoutIfNeeded()

        everyControlAnswers(row.debugPressables, expected: MediaFilter.allCases.count, "looks")
        let first = try #require(row.debugPressables.first)
        let feedback = try #require(PressFeedback.attached(to: first))
        #expect(feedback.debugTarget === row.debugChips().first, "the clear button moves instead of its card")
    }

    /// The two icons, then every dial and effect pill.
    @Test func everyButtonOfTheEffectsToolsGivesAndTicks() {
        let tools = MediaEffectsToolsView()
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaEffectsToolsView.height)
        tools.layoutIfNeeded()

        everyControlAnswers(
            tools.debugPressables,
            expected: 2 + LookAdjustments.Key.allCases.count + LookEffectKind.allCases.count,
            "effects"
        )
    }

    @Test func everyTransitionCardGivesAndTicks() {
        let row = MediaTransitionRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTransitionRowView.height)
        row.layoutIfNeeded()

        everyControlAnswers(row.debugPressables, expected: MediaTransitionCatalog.choices.count + 1, "transitions")
    }

    /// The rate chips over the track.
    @Test func everyRateChipGivesAndTicks() {
        let row = MediaSpeedRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 40)
        row.layoutIfNeeded()

        everyControlAnswers(row.debugPressables, expected: MediaTimelining.rates.count, "rates")
    }

    /// The lengths a transition can be given.
    @Test func everyLengthChipGivesAndTicks() {
        let row = MediaTransitionDurationRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 40)
        row.layoutIfNeeded()

        everyControlAnswers(
            row.debugPressables, expected: MediaTimelining.transitionLengths.count, "lengths"
        )
    }

    @Test func everyPieceFilterCardGivesAndTicks() {
        let row = MediaSegmentFilterRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: MediaSegmentFilterRowView.height)
        row.layoutIfNeeded()

        everyControlAnswers(
            row.debugPressables, expected: MediaSegmentFilterRowView.filterChoices.count + 1, "piece filters"
        )
    }

    /// ⚠️ **THE CLOSE BUTTON TICKS AND LEAVES THE MOTION TO ITS GLASS.** It sits
    /// in an interactive `UIGlassEffect`, which scales and shimmers under a
    /// touch by itself; a second scale on the glyph would fight it.
    @Test func theCloseButtonTicksAndLeavesTheMotionToItsGlass() throws {
        let row = MediaTransitionRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTransitionRowView.height)
        row.layoutIfNeeded()
        let close = try #require(row.debugPressables.last)
        try #require(close === row.debugCloseButton, "guard: the last pressable is the close button")
        let feedback = try #require(PressFeedback.attached(to: close))

        close.sendActions(for: .touchDown)
        close.sendActions(for: .touchUpInside)

        #expect(feedback.debugEvents == [.pressed(scale: 1), .released(tap: true, sprang: false)],
                "\(feedback.debugEvents)")
    }

    /// "Add text", then a card per overlay already placed — text, emoji and a
    /// sticker, so every kind of face is asked.
    @Test func everyOverlayCardGivesAndTicks() {
        let tools = MediaOverlayToolsView(addTitle: "Add text", addSymbol: "textformat")
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaOverlayToolsView.height)
        tools.show([
            FrameOverlay(id: "t", content: .text(TextOverlay(text: "Hello"))),
            FrameOverlay(id: "e", content: .emoji("🎉")),
            FrameOverlay(id: "s", content: .sticker(id: "not-in-the-catalog"))
        ])
        tools.layoutIfNeeded()

        everyControlAnswers(tools.debugFaces, expected: 4, "overlays")
    }

    /// Files, From a video, and Remove — the levels are sliders, which iOS
    /// already answers while held.
    @Test func everyButtonOfTheSongToolsGivesAndTicks() {
        let tools = MediaSoundtrackToolsView()
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaSoundtrackToolsView.height)
        tools.layoutIfNeeded()

        everyControlAnswers(tools.debugPressables, expected: 3, "song")
    }

    /// The two cycle buttons, every typeface, every ink, and the colour well.
    @Test func everyControlOfTheTextStyleBarGivesAndTicks() {
        let bar = MediaTextStyleBar(frame: CGRect(x: 0, y: 0, width: 390, height: MediaTextStyleBar.height))
        bar.layoutIfNeeded()

        everyControlAnswers(
            bar.debugPressables,
            expected: 2 + OverlayFont.allCases.count + MediaTextPalette.swatches.count + 1,
            "text style"
        )
    }

    // MARK: - The scrollers they live in

    /// ⚠️ **TOUCHES REACH THE CHIPS AT ONCE, AND THE SCROLL STILL WINS.** With
    /// `delaysContentTouches` left on, a tap quicker than ~150ms is handed over
    /// as a touch-down and a touch-up in the same instant and no press is ever
    /// seen; off, the scroll takes a drag back by cancelling the chip's touch —
    /// which is a silent release (`PressFeedbackTests`).
    @Test func theChipScrollerHandsTouchesOverAtOnceAndStillTakesTheDrag() {
        let scroller = ChipScrollView()

        #expect(!scroller.delaysContentTouches, "a quick tap is never seen to press")
        #expect(scroller.canCancelContentTouches, "a drag starting on a chip would be kept by the chip")
        #expect(scroller.touchesShouldCancel(in: UIButton()), "a drag starting on a chip would be kept by the chip")
    }

    // MARK: - The rulers

    /// ⚠️ **THE STRIP GROWS, ON THE FINGER, AND THE TICK STAYS UNDER IT.** The
    /// pan measures in the dial's own points while the strip is drawn larger:
    /// without dividing by the held scale, every tick would outrun the finger
    /// by six percent. Asked through the same routine the pan calls.
    @Test func theStraighteningStripGrowsWhileHeldAndItsTickStaysUnderTheFinger() throws {
        let dial = StraightenDialView()
        dial.frame = CGRect(x: 0, y: 0, width: 300, height: StraightenDialView.height)
        dial.layoutIfNeeded()
        let hold = dial.debugHold
        #expect(hold.style == .hold)
        #expect(hold.debugRecognizer?.view === dial, "not on the view that owns the drag")
        #expect(hold.debugTarget === dial.debugStrip, "something other than the strip grows")

        hold.press()
        try #require(hold.scale == PressFeedback.Metrics.heldScale,
                     "guard: nothing grew — is Reduce Motion on on this simulator?")
        dial.debugFingerTravel(-60)

        let expected = 60 / PressFeedback.Metrics.heldScale / StraightenDial.pointsPerDegree
        #expect(abs(dial.angle - expected) < 0.0001, "turned \(dial.angle)°, the tick under the finger is \(expected)°")

        hold.release(asTap: false)
        dial.debugFingerTravel(-60)
        #expect(abs(dial.angle - (expected + 10)) < 0.0001, "released, a drag is the plain arithmetic again")
    }

    @Test func theEffectsRulerGrowsWhileHeldAndItsTickStaysUnderTheFinger() throws {
        let ruler = MediaValueRulerView()
        ruler.frame = CGRect(x: 0, y: 0, width: 300, height: MediaValueRulerView.height)
        ruler.configure(name: "Brightness", range: -1...1, rest: 0, value: 0)
        ruler.layoutIfNeeded()
        let hold = ruler.debugHold
        #expect(hold.style == .hold)
        #expect(hold.debugRecognizer?.view === ruler, "not on the view that owns the drag")
        #expect(hold.debugTarget === ruler.debugStrip, "something other than the strip grows")

        hold.press()
        try #require(hold.scale == PressFeedback.Metrics.heldScale,
                     "guard: nothing grew — is Reduce Motion on on this simulator?")
        ruler.debugBeginDrag()
        ruler.debugFingerTravel(-60)

        let expected = Double(60 / PressFeedback.Metrics.heldScale / ValueRuler.pointsPerPercent) / 100
        #expect(abs(ruler.value - expected) < 0.000001, "moved to \(ruler.value), the tick under the finger is \(expected)")
    }
}
