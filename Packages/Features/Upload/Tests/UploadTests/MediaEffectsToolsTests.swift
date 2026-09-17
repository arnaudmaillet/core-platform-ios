import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// The Effects tools on their own: what they draw, say and announce.
@MainActor
struct MediaEffectsToolsTests {
    private func tools() -> MediaEffectsToolsView {
        let tools = MediaEffectsToolsView()
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaEffectsToolsView.height)
        tools.layoutIfNeeded()
        return tools
    }

    /// ⚠️ **A SYMBOL THAT DOES NOT EXIST IS AN EMPTY CARD, NOT AN ERROR** —
    /// asked of the runtime, which is the one instrument that cannot be wrong.
    @Test func everyEffectsGlyphExists() {
        let missing = MediaEffectsCatalog.glyphs.filter { UIImage(systemName: $0) == nil }
        #expect(missing.isEmpty, "no such symbols: \(missing)")
        #expect(MediaEffectsCatalog.glyphs.count == 11, "close, none and the nine dials")
    }

    /// One effect at a time: choosing one un-rings the one before, and "None"
    /// is ringed exactly when nothing is chosen.
    @Test func effectsAreExclusive() {
        let tools = tools()
        var told: [LookEffect?] = []
        tools.onEffect = { effect, _ in told.append(effect) }
        #expect(tools.debugRingedEffects == [nil], "guard: None is ringed at rest")

        tools.debugTapEffect(.blur)
        #expect(tools.debugRingedEffects == [.blur])
        tools.debugTapEffect(.vhs)
        #expect(tools.debugRingedEffects == [.vhs], "the blur card let go")
        tools.debugTapNone()
        #expect(tools.debugRingedEffects == [nil])

        #expect(told == [
            LookEffect(kind: .blur, intensity: 1),
            LookEffect(kind: .vhs, intensity: 1),
            nil
        ])
    }

    /// A tap on an effect opens its strength; moving it announces the effect
    /// at that strength, and zero announces no effect at all.
    @Test func anEffectsSliderSetsItsStrength() {
        let tools = tools()
        var told: [LookEffect?] = []
        tools.onEffect = { effect, _ in told.append(effect) }

        tools.debugTapEffect(.bloom)
        #expect(tools.debugShowsSlider)
        let slider = tools.debugSlider.debugSlider
        slider.value = 0.25
        slider.sendActions(for: .valueChanged)
        slider.value = 0
        slider.sendActions(for: .valueChanged)

        #expect(told == [LookEffect(kind: .bloom, intensity: 1), LookEffect(kind: .bloom, intensity: 0.25), nil])
        #expect(tools.debugShowsSlider, "a strength dragged to zero keeps its slider under the finger")
    }

    @Test func sliderSpeaksItsValue() {
        let row = MediaValueSliderRow()
        row.configure(title: "Brightness", closeLabel: "Close Brightness", range: -1...1, value: 0.23)
        #expect(row.debugSlider.accessibilityValue == "plus 23")
        #expect(row.debugValueText == "+23")

        row.show(-0.4)
        #expect(row.debugSlider.accessibilityValue == "minus 40")
        #expect(row.debugValueText == "−40")

        row.configure(title: "Grain", closeLabel: "Close Grain", range: 0...1, value: 0.5)
        #expect(row.debugSlider.accessibilityValue == "50", "a one-sided dial carries no sign")
        #expect(row.debugSlider.accessibilityLabel == "Grain")
        #expect(row.debugSlider.accessibilityCustomActions?.map(\.name) == ["Reset"])
    }

    /// The zero tick: arriving at zero or passing through it ticks once;
    /// moving on either side of it does not. The double tap resets to exactly
    /// zero and says so.
    @Test func zeroTicksAndTheDoubleTapResets() {
        let row = MediaValueSliderRow()
        row.configure(title: "Warmth", closeLabel: "Close Warmth", range: -1...1, value: 0)
        var told: [Double] = []
        row.onChange = { value, _ in told.append(value) }
        let slider = row.debugSlider

        for value: Float in [0.2, 0.3, -0.1, -0.2] {
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
        #expect(row.neutralTicks == 1, "one crossing, from +0.3 to -0.1")

        row.debugDoubleTapValue()
        #expect(row.value == 0)
        #expect(told.last == 0)
        #expect(row.neutralTicks == 2)
        #expect(slider.value == 0)
    }

    /// A turned dial wears its dot; one at rest does not.
    @Test func aTurnedDialWearsADot() {
        let tools = tools()
        var look = FrameLook.neutral
        look.adjustments.contrast = -0.3
        tools.show(look)

        #expect(tools.debugDialIsMarked(.contrast))
        #expect(!tools.debugDialIsMarked(.brightness))
        #expect(tools.debugDialCard(.contrast)?.accessibilityValue == "minus 30")
    }
}
