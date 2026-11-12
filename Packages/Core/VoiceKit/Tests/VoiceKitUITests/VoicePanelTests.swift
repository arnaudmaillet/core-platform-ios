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
/// (#2274), the waveform across the panel, one slot at the end for the timer
/// or the speed; 44 pt tall and a rounded rectangle at both sizes (#2329);
/// at full size its width says its length — capped in a conversation —
/// compact, it fills its host; its ground and inks are the host's, never
/// the brand's.
@MainActor
struct VoicePanelTests {
    /// A voice `width` wide at its own height, laid out — at `textSize`,
    /// or the app's.
    private func laidOut(
        _ size: VoiceView.Size, width: CGFloat, duration: TimeInterval = 2, levels: [UInt8]? = VoiceView.genericLevels,
        leadingInset: CGFloat = 0, cap: CGFloat? = nil, role: VoiceView.Role = .post(author: nil),
        playback: VoiceView.State.Playback = .rest, textSize: UIContentSizeCategory? = nil
    ) -> VoiceView {
        let view = VoiceView(size: size, leadingInset: leadingInset, maxPanelWidth: cap)
        if let textSize {
            view.traitOverrides.preferredContentSizeCategory = textSize
            view.updateTraitsIfNeeded()
        }
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

    // MARK: - The panel's size and corner (#2329)

    /// At full length (and compact, whatever the length) the panel fills its
    /// container, at its size's height and corner.
    @Test(arguments: [VoiceView.Size.full, .compact], [CGFloat(240), 320, 390])
    func atFullLengthThePanelFillsItsContainer(_ size: VoiceView.Size, width: CGFloat) {
        let view = laidOut(size, width: width, duration: 60)
        let panel = view.debugPanelFrame
        #expect(panel.minX == 0 && abs(panel.width - width) < 0.5, "\(panel) in \(width)")
        #expect(panel.height == VoiceView.panelHeight(for: size))
        #expect(view.debugPanelCornerRadius == VoiceView.panelCornerRadius(for: size))
    }

    /// Both sizes are 44 pt tall (#2329: the glyph's 32 pt frame and 6 pt of
    /// air; 56 pt in full before), the bars 24 pt, the corner the media
    /// tiles' — a rounded rectangle, not a capsule. What still tells them
    /// apart: the glyph (20 / 16 pt) and the width rule.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func bothSizesAre44PointsTallAndRounded(_ size: VoiceView.Size) {
        #expect(VoiceView.panelHeight(for: size) == 44)
        #expect(VoiceView.buttonSide(for: size) == 32)
        #expect(VoiceView.panelPadding(for: size) == 6)
        #expect(VoiceView.waveformHeight(for: size) == 24)
        #expect(VoiceView.panelCornerRadius(for: size) == Surface.mediaCornerRadius)
        #expect(VoiceView.panelCornerRadius(for: size) < VoiceView.panelHeight(for: size) / 2, "a capsule again")
        #expect(VoiceView.glyphPointSize(for: .full) == 20 && VoiceView.glyphPointSize(for: .compact) == 16)
        let view = laidOut(size, width: 320)
        #expect(view.debugPanelFrame.height == 44)
        #expect(view.debugPanelCornerRadius == Surface.mediaCornerRadius)
        #expect(view.debugWaveformFrame.height == 24)
    }

    /// In a conversation the panel starts at the text column and, at full
    /// length, stops at the cap; in a narrower column it takes the column.
    @Test func aConversationsPanelIsCapped() {
        let cap = VoiceView.conversationMaxWidth
        let wide = laidOut(.full, width: 900, duration: 120, leadingInset: 44, cap: cap, role: .message)
        #expect(wide.debugPanelFrame.minX == 44)
        #expect(abs(wide.debugPanelFrame.width - cap) < 0.5, "\(wide.debugPanelFrame)")
        let narrow = laidOut(.full, width: 300, duration: 120, leadingInset: 44, cap: cap, role: .message)
        #expect(abs(narrow.debugPanelFrame.width - 256) < 0.5, "\(narrow.debugPanelFrame)")
        // A short message stands at the narrowest, a mid one between.
        let short = laidOut(.full, width: 900, duration: 1, leadingInset: 44, cap: cap, role: .message)
        #expect(abs(short.debugPanelFrame.width - VoiceView.minimumPanelWidth) < 0.5, "\(short.debugPanelFrame)")
        let mid = laidOut(.full, width: 900, duration: 16, leadingInset: 44, cap: cap, role: .message)
        let expected = VoiceView.minimumPanelWidth + (cap - VoiceView.minimumPanelWidth) / 2
        #expect(abs(mid.debugPanelFrame.width - expected) < 0.5, "\(mid.debugPanelFrame) for \(expected)")
    }

