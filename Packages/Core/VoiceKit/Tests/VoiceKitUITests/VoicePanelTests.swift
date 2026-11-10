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

/// The voice component as a neutral panel (#2241): a filled disc, the
/// waveform across the whole width, the timer at the end; the panel fills
/// its container at each size — capped in a conversation — and is one width
/// whatever the length; its ground and inks are the host's, never the
/// brand's.
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

    /// Compact is a little shorter than full: a smaller disc, shorter bars.
    @Test func compactIsALittleShorter() {
        #expect(VoiceView.panelHeight(for: .compact) < VoiceView.panelHeight(for: .full))
        #expect(VoiceView.buttonSide(for: .full) == 40 && VoiceView.buttonSide(for: .compact) == 32)
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

    /// The bars run from the disc to the timer, as many as the width holds
    /// (2 pt bars, 2 pt apart), spread edge to edge.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func theWaveformRunsFromTheDiscToTheTimer(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 360)
        let button = view.debugPlayButton.convert(view.debugPlayButton.bounds, to: view)
        let bars = view.debugWaveformFrame
        let timer = view.debugTimerFrame
        #expect(abs(bars.minX - (button.maxX + Spacing.sm)) < 0.5, "\(bars) after \(button)")
        #expect(abs(bars.maxX - (timer.minX - Spacing.sm)) < 0.5, "\(bars) before \(timer)")
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

    // MARK: - The filled play button

    /// A disc — black in the light, white in the dark — with its glyph
    /// knocked out in the other; the app's icon button, at 40 pt in full.
    @Test(arguments: [VoiceView.Size.full, .compact])
    func thePlayButtonIsAFilledDisc(_ size: VoiceView.Size) {
        let view = laidOut(size, width: 320)
        #expect(view.debugPlayButtonIsAFilledDisc)
        let side = VoiceView.buttonSide(for: size)
        #expect(view.debugButtonSize == CGSize(width: side, height: side))
        #expect(rgba(view.debugDiscFill, .light) == [0, 0, 0, 1])
        #expect(rgba(view.debugDiscFill, .dark) == [1, 1, 1, 1])
        #expect(rgba(view.debugGlyphInk, .light) == [1, 1, 1, 1])
        #expect(rgba(view.debugGlyphInk, .dark) == [0, 0, 0, 1])
        #expect(view.debugGlyph == "play.fill")
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

    /// Under way, the speed chip comes into the panel after the timer; the
    /// panel keeps its width, the waveform gives the chip its room.
    @Test func theChipStandsInsideThePanel() {
        let view = laidOut(.full, width: 340, playback: .playing(progress: 0.3))
        let panel = view.debugPanelFrame
        let chip = view.debugChipFrame
        #expect(view.debugShowsChip)
        #expect(abs(panel.width - 340) < 0.5)
        #expect(chip.maxX <= panel.maxX && chip.minX >= view.debugTimerFrame.maxX, "\(chip) in \(panel)")
        #expect(view.debugWaveformFrame.maxX < view.debugTimerFrame.minX)
        #expect(view.waveform.bars.count == VoiceView.barCount(forWidth: view.debugWaveformFrame.width))
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

    /// The panel reads as one element — its parts are not elements — with
    /// its label, its ±5 s adjustment and its play and speed actions.
    @Test func voiceOverReadsThePanelAsOne() {
        let view = laidOut(.full, width: 320, duration: 12, role: .message)
        #expect(view.isAccessibilityElement)
        #expect(!view.debugPlayButton.isAccessibilityElement)
        #expect(view.accessibilityLabel == "Your voice message, 12 seconds, played")
        #expect(view.accessibilityTraits.contains(.adjustable))
        let actions = view.accessibilityCustomActions?.map(\.name) ?? []
        #expect(actions.contains("Play") && actions.contains("Speed 1×"))
    }
}
