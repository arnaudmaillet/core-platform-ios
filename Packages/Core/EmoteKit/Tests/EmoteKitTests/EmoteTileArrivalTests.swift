import Testing
import UIKit
@testable import EmoteKit

/// A keyboard or strip tile whose animated art is on its way (#731): its
/// place stays empty — no system glyph behind — and the art bounces in.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteTileArrivalTests {
    /// Art that takes 300 ms to come, then lands — INJECTED, never a real
    /// Lottie bake (#1686). What these tests check is the tile: empty while
    /// the art is on its way, then the bounce. A real bake runs on the ONE
    /// serial bake thread the whole test process shares, and commits only
    /// while the main thread sleeps (`EmoteBakeQueue`): on a loaded CI runner
    /// this test's bake waited behind every parallel suite's for its whole
    /// 8 000-look budget (~136 s, runs 39822335612 and 40085406750) and its
    /// art "never came". The baker has suites of its own.
    private func slowEngine(_ answers: Bool = true) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return answers ? EmoteLabelTests.syntheticArt(side: side, frames: 4) : nil
        }
        // The skeleton under default conditions, whatever the host's Low
        // Power or Reduce Motion says: the bounce is what is counted.
        engine.skeletonConditions = { EmoteSkeleton.Conditions() }
        return engine
    }

    private func hostedTile() -> (EmoteTileView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let tile = EmoteTileView(frame: CGRect(x: 20, y: 20, width: 44, height: 44))
        window.addSubview(tile)
        return (tile, window)
    }

    @Test func anAnimatedTileOnItsWayShowsNothingThenBouncesIn() async throws {
        let engine = slowEngine()
        // An emoji, as the keyboard shows them.
        let lol = try #require(engine.catalog.emote(id: "noto:1f525"))
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(lol, engine: engine, prefersAnimation: true)
        #expect(!tile.isShowingArt)
        // 300 ms of art on its way: looks, not a clock, for a frozen process.
        #expect(await settle(looks: 4_000) { tile.isShowingArt }, "the art never came")
        #expect(tile.bounceInCount == 1, "the art landed without its bounce")
    }

    /// No art after all: a still skeleton — never the glyph (#1504).
    @Test func aTileWithNoArtHoldsAStillSkeleton() async throws {
        let engine = slowEngine(false)
        let lol = try #require(engine.catalog.emote(id: "noto:1f525"))
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(lol, engine: engine, prefersAnimation: true)
        #expect(await settle(looks: 4_000) { tile.showsFailedSkeleton }, "an emote with no art showed no still skeleton")
        #expect(!tile.isShowingArt)
    }

    /// Art already resident lands at once, without a bounce.
    @Test func residentArtLandsWithoutABounce() throws {
        let engine = EmoteEngine(diskCache: nil)
        let lol = try #require(engine.catalog.emote(id: "lol"))
        engine.insert(EmoteLabelTests.syntheticArt(side: EmoteTileView.pixelSide), for: lol,
                      pixelSide: EmoteTileView.pixelSide, motion: .loop)
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(lol, engine: engine, prefersAnimation: true)
        #expect(tile.isShowingArt)
        #expect(tile.bounceInCount == 0, "art already there bounced in")
    }
}