    // MARK: - The width says the length (#2329)

    /// Telegram's rule: the narrowest up to 2 s, the full width from 30 s,
    /// straight between, on whole seconds — and never wider than there is
    /// room for.
    @Test func theWidthForALength() {
        let narrowest = VoiceView.minimumPanelWidth
        #expect(narrowest >= 150 && narrowest <= 170, "the stated minimum: \(narrowest)")
        let full: CGFloat = 360
        for length: TimeInterval in [0, 0.4, 1, 2, 2.9] {
            #expect(VoiceView.panelWidth(forLength: length, available: full) == narrowest, "\(length) s")
        }
        for length: TimeInterval in [30, 30.5, 60, 300] {
            #expect(VoiceView.panelWidth(forLength: length, available: full) == full, "\(length) s")
        }
        // Straight between: each second the same step.
        let step = (full - narrowest) / 28
        for length in 2...30 {
            let width = VoiceView.panelWidth(forLength: TimeInterval(length), available: full)
            #expect(abs(width - (narrowest + step * CGFloat(length - 2))) < 0.001, "\(length) s: \(width)")
        }
        #expect(VoiceView.panelWidth(forLength: 16, available: full) == narrowest + (full - narrowest) / 2)
        // A tenth more, the same whole second: the same width.
        #expect(VoiceView.panelWidth(forLength: 4.37, available: full) == VoiceView.panelWidth(forLength: 4.4, available: full))
        // Capped by the room: under the narrowest, the room itself.
        for length: TimeInterval in [1, 16, 60] {
            #expect(VoiceView.panelWidth(forLength: length, available: 120) == 120, "\(length) s in 120 pt")
            #expect(VoiceView.panelWidth(forLength: length, available: 200) <= 200)
        }
        #expect(VoiceView.panelWidth(forLength: 60, available: 0) == 0)
    }

    /// A full panel's width says its length, leading-aligned, and its bars'
    /// count follows its width: a 1 s voice is a short panel with few bars,
    /// a minute's the whole width.
    @Test func aFullPanelsWidthSaysItsLength() {
        let width: CGFloat = 360
        let lengths: [TimeInterval] = [1, 5, 15, 30, 60]
        let views = lengths.map { laidOut(.full, width: width, duration: $0) }
        for (length, view) in zip(lengths, views) {
            let panel = view.debugPanelFrame
            #expect(panel.minX == 0, "\(length) s: not leading-aligned")
            let expected = VoiceView.panelWidth(forLength: length, available: width)
            #expect(abs(panel.width - expected) < 0.5, "\(length) s: \(panel.width) for \(expected)")
            #expect(view.waveform.bars.count == VoiceView.barCount(forWidth: view.debugWaveformFrame.width))
            #expect(view.debugPanelFrame.height == VoiceView.panelHeight(for: .full))
        }
        let counts = views.map(\.waveform.bars.count)
        #expect(counts == counts.sorted() && counts.first! < counts.last!, "the bars don't follow the width: \(counts)")
        #expect(abs(views[0].debugPanelFrame.width - VoiceView.minimumPanelWidth) < 0.5)
        #expect(views[0].waveform.bars.count >= 10, "the narrowest holds too few bars: \(views[0].waveform.bars.count)")
    }

