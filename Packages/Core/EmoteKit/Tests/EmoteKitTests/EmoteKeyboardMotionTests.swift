import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The emote keyboard's emotes always animate (#926): their motion is the
/// keyboard's content, so idle calm (#650) does not rest them — only Reduce
/// Motion and Low Power Mode do, with what already stills every emote (Animate
/// Emojis off, Power Saving, overheating). Since #1072 no emote rests in idle
/// calm; the keyboard differs from the rest only under Low Power.
///
/// ⚠️ SYNCHRONOUS, AND IT MUST STAY SO: `AnimatedIconView.forcedPolicy`,
/// `EmoteMotion.keyboardConditions` and `EmoteMotion.conditions` are
/// process-wide; a test that awaited
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

    /// Idle calm rests neither a keyboard tile nor any other: a strip or rail
    /// tile, which #650 rested with the app's decoration, plays through it
    /// too now (#1072). The witness is a gate both share: Reduce Motion
    /// stills them both.
    @Test func keyboardAndStripTilesBothPlayThroughIdleCalm() throws {
        var conditions = Conditions(idleCalm: true)
        EmoteMotion.keyboardConditions = { conditions }
        EmoteMotion.conditions = { conditions }
        defer {
            EmoteMotion.keyboardConditions = { .current }
            EmoteMotion.conditions = { .current }
        }
        let engine = warmEngine()

        let (keyboard, w1) = try hostedTile(engine, asContent: true)
        defer { w1.isHidden = true }
        #expect(keyboard.isAnimating, "a resting app stilled the keyboard")

        let (strip, w2) = try hostedTile(engine, asContent: false)
        defer { w2.isHidden = true }
        #expect(strip.isAnimating, "a resting app stilled a strip tile")
        #expect(strip.player.playbackPolicy == .full)

        conditions.reducesMotion = true
        let (stilled, w3) = try hostedTile(engine, asContent: false)
        defer { w3.isHidden = true }
        #expect(!stilled.isAnimating, "witness: Reduce Motion left a strip tile playing")
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

    // MARK: - The `:query` strip (#958)

    private func hostedStrip(_ engine: EmoteEngine) throws -> (EmoteSuggestionStrip, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)))
        window.isHidden = false
        let strip = EmoteSuggestionStrip(engine: engine)
        let matches = Array(engine.catalog.all.filter(\.isUnicodeEmoji).prefix(4))
        try #require(matches.count == 4)
        strip.frame = CGRect(x: 16, y: 600, width: EmoteSuggestionStrip.fittingWidth(count: 4),
                             height: EmoteSuggestionStrip.height)
        window.addSubview(strip)
        strip.show(matches)
        strip.layoutIfNeeded()
        return (strip, window)
    }

    /// The strip's tiles are keyboard tiles: a resting app (decoration forced
    /// still, as idle calm has it) leaves them looping.
    @Test func theQueryStripPlaysWhileDecorationRests() throws {
        AnimatedIconView.forcedPolicy = .still
        EmoteMotion.keyboardConditions = { Conditions(idleCalm: true) }
        defer {
            AnimatedIconView.forcedPolicy = nil
            EmoteMotion.keyboardConditions = { .current }
        }
        let (strip, window) = try hostedStrip(warmEngine())
        defer { window.isHidden = true }
        let tiles = strip.displayedTiles
        try #require(tiles.count == 4)
        #expect(tiles.allSatisfy { $0.isAnimating }, "a resting app stilled the :query strip")
    }

    /// Each gating condition stills the strip, idle calm or not.
    @Test(arguments: ["reducesMotion", "lowPower", "animateEmojisOff", "overheated"])
    func eachConditionStillsTheQueryStrip(_ condition: String) throws {
        var gated = Conditions(idleCalm: true)
        switch condition {
        case "reducesMotion": gated.reducesMotion = true
        case "lowPower": gated.lowPower = true
        case "animateEmojisOff": gated.animatesEmotes = false
        default: gated.overheated = true
        }
        let gate = gated
        EmoteMotion.keyboardConditions = { gate }
        defer { EmoteMotion.keyboardConditions = { .current } }
        let (strip, window) = try hostedStrip(warmEngine())
        defer { window.isHidden = true }
        let tiles = strip.displayedTiles
        try #require(tiles.count == 4)
        #expect(tiles.allSatisfy { !$0.isAnimating }, "\(condition) left the :query strip playing")
    }

    /// A change while the strip shows re-dresses its tiles in place: Low
    /// Power on stills them, off plays them again.
    @Test func theQueryStripFollowsAChangeInPlace() throws {
        var conditions = Conditions()
        EmoteMotion.keyboardConditions = { conditions }
        defer { EmoteMotion.keyboardConditions = { .current } }
        let (strip, window) = try hostedStrip(warmEngine())
        defer { window.isHidden = true }
        try #require(strip.displayedTiles.count == 4)
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating })

        conditions.lowPower = true
        strip.redressIfPolicyChanged()
        #expect(strip.displayedTiles.allSatisfy { !$0.isAnimating }, "Low Power left the strip playing")

        conditions.lowPower = false
        strip.redressIfPolicyChanged()
        #expect(strip.displayedTiles.allSatisfy { $0.isAnimating }, "the strip did not play again")
    }
}
