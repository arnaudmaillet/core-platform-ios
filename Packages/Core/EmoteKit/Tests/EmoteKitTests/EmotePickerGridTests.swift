import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The emote panel's grid: our own catalogue drawn as its own art (never the
/// system glyphs), tiles with nothing behind them, and art that moves only
/// while the grid scrolls — the strip's rule.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmotePickerGridTests {
    /// The stock Face ID keyboard's height on a 402pt Pro.
    private static let panelSize = CGSize(width: 402, height: 328)

    /// Two-frame-or-more art resident for every emote, so tiles present
    /// synchronously and nothing bakes.
    private func warmEngine(art: AnimatedIconArt = EmoteStripTests.sheetArt(frames: 8, step: 0.1)) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        for emote in engine.catalog.all {
            engine.insert(art, for: emote, pixelSide: EmoteTileView.pixelSide, motion: .loop)
        }
        return engine
    }

    /// `playsAtRest: false` hosts the panel on the strip's and the rail's
    /// rule (#559: play while scrolling, finish the loop, rest) — the shared
    /// `EmoteScrollPlayback` rules are pinned through it; the keyboard itself
    /// plays at rest (#731).
    private func hosted(
        _ engine: EmoteEngine, recents: [Emote] = [], playsAtRest: Bool = true
    ) -> (EmotePickerView, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)))
        window.isHidden = false
        let panel = EmotePickerView(engine: engine)
        panel.scrollPlaybackForTesting.playsAtRest = playsAtRest
        panel.reload(recents: recents)
        panel.frame = CGRect(origin: CGPoint(x: 0, y: 874 - Self.panelSize.height), size: Self.panelSize)
        window.addSubview(panel)
        panel.layoutIfNeeded()
        panel.collectionView.layoutIfNeeded()
        return (panel, window)
    }

    private func tearDown(_ window: UIWindow) {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }

    private func scroll(_ panel: EmotePickerView, to y: CGFloat) {
        let grid = panel.collectionView
        grid.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        grid.layoutIfNeeded()
    }

    // MARK: - What it lists

    /// The sections together are exactly the catalogue the strip lists —
    /// every emote once, the GIF emotes included — each in catalogue order,
    /// Recent on top when there is one.
    @Test func itListsTheWholeCatalogueOnce() throws {
        let catalog = EmoteCatalog.shared
        let panel = EmotePickerView(engine: EmoteEngine(diskCache: nil))
        panel.reload(recents: [])
        let listed = panel.sections.flatMap(\.emotes).map(\.id)
        #expect(listed.count == catalog.all.count)
        #expect(Set(listed) == Set(catalog.all.map(\.id)))
        #expect(Set(listed) == Set(EmoteStripView(engine: EmoteEngine(diskCache: nil), recents: nil).emotes.map(\.id)))
        for gif in ["lol", "blush"] { #expect(listed.contains(gif), "the \(gif) GIF emote") }
        let rank = Dictionary(uniqueKeysWithValues: catalog.all.enumerated().map { ($1.id, $0) })
        for section in panel.sections {
            let order = section.emotes.compactMap { rank[$0.id] }
            #expect(order == order.sorted(), "\(section.id) in catalogue order")
        }
        #expect(panel.sections.first?.emotes.map(\.id) == EmoteCatalog.house.map(\.id))

        let fire = try #require(catalog.emote(id: "noto:1f525"))
        panel.reload(recents: [fire])
        #expect(panel.sections.first?.id == "recent")
        #expect(panel.sections.first?.emotes == [fire])
    }

    /// Every displayed tile asks for its own art — a Noto emoji as much as a
    /// house emote — instead of resting on the system glyph.
    @Test func everyDisplayedTileAsksForItsArt() throws {
        // Cold: nothing resident, every bake held back by the delay.
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.bakeDelay = .seconds(30)
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        let tiles = panel.displayedTiles
        try #require(tiles.count > EmoteCatalog.house.count, "the first Noto section is on screen")
        let noto = tiles.compactMap(\.emote).filter(\.isUnicodeEmoji)
        try #require(!noto.isEmpty)
        for emote in noto {
            #expect(engine.isBaking(emote, pixelSide: EmoteTileView.pixelSide, motion: .loop), "\(emote.id) asks")
        }
    }

    /// Warm, every displayed tile shows art; a tile scrolled off lets it go.
    @Test func displayedTilesShowArtAndOnlyThose() throws {
        let engine = warmEngine()
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        let first = panel.displayedTiles
        try #require(!first.isEmpty)
        #expect(first.allSatisfy { $0.isShowingArt })
        scroll(panel, to: 1200)
        #expect(panel.displayedTiles.allSatisfy { $0.isShowingArt })
        let offScreen = first.filter { tile in !panel.displayedTiles.contains { $0 === tile } }
        #expect(offScreen.allSatisfy { !$0.isShowingArt }, "scrolled off, the art goes")

        panel.removeFromSuperview()
        #expect(panel.displayedTiles.allSatisfy { !$0.isShowingArt }, "a panel taken down holds no sheets")
    }

    // MARK: - Nothing behind the emote

    /// No cell, content view, background configuration or tile paints
    /// anything; the press plate is translucent and shows only while pressed.
    @Test func tilesHaveNoBackground() throws {
        let (panel, window) = hosted(warmEngine())
        defer { tearDown(window) }
        #expect(panel.collectionView.backgroundColor == .clear)
        let grid = panel.collectionView
        let cells = grid.indexPathsForVisibleItems.compactMap { grid.cellForItem(at: $0) as? EmoteTileCell }
        try #require(!cells.isEmpty)
        for cell in cells {
            // The background configuration owns the cell's colour (and
            // clears `backgroundColor` to nil): either way, nothing painted.
            #expect(cell.backgroundColor == nil || cell.backgroundColor == .clear)
            #expect(cell.contentView.backgroundColor == .clear)
            #expect(cell.backgroundConfiguration?.backgroundColor == .clear)
            #expect(cell.backgroundView == nil && cell.selectedBackgroundView == nil)
            #expect(cell.tile.backgroundColor == .clear)
            #expect(cell.tile.player.backgroundColor == .clear)
            #expect(cell.pressPlate.opacity == 0, "no plate at rest")
        }

        let cell = try #require(cells.first)
        cell.isHighlighted = true
        #expect(cell.pressPlate.opacity == 1)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let fill = UIColor.tertiarySystemFill.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var alpha: CGFloat = 0
            fill.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #expect(alpha > 0 && alpha < 0.5, "\(style.rawValue): a translucent plate, never a slab")
        }
        cell.isHighlighted = false
        #expect(cell.pressPlate.opacity == 0)
        // A tap leaves nothing selected behind it.
        panel.select(IndexPath(item: 0, section: 0))
        #expect(grid.indexPathsForSelectedItems?.isEmpty ?? true)
    }

    // MARK: - What plays

    /// ⚠️ THE KEYBOARD'S EMOTES LOOP FROM THE MOMENT THEY SHOW (#731, the
    /// owner's call over #559's still-at-rest rule): at rest every displayed
    /// tile plays, each holding a slot, and tiles a jump brings in play too.
    @Test func atRestTheKeyboardsTilesLoop() throws {
        let engine = warmEngine(art: EmoteStripTests.sheetArt(frames: 8, step: 0.1, blank: 2))
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        let tiles = panel.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(!panel.isScrolling)
        #expect(tiles.allSatisfy { $0.isAnimating }, "a tile at rest is still")
        #expect(engine.playingTileCount == tiles.count)

        scroll(panel, to: 900)
        let shown = panel.displayedTiles
        try #require(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.isAnimating }, "a tile brought in by a jump is still")
        #expect(engine.playingTileCount == shown.count, "the slots follow the screen")
    }

    /// A scroll's end does not still them: the loops go on.
    @Test func aScrollsEndLeavesTheKeyboardLooping() async throws {
        let engine = warmEngine(art: EmoteStripTests.sheetArt(frames: 20, step: 0.03))
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        let grid = panel.collectionView
        panel.scrollViewWillBeginDragging(grid)
        panel.scrollViewDidEndDecelerating(grid)
        let tile = try #require(panel.displayedTiles.first)
        #expect(tile.isAnimating)
        #expect(!tile.player.isFinishingLoop, "the loop is being played out to a rest")
        // Still moving well after a loop's length.
        try await Task.sleep(for: .milliseconds(800))
        #expect(tile.isAnimating, "the tile came to rest")
    }

    /// The budget still caps them; a tile denied a slot tries again when
    /// the grid moves.
    @Test func theBudgetStillCapsTheKeyboard() throws {
        let engine = warmEngine()
        engine.maxPlayingTiles = 3
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        try #require(panel.displayedTiles.count > 3, "more tiles than slots")
        #expect(panel.displayedTiles.filter(\.isAnimating).count == 3)
        #expect(engine.playingTileCount == 3)
        scroll(panel, to: 900)
        let grid = panel.collectionView
        panel.scrollViewWillBeginDragging(grid)
        panel.scrollViewDidEndDecelerating(grid)
        #expect(engine.playingTileCount <= 3)
        #expect(panel.displayedTiles.filter(\.isAnimating).count == engine.playingTileCount,
                "a slot is held by a tile off screen")
    }

    /// Leaving the window holds nothing: no slot, no art.
    @Test func leavingTheWindowReleasesEverySlot() throws {
        let engine = warmEngine()
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        try #require(engine.playingTileCount > 0)
        panel.removeFromSuperview()
        #expect(engine.playingTileCount == 0, "a keyboard taken down kept playing")
    }

    // MARK: - The shared rule (#559), through a panel hosted on it

    /// From the drag's start to the end of the glide every displayed tile
    /// plays — the whole screen of them, the ones scrolled in meanwhile too;
    /// once the grid stops, none.
    @Test func displayedTilesPlayOnlyWhileTheGridScrolls() async throws {
        let engine = warmEngine()
        let (panel, window) = hosted(engine, playsAtRest: false)
        defer { tearDown(window) }
        let grid = panel.collectionView

        panel.scrollViewWillBeginDragging(grid)
        #expect(panel.isScrolling)
        let first = panel.displayedTiles
        #expect(first.count > 40, "\(first.count): a whole screen of tiles")
        #expect(first.allSatisfy { $0.isAnimating }, "the drag starts every displayed tile")
        #expect(engine.playingTileCount == first.count)
        #expect(engine.animatedCount == 0, "the labels' budget is untouched")

        for step in 1...4 {
            scroll(panel, to: CGFloat(step) * 300)
            let shown = panel.displayedTiles
            try #require(!shown.isEmpty)
            #expect(shown.allSatisfy { $0.isAnimating }, "step \(step): a tile scrolled in plays")
            #expect(engine.playingTileCount == shown.count, "step \(step): the slots follow the screen")
        }

        panel.scrollViewDidEndDragging(grid, willDecelerate: true)
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating }, "the glide still plays")
        panel.scrollViewDidEndDecelerating(grid)
        #expect(!panel.isScrolling)
        // #559: each emote finishes its loop first, then rests.
        try #require(await settle { panel.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating } },
                     "stopped once their loops end, nothing plays")
        #expect(engine.playingTileCount == 0)

        // A drag let go without a glide stops it as well.
        panel.scrollViewWillBeginDragging(grid)
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating })
        panel.scrollViewDidEndDragging(grid, willDecelerate: false)
        try #require(await settle { panel.displayedTiles.allSatisfy { !$0.isAnimating } })
    }

    @Test func aScrollThatEndsLetsEachEmoteFinishItsLoop() async throws {
        // #559: an emote never stops posed mid-gesture. A 0.6 s loop keeps
        // the wait short; frames are waited for, never timed.
        let frames = 20
        let (panel, window) = hosted(warmEngine(art: EmoteStripTests.sheetArt(frames: frames, step: 0.03)), playsAtRest: false)
        defer { tearDown(window) }
        let grid = panel.collectionView
        let tile = try #require(panel.displayedTiles.first)
        #expect(tile.player.displayedFrame == 0)

        // ⚠️ THE GRID COUNTS AS MOVING until the scroll is ended by hand
        // (#621): without it the settle watch ends the scroll after 250 ms and
        // the tile plays its one loop out and rests on frame 0 — a starved
        // runner that misses that single pass can never see a frame move.
        // Moving, the tile loops and every pass is another chance.
        panel.scrollPlaybackForTesting.gridIsMoving = { _ in true }
        panel.scrollViewWillBeginDragging(grid)
        try #require(await settle { tile.isAnimating }, "the drag did not start the tile")
        // Any frame past the poster: a 0.3 s window (frames 1…10) is narrower
        // than a starved main thread's gaps (see EmoteStripTests).
        try #require(
            await settle { (tile.player.displayedFrame ?? 0) != 0 },
            "the tile never left its poster frame"
        )
        panel.scrollViewDidEndDecelerating(grid)
        #expect(tile.isAnimating, "it plays out its loop instead of freezing")
        #expect(tile.player.isFinishingLoop)

        try #require(await settle { !tile.isAnimating }, "the loop ends")
        #expect(tile.player.displayedFrame == 0, "it rests on its poster frame")
    }

    /// Scrolling again before the loop ends just carries on: no restart.
    @Test func scrollingAgainBeforeTheLoopEndsCarriesOn() async throws {
        let frames = 20
        let (panel, window) = hosted(warmEngine(art: EmoteStripTests.sheetArt(frames: frames, step: 0.03)), playsAtRest: false)
        defer { tearDown(window) }
        let grid = panel.collectionView
        let tile = try #require(panel.displayedTiles.first)
        // ⚠️ THE GRID COUNTS AS MOVING for the length of this hand-driven
        // scroll (#621). Without it the settle watch sees no gesture, ends the
        // scroll after 250 ms, and the tile plays out and rests on frame 0 —
        // so on a starved runner that misses frames 1…10 first, the wait
        // below can never hold. Moving, the tile loops and the window recurs.
        panel.scrollPlaybackForTesting.gridIsMoving = { _ in true }

        panel.scrollViewWillBeginDragging(grid)
        // Any frame past the poster, not a 0.3 s window (see EmoteStripTests).
        try #require(await settle { (tile.player.displayedFrame ?? 0) != 0 })
        panel.scrollViewDidEndDecelerating(grid)
        let before = try #require(tile.player.displayedFrame)
        panel.scrollViewWillBeginDragging(grid)
        #expect(!tile.player.isFinishingLoop, "the finish is dropped")
        #expect(tile.isAnimating, "still playing")
        let after = try #require(tile.player.displayedFrame)
        #expect(after == before || after == (before + 1) % frames, "no restart: \(before) → \(after)")
        panel.scrollViewDidEndDecelerating(grid)
    }

    /// A touch that stops the glide tells the delegate nothing; the grid
    /// still comes to rest.
    @Test func aStoppedGlideComesToRestWithoutADelegateCall() async throws {
        let (panel, window) = hosted(warmEngine(), playsAtRest: false)
        defer { tearDown(window) }
        panel.scrollViewWillBeginDragging(panel.collectionView)
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating })
        try #require(await settle { !panel.isScrolling }, "the settle watch ends the scroll")
        try #require(await settle { panel.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating } },
                     "each emote rests once its loop ends")
    }

    // MARK: - A tap

    /// A tap hands over the emote as written — a house `:code:` or the
    /// emoji itself — wherever it sits in the grid.
    @Test func aTapHandsOverTheEmoteAsWritten() throws {
        let panel = EmotePickerView(engine: EmoteEngine(diskCache: nil))
        panel.reload(recents: [])
        var picked: [String] = []
        panel.onSelect = { picked.append($0.insertionText) }
        let house = try #require(panel.sections.firstIndex { $0.id == EmoteSection.house.rawValue })
        let lol = try #require(panel.sections[house].emotes.firstIndex { $0.id == "lol" })
        panel.select(IndexPath(item: lol, section: house))
        let smileys = try #require(panel.sections.firstIndex { $0.id == EmoteSection.smileys.rawValue })
        panel.select(IndexPath(item: 0, section: smileys))
        #expect(picked == [":lol:", panel.sections[smileys].emotes[0].glyph])
    }
}
