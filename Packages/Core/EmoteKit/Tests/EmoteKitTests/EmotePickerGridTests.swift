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

    private func hosted(_ engine: EmoteEngine, recents: [Emote] = []) -> (EmotePickerView, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)))
        window.isHidden = false
        let panel = EmotePickerView(engine: engine)
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

    /// At rest no tile plays and none holds a slot; every displayed tile is
    /// on its poster frame.
    @Test func atRestNoTilePlays() throws {
        let engine = warmEngine(art: EmoteStripTests.sheetArt(frames: 8, step: 0.1, blank: 2))
        let (panel, window) = hosted(engine)
        defer { tearDown(window) }
        let tiles = panel.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(!panel.isScrolling)
        #expect(tiles.allSatisfy { $0.isShowingArt && !$0.isAnimating && $0.player.isPaused })
        #expect(tiles.allSatisfy { $0.player.displayedFrame == 2 }, "the poster, not a blank opening frame")
        #expect(engine.playingTileCount == 0)

        // Tiles brought in by a jump set in code are still too.
        scroll(panel, to: 900)
        let shown = panel.displayedTiles
        try #require(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.isShowingArt && !$0.isAnimating })
    }

    /// From the drag's start to the end of the glide every displayed tile
    /// plays — the whole screen of them, the ones scrolled in meanwhile too;
    /// once the grid stops, none.
    @Test func displayedTilesPlayOnlyWhileTheGridScrolls() throws {
        let engine = warmEngine()
        let (panel, window) = hosted(engine)
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
        #expect(panel.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating }, "stopped, nothing plays")
        #expect(engine.playingTileCount == 0)

        // A drag let go without a glide stops it as well.
        panel.scrollViewWillBeginDragging(grid)
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating })
        panel.scrollViewDidEndDragging(grid, willDecelerate: false)
        #expect(panel.displayedTiles.allSatisfy { !$0.isAnimating })
    }

    /// Stopping holds each tile on the frame it reached — no reset to the
    /// poster — and the next scroll plays on from there.
    ///
    /// ⚠️ **WAIT FOR A FRAME, NOT FOR A DURATION.** The frame follows the
    /// wall clock round a 4 s loop. A fixed 200 ms sleep came back after ~4 s
    /// on a CI runner whose main thread the neighbouring suites held, and the
    /// loop had wrapped to frame 0 (`held → 0`, run 37143240022). So the
    /// tile is stopped once it shows a frame in the first half of the loop —
    /// far from the wrap, whenever the main thread gets back here.
    @Test func stoppingHoldsTheFrameAndTheNextScrollPlaysOn() async throws {
        let frames = 40
        let (panel, window) = hosted(warmEngine(art: EmoteStripTests.sheetArt(frames: frames, step: 0.1)))
        defer { tearDown(window) }
        let grid = panel.collectionView
        let tile = try #require(panel.displayedTiles.first)
        #expect(tile.player.displayedFrame == 0)

        panel.scrollViewWillBeginDragging(grid)
        try #require(
            await settle { (1...frames / 2).contains(tile.player.displayedFrame ?? 0) },
            "the tile reaches the first half of its loop"
        )
        panel.scrollViewDidEndDecelerating(grid)
        let held = try #require(tile.player.displayedFrame)
        #expect(held > 0, "it moved while the grid scrolled")
        #expect(!tile.isAnimating)

        try await Task.sleep(for: .milliseconds(300))
        #expect(tile.player.displayedFrame == held, "held where it stopped, not reset")

        panel.scrollViewWillBeginDragging(grid)
        let resumed = try #require(tile.player.displayedFrame)
        #expect(resumed == held || resumed == (held + 1) % frames, "plays on from \(held): \(resumed)")
        panel.scrollViewDidEndDecelerating(grid)
    }

    /// A touch that stops the glide tells the delegate nothing; the grid
    /// still comes to rest.
    @Test func aStoppedGlideComesToRestWithoutADelegateCall() async throws {
        let (panel, window) = hosted(warmEngine())
        defer { tearDown(window) }
        panel.scrollViewWillBeginDragging(panel.collectionView)
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating })
        try #require(await settle { !panel.isScrolling }, "the settle watch ends the scroll")
        #expect(panel.displayedTiles.allSatisfy { $0.isShowingArt && !$0.isAnimating })
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
