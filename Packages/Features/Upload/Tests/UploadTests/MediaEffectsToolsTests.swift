import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// The Effects tools on their own: what they draw, say and announce.
@MainActor
struct MediaEffectsToolsTests {
    private func tools() -> (tools: MediaEffectsToolsView, window: UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let tools = MediaEffectsToolsView()
        tools.frame = CGRect(x: 0, y: 600, width: 390, height: MediaEffectsToolsView.height)
        window.addSubview(tools)
        window.isHidden = false
        tools.layoutIfNeeded()
        return (tools, window)
    }

    /// ⚠️ **A SYMBOL THAT DOES NOT EXIST IS AN EMPTY PILL, NOT AN ERROR** —
    /// asked of the runtime, which is the one instrument that cannot be wrong.
    @Test func everyEffectsGlyphExists() {
        let missing = MediaEffectsCatalog.glyphs.filter { UIImage(systemName: $0) == nil }
        #expect(missing.isEmpty, "no such symbols: \(missing)")
        #expect(MediaEffectsCatalog.glyphs.count == 10, "none and the nine dials")
    }

    // MARK: - The layout

    /// ⚠️ **THE REQUEST, AS WORDS:** "don't hide the row of options; show a
    /// graduated ruler above it, laid out like crop." So the ruler comes in
    /// above the row, the row stays and still takes a tap, and the band is the
    /// crop tools' height.
    @Test func theRulerComesInAboveTheRowAndTheRowStays() {
        let (tools, window) = tools()
        _ = window
        #expect(!tools.debugShowsRuler, "guard: no ruler before a pill is chosen")
        #expect(tools.debugShowsRow)

        tools.debugTapDial(.contrast)
        tools.layoutIfNeeded()

        #expect(tools.debugShowsRuler)
        #expect(tools.debugShowsRow, "the row was put away for the ruler")
        let ruler = tools.debugRulerFrame, row = tools.debugRowFrame
        #expect(ruler.height > 0 && row.height > 0)
        #expect(ruler.maxY <= row.minY, "the ruler is not above the row: \(ruler) vs \(row)")
        #expect(ruler.minY >= 0 && row.maxY <= tools.bounds.height, "a part runs out of the band")
        #expect(MediaEffectsToolsView.height == MediaCropToolsView.height, "not the crop tools' layout")

        tools.debugTapDial(.saturation)
        #expect(tools.debugShowsRuler, "the next dial is one tap away")
        #expect(tools.debugFocusedPills == ["Saturation"])
        #expect(tools.debugRuler.accessibilityLabel == "Saturation")
    }

    /// A tap on the pill whose ruler is up puts the ruler away — the only
    /// way to, now that there is no close button.
    @Test func aSecondTapPutsTheRulerAway() {
        let (tools, window) = tools()
        _ = window
        tools.debugTapDial(.warmth)
        #expect(tools.debugShowsRuler, "guard")

        tools.debugTapDial(.warmth)

        #expect(!tools.debugShowsRuler)
        #expect(tools.focus == .browsing)
        #expect(tools.debugFocusedPills.isEmpty)
        #expect(tools.debugShowsRow)
    }

    /// `[icon label]` side by side at rest; `[label number]` once turned, the
    /// number standing where the symbol was not.
    @Test func aPillIsARowNotAStack() throws {
        let (tools, window) = tools()
        _ = window
        let rest = try #require(tools.debugParts(.brightness))
        let icon = try #require(rest.icon, "the symbol is missing at rest")
        #expect(rest.reading == nil)
        #expect(icon.maxX <= rest.caption.minX, "the symbol is not before the word: \(icon) \(rest.caption)")
        #expect(abs(icon.midY - rest.caption.midY) < 1, "the two are not on one line")
        #expect(tools.debugPillSize(.brightness)?.height == 30)

        var look = FrameLook.neutral
        look.adjustments.brightness = 0.2
        tools.show(look)
        tools.layoutIfNeeded()

        let turned = try #require(tools.debugParts(.brightness))
        #expect(turned.icon == nil, "the symbol stayed beside the number")
        let reading = try #require(turned.reading, "no number on a turned pill")
        #expect(turned.caption.maxX <= reading.minX, "the number is not after the word")
        #expect(abs(turned.caption.midY - reading.midY) < 1)
        #expect(tools.debugReading(.brightness) == "+20%")
    }

