import Testing
import UIKit
@testable import EmoteKit

/// A keyboard or strip tile whose animated art is on its way (#731): its
/// place stays empty — no system glyph behind — and the art bounces in.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteTileArrivalTests {
    private func slowEngine(_ answers: Bool = true) -> EmoteEngine {
        EmoteEngine(diskCache: nil, animationProvider: { emote in
            try? await Task.sleep(for: .milliseconds(300))
            return answers ? await EmoteEngine.bundledAnimation(for: emote) : nil
        })
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
        // An emoji: its loop is a Lottie, made by the provider above.
        let lol = try #require(engine.catalog.emote(id: "noto:1f525"))
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(lol, engine: engine, prefersAnimation: true)
        #expect(!tile.showsGlyph, "a glyph stands in for the art on its way")
        #expect(!tile.isShowingArt)
        var bounced = false
        #expect(await settle {
            bounced = bounced || tile.isBouncingIn
            return tile.isShowingArt
        }, "the art never came")
        #expect(bounced || tile.isBouncingIn, "the art landed without its bounce")
        #expect(!tile.showsGlyph)
    }

    /// No art after all: the glyph is all there is, so it shows.
    @Test func aTileWithNoArtFallsBackToItsGlyph() async throws {
        let engine = slowEngine(false)
        let lol = try #require(engine.catalog.emote(id: "noto:1f525"))
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(lol, engine: engine, prefersAnimation: true)
        #expect(await settle { tile.showsGlyph }, "an emote with no art showed nothing")
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
        #expect(!tile.isBouncingIn, "art already there bounced in")
    }
}