    /// A voice laid out with another length takes the new one's width — a
    /// reused row never keeps the last voice's.
    @Test func aNewLengthTakesItsWidth() {
        let view = laidOut(.full, width: 360, duration: 60)
        view.configure(VoiceView.State(levels: VoiceView.genericLevels, duration: 1))
        view.layoutIfNeeded()
        #expect(abs(view.debugPanelFrame.width - VoiceView.minimumPanelWidth) < 0.5, "\(view.debugPanelFrame)")
    }

    /// Compact keeps its host's width whatever the length — a shelf's card,
    /// a history row, the map's bubble fix it — and a full panel whose host
    /// says so does too.
    @Test func aFixedWidthKeepsItsWidth() {
        let short = laidOut(.compact, width: 340, duration: 2)
        let long = laidOut(.compact, width: 340, duration: 50)
        #expect(short.debugPanelFrame == long.debugPanelFrame)
        #expect(short.waveform.bars.count == long.waveform.bars.count)
        #expect(abs(short.debugPanelFrame.width - 340) < 0.5)
        #expect(short.debugTimerText == "2\u{2033}" && long.debugTimerText == "50\u{2033}", "a post's seconds (#2294)")
        #expect(VoiceView(size: .full).widthFollowsLength && !VoiceView(size: .compact).widthFollowsLength)
        let fixed = VoiceView(size: .full, widthFollowsLength: false)
        fixed.configure(VoiceView.State(levels: VoiceView.genericLevels, duration: 1))
        fixed.frame = CGRect(x: 0, y: 0, width: 340, height: VoiceView.panelHeight(for: .full))
        fixed.layoutIfNeeded()
        #expect(abs(fixed.debugPanelFrame.width - 340) < 0.5, "\(fixed.debugPanelFrame)")
        // Turned on later, the rule applies at once.
        fixed.widthFollowsLength = true
        fixed.layoutIfNeeded()
        #expect(abs(fixed.debugPanelFrame.width - VoiceView.minimumPanelWidth) < 0.5, "\(fixed.debugPanelFrame)")
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
        let narrow = laidOut(.full, width: 280, duration: 60)
        let wide = laidOut(.full, width: 600, duration: 60)
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

    /// What the slot shows: the total at rest, the speed while it plays (and
    /// from the tap, while it loads), the time reached when paused mid-way,
    /// the total again at the end.
    @Test(arguments: [VoiceView.Role.message, .post(author: "Ava")])
    func theSlotFollowsThePlayback(_ role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 340, duration: 12, role: role)
        // A message's clock, a post's seconds (#2294).
        let (total, reached) = role == .message ? ("0:12", "0:07") : ("12\u{2033}", "7\u{2033}")
        #expect(view.debugShowsTimer && !view.debugShowsSpeed && view.debugTimerText == total)
        #expect(view.debugTimerAlpha == 1 && view.debugSpeedAlpha == 0)

        state.playback = .loading
        view.update(state)
        #expect(view.debugShowsSpeed, "the glyph and the slot change together, on the tap")

        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(view.debugShowsSpeed && !view.debugShowsTimer)
        #expect(view.debugSpeedTitle == "1.5×")
        #expect(view.debugTimerAlpha == 0 && view.debugSpeedAlpha == 1)

        state.playback = .paused(progress: 7.0 / 12)
        view.update(state)
        #expect(view.debugShowsTimer && !view.debugShowsSpeed)
        #expect(view.debugTimerText == reached, "paused, the time it resumes from")

        state.playback = .rest
        view.update(state)
        #expect(view.debugShowsTimer && view.debugTimerText == total, "the end shows the total again")
        #expect(VoiceView.slotContent(for: .failed) == .timer)
    }