    /// ⚠️ **A PILL ALREADY IN VIEW DOES NOT MOVE THE ROW.** Revealing it with
    /// `scrollRectToVisible` and a margin slides the row whenever the pill sits
    /// closer to an edge than that margin — under the finger that had just
    /// aimed at it, and measured on an SE as the whole row stepping sideways.
    @Test func choosingAPillInViewLeavesTheRowWhereItIs() throws {
        let (tools, window) = tools()
        _ = window
        tools.layoutIfNeeded()
        let pill = try #require(tools.debugPillFrame(.brightness))
        // Scrolled so the pill is whole and eight points inside the trailing
        // edge — visible, and nearer the edge than the margin a reveal adds.
        tools.debugRowOffset = pill.maxX + 8 - tools.debugRowWindow
        let before = tools.debugRowOffset

        tools.debugTapDial(.brightness)
        tools.layoutIfNeeded()

        // ⚠️ THE DECISION, NOT THE OFFSET: the scroll is animated, so the
        // offset it would land on is not there to read in the same turn.
        #expect(tools.debugRevealed == nil, "the row was scrolled to \(String(describing: tools.debugRevealed))")
        #expect(tools.debugRowOffset == before)

        // And a pill off the end is still brought in.
        tools.debugRowOffset = 0
        tools.debugTapDial(.grain)
        #expect(tools.debugRevealed != nil, "the last dial was left off the row")
    }

    // MARK: - Effects

