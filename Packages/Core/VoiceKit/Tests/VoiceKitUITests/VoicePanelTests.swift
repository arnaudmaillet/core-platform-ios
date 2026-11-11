import DesignSystem
import Foundation
import Testing
import UIKit
@testable import VoiceKitUI

/// A colour's components as `style` resolves it, to three decimals — two
/// dynamic colours compare by what they draw, not by identity.
@MainActor
func rgba(_ color: UIColor?, _ style: UIUserInterfaceStyle) -> [CGFloat] {
    guard let color else { return [] }
    let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha].map { ($0 * 1000).rounded() / 1000 }
}

/// The voice component as a neutral panel (#2241): a bare play glyph
/// (#2274), the waveform across the whole width, one slot at the end for the
/// timer or the speed; the panel fills its container at each size — capped
/// in a conversation — and is one width whatever the length; its ground and
/// inks are the host's, never the brand's.
@MainActor
struct VoicePanelTests {
    /// A voice `width` wide at its own height, laid out.
    private func laidOut(
        _ size: VoiceView.Size, width: CGFloat, duration: TimeInterval = 2, levels: [UInt8]? = VoiceView.genericLevels,
        leadingInset: CGFloat = 0, cap: CGFloat? = nil, role: VoiceView.Role = .post(author: nil),
        playback: VoiceView.State.Playback = .rest
    ) -> VoiceView {
        let view = VoiceView(size: size, leadingInset: leadingInset, maxPanelWidth: cap)
        view.role = role
        view.configure(VoiceView.State(levels: levels, duration: duration, playback: playback))
        let height = view.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - The panel fills its container

    @Test(arguments: [VoiceView.Size.full, .compact], [CGFloat(240), 320, 390])
    func thePanelFillsItsContainer(_ size: VoiceView.Size, width: CGFloat) {
        let view = laidOut(size, width: width)
        let panel = view.debugPanelFrame
        #expect(panel.minX == 0 && abs(panel.width - width) < 0.5, "\(panel) in \(width)")
        #expect(panel.height == VoiceView.panelHeight(for: size))
        #expect(view.debugPanelCornerRadius == VoiceView.panelCornerRadius(for: size))
    }

    /// Compact is a little shorter than full: a smaller glyph, shorter bars;
    /// the panel's height stays 56 / 44 pt (#2274).
    @Test func compactIsALittleShorter() {
        #expect(VoiceView.panelHeight(for: .compact) < VoiceView.panelHeight(for: .full))
        #expect(VoiceView.panelHeight(for: .full) == 56 && VoiceView.panelHeight(for: .compact) == 44)
        #expect(VoiceView.buttonSide(for: .full) == 40 && VoiceView.buttonSide(for: .compact) == 32)
        #expect(VoiceView.glyphPointSize(for: .full) == 20 && VoiceView.glyphPointSize(for: .compact) == 16)
        #expect(VoiceView.waveformHeight(for: .full) >= 30 && VoiceView.waveformHeight(for: .full) <= 36)
        #expect(VoiceView.waveformHeight(for: .compact) < VoiceView.waveformHeight(for: .full))
    }

    /// In a conversation the panel starts at the text column and stops at
    /// the cap; in a narrower column it takes the column.
    @Test func aConversationsPanelIsCapped() {
        let cap = VoiceView.conversationMaxWidth
        let wide = laidOut(.full, width: 900, leadingInset: 44, cap: cap, role: .message)
        #expect(wide.debugPanelFrame.minX == 44)
        #expect(abs(wide.debugPanelFrame.width - cap) < 0.5, "\(wide.debugPanelFrame)")
        let narrow = laidOut(.full, width: 300, leadingInset: 44, cap: cap, role: .message)
        #expect(abs(narrow.debugPanelFrame.width - 256) < 0.5, "\(narrow.debugPanelFrame)")
    }

    /// "Its width says its length" is gone: a 2 s voice and a 50 s one draw
    /// the same panel and the same number of bars.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func oneWidthWhateverTheLength(_ size: VoiceView.Size) {
        let short = laidOut(size, width: 340, duration: 2)
        let long = laidOut(size, width: 340, duration: 50)
        #expect(short.debugPanelFrame == long.debugPanelFrame)
        #expect(short.waveform.bars.count == long.waveform.bars.count)
        #expect(short.debugTimerText == "0:02" && long.debugTimerText == "0:50")
    }

