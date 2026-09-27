import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The label: where emotes are placed, when the glyph under them is erased,
/// and what is never done (off screen, truncated, Reduce Motion, over budget).
@MainActor
@Suite(.serialized)
struct EmoteLabelTests {
    private let font = UIFont.systemFont(ofSize: 17)

    /// An engine whose every emote already has art in every bucket, so a
    /// layout pass installs synchronously — the same path a warm cache takes.
    private func warmEngine(_ ids: [String]) throws -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        for id in ids {
            let emote = try #require(engine.catalog.emote(id: id))
            for side in EmoteEngine.pixelBuckets {
                engine.insert(Self.syntheticArt(side: side), for: emote, pixelSide: side, motion: .loop)
                engine.insert(Self.syntheticArt(side: side, frames: 1), for: emote, pixelSide: side, motion: .still)
            }
        }
        return engine
    }

    /// Two solid frames — enough to be "animated" without baking anything.
    static func syntheticArt(side: Int, frames: Int = 2) -> AnimatedIconArt {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side * frames, height: side),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()
        )
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side * frames, height: side))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: frames, columns: frames, frameDuration: 1.0 / 30))
    }

    private func hostedLabel(
        _ text: String, engine: EmoteEngine, width: CGFloat = 320, lines: Int = 0
    ) -> (EmoteLabel, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.textColor = .black
        label.numberOfLines = lines
        label.setEmoteText(text)
        window.addSubview(label)
        let size = label.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: 10, y: 10, width: width, height: size.height)
        label.layoutIfNeeded()
        return (label, window)
    }

    @Test func eachVisibleEmoteGetsAPlayerOverItsGlyph() throws {
        let engine = try warmEngine(["noto:1f525", "lol"])
        let (label, window) = hostedLabel("hot 🔥 take :lol:", engine: engine)
        defer { window.isHidden = true }
        #expect(label.placedEmoteCount == 2)
        #expect(label.showingEmoteCount == 2)
        #expect(label.coveredMarkIndices == [0, 1])
        for frame in label.emoteFrames {
            // Square, at the font's height (an emoji glyph is ~1.2 em), and
            // inside the label's line box.
            #expect(abs(frame.width - frame.height) < 0.01)
            #expect(frame.height > font.pointSize * 0.9 && frame.height < font.lineHeight * 1.4, "\(frame)")
            #expect(frame.minY >= -2 && frame.maxY <= label.bounds.height + 2, "\(frame)")
        }
        // In reading order.
        #expect(label.emoteFrames[0].minX < label.emoteFrames[1].minX)
    }

    /// The glyph the label drew is exactly where the animation goes: its ink
    /// lies inside the player's square.
    @Test func theSquareCoversTheDrawnGlyph() throws {
        let engine = EmoteEngine(diskCache: nil)   // cold: nothing covers the glyph yet
        let (label, window) = hostedLabel("go 🔥 go", engine: engine)
        defer { window.isHidden = true }
        let frame = try #require(label.emoteFrames.first)
        #expect(label.showingEmoteCount == 0)

        let ink = try #require(Self.colouredInk(of: label))
        #expect(frame.insetBy(dx: -1, dy: -1).contains(ink), "ink \(ink) outside \(frame)")
        #expect(ink.height > frame.height * 0.7, "ink \(ink) much smaller than \(frame)")
    }

    /// Never blank: before art arrives the glyph is drawn; once a player
    /// shows art, that glyph (and only that one) is not.
    @Test func theGlyphIsErasedOnlyUnderAShowingPlayer() throws {
        let cold = EmoteEngine(diskCache: nil)
        let (before, w1) = hostedLabel("🔥", engine: cold)
        defer { w1.isHidden = true }
        #expect(Self.colouredInk(of: before) != nil, "a cold emote must still draw its glyph")

        let (after, w2) = hostedLabel("🔥", engine: try warmEngine(["noto:1f525"]))
        defer { w2.isHidden = true }
        #expect(after.showingEmoteCount == 1)
        #expect(Self.colouredInk(of: after) == nil, "the glyph under a playing emote must be erased")
    }

    /// The metric contract, end to end: a label's size is the same with or
    /// without art, and the same as a plain `UILabel`'s for the same text.
    @Test func placeholdersNeverMoveTheText() throws {
        let text = "a :lol: b 🔥 and some more words to wrap onto a second line"
        let (cold, w1) = hostedLabel(text, engine: EmoteEngine(diskCache: nil), width: 200)
        let (warm, w2) = hostedLabel(text, engine: try warmEngine(["lol", "noto:1f525"]), width: 200)
        defer { w1.isHidden = true; w2.isHidden = true }
        #expect(cold.bounds.size == warm.bounds.size)

        let plain = UILabel()
        plain.numberOfLines = 0
        plain.attributedText = EmoteText.attributedString(text, attributes: [.font: font])
        let plainSize = plain.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        #expect(abs(plainSize.height - cold.bounds.height) < 1, "\(plainSize) vs \(cold.bounds.size)")
        #expect(cold.bounds.height > font.lineHeight * 1.5, "the text did not wrap")
    }

    /// A truncated emote must not animate outside the text.
    @Test func truncatedAndClippedEmotesAreNotPlaced() throws {
        let engine = try warmEngine(["noto:1f525", "noto:1f602"])
        let text = "🔥 a sentence long enough that it truncates well before its end 😂"
        let (label, window) = hostedLabel(text, engine: engine, width: 200, lines: 1)
        defer { window.isHidden = true }
        label.lineBreakMode = .byTruncatingTail
        label.layoutIfNeeded()
        #expect(label.placedEmoteCount == 1)
        #expect(label.coveredMarkIndices == [0])
    }

    @Test func nothingHappensOffScreen() throws {
        let engine = EmoteEngine(diskCache: nil)
        let label = EmoteLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        label.engine = engine
        label.setEmoteText("🔥 😂 :lmao:")
        label.layoutIfNeeded()
        #expect(label.placedEmoteCount == 0)
        #expect(engine.stats.bakesStarted == 0)
        let fire = try #require(engine.catalog.emote(id: "noto:1f525"))
        #expect(!engine.isBaking(fire, pixelSide: 64, motion: .loop))
    }

    /// Leaving the window cancels what was baking and frees the slots.
    @Test func leavingTheWindowTearsDown() throws {
        let engine = try warmEngine(["noto:1f525"])
        let (label, window) = hostedLabel("🔥🔥", engine: engine)
        defer { window.isHidden = true }
        #expect(engine.animatedCount == 2)
        label.removeFromSuperview()
        #expect(label.placedEmoteCount == 0)
        #expect(engine.animatedCount == 0)
    }

    /// Cell reuse: new text drops the old emotes at once.
    @Test func newTextClearsOldPlayers() throws {
        let engine = try warmEngine(["noto:1f525"])
        let (label, window) = hostedLabel("🔥", engine: engine)
        defer { window.isHidden = true }
        #expect(label.placedEmoteCount == 1)
        label.setEmoteText("plain words")
        label.layoutIfNeeded()
        #expect(label.placedEmoteCount == 0)
        #expect(label.subviews.isEmpty)
        #expect(engine.animatedCount == 0)
    }

    /// Over the budget, the extra emotes keep their static glyph — drawn, not
    /// blank — and take a slot when one frees.
    @Test func theBudgetCapsAnimationsAndHandsSlotsOn() throws {
        let engine = try warmEngine(["noto:1f525"])
        engine.maxAnimatedEmotes = 1
        let (first, w1) = hostedLabel("🔥🔥", engine: engine)
        defer { w1.isHidden = true }
        #expect(first.showingEmoteCount == 1)
        #expect(first.coveredMarkIndices.count == 1)
        let (second, w2) = hostedLabel("🔥", engine: engine)
        defer { w2.isHidden = true }
        #expect(second.showingEmoteCount == 0)

        first.removeFromSuperview()
        second.layoutIfNeeded()
        #expect(second.showingEmoteCount == 1)
    }

    // MARK: - Visibility and slots

    /// A label two views deep in a window: window → container → label.
    private func nestedLabel(
        _ text: String, engine: EmoteEngine, in container: UIView
    ) -> (EmoteLabel, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        window.addSubview(container)
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.setEmoteText(text)
        container.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 300, height: 30)
        label.layoutIfNeeded()
        return (label, window)
    }

    /// A HIDDEN ANCESTOR (a collection view's parked cell) gives the slots
    /// back, and showing it again takes them again.
    @Test func aLabelInAHiddenContainerReleasesItsSlots() throws {
        let engine = try warmEngine(["noto:1f525"])
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let (label, window) = nestedLabel("🔥🔥", engine: engine, in: container)
        defer { window.isHidden = true }
        #expect(engine.animatedCount == 2)

        container.isHidden = true
        EmoteVisibilityMonitor.shared.tick()
        #expect(engine.animatedCount == 0)
        #expect(label.placedEmoteCount == 0)
        #expect(label.coveredMarkIndices.isEmpty, "a label that gave its players back must draw its glyphs")

        container.isHidden = false
        EmoteVisibilityMonitor.shared.tick()
        label.layoutIfNeeded()
        #expect(engine.animatedCount == 2)
        #expect(label.showingEmoteCount == 2)
    }

    /// OUT OF A SCROLL VIEW'S BOUNDS (a pager's neighbour page, a row
    /// scrolled away) gives the slots back; scrolling back takes them again.
    @Test func aLabelScrolledOutOfAScrollViewReleasesItsSlots() throws {
        let engine = try warmEngine(["noto:1f525"])
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let (label, window) = nestedLabel("🔥", engine: engine, in: scroll)
        defer { window.isHidden = true }
        #expect(engine.animatedCount == 1)

        // Still partly inside: keeps its slot.
        scroll.contentOffset = CGPoint(x: 0, y: 30)
        EmoteVisibilityMonitor.shared.tick()
        #expect(engine.animatedCount == 1)

        scroll.contentOffset = CGPoint(x: 0, y: 1000)
        EmoteVisibilityMonitor.shared.tick()
        #expect(engine.animatedCount == 0)
        #expect(label.placedEmoteCount == 0)

        scroll.contentOffset = .zero
        EmoteVisibilityMonitor.shared.tick()
        label.layoutIfNeeded()
        #expect(engine.animatedCount == 1)
    }

    @Test func aTransparentAncestorReleasesTheSlots() throws {
        let engine = try warmEngine(["noto:1f525"])
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let (_, window) = nestedLabel("🔥", engine: engine, in: container)
        defer { window.isHidden = true }
        #expect(engine.animatedCount == 1)
        container.alpha = 0
        EmoteVisibilityMonitor.shared.tick()
        #expect(engine.animatedCount == 0)
    }

    /// Laid out outside the window (an off-screen page that does not clip):
    /// never takes a slot at all, and still draws its glyph.
    @Test func aLabelOutsideTheWindowNeverTakesASlot() throws {
        let engine = try warmEngine(["noto:1f525"])
        let container = UIView(frame: CGRect(x: 1000, y: 0, width: 400, height: 400))
        let (label, window) = nestedLabel("🔥", engine: engine, in: container)
        defer { window.isHidden = true }
        #expect(engine.animatedCount == 0)
        #expect(label.placedEmoteCount == 0)
        #expect(Self.colouredInk(of: label) != nil, "its glyph is still drawn")
    }

    /// The monitor's own timer does it, with no test calling `tick()`, and
    /// the freed slot goes to a VISIBLE label that was waiting for one.
    @Test func theMonitorFreesSlotsForVisibleLabelsOnItsOwn() async throws {
        let engine = try warmEngine(["noto:1f525"])
        engine.maxAnimatedEmotes = 1
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let (hidden, window) = nestedLabel("🔥", engine: engine, in: container)
        defer { window.isHidden = true }
        #expect(hidden.showingEmoteCount == 1)
        let visible = EmoteLabel(frame: CGRect(x: 10, y: 250, width: 300, height: 30))
        visible.engine = engine
        visible.font = font
        visible.setEmoteText("🔥")
        window.addSubview(visible)
        visible.layoutIfNeeded()
        #expect(visible.showingEmoteCount == 0, "over the cap: waits on its glyph")
        #expect(EmoteVisibilityMonitor.shared.isRunning)

        container.isHidden = true
        for _ in 0..<100 where visible.showingEmoteCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
        #expect(hidden.placedEmoteCount == 0)
        #expect(visible.showingEmoteCount == 1)
        #expect(engine.animatedCount == 1)
    }

    /// A label with no emotes, or out of any window, is not monitored.
    @Test func onlyLabelsWithEmotesInAWindowAreMonitored() throws {
        let engine = try warmEngine(["noto:1f525"])
        let (label, window) = hostedLabel("🔥", engine: engine)
        defer { window.isHidden = true }
        let before = EmoteVisibilityMonitor.shared.registeredCount
        label.setEmoteText("plain words")
        #expect(EmoteVisibilityMonitor.shared.registeredCount == before - 1)
        label.setEmoteText("🔥")
        #expect(EmoteVisibilityMonitor.shared.registeredCount == before)
        label.removeFromSuperview()
        #expect(EmoteVisibilityMonitor.shared.registeredCount == before - 1)
    }

    /// Reduce Motion: an emoji is left to the system (nothing placed, nothing
    /// baked); a house emote shows its first frame.
    @Test func reduceMotionShowsStills() throws {
        AnimatedIconView.forcedPolicy = .still
        defer { AnimatedIconView.forcedPolicy = nil }
        let engine = try warmEngine(["noto:1f525", "lol"])
        let (label, window) = hostedLabel("🔥 :lol:", engine: engine)
        defer { window.isHidden = true }
        #expect(label.placedEmoteCount == 1)
        #expect(label.coveredMarkIndices == [1])
        #expect(engine.animatedCount == 0, "a still must not hold an animation slot")
        #expect(engine.stats.bakesStarted == 0)
    }

    /// Swapping the class is the whole adoption: plain `text` is marked on
    /// the way in, and text without emotes stays on `UILabel`'s path.
    @Test func plainTextIsMarkedOnTheWayIn() throws {
        let engine = try warmEngine(["lol"])
        let (label, window) = hostedLabel("", engine: engine)
        defer { window.isHidden = true }
        label.text = "ha :lol:"
        #expect(label.text == "ha 😆")
        #expect(label.hasEmotes)
        label.text = "just words"
        #expect(label.attributedText?.string == "just words")
        #expect(!label.hasEmotes)
    }

    /// A subclass that draws its text inset says so, and its emotes follow.
    @Test func anInsetSubclassPlacesEmotesInItsInsetBox() throws {
        let engine = try warmEngine(["noto:1f525"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        defer { window.isHidden = true }
        let plain = EmoteLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        let inset = InsetLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        for label in [plain, inset] {
            label.engine = engine
            label.font = font
            label.setEmoteText("🔥")
            window.addSubview(label)
            label.layoutIfNeeded()
        }
        let a = try #require(plain.emoteFrames.first)
        let b = try #require(inset.emoteFrames.first)
        #expect(abs((b.minX - a.minX) - InsetLabel.inset) < 0.5, "\(a) → \(b)")
    }

    @Test func rightToLeftTextPlacesEmotesInsideTheLabel() throws {
        let engine = try warmEngine(["noto:1f525"])
        let (label, window) = hostedLabel("مرحبا 🔥 بالعالم", engine: engine)
        defer { window.isHidden = true }
        let frame = try #require(label.emoteFrames.first)
        #expect(label.bounds.insetBy(dx: -2, dy: -2).contains(frame), "\(frame) outside \(label.bounds)")
    }

    // MARK: - Pixels

    /// The bounding box of COLOURED ink in the label's own drawing — emoji
    /// glyphs are colour, the text is black — in the label's coordinates.
    static func colouredInk(of label: EmoteLabel) -> CGRect? {
        let scale: CGFloat = 2
        let width = Int(label.bounds.width * scale), height = Int(label.bounds.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            UIGraphicsPushContext(context)
            label.drawText(in: label.bounds)
            UIGraphicsPopContext()
        }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let r = Int(bytes[o]), g = Int(bytes[o + 1]), b = Int(bytes[o + 2]), a = Int(bytes[o + 3])
                guard a > 64, max(r, g, b) - min(r, g, b) > 40 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
