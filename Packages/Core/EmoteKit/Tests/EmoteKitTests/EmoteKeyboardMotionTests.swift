import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The emote keyboard's emotes always animate (#926): their motion is the
/// keyboard's content, so idle calm (#650) does not rest them — only Reduce
/// Motion and Low Power Mode do, with what already stills every emote (Animate
/// Emojis off, Power Saving, overheating). The rest of the app's decoration
/// keeps the app's policy.
///
/// ⚠️ SYNCHRONOUS, AND IT MUST STAY SO: `AnimatedIconView.forcedPolicy` and
/// `EmoteMotion.keyboardConditions` are process-wide; a test that awaited
/// while forcing them would hand them to the suites beside it.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteKeyboardMotionTests {
    private typealias Conditions = EmoteMotion.KeyboardConditions

    // MARK: - The gate, per condition

    @Test func nothingSetPlays() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions()) == .full)
    }

    /// ⚠️ THE POINT OF #926: a resting app rests decoration, not the keyboard.
    @Test func idleCalmDoesNotStillTheKeyboard() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(idleCalm: true)) == .full)
    }

    @Test func reduceMotionStillsIt() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(reducesMotion: true)) == .still)
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(reducesMotion: true, idleCalm: true)) == .still)
    }

    /// Still, not the decoration's halved rate.
    @Test func lowPowerModeStillsIt() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(lowPower: true)) == .still)
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(lowPower: true, idleCalm: true)) == .still)
    }

    /// The viewer's own switch (and Power Saving, which turns it off).
    @Test func animateEmojisOffStillsIt() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(animatesEmotes: false)) == .still)
    }

    @Test func overheatingStillsIt() {
        #expect(EmoteMotion.keyboardPolicy(for: Conditions(overheated: true)) == .still)
    }

    // MARK: - Tiles

    /// Two-frame-or-more art resident for every emote, so tiles present
    /// synchronously and nothing bakes.
    private func warmEngine() -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        let art = EmoteStripTests.sheetArt(frames: 8, step: 0.1)
        for emote in engine.catalog.all {
            engine.insert(art, for: emote, pixelSide: EmoteTileView.pixelSide, motion: .loop)
        }
        return engine
    }

    private func hostedTile(_ engine: EmoteEngine, asContent: Bool) throws -> (EmoteTileView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let tile = EmoteTileView(frame: CGRect(x: 20, y: 20, width: 44, height: 44))
        window.addSubview(tile)
        let fire = try #require(engine.catalog.emote(id: "noto:1f525"))
        tile.playsAsContent = asContent
        tile.configure(fire, engine: engine, prefersAnimation: true)
        return (tile, window)
    }

    /// Idle calm stills the app's decoration through `AnimatedIconView`'s
    /// policy — forced still here, as a resting app has it. A keyboard tile
    /// plays on; a strip or rail tile (decoration) rests, as before.
    @Test func aKeyboardTilePlaysWhileDecorationRests() throws {
        AnimatedIconView.forcedPolicy = .still
        EmoteMotion.keyboardConditions = { Conditions(idleCalm: true) }
        defer {
            AnimatedIconView.forcedPolicy = nil
            EmoteMotion.keyboardConditions = { .current }
        }
        let engine = warmEngine()

        let (keyboard, w1) = try hostedTile(engine, asContent: true)
        defer { w1.isHidden = true }
        #expect(keyboard.isAnimating, "a resting app stilled the keyboard")

        let (decoration, w2) = try hostedTile(engine, asContent: false)
        defer { w2.isHidden = true }
        #expect(!decoration.isAnimating, "witness: the app's decoration rests")
    }

    /// Low Power Mode stills a keyboard tile — while the app's decoration
    /// would still play (at its halved rate).
    @Test func lowPowerStillsAKeyboardTile() throws {
        EmoteMotion.keyboardConditions = { Conditions(lowPower: true) }
        defer { EmoteMotion.keyboardConditions = { .current } }
        let (tile, window) = try hostedTile(warmEngine(), asContent: true)
        defer { window.isHidden = true }
        #expect(!tile.isAnimating)
        #expect(tile.player.playbackPolicy == .still)
    }

    @Test func reduceMotionStillsAKeyboardTile() throws {
        EmoteMotion.keyboardConditions = { Conditions(reducesMotion: true) }
        defer { EmoteMotion.keyboardConditions = { .current } }
        let (tile, window) = try hostedTile(warmEngine(), asContent: true)
        defer { window.isHidden = true }
        #expect(!tile.isAnimating)
        #expect(tile.showsGlyph, "an emoji's still is its system glyph")
    }

    // MARK: - The panel

    private func hostedPanel(_ engine: EmoteEngine) -> (EmotePickerView, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)))
        window.isHidden = false
        let panel = EmotePickerView(engine: engine)
        panel.reload(recents: [])
        panel.frame = CGRect(x: 0, y: 874 - 328, width: 402, height: 328)
        window.addSubview(panel)
        panel.layoutIfNeeded()
        panel.collectionView.layoutIfNeeded()
        return (panel, window)
    }

    /// The panel's tiles are keyboard tiles: they loop at rest through idle
    /// calm, stop the moment Low Power comes on, and play again when it goes —
    /// re-dressed in place, with no scroll.
    @Test func thePanelFollowsTheKeyboardPolicyAndItsChanges() throws {
        AnimatedIconView.forcedPolicy = .still
        var conditions = Conditions(idleCalm: true)
        EmoteMotion.keyboardConditions = { conditions }
        defer {
            AnimatedIconView.forcedPolicy = nil
            EmoteMotion.keyboardConditions = { .current }
        }
        let (panel, window) = hostedPanel(warmEngine())
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        let tiles = panel.displayedTiles
        try #require(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.isAnimating }, "a resting app stilled the keyboard's tiles")

        conditions.lowPower = true
        panel.redressIfPolicyChanged()
        #expect(panel.displayedTiles.allSatisfy { !$0.isAnimating }, "Low Power left the keyboard playing")

        conditions.lowPower = false
        panel.redressIfPolicyChanged()
        #expect(panel.displayedTiles.allSatisfy { $0.isAnimating }, "the tiles did not play again")
    }

    /// A change while the panel is down touches nothing: its tiles hold no
    /// art off screen, and dress themselves afresh when it comes back.
    @Test func aChangeWhileThePanelIsDownDressesNothing() throws {
        var conditions = Conditions()
        EmoteMotion.keyboardConditions = { conditions }
        defer { EmoteMotion.keyboardConditions = { .current } }
        let (panel, window) = hostedPanel(warmEngine())
        defer { window.isHidden = true }
        let tiles = panel.displayedTiles
        try #require(!tiles.isEmpty)
        panel.removeFromSuperview()

        conditions.reducesMotion = true
        panel.redressIfPolicyChanged()
        #expect(tiles.allSatisfy { !$0.isShowingArt }, "a panel taken down was dressed again")
    }
}