    // MARK: - The waveform across the width

    /// The bars run from the glyph to the slot (#2274), as many as the width
    /// holds (2 pt bars, 2 pt apart), spread edge to edge.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func theWaveformRunsFromTheGlyphToTheSlot(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 360)
        let button = view.debugPlayButton.convert(view.debugPlayButton.bounds, to: view)
        let bars = view.debugWaveformFrame
        let slot = view.debugSlotFrame
        #expect(abs(bars.minX - (button.maxX + Spacing.sm)) < 0.5, "\(bars) after \(button)")
        #expect(abs(bars.maxX - (slot.minX - Spacing.sm)) < 0.5, "\(bars) before \(slot)")
        #expect(bars.height == VoiceView.waveformHeight(for: size))
        #expect(view.waveform.bars.count == VoiceView.barCount(forWidth: bars.width))
        let drawn = view.waveform.barStep * CGFloat(view.waveform.bars.count - 1) + VoiceView.barWidth
        #expect(abs(drawn - bars.width) < 0.5, "the bars stop short of the timer")
        #expect(view.waveform.barStep >= VoiceView.barWidth + VoiceView.barGap - 0.01)
    }

    /// A wider panel holds more bars: the count follows the width.
    @Test func theBarCountFollowsTheWidth() {
        #expect(VoiceView.barCount(forWidth: 180) == 45)
        let narrow = laidOut(.full, width: 280)
        let wide = laidOut(.full, width: 600)
        #expect(wide.waveform.bars.count > narrow.waveform.bars.count)
        #expect(wide.waveform.bars.count > 100, "a wide panel holds more bars than the voice's 100 levels")
    }

    /// More bars than levels reads between them — no flat blocks; fewer
    /// keeps each bin's peak.
    @Test func moreBarsThanLevelsAreInterpolated() {
        #expect(VoiceView.rebin([0, 31], to: 5) == [0, 8, 16, 23, 31])
        let levels: [UInt8] = (0..<100).map { UInt8($0 % 2 == 0 ? 4 : 28) }
        let bars = VoiceView.rebin(levels, to: 150)
        #expect(bars.count == 150)
        #expect(bars.first == 4 && bars.last == 28)
        // Repeating each level would draw runs of two equal bars; read
        // between them, neighbours differ all the way.
        let runs = zip(bars, bars.dropFirst()).filter { $0 == $1 }.count
        #expect(runs < 10, "\(runs) equal neighbours: stretched, not interpolated")
        var peaks = [UInt8](repeating: 3, count: 100)
        peaks[2] = 31
        #expect(VoiceView.rebin(peaks, to: 45).filter { $0 == 31 }.count == 1, "a bin's peak was lost")
    }

    /// The mock's flattest voice — a synthesised take whose levels barely
    /// leave the top — still draws a shape: its bars spread over most of the
    /// height, where their raw levels would stand within a third of it.
    @Test func aFlatSoundingVoiceStillHasAShape() {
        let digits = Array("0123456789abcdefghijklmnopqrstuv")
        let wire = "vvttsvqtvuupsrtpqrqsspssvurspssnsprnprvutsrtvprvtrvutquvprpssrsququrrlurqorrrrqrutsptuoprsoqotuuuptr"
        let levels = wire.compactMap { character in digits.firstIndex(of: character).map(UInt8.init) }
        #expect(levels.count == 100)
        let bars = VoiceView.rebin(levels, to: 60)
        let raw = bars.map { CGFloat($0) / 31 }
        let shares = VoiceView.drawnShares(of: bars)
        let rawSpread = (raw.max() ?? 0) - (raw.min() ?? 0)
        let drawnSpread = (shares.max() ?? 0) - (shares.min() ?? 0)
        #expect(rawSpread < 0.35)
        #expect(drawnSpread > 0.6, "the flat voice still draws an even row (\(drawnSpread))")
        #expect(Set(shares.map { ($0 * 20).rounded() }).count >= 6, "too few heights to read as a voice")
    }

    /// A pause stays the minimum bar; a voiced bar never falls to it; a
    /// voice of one level stands full.
    @Test func pausesAndSteadyVoices() {
        let shares = VoiceView.drawnShares(of: [0, 1, 31, 0])
        #expect(shares[0] == 0 && shares[3] == 0)
        #expect(shares[1] >= VoiceView.quietShare)
        #expect(shares[2] == 1)
        #expect(VoiceView.drawnShares(of: [UInt8](repeating: 14, count: 20)).allSatisfy { $0 == 1 })
        #expect(VoiceView.drawnShares(of: [0, 0]) == [0, 0])
    }

    /// The voice panel spreads the contrast; the mark keeps the raw levels.
    @Test func onlyThePanelSpreadsTheContrast() {
        let view = laidOut(.full, width: 320)
        #expect(view.waveform.fillsWidth && view.waveform.spreadsLevels)
        let mark = WaveformBars()
        #expect(!mark.fillsWidth && !mark.spreadsLevels)
    }

    // MARK: - The bare play glyph (#2274)

    /// No disc: the app's icon button as a bare glyph, in the played bars'
    /// ink, 20 pt in full and 16 pt compact, centred where the disc was —
    /// its frame the disc's, the panel's air even round it.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func thePlayButtonHasNoDisc(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 320)
        #expect(view.debugPlayButtonIsABareGlyph, "the play button still draws a ground")
        let side = VoiceView.buttonSide(for: size)
        #expect(view.debugButtonSize == CGSize(width: side, height: side))
        #expect(view.debugGlyphPointSize == VoiceView.glyphPointSize(for: size))
        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(rgba(view.debugGlyphInk, style) == rgba(view.inks.played, style), "the glyph isn't the played bars' ink")
        }
        #expect(view.debugGlyph == AppSymbol.play.rawValue)
        // The owner's play (#2276) resolves: the button draws it.
        #expect(view.debugButtonImage?.isSymbolImage == true)
        let button = view.debugPlayButton.convert(view.debugPlayButton.bounds, to: view)
        let panel = view.debugPanelFrame
        #expect(abs((button.minY - panel.minY) - (panel.maxY - button.maxY)) < 0.5, "\(button) in \(panel)")
        // A host's ink reaches the glyph.
        view.inks = VoiceView.Inks(played: .white, unplayed: .gray, timer: .lightGray)
        #expect(rgba(view.debugGlyphInk, .light) == [1, 1, 1, 1])
    }

    // MARK: - The line, centred (#2274)

    /// The line stands in the middle of the panel: at the panel's own height
    /// the panel's air above and below; held shorter by a host, the air
    /// shrinks evenly — never on one side only.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func theLineIsCentredEvenWhenTheHostIsShorter(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 320)
        let padding = VoiceView.panelPadding(for: size)
        func air() -> (above: CGFloat, below: CGFloat) {
            let line = view.debugLineFrame, panel = view.debugPanelFrame
            return (line.minY - panel.minY, panel.maxY - line.maxY)
        }
        let natural = air()
        #expect(abs(natural.above - padding) < 0.5 && abs(natural.below - padding) < 0.5, "\(natural)")
        view.frame.size.height = VoiceView.panelHeight(for: size) - 5
        view.layoutIfNeeded()
        let squeezed = air()
        #expect(abs(squeezed.above - squeezed.below) < 0.5, "\(squeezed): the air went on one side")
        #expect(view.debugLineFrame.height == VoiceView.buttonSide(for: size), "the line itself gave way")
    }

    // MARK: - Neutral inks

    /// The panel's ground is the host's ink at a low opacity: a grey, in
    /// both appearances, nowhere the brand's tint; the dot is the label's.
    @Test func thePanelIsNeutral() {
        let view = laidOut(.full, width: 320, role: .message)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let ground = rgba(view.debugPanelFill, style)
            #expect(ground.count == 4 && ground[0] == ground[1] && ground[1] == ground[2], "\(ground) is not a grey")
            #expect(ground != rgba(Palette.tint, style))
            let opacity = style == .dark ? VoiceView.Inks.panelOpacityDark : VoiceView.Inks.panelOpacityLight
            #expect(abs(ground[3] - opacity) < 0.002)
            #expect(rgba(view.debugDotFill, style) == rgba(UIColor.label, style))
            #expect(rgba(view.debugDotFill, style) != rgba(Palette.tint, style), "the unplayed dot is the brand's")
        }
    }

    /// The inks on each ground the component is drawn on: a plain row and a
    /// card (the standard inks, light and dark), the dark page (the standard
    /// inks resolved dark), the map's glass (its own label-based inks).
    @Test func theInksFollowEachGround() {
        let standard = VoiceView.Inks.standard
        // Plain and card, light: a dark grey on black-derived ground.
        #expect(rgba(standard.panel, .light) == rgba(UIColor(white: 0, alpha: VoiceView.Inks.panelOpacityLight), .light))
        // Dark page: white-derived.
        #expect(rgba(standard.panel, .dark) == rgba(UIColor(white: 1, alpha: VoiceView.Inks.panelOpacityDark), .dark))
        // Glass: the host's ink, whatever its own opacity, at the panel's.
        let glass = VoiceView.Inks(
            played: UIColor.label.withAlphaComponent(0.8), unplayed: UIColor.label.withAlphaComponent(0.28),
            timer: .secondaryLabel
        )
        #expect(rgba(glass.panel, .light) == rgba(standard.panel, .light))
        // A host ink that is not the label's: its own hue, never the brand's.
        let white = VoiceView.Inks(played: .white, unplayed: .lightGray, timer: .white)
        #expect(rgba(white.panel, .light) == rgba(UIColor(white: 1, alpha: VoiceView.Inks.panelOpacityLight), .light))
    }

    // MARK: - States

    /// Idle, playing, paused mid-way, loading its levels, failed, unplayed:
    /// the panel keeps its height and width in every one — playing never
    /// re-lays a list.
    @Test func everyStateKeepsThePanel() {
        let playbacks: [VoiceView.State.Playback] = [
            .rest, .loading, .playing(progress: 0.4), .paused(progress: 0.6), .failed,
        ]
        let frames = playbacks.map { laidOut(.full, width: 340, role: .message, playback: $0).debugPanelFrame }
        #expect(Set(frames.map(\.height)).count == 1, "\(frames)")
        #expect(Set(frames.map(\.width)).count == 1, "\(frames)")
        let waiting = laidOut(.full, width: 340, levels: nil)
        #expect(waiting.waveform.debugWaiting, "no levels yet draws the flat row")
        #expect(waiting.debugPanelFrame.height == frames[0].height)
    }

    // MARK: - One slot (#2274)

    /// What the slot shows: the total at rest, the chip while it plays (and
    /// from the tap, while it loads), the time reached when paused mid-way,
    /// the total again at the end.
    @Test(arguments: [VoiceView.Role.message, .post(author: "Ava")])
    func theSlotFollowsThePlayback(_ role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 340, duration: 12, role: role)
        #expect(view.debugShowsTimer && !view.debugShowsChip && view.debugTimerText == "0:12")
        #expect(view.debugTimerAlpha == 1 && view.debugChipAlpha == 0)

        state.playback = .loading
        view.update(state)
        #expect(view.debugShowsChip, "the glyph and the slot change together, on the tap")

        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(view.debugShowsChip && !view.debugShowsTimer)
        #expect(view.debugChipTitle == "1.5×")
        #expect(view.debugTimerAlpha == 0 && view.debugChipAlpha == 1)

        state.playback = .paused(progress: 7.0 / 12)
        view.update(state)
        #expect(view.debugShowsTimer && !view.debugShowsChip)
        #expect(view.debugTimerText == "0:07", "paused, the time it resumes from")

        state.playback = .rest
        view.update(state)
        #expect(view.debugShowsTimer && view.debugTimerText == "0:12", "the end shows the total again")
        #expect(VoiceView.slotContent(for: .failed) == .timer)
    }

    /// One slot, one size, whatever it shows: the waveform's frame and its
    /// bars never change between states — binned once — and the chip's pill
    /// fills the slot, the timer centred in it.
    @Test(arguments: [VoiceView.Size.full, .compact], [VoiceView.Role.message, .post(author: nil)])
    func theSlotAndTheWaveformNeverMove(_ size: VoiceView.Size, role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12, unplayed: role == .message)
        let view = laidOut(size, width: 340, duration: 12, role: role)
        view.configure(state)
        view.layoutIfNeeded()
        let slot = view.debugSlotFrame
        let bars = view.debugWaveformFrame
        let count = view.waveform.bars.count
        #expect(slot.width > 0 && slot.height > 0)
        #expect(abs(view.debugTimerFrame.midX - slot.midX) < 0.5, "the timer isn't centred in the slot")
        let playbacks: [VoiceView.State.Playback] = [.loading, .playing(progress: 0.3), .paused(progress: 0.6), .rest, .failed]
        for (index, playback) in playbacks.enumerated() {
            state.playback = playback
            state.speedLabel = ["1×", "1.5×", "2×"][index % 3]
            view.update(state)
            view.layoutIfNeeded()
            #expect(view.debugSlotFrame == slot, "\(playback): the slot moved")
            #expect(view.debugWaveformFrame == bars, "\(playback): the waveform moved")
            #expect(view.waveform.bars.count == count, "\(playback): the bars were re-binned")
            if view.debugShowsChip {
                #expect(view.debugChipFrame == slot, "the chip's pill doesn't fill the slot")
            }
        }
        // A message's unplayed dot keeps its own place after the slot.
        if role == .message {
            #expect(slot.maxX < view.debugPanelFrame.maxX - VoiceView.panelTrailingPadding - VoiceView.dotSide)
        } else {
            #expect(abs(slot.maxX - (view.debugPanelFrame.maxX - VoiceView.panelTrailingPadding)) < 0.5)
        }
    }

    /// The slot holds the widest timer the voice can show — its total
    /// length's format — and the widest speed: never narrower than either.
    @Test(arguments: [TimeInterval(12), 65, 760])
    func theSlotHoldsTheWidestTimerAndSpeed(_ duration: TimeInterval) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: duration)
        let view = laidOut(.full, width: 340, duration: duration)
        let slot = view.debugSlotFrame
        #expect(view.debugTimerFrame.width <= slot.width + 0.5)
        state.playback = .playing(progress: 0.5)
        state.speedLabel = VoiceView.widestSpeedLabel
        view.update(state)
        view.debugSetSpeedLabel(VoiceView.widestSpeedLabel)
        #expect(view.debugSlotFrame == slot)
        #expect(view.debugChipFrame == slot)
    }

    /// The change is a cross-fade in place on screen; under Reduce Motion, a
    /// cut.
    @Test(arguments: [false, true])
    func theSlotCrossFadesOrCuts(_ reduced: Bool) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 340, duration: 12)
        view.reducesMotion = { reduced }
        window.addSubview(view)
        state.playback = .playing(progress: 0.2)
        view.update(state)
        #expect(view.debugShowsChip)
        #expect(view.debugTimerAlpha == 0 && view.debugChipAlpha == 1)
        #expect(view.debugSlotIsFading == !reduced, reduced ? "Reduce Motion faded the slot" : "the slot cut")
        view.removeFromSuperview()
    }

    // MARK: - The whole panel swells (#2274)

    /// A finger on the waveform swells the whole panel by the app's press
    /// swell on its size — and nothing inside it on its own; it settles when
    /// the finger lifts, and when it is cancelled.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func aFingerOnTheWaveformSwellsTheWholePanel(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 320, playback: .playing(progress: 0.3))
        view.reducesMotion = { false }
        let resting = view.debugPanelRestingSize
        let scale = PressFeedback.swelledScale(for: resting)
        #expect(scale.x > 1 && scale.y > 1)
        view.waveform.debugFinger(true)
        #expect(view.debugPanelTransform == CGAffineTransform(scaleX: scale.x, y: scale.y))
        #expect(view.debugPartTransforms.allSatisfy { $0 == .identity }, "a part swelled on its own")
        #expect(view.debugPanelRestingSize == resting, "the swell re-laid the panel")
        // Lifted: it settles.
        view.waveform.debugFinger(false)
        #expect(view.debugPanelTransform == .identity)
        // A scrub keeps it swollen past the touch's cancel (the drag took
        // the touch), until the drag ends.
        view.waveform.debugFinger(true)
        view.waveform.onSeek?(0.5, true)
        view.waveform.debugFinger(false)
        #expect(view.debugPanelTransform != .identity, "the scrub's own cancel settled it")
        view.waveform.onSeek?(0.6, false)
        #expect(view.debugPanelTransform == .identity)
    }

    /// The play glyph keeps its own press: the panel swells only for the
    /// waveform.
    @Test func thePlayButtonDoesNotSwellThePanel() {
        let view = laidOut(.full, width: 320)
        view.reducesMotion = { false }
        view.debugTapPlay()
        #expect(view.debugPanelTransform == .identity)
    }

    /// The point under the finger doesn't jump: the seek is read on the
    /// panel at rest, so the swell never moves the playhead.
    @Test func theSwellNeverMovesThePlayhead() {
        let view = laidOut(.full, width: 320)
        view.reducesMotion = { false }
        let bars = view.debugWaveformFrame
        let point = CGPoint(x: bars.minX + bars.width * 0.3, y: bars.midY)
        let before = view.debugSeekFraction(at: point)
        #expect(abs(before - 0.3) < 0.01)
        view.waveform.debugFinger(true)
        #expect(view.debugWaveformFrame != bars, "guard: the bars didn't swell with the panel")
        #expect(view.debugSeekFraction(at: point) == before, "the swell moved the playhead")
        view.waveform.debugFinger(false)
    }

    /// Under Reduce Motion the panel never swells, as for the app's buttons.
    @Test func reduceMotionSwellsNothing() {
        let view = laidOut(.full, width: 320)
        view.reducesMotion = { true }
        view.waveform.debugFinger(true)
        view.waveform.onSeek?(0.4, true)
        #expect(view.debugPanelTransform == .identity)
        view.waveform.onSeek?(0.4, false)
        view.waveform.debugFinger(false)
    }

    // MARK: - No brand colour, no length's width

    /// No brand token anywhere in the component's sources (#2241).
    @Test func noBrandColourInTheComponent() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoiceKitUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // VoiceKit
            .appending(path: "Sources/VoiceKitUI")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "guard: the component's sources weren't found")
        let tokens = ["Palette.", "BrandTheme", "AccentColor", "brandGradient"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in tokens {
                #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token)")
            }
        }
    }

    /// "Its width says its length" is gone everywhere: no source asks for a
    /// width from a duration.
    @Test func noWidthFromALengthLeft() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoiceKitUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // VoiceKit
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let needle = "width(for" + "Duration"
        var found: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                let path = file.path
                guard file.pathExtension == "swift", !path.contains("/.build/") else { continue }
                if (try? String(contentsOf: file, encoding: .utf8))?.contains(needle) == true {
                    found.append(file.lastPathComponent)
                }
            }
        }
        #expect(found.isEmpty, "\(found)")
    }

    // MARK: - VoiceOver

    /// At rest the panel reads as one element — its parts are not elements —
    /// with its label, its time and speed as its value, its ±5 s adjustment
    /// and its play action; the speed changes only while it plays (#2274).
    @Test func voiceOverReadsThePanelAsOne() {
        let view = laidOut(.full, width: 320, duration: 12, role: .message)
        #expect(view.isAccessibilityElement)
        #expect(view.debugAccessibilityElements == nil)
        #expect(!view.debugPlayButton.isAccessibilityElement)
        #expect(view.accessibilityLabel == "Your voice message, 12 seconds, played")
        #expect(view.accessibilityValue == "0:12, speed 1×")
        #expect(view.accessibilityTraits.contains(.adjustable))
        let actions = view.accessibilityCustomActions?.map(\.name) ?? []
        #expect(actions.contains("Play") && !actions.contains { $0.hasPrefix("Speed") })
    }

    /// While it plays, the voice says its time and speed, and the speed chip
    /// stands as its own element beside it (#2274).
    @Test func voiceOverReadsTheChipAsItsOwnWhileItShows() {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 320, duration: 12, role: .post(author: "Ava"))
        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(!view.isAccessibilityElement)
        #expect(view.debugAccessibilityElements?.count == 2)
        #expect(view.debugPlayElementValue == "0:06, speed 1.5×")
        #expect(view.accessibilityCustomActions?.map(\.name).contains("Speed 1.5×") == true)
        state.playback = .paused(progress: 0.5)
        view.update(state)
        #expect(view.isAccessibilityElement && view.debugAccessibilityElements == nil)
        #expect(view.accessibilityValue == "0:06, speed 1.5×")
    }
}