    /// One slot, one size, whatever it shows: the waveform's frame and its
    /// bars never change between states — binned once — and the speed's
    /// button fills the slot; the timer and the speed's words stand against
    /// its trailing edge (#2364).
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
        #expect(abs(view.debugTimerFrame.maxX - slot.maxX) < 0.5, "the timer isn't against the slot's trailing edge")
        let playbacks: [VoiceView.State.Playback] = [.loading, .playing(progress: 0.3), .paused(progress: 0.6), .rest, .failed]
        for (index, playback) in playbacks.enumerated() {
            state.playback = playback
            state.speedLabel = ["1×", "1.5×", "2×"][index % 3]
            view.update(state)
            view.layoutIfNeeded()
            #expect(view.debugSlotFrame == slot, "\(playback): the slot moved")
            #expect(view.debugWaveformFrame == bars, "\(playback): the waveform moved")
            #expect(view.waveform.bars.count == count, "\(playback): the bars were re-binned")
            if view.debugShowsSpeed {
                #expect(view.debugSpeedFrame == slot, "the speed doesn't fill the slot")
                #expect(abs(view.debugSpeedWordsFrame.maxX - slot.maxX) < 0.5, "the speed isn't against the trailing edge")
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
    /// length in its own format (#2294) — and the widest speed: never
    /// narrower than either.
    @Test(arguments: [TimeInterval(12), 65, 760], [VoiceView.Role.message, .post(author: nil)])
    func theSlotHoldsTheWidestTimerAndSpeed(_ duration: TimeInterval, role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: duration)
        let view = laidOut(.full, width: 340, duration: duration, role: role)
        let slot = view.debugSlotFrame
        #expect(view.debugTimerFrame.width <= slot.width + 0.5)
        state.playback = .playing(progress: 0.5)
        state.speedLabel = VoiceView.widestSpeedLabel
        view.update(state)
        view.debugSetSpeedLabel(VoiceView.widestSpeedLabel)
        #expect(view.debugSlotFrame == slot)
        #expect(view.debugSpeedFrame == slot)
        #expect(view.debugSpeedWordsFrame.width <= slot.width + 0.5, "the widest speed overflows the slot")
    }

    /// The slot is measured on the voice's own format (#2294) — a post's
    /// seconds, a message's clock — and again when a laid-out panel's role
    /// changes. An hour's length, which no post has, so the timer is wider
    /// than the speed and decides the slot.
    @Test func theSlotIsMeasuredOnTheVoicesOwnFormat() {
        let post = laidOut(.full, width: 340, duration: 3_723, role: .post(author: nil))
        let message = laidOut(.full, width: 340, duration: 3_723, role: .message)
        #expect(post.debugTimerText == "3723\u{2033}" && message.debugTimerText == "1:02:03")
        for view in [post, message] {
            #expect(view.debugTimerFrame.width <= view.debugSlotFrame.width + 0.5, "\(view.role): the timer overflows")
        }
        message.role = .post(author: nil)
        message.layoutIfNeeded()
        #expect(message.debugTimerText == "3723\u{2033}", "a role change kept the clock")
        #expect(abs(message.debugSlotFrame.width - post.debugSlotFrame.width) < 0.5, "the slot kept the clock's width")
    }

    // MARK: - The slot hugs its words (#2364)

    /// The width `text` takes in `font`, as the slot measures it.
    private func wordsWidth(_ text: String, _ font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The slot's width is the widest of its states as words (#2364): the
    /// voice's timer at its longest — a post's "30″", a message's "0:30" —
    /// and the bare "1.5×", at the text size; nothing round them. About 30
    /// pt at the default size (about 50 with #2329's capsule), wider at
    /// XXXL. A laid-out panel's slot is that width.
    @Test(arguments: [VoiceView.TimerStyle.seconds, .clock], [UIContentSizeCategory.large, .extraExtraExtraLarge])
    func theSlotIsTheWidestOfItsWords(_ style: VoiceView.TimerStyle, textSize: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: textSize)
        let font = VoiceView.timerFont(compatibleWith: traits)
        let longest = wordsWidth(VoiceView.timerText(30, style: style), font)
        let speed = wordsWidth(VoiceView.widestSpeedLabel, font)
        let slot = VoiceView.slotSize(forLength: 30, style: style, traits: traits)
        #expect(slot.width == ceil(max(longest, speed)), "\(style) at \(textSize.rawValue): \(slot.width)")
        #expect(slot.width >= ceil(longest) && slot.width >= ceil(speed))
        #expect(slot.height >= ceil(font.lineHeight), "the slot is shorter than a line of its words")
        if textSize == .large {
            #expect(slot.width >= 20 && slot.width <= 36, "no longer hugs its words: \(slot.width)")
        } else {
            let large = VoiceView.slotSize(forLength: 30, style: style, traits: UITraitCollection(preferredContentSizeCategory: .large))
            #expect(slot.width > large.width, "the slot doesn't follow the text size")
        }
        // A short voice's slot still holds the bare "1.5×".
        let short = VoiceView.slotSize(forLength: 2, style: style, traits: traits)
        #expect(short.width == ceil(max(wordsWidth(VoiceView.timerText(2, style: style), font), speed)))

        let role: VoiceView.Role = style == .clock ? .message : .post(author: nil)
        let view = laidOut(.full, width: 390, duration: 30, role: role, textSize: textSize)
        let drawn = view.debugSlotFrame.width
        #expect(abs(drawn - slot.width) < 0.5, "\(style) at \(textSize.rawValue): the panel's slot \(drawn) vs \(slot.width)")
        #expect(view.debugTimerFont?.pointSize == font.pointSize, "the timer isn't at the view's text size")
    }

    /// The timer and the speed stand against the slot's trailing edge, not
    /// centred (#2364): the spare, when one is shorter than the other, goes
    /// toward the waveform.
    @Test(arguments: [VoiceView.Role.message, .post(author: nil)])
    func theTimerAndTheSpeedAreTrailingAligned(_ role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 2)
        let view = laidOut(.full, width: 340, duration: 2, role: role)
        let slot = view.debugSlotFrame
        let timer = view.debugTimerFrame
        #expect(abs(timer.maxX - slot.maxX) < 0.5, "\(timer) in \(slot)")
        if role != .message {
            // "2″" is shorter than "1.5×": the spare stands before it.
            #expect(timer.minX > slot.minX + 1, "the spare isn't toward the waveform: \(timer) in \(slot)")
        }
        state.playback = .playing(progress: 0.3)
        for speed in ["1×", "1.5×", "2×"] {
            state.speedLabel = speed
            view.update(state)
            view.layoutIfNeeded()
            let words = view.debugSpeedWordsFrame
            #expect(abs(words.maxX - slot.maxX) < 0.5, "\(speed): \(words) in \(slot)")
            #expect(words.minX >= slot.minX - 0.5, "\(speed) overflows the slot")
            #expect(abs(words.midY - slot.midY) < 0.5, "\(speed) isn't level with the slot")
        }
        #expect(view.debugSlotFrame == slot, "the slot moved")
    }

