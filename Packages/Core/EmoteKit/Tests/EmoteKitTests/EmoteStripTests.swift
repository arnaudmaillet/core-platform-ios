import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The conversation footer's strip: every emote the build ships, every
/// DISPLAYED tile dressed and nothing else, art that moves only while the
/// strip scrolls (and holds a slot only then), and a scroll view that runs
/// the capsule's whole width.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteStripTests {
    private static let size = CGSize(width: 300, height: 48)

    /// An engine with two-frame art resident for every emote, so tiles present
    /// synchronously — the warm-cache path — and nothing bakes.
    private func warmEngine() -> EmoteEngine {
        warmEngine(art: EmoteLabelTests.syntheticArt(side: EmoteTileView.pixelSide))
    }

    private func warmEngine(art: AnimatedIconArt) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        for emote in engine.catalog.all {
            engine.insert(art, for: emote, pixelSide: EmoteTileView.pixelSide, motion: .loop)
        }
        return engine
    }

    /// `frames` solid frames of `step` seconds each, the first `blank` of them
    /// transparent. ⚠️ Tiny cells: the same art is filed under all ~230
    /// emotes, each at its byte cost, and full-size cells overflow the
    /// engine's memory cache — evicted tiles then bake instead of showing.
    static func sheetArt(frames: Int, step: CFTimeInterval, blank: Int = 0) -> AnimatedIconArt {
        let side = 8
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side * frames, height: side),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }()
        )
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: side * blank, y: 0, width: side * (frames - blank), height: side))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: frames, columns: frames, frameDuration: step))
    }

    private func hosted(_ engine: EmoteEngine, recents: EmoteRecents? = nil) -> (EmoteStripView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
        let strip = EmoteStripView(engine: engine, recents: recents)
        strip.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: Self.size)
        window.addSubview(strip)
        strip.layoutIfNeeded()
        strip.collectionView.layoutIfNeeded()
        return (strip, window)
    }

    private func tearDown(_ window: UIWindow) {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }

    /// The whole catalogue in its order — the house emotes, the map's GIF
    /// emotes among them, then every Noto emoji — not a favourites subset.
    @Test func itListsEveryEmoteTheBuildShips() {
        let strip = EmoteStripView(engine: EmoteEngine(diskCache: nil), recents: nil)
        let catalog = EmoteCatalog.shared
        #expect(strip.emotes.map(\.id) == catalog.all.map(\.id))
        #expect(strip.emotes.count == EmoteCatalog.house.count + catalog.all.filter(\.isUnicodeEmoji).count)
        #expect(strip.emotes.count > 200, "\(strip.emotes.count): the Noto subset is missing")
        for gif in ["lol", "blush"] {
            #expect(strip.emotes.contains { $0.id == gif }, "the \(gif) GIF emote")
        }
        #expect(strip.collectionView.numberOfItems(inSection: 0) == strip.emotes.count)
    }

    /// The scroll view is the capsule's full width; the rest position comes
    /// from the content inset, so tiles scroll right up to the rounded ends,
    /// which are the clip.
    @Test func theScrollViewRunsTheCapsulesWholeWidth() throws {
        let (strip, window) = hosted(warmEngine())
        defer { tearDown(window) }
        let grid = strip.collectionView
        #expect(grid.convert(grid.bounds, to: strip) == strip.bounds)
        #expect(strip.glass.frame == strip.bounds)
        #expect(strip.glass.clipsToBounds, "the capsule is the clip")
        #expect(strip.glass.effect is UIGlassEffect)
        #expect(strip.glass.backgroundColor == nil)
        #expect(grid.contentInset.left == EmoteStripView.cellInset)
        #expect(grid.contentInset.right == EmoteStripView.cellInset)
        let first = try #require(grid.cellForItem(at: IndexPath(item: 0, section: 0)))
        #expect(first.convert(first.bounds, to: strip).minX == EmoteStripView.cellInset, "at rest on the first tile")
        #expect(first.bounds.height == Self.size.height - EmoteStripView.cellInset * 2)
    }

    /// Every displayed tile is dressed; a tile scrolled out lets its art go
    /// at once. A still tile holds no slot, and none is taken from the labels.
    @Test func displayedTilesAreDressedAndOnlyThose() throws {
        let engine = warmEngine()
        let (strip, window) = hosted(engine)
        defer { tearDown(window) }
        let tiles = strip.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.isShowingArt }, "every displayed tile is dressed, emoji or house emote")
        #expect(engine.playingTileCount == 0, "at rest, nothing plays")

        let grid = strip.collectionView
        strip.scrollViewWillBeginDragging(grid)
        for step in 1...6 {
            grid.setContentOffset(CGPoint(x: CGFloat(step) * 400, y: grid.contentOffset.y), animated: false)
            grid.layoutIfNeeded()
            let shown = strip.displayedTiles
            #expect(shown.allSatisfy { $0.isShowingArt })
            #expect(engine.playingTileCount == shown.count,
                    "step \(step): \(engine.playingTileCount) slots, \(shown.count) shown")
        }
        #expect(engine.animatedCount == 0, "the labels' budget is untouched")

        strip.removeFromSuperview()
        #expect(engine.playingTileCount == 0, "off the window, nothing plays")
        #expect(tiles.allSatisfy { !$0.isShowingArt }, "nor holds its art")
    }

    /// At rest nothing moves: the first appearance dresses every tile still,
    /// on its poster frame, and so does a layout pass that brings tiles in.
    @Test func atRestNoTilePlays() throws {
        let (strip, window) = hosted(warmEngine(art: Self.sheetArt(frames: 8, step: 0.1)))
        defer { tearDown(window) }
        let tiles = strip.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(!strip.isScrolling)
        #expect(tiles.allSatisfy { $0.isShowingArt && !$0.isAnimating && $0.player.isPaused })
        #expect(tiles.allSatisfy { $0.player.displayedFrame == 0 }, "the poster frame, not wherever the clock is")

        // Tiles brought in at rest (a layout change, an offset set in code).
        let grid = strip.collectionView
        grid.setContentOffset(CGPoint(x: 900, y: grid.contentOffset.y), animated: false)
        grid.layoutIfNeeded()
        let shown = strip.displayedTiles
        try #require(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.isShowingArt && !$0.isAnimating })
    }

    /// From the drag's start to the end of the glide every displayed tile
    /// plays, the ones scrolled in meanwhile too; once the strip stops, none.
    @Test func displayedTilesPlayOnlyWhileTheStripScrolls() async throws {
        let engine = warmEngine(art: Self.sheetArt(frames: 8, step: 0.1))
        let (strip, window) = hosted(engine)
        defer { tearDown(window) }
        let grid = strip.collectionView

        strip.scrollViewWillBeginDragging(grid)
        #expect(strip.isScrolling)
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating }, "the drag starts them")

        for step in 1...3 {
            grid.setContentOffset(CGPoint(x: CGFloat(step) * 400, y: grid.contentOffset.y), animated: false)
            grid.layoutIfNeeded()
            let shown = strip.displayedTiles
            try #require(!shown.isEmpty)
            #expect(shown.allSatisfy { $0.isAnimating }, "step \(step): a tile scrolled in plays")
            #expect(engine.playingTileCount == shown.count, "step \(step): the slots follow the screen")
        }

        strip.scrollViewDidEndDragging(grid, willDecelerate: true)
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating }, "the glide still plays")
        strip.scrollViewDidEndDecelerating(grid)
        #expect(!strip.isScrolling)
        // #559: each emote finishes its loop first, then rests.
        try #require(await settle { strip.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating } },
                     "stopped once their loops end, nothing plays")
        #expect(engine.playingTileCount == 0, "a still tile gives its slot back")

        // A drag let go without a glide stops it as well.
        strip.scrollViewWillBeginDragging(grid)
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating })
        strip.scrollViewDidEndDragging(grid, willDecelerate: false)
        try #require(await settle { strip.displayedTiles.allSatisfy { !$0.isAnimating } })
    }

    @Test func aScrollThatEndsLetsEachEmoteFinishItsLoop() async throws {
        // #559: an emote never stops posed mid-gesture. A 0.6 s loop keeps
        // the wait short; frames are waited for, never timed.
        let frames = 20
        let (strip, window) = hosted(warmEngine(art: Self.sheetArt(frames: frames, step: 0.03)))
        defer { tearDown(window) }
        let grid = strip.collectionView
        let tile = try #require(strip.displayedTiles.first)
        #expect(tile.player.displayedFrame == 0)

        strip.scrollViewWillBeginDragging(grid)
        try #require(
            await settle { (1...frames / 2).contains(tile.player.displayedFrame ?? 0) },
            "the tile reaches the first half of its loop"
        )
        strip.scrollViewDidEndDecelerating(grid)
        #expect(tile.isAnimating, "it plays out its loop instead of freezing")
        #expect(tile.player.isFinishingLoop)

        try #require(await settle { !tile.isAnimating }, "the loop ends")
        #expect(tile.player.displayedFrame == 0, "it rests on its poster frame")
    }

    /// Slots come back once each loop ends, whatever the number of scrolls,
    /// and never exceed `maxPlayingTiles` meanwhile — here fewer slots than
    /// tiles on screen.
    @Test func slotsComeBackAfterManyScrolls() async throws {
        let engine = warmEngine(art: Self.sheetArt(frames: 10, step: 0.03))
        engine.maxPlayingTiles = 3
        let (strip, window) = hosted(engine)
        defer { tearDown(window) }
        let grid = strip.collectionView
        try #require(strip.displayedTiles.count > 3, "more tiles than slots")
        for _ in 0..<8 {
            strip.scrollViewWillBeginDragging(grid)
            #expect(engine.playingTileCount <= engine.maxPlayingTiles)
            strip.scrollViewDidEndDecelerating(grid)
            #expect(engine.playingTileCount <= engine.maxPlayingTiles)
        }
        try #require(await settle { engine.playingTileCount == 0 }, "every slot is back once the loops end")
    }

    /// A scroll that ends finishes the loops (the slots are kept meanwhile);
    /// leaving the window is a hard stop that frees them at once.
    @Test func endingAScrollFinishesButLeavingTheWindowStops() throws {
        let engine = warmEngine(art: Self.sheetArt(frames: 20, step: 0.05))
        let (strip, window) = hosted(engine)
        defer { tearDown(window) }
        let grid = strip.collectionView
        strip.scrollViewWillBeginDragging(grid)
        let playing = engine.playingTileCount
        try #require(playing > 0)
        strip.scrollViewDidEndDecelerating(grid)
        #expect(engine.playingTileCount == playing, "finishing: the slots are still held")

        strip.scrollViewWillBeginDragging(grid)
        strip.removeFromSuperview()
        #expect(engine.playingTileCount == 0, "a hard stop gives every slot back at once")
        #expect(!strip.isScrolling)
    }

    /// Scrolling again before the loop ends just carries on: no restart.
    @Test func scrollingAgainBeforeTheLoopEndsCarriesOn() async throws {
        let frames = 20
        let (strip, window) = hosted(warmEngine(art: Self.sheetArt(frames: frames, step: 0.03)))
        defer { tearDown(window) }
        let grid = strip.collectionView
        let tile = try #require(strip.displayedTiles.first)

        strip.scrollViewWillBeginDragging(grid)
        try #require(await settle { (1...frames / 2).contains(tile.player.displayedFrame ?? 0) })
        strip.scrollViewDidEndDecelerating(grid)
        let before = try #require(tile.player.displayedFrame)
        strip.scrollViewWillBeginDragging(grid)
        #expect(!tile.player.isFinishingLoop, "the finish is dropped")
        #expect(tile.isAnimating, "still playing")
        let after = try #require(tile.player.displayedFrame)
        #expect(after == before || after == (before + 1) % frames, "no restart: \(before) → \(after)")
        strip.scrollViewDidEndDecelerating(grid)
    }

    /// A touch that stops the glide tells the delegate nothing; the strip
    /// still comes to rest once its scroll view is neither tracked, dragged
    /// nor decelerating.
    @Test func aStoppedGlideComesToRestWithoutADelegateCall() async throws {
        let (strip, window) = hosted(warmEngine(art: Self.sheetArt(frames: 8, step: 0.1)))
        defer { tearDown(window) }
        strip.scrollViewWillBeginDragging(strip.collectionView)
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating })
        try #require(await settle { !strip.isScrolling }, "the settle watch ends the scroll")
        try #require(await settle { strip.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating } },
                     "each emote rests once its loop ends")
    }

    /// A tap hands the emote over and files it under Recent.
    @Test func aTapSelectsAndRemembers() throws {
        let recents = EmoteRecents(defaults: UserDefaults(suiteName: "emote-strip-\(UUID().uuidString)")!)
        let strip = EmoteStripView(engine: EmoteEngine(diskCache: nil), recents: recents)
        var picked: [Emote] = []
        strip.onSelect = { picked.append($0) }
        let lol = try #require(strip.emotes.firstIndex { $0.id == "lol" })
        strip.select(lol)
        #expect(picked.map(\.insertionText) == [":lol:"])
        #expect(recents.ids == ["lol"])
    }
}
