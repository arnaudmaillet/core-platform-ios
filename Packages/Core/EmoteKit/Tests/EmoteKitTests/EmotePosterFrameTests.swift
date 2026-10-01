import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The frame a still emote shows is never a blank opening frame.
@MainActor
@Suite(.serialized)
struct EmotePosterFrameTests {
    @Test func aFullFirstFrameIsThePoster() {
        #expect(EmoteStripTests.sheetArt(frames: 6, step: 0.1).posterFrame() == 0)
    }

    @Test func aLoopThatOpensBlankRestsOnItsFirstFullFrame() {
        let art = EmoteStripTests.sheetArt(frames: 8, step: 0.1, blank: 3)
        let coverage = art.frameCoverage()
        #expect(coverage[0] == 0 && coverage[2] == 0 && coverage[3] > 0, "\(coverage)")
        #expect(art.posterFrame() == 3)
    }

    /// A mark that pops in (scale and alpha from zero) rests once it is in.
    @Test func aMarkThatPopsInRestsOnceItIsIn() {
        let mark = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        let track = AnimatedIconMotionTrack(
            scales: [0, 0.3, 0.9, 1, 1, 0], rotations: [0, 0, 0, 0, 0, 0],
            alphas: [0, 1, 1, 1, 1, 0], step: 0.1
        )
        #expect(AnimatedIconArt.decomposed(AnimatedIconStill(mark: mark, track: track)).posterFrame() == 2)
    }

    /// A tile dressed at rest shows the poster, and plays on from it.
    @Test func aStillTileShowsThePoster() throws {
        let engine = EmoteEngine(diskCache: nil)
        let emote = try #require(engine.catalog.all.first)
        let art = EmoteStripTests.sheetArt(frames: 8, step: 0.1, blank: 2)
        engine.insert(art, for: emote, pixelSide: EmoteTileView.pixelSide, motion: .loop)
        let tile = EmoteTileView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        tile.configure(emote, engine: engine, prefersAnimation: true, playing: false)
        #expect(tile.isShowingArt && !tile.isAnimating)
        #expect(tile.player.displayedFrame == 2)
        tile.setPlaying(true)
        #expect(tile.isAnimating)
        #expect([2, 3].contains(tile.player.displayedFrame ?? -1))
        tile.reset()
    }

    /// The real thing, baked: the poster of every kind of house art is
    /// covered — 🎂 and ❣️ open on an empty frame, a Noto face and a
    /// StickerKit sticker do not. Prints each frame 0 for the record.
    @Test func bakedPostersAreNeverBlank() async throws {
        var lines: [String] = []
        for id in ["noto:1f382", "noto:2763_fe0f", "noto:1f602", "lmao"] {
            let engine = EmoteEngine(diskCache: nil)
            engine.bakeDelay = .zero
            let emote = try #require(engine.catalog.emote(id: id))
            let art = try #require(await engine.art(for: emote, pixelSide: EmoteTileView.pixelSide))
            let coverage = art.frameCoverage()
            let fullest = try #require(coverage.max())
            #expect(fullest > 0, "\(id) bakes to nothing")
            let poster = art.posterFrame()
            #expect(coverage[poster] >= fullest * 0.75, "\(id): poster \(poster) is \(coverage[poster] / fullest)")
            lines.append(String(
                format: "%@ frames=%d frame0=%.2f poster=%d (%.2f)",
                emote.glyph, art.frameCount, coverage[0] / fullest, poster, coverage[poster] / fullest
            ))
        }
        print("[emote-poster]\n" + lines.joined(separator: "\n"))
    }
}