    /// One effect at a time: choosing one lets the one before go, and "None"
    /// can be tapped exactly while something is on.
    @Test func effectsAreExclusive() {
        let (tools, window) = tools()
        _ = window
        var told: [LookEffect?] = []
        tools.onEffect = { effect, _ in told.append(effect) }
        #expect(tools.debugChosenEffects.isEmpty)
        #expect(!tools.debugNoneIsEnabled, "guard: nothing to take away at rest")

        tools.debugTapEffect(.blur)
        #expect(tools.debugChosenEffects == [.blur])
        #expect(tools.debugNoneIsEnabled)
        #expect(tools.debugReading(.blur) == "100%")
        tools.debugTapEffect(.vhs)
        #expect(tools.debugChosenEffects == [.vhs], "the blur pill let go")
        #expect(tools.debugReading(.blur) == nil, "the blur pill kept its number")
        tools.debugTapNone()
        #expect(tools.debugChosenEffects.isEmpty)
        #expect(!tools.debugShowsRuler, "the ruler of an effect that is gone stayed up")
        #expect(!tools.debugNoneIsEnabled)

        #expect(told == [
            LookEffect(kind: .blur, intensity: 1),
            LookEffect(kind: .vhs, intensity: 1),
            nil
        ])
    }

    /// A tap on an effect brings up its strength; moving it announces the
    /// effect at that strength, and zero announces no effect at all.
    @Test func anEffectsRulerSetsItsStrength() {
        let (tools, window) = tools()
        _ = window
        var told: [LookEffect?] = []
        tools.onEffect = { effect, _ in told.append(effect) }

        tools.debugTapEffect(.bloom)
        #expect(tools.debugShowsRuler)
        #expect(tools.debugRuler.value == 1)
        tools.debugRuler.debugSet(0.25)
        #expect(tools.debugReading(.bloom) == "25%")
        tools.debugRuler.debugSet(0)

        #expect(told == [LookEffect(kind: .bloom, intensity: 1), LookEffect(kind: .bloom, intensity: 0.25), nil])
        #expect(tools.debugShowsRuler, "a strength dragged to zero keeps its ruler under the finger")
    }

    /// ⚠️ **A TAP ON THE CHOSEN EFFECT IS NOT A RE-CHOICE** — it would put the
    /// strength back to full under a finger that only wanted the ruler.
    @Test func aChosenEffectsPillOnlyTogglesItsRuler() {
        let (tools, window) = tools()
        _ = window
        var told: [LookEffect?] = []
        tools.onEffect = { effect, _ in told.append(effect) }
        tools.debugTapEffect(.comic)
        tools.debugRuler.debugSet(0.4)
        tools.debugTapEffect(.comic)
        #expect(!tools.debugShowsRuler)
        tools.debugTapEffect(.comic)

        #expect(tools.debugShowsRuler)
        #expect(tools.debugRuler.value == 0.4)
        #expect(told.count == 2, "a tap re-announced the effect: \(told)")
    }

    // MARK: - The dials

    /// A turned dial shows its number; one at rest shows its symbol, and both
    /// say their value to VoiceOver.
    @Test func aTurnedDialShowsItsNumber() {
        let (tools, window) = tools()
        _ = window
        var look = FrameLook.neutral
        look.adjustments.contrast = -0.3
        tools.show(look)

        #expect(tools.debugReading(.contrast) == "−30%")
        #expect(tools.debugReading(.brightness) == nil)
        #expect(tools.debugDialPill(.contrast)?.accessibilityValue == "minus 30 percent")
        #expect(tools.debugDialPill(.brightness)?.accessibilityValue == "0 percent")
    }

    /// Turning a dial on the ruler announces it and relabels its pill on the
    /// way, not only when the finger lifts.
    @Test func aDragAnnouncesAndRelabelsAsItGoes() {
        let (tools, window) = tools()
        _ = window
        var told: [(Double, Bool)] = []
        var tracking: [Bool] = []
        tools.onDial = { key, value, isTracking in
            #expect(key == .shadows)
            told.append((value, isTracking))
        }
        tools.onTracking = { tracking.append($0) }
        tools.debugTapDial(.shadows)
        let ruler = tools.debugRuler

        ruler.debugBeginDrag()
        ruler.debugDrag(by: -30)
        #expect(tools.debugReading(.shadows) == "+10%", "the pill waited for the lift")
        ruler.debugDrag(by: -1)
        ruler.debugEndDrag()

        #expect(tracking == [true, false])
        #expect(told.map { $0.1 } == [true, true, false])
        #expect(told.last.map { abs($0.0 - 0.10) < 0.0001 } == true, "the lift did not settle on whole percent: \(told)")
    }

    // MARK: - The ruler on its own

    @Test func theRulerSpeaksItsValue() {
        let ruler = MediaValueRulerView()
        ruler.configure(name: "Brightness", range: -1...1, rest: 0, value: 0.23)
        #expect(ruler.accessibilityValue == "plus 23 percent")
        #expect(ruler.debugReading == "+23%")
        #expect(ruler.accessibilityTraits.contains(.adjustable))

        ruler.show(-0.4)
        #expect(ruler.accessibilityValue == "minus 40 percent")
        #expect(ruler.debugReading == "−40%")

        ruler.configure(name: "Grain", range: 0...1, rest: 0, value: 0.5)
        #expect(ruler.accessibilityValue == "50 percent", "a one-sided dial carries no sign")
        #expect(ruler.accessibilityLabel == "Grain")
    }

    /// Stating a value is not a change.
    @Test func configuringIsSilent() {
        let ruler = MediaValueRulerView()
        var told = 0
        ruler.onChange = { _, _ in told += 1 }
        ruler.configure(name: "Warmth", range: -1...1, rest: 0, value: 0.5)
        ruler.show(-0.5)
        #expect(told == 0)
        #expect(ruler.clicks == 0)
    }

    /// A click on each tenth reached or passed, none in between; the readout
    /// tap goes back to rest exactly and says so.
    @Test func detentsClickAndTheReadoutResets() {
        let ruler = MediaValueRulerView()
        ruler.configure(name: "Warmth", range: -1...1, rest: 0, value: 0)
        var told: [Double] = []
        ruler.onChange = { value, _ in told.append(value) }

        ruler.debugBeginDrag()
        ruler.debugDrag(by: -9) // +3%
        #expect(ruler.clicks == 0)
        ruler.debugDrag(by: -9) // +6%: nearest tenth is now +10
        #expect(ruler.clicks == 1)
        ruler.debugDrag(by: -9) // +9%
        #expect(ruler.clicks == 1)
        ruler.debugEndDrag()

        ruler.debugTapReadout()
        #expect(ruler.value == 0)
        #expect(told.last == 0)
        #expect(ruler.clicks == 2)

        let before = told.count
        ruler.debugTapReadout()
        #expect(told.count == before, "a tap at rest announced a change")
    }

    /// An effect's ruler rests at full strength, not at zero.
    @Test func theReadoutGoesBackToTheRulersOwnRest() {
        let ruler = MediaValueRulerView()
        ruler.configure(name: "Blur", range: 0...1, rest: 1, value: 0.3)
        ruler.debugTapReadout()
        #expect(ruler.value == 1)
    }

    /// ⚠️ **ASSERTED ON WHAT IS DRAWN.** The needle is the tint and sits in the
    /// middle; the ticks between rest and the needle are tinted too, so a
    /// turned dial reads as a coloured span.
    @Test func theRulerDrawsItsNeedleAndItsSpan() throws {
        let ruler = MediaValueRulerView()
        ruler.tintColor = .systemRed
        ruler.frame = CGRect(x: 0, y: 0, width: 300, height: MediaValueRulerView.height)
        ruler.configure(name: "Brightness", range: -1...1, rest: 0, value: 0)
        ruler.layoutIfNeeded()
        let strip = ruler.debugStrip

        let atRest = try #require(Self.render(strip))
        #expect(Self.redColumns(in: atRest).contains { abs($0 - 150) <= 2 }, "no needle in the middle")
        #expect(!Self.redColumns(in: atRest).contains { $0 < 140 }, "a span drawn at rest")

        ruler.show(0.2) // rest is 60pt to the left of the needle
        let turned = try #require(Self.render(strip))
        let red = Self.redColumns(in: turned)
        #expect(red.contains { abs($0 - 90) <= 2 }, "the rest tick is not tinted: \(red)")
        #expect(red.contains { abs($0 - 120) <= 2 }, "the span between is not tinted")
        #expect(!red.contains { $0 < 80 }, "ticks past rest were tinted")
    }

    // MARK: - Rendering

    private static func render(_ view: UIView) -> UIImage? {
        guard view.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        view.layer.setNeedsDisplay()
        view.layer.displayIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    /// The x of every column holding a clearly red pixel.
    private static func redColumns(in image: UIImage) -> Set<Int> {
        guard let cg = image.cgImage else { return [] }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var columns = Set<Int>()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
                if a > 40, r > g + 40, r > b + 40 { columns.insert(x) }
            }
        }
        return columns
    }
}

