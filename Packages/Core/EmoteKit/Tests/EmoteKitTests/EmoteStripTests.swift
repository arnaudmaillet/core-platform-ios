import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The conversation footer's strip: every emote the build ships, every
/// DISPLAYED tile animating and nothing else holding a slot, and a scroll view
/// that runs the capsule's whole width.
@MainActor
@Suite(.serialized)
struct EmoteStripTests {
    private static let size = CGSize(width: 300, height: 48)

    /// An engine with two-frame art resident for every emote, so tiles present
    /// synchronously — the warm-cache path — and nothing bakes.
    private func warmEngine() -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        for emote in engine.catalog.all {
            engine.insert(
                EmoteLabelTests.syntheticArt(side: EmoteTileView.pixelSide), for: emote,
                pixelSide: EmoteTileView.pixelSide, motion: .loop
            )
        }
        return engine
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

    /// Every displayed tile animates; a tile scrolled out gives its slot back
    /// at once, so the slots in use never exceed what is on screen.
    @Test func displayedTilesAnimateAndOnlyThose() throws {
        let engine = warmEngine()
        let (strip, window) = hosted(engine)
        defer { tearDown(window) }
        let tiles = strip.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.isShowingArt }, "every displayed tile animates, emoji or house emote")
        #expect(engine.animatedCount == tiles.count)

        let grid = strip.collectionView
        for step in 1...6 {
            grid.setContentOffset(CGPoint(x: CGFloat(step) * 400, y: grid.contentOffset.y), animated: false)
            grid.layoutIfNeeded()
            let shown = strip.displayedTiles
            #expect(shown.allSatisfy { $0.isShowingArt })
            #expect(engine.animatedCount == shown.count, "step \(step): \(engine.animatedCount) slots, \(shown.count) shown")
        }

        strip.removeFromSuperview()
        #expect(engine.animatedCount == 0, "off the window, nothing plays")
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