    /// The speed is a bare text button (#2364): no capsule, no ground —
    /// pressed, its words dim and nothing appears — with an invisible
    /// target of at least 44 × 44 pt round its words, which reaches past
    /// the slot into the panel's trailing air.
    @Test(arguments: [VoiceView.Role.message, .post(author: nil)])
    func theSpeedIsBareWordsWithA44PointTarget(_ role: VoiceView.Role) {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 340, duration: 12, role: role)
        let slot = view.debugSlotFrame
        // At rest the timer has the slot: the speed takes no press.
        #expect(view.debugPressTarget(at: CGPoint(x: slot.midX, y: slot.midY)) != "speed")

        state.playback = .playing(progress: 0.3)
        view.update(state)
        view.layoutIfNeeded()
        #expect(!view.debugSpeedHasAGround, "the speed has a ground")
        let words = view.debugSpeedWordsFrame
        let target = view.debugSpeedTargetFrame
        #expect(target.width >= VoiceView.speedTargetSide - 0.01 && target.height >= VoiceView.speedTargetSide - 0.01, "\(target)")
        #expect(target.contains(words.insetBy(dx: 0.5, dy: 0.5)) && target.contains(slot.insetBy(dx: 0.5, dy: 0.5)))
        #expect(abs(target.midY - words.midY) < 0.5, "the target isn't round the words")
        // A press on the words, above them, below them, and in the trailing
        // air after them is the speed's.
        let points = [
            CGPoint(x: words.midX, y: words.midY),
            CGPoint(x: words.midX, y: words.midY - 18),
            CGPoint(x: words.midX, y: words.midY + 18),
            CGPoint(x: min(target.maxX, view.debugPanelFrame.maxX) - 1, y: words.midY),
        ]
        for point in points {
            #expect(view.debugPressTarget(at: point) == "speed", "\(point) misses the speed (\(target))")
            #expect(view.keepsPress(at: point), "\(point): the row would take the speed's press")
        }
        #expect(view.debugPressTarget(at: CGPoint(x: view.debugWaveformFrame.minX + 2, y: words.midY)) == "waveform")