/// The ruler's arithmetic.
struct ValueRulerTests {
    /// Dragging right brings smaller values under the needle.
    @Test func theSignIsThePhysicalOne() {
        #expect(abs(ValueRuler.advanced(0, by: 30, in: -1...1) - -0.10) < 1e-9)
        #expect(abs(ValueRuler.advanced(0, by: -30, in: -1...1) - 0.10) < 1e-9)
    }

    /// Clamped at both ends, and advanced from wherever the value is, so a
    /// drag past the end answers at once on the way back.
    @Test func theEndsHoldAndDoNotGoNumb() {
        var value = 0.9
        value = ValueRuler.advanced(value, by: -600, in: -1...1)
        #expect(value == 1)
        value = ValueRuler.advanced(value, by: 3, in: -1...1)
        #expect(abs(value - 0.99) < 1e-9)
        #expect(ValueRuler.advanced(0.1, by: 600, in: 0...1) == 0)
    }

    @Test func detentsAreTenths() {
        #expect(ValueRuler.detentIndex(for: 0.04) == 0)
        #expect(ValueRuler.detentIndex(for: 0.06) == 1)
        #expect(ValueRuler.detentIndex(for: -0.26) == -3)
    }

    /// Whole percentages on the lift, and exactly zero under half a percent.
    @Test func settlingRoundsToWholePercent() {
        #expect(ValueRuler.settled(0.2349) == 0.23)
        #expect(ValueRuler.settled(0.004) == 0)
        #expect(ValueRuler.settled(-0.004) == 0)
        #expect(ValueRuler.settled(-0.456) == -0.46)
    }

    @Test func readings() {
        #expect(ValueRuler.reading(0.23, twoSided: true).written == "+23%")
        #expect(ValueRuler.reading(0.23, twoSided: true).spoken == "plus 23 percent")
        #expect(ValueRuler.reading(-0.4, twoSided: true).written == "−40%")
        #expect(ValueRuler.reading(-0.4, twoSided: true).spoken == "minus 40 percent")
        #expect(ValueRuler.reading(0, twoSided: true).written == "0%")
        #expect(ValueRuler.reading(0.5, twoSided: false).written == "50%")
        #expect(ValueRuler.reading(0.5, twoSided: false).spoken == "50 percent")
    }
}