        // Pressed, the words dim; no ground appears.
        view.debugSpeedButton.isHighlighted = true
        #expect(abs(view.debugSpeedWordsAlpha - VoiceView.speedPressedAlpha) < 0.001)
        #expect(!view.debugSpeedHasAGround, "a ground appeared under the finger")
        #expect(view.debugSpeedTransform == .identity, "the press moved the words")
        view.debugSpeedButton.isHighlighted = false
        #expect(view.debugSpeedWordsAlpha == 1)
    }

    /// The speed's target: at least 44 pt each way, centred on the words;
    /// words already larger keep their own size.
    @Test func theSpeedsTargetIsAtLeast44Points() {
        let small = VoiceView.speedTarget(around: CGRect(x: 100, y: 10, width: 18, height: 17))
        #expect(small.width == 44 && small.height == 44)
        #expect(small.midX == 109 && small.midY == 18.5)
        let large = VoiceView.speedTarget(around: CGRect(x: 0, y: 0, width: 60, height: 50))
        #expect(large == CGRect(x: 0, y: 0, width: 60, height: 50))
    }

    /// On screen the change is the morph (#2329): the timer's words go up
    /// and out as the speed's come up and in, in place against the slot's
    /// trailing edge — both fading on one curve, so the slot is never empty;
    /// to paused, the reverse. No ground grows (#2364). Under Reduce Motion
    /// a plain cross-fade; off screen, a cut.
    @Test(arguments: [false, true])
    func theSlotMorphsOrCrossFades(_ reduced: Bool) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 340, duration: 12)
        view.reducesMotion = { reduced }
        window.addSubview(view)
        view.layoutIfNeeded()
        let slot = view.debugSlotFrame

        state.playback = .playing(progress: 0.2)
        view.update(state)
        #expect(view.debugShowsSpeed)
        #expect(view.debugTimerAlpha == 0 && view.debugSpeedAlpha == 1)
        #expect(view.debugSlotMotion == (reduced ? .crossFade : .morph))
        #expect(view.debugSlotIsFading, "the slot cut")
        let durations = view.debugSlotOpacityDurations
        let duration = reduced ? VoiceView.slotCrossFadeDuration : VoiceView.slotMorphDuration
        #expect(durations.count == 2 && durations.allSatisfy { abs($0 - duration) < 0.001 },
                "the timer and the speed don't trade places together: \(durations)")
        // No ground, whatever the motion (#2364), and the words in place.
        #expect(!view.debugSpeedHasAGround)
        #expect(view.debugSpeedFrame == slot && abs(view.debugSpeedWordsFrame.maxX - slot.maxX) < 0.5)
        if reduced {
            #expect(!view.debugSlotIsTurning && view.debugSpeedTransform == .identity, "Reduce Motion moved the words")
        } else {
            #expect(view.debugSlotIsTurning, "the words don't turn")
            #expect(view.debugTimerTransform.ty < 0, "the timer doesn't go up")
            #expect(view.debugTimerTransform.tx == 0, "the timer moves sideways")
            #expect(view.debugSpeedTransform == .identity, "the speed doesn't land in place")
        }

        state.playback = .paused(progress: 0.5)
        view.update(state)
        #expect(view.debugShowsTimer && view.debugTimerAlpha == 1 && view.debugSpeedAlpha == 0)
        #expect(view.debugSlotMotion == (reduced ? .crossFade : .morph))
        if !reduced {
            #expect(view.debugTimerTransform == .identity, "the timer doesn't land in place")
            #expect(view.debugSpeedTransform.ty > 0, "the speed doesn't go down")
            #expect(view.debugSpeedTransform.tx == 0, "the speed moves sideways")
        }
        view.removeFromSuperview()

        // Off screen: a cut, at rest.
        let still = laidOut(.full, width: 340, duration: 12)
        state.playback = .playing(progress: 0.2)
        still.update(state)
        #expect(still.debugSlotMotion == .cut && !still.debugSlotIsFading)
        #expect(still.debugSpeedTransform == .identity && still.debugSpeedAlpha == 1)
    }

    /// A tap goes rest → loading → playing (#2329, filmed: the morph and the
    /// glyph's swap froze, then cut to their end). The morph and the swap
    /// start at the tap — loading — and the playing state that follows
    /// leaves them running: the slot's turn and the glyph's copies are
    /// still there, and the leaving timer keeps its words, not the "0:00"
    /// reached.
    @Test func playingLeavesTheTapsMotionRunning() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 34)
        let view = laidOut(.full, width: 340, duration: 34, role: .message)
        view.reducesMotion = { false }
        window.addSubview(view)
        view.layoutIfNeeded()
        #expect(view.debugTimerText == "0:34")

        state.playback = .loading
        view.update(state)
        #expect(view.debugSlotMotion == .morph && view.debugSlotIsTurning, "the tap didn't start the morph")
        #expect(PlayPauseGlyph.debugCopies(of: view.debugPlayButton) > 0, "the tap didn't start the glyph's swap")
        let speed = view.debugSpeedTransform

        state.playback = .playing(progress: 0)
        view.update(state)
        #expect(view.debugSlotIsTurning, "playing cut the morph")
        #expect(view.debugSlotOpacityDurations.count == 2, "playing cut the fades")
        #expect(view.debugSpeedTransform == speed, "playing moved the speed's words")
        #expect(PlayPauseGlyph.debugCopies(of: view.debugPlayButton) > 0, "playing cut the glyph's swap")
        #expect(view.debugTimerText == "0:34", "the leaving timer's words changed mid-motion")
        for progress in [0.01, 0.02] {
            state.playback = .playing(progress: progress)
            view.update(state)
        }
        #expect(view.debugSlotIsTurning && view.debugTimerText == "0:34", "a frame of playback cut the morph")

        // Paused, the timer comes back with the time reached.
        state.playback = .paused(progress: 0.5)
        view.update(state)
        #expect(view.debugTimerText == "0:17")
        view.removeFromSuperview()
    }

    /// The timer and the speed read as one set of words (#2329, #2364): a
    /// row button's title font — the subheadline on the app's scale, scaled
    /// with the text size — with monospaced digits, in one ink; no longer
    /// caption1 grey.
    @Test func theTimerAndTheSpeedReadAsOne() throws {
        let view = laidOut(.full, width: 340, duration: 12)
        let font = try #require(view.debugTimerFont)
        let row = AppButton.titleFont(for: .row)
        #expect(font.pointSize == row.pointSize, "\(font.pointSize) vs a row button's \(row.pointSize)")
        #expect(font.familyName == row.familyName)
        #expect(font.pointSize > UIFont.defaultPointSize(for: .caption1), "still the caption's size")
        #expect(font.pointSize == VoiceView.timerFont.pointSize)
        #expect(view.debugSpeedFont == font, "the speed isn't in the timer's font")
        let widths = ["1", "8"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        #expect(abs(widths[0] - widths[1]) < 0.01, "the digits aren't monospaced: \(widths)")
        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(rgba(view.debugTimerInk, style) == rgba(UIColor.label, style), "the timer is still a grey")
            #expect(rgba(view.debugSpeedInk, style) == rgba(view.debugTimerInk, style), "the timer and the speed differ")
        }
        // A host's ink reaches both.
        view.inks = VoiceView.Inks(played: .white, unplayed: .gray, timer: .white)
        #expect(rgba(view.debugTimerInk, .light) == [1, 1, 1, 1] && rgba(view.debugSpeedInk, .light) == [1, 1, 1, 1])
    }

    // MARK: - The whole panel swells (#2274)

    /// A finger on the waveform swells the whole panel by the app's press
    /// swell on its size — and nothing inside it on its own; it settles when
    /// the finger lifts, and when it is cancelled. What it holds — the
    /// glyph, the bars, the slot — scales by ONE factor on both axes, while
    /// its ground grows by the swell's points across and down, its corner
    /// kept (#2284, #2329).
    @Test(arguments: [VoiceView.Size.full, .compact])
    func aFingerOnTheWaveformSwellsTheWholePanel(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 320, playback: .playing(progress: 0.3))
        view.reducesMotion = { false }
        let resting = view.debugPanelRestingSize
        let scale = PressFeedback.swelledScale(for: resting)
        let even = PressFeedback.swell(for: resting).content
        #expect(scale.x > 1 && scale.y > 1)
        #expect(view.debugGroundSize == resting, "the ground at rest is not the panel")
        #expect(view.debugWaveformSwellFactor == even, "the bars aren't drawn for the content's swell")
        view.waveform.debugFinger(true)
        let transform = view.debugPanelTransform
        #expect(transform.a == transform.d && transform.b == 0 && transform.c == 0, "the content is stretched: \(transform)")
        #expect(transform == CGAffineTransform(scaleX: even, y: even))
        let drawn = view.debugDrawnGroundSize
        #expect(abs(drawn.width - resting.width * scale.x) < 0.01, "across: \(drawn) for \(resting)")
        #expect(abs(drawn.height - resting.height * scale.y) < 0.01, "down: \(drawn) for \(resting)")
        #expect(view.debugPanelCornerRadius == VoiceView.panelCornerRadius(for: size), "the swell changed the corner")
        #expect(view.debugPartTransforms.allSatisfy { $0 == .identity }, "a part swelled on its own")
        #expect(view.debugPanelRestingSize == resting, "the swell re-laid the panel")
        // Lifted: it settles.
        view.waveform.debugFinger(false)
        #expect(view.debugPanelTransform == .identity)
        #expect(view.debugGroundSize == resting && view.debugPanelCornerRadius == VoiceView.panelCornerRadius(for: size))
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
        #expect(view.debugGroundSize == view.debugPanelRestingSize, "the ground grew under Reduce Motion")
        view.waveform.onSeek?(0.4, false)
        view.waveform.debugFinger(false)
    }

    // MARK: - No brand colour

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

    /// While it plays, the voice says its time and speed, and the speed
    /// stands as its own element beside it (#2274): "Playback speed", its
    /// words its value — bare words now, read the same (#2364).
    @Test func voiceOverReadsTheSpeedAsItsOwnWhileItShows() {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        let view = laidOut(.full, width: 320, duration: 12, role: .post(author: "Ava"))
        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(!view.isAccessibilityElement)
        #expect(view.debugAccessibilityElements?.count == 2)
        #expect(view.debugAccessibilityElements?.last as? UIControl === view.debugSpeedButton)
        #expect(view.debugSpeedButton.isAccessibilityElement && view.debugSpeedButton.accessibilityTraits.contains(.button))
        #expect(view.debugSpeedButton.accessibilityLabel == "Playback speed")
        #expect(view.debugSpeedButton.accessibilityValue == "1.5×")
        #expect(view.debugPlayElementValue == "6 seconds, speed 1.5×", "a post's time, spoken (#2294)")
        #expect(view.accessibilityCustomActions?.map(\.name).contains("Speed 1.5×") == true)
        state.playback = .paused(progress: 0.5)
        view.update(state)
        #expect(view.isAccessibilityElement && view.debugAccessibilityElements == nil)
        #expect(view.accessibilityValue == "6 seconds, speed 1.5×")
    }
}
