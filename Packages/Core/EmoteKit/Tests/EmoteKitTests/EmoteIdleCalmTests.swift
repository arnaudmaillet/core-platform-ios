import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// Animated emotes in text keep playing through idle calm (#1072, the
/// owner's decision of 2026-10-13): idle calm (#580/#650) rests the app's
/// decoration, and an emote in a caption or a comment froze while the viewer
/// simply read. What already stilled every emote still does: Reduce Motion,
/// Animate Emojis off, Power Saving, overheating — and Low Power keeps its
/// half rate. The map's markers, far more numerous, still rest (the owner's
/// second decision on #1072).
///
/// ⚠️ IDLE CALM IS INJECTED (`EmoteMotion.conditions`), never the app-wide
/// `IdleCalm`. And the tests that force it are SYNCHRONOUS: the seam is
/// process-wide while set, and an await would hand it to the suites beside.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteIdleCalmTests {
    private typealias Conditions = EmoteMotion.Conditions
    private let font = UIFont.systemFont(ofSize: 17)

    private func warmEngine() throws -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        let fire = try #require(engine.catalog.emote(id: "noto:1f525"))
        for side in EmoteEngine.pixelBuckets {
            engine.insert(EmoteLabelTests.syntheticArt(side: side), for: fire, pixelSide: side, motion: .loop)
            engine.insert(EmoteLabelTests.syntheticArt(side: side, frames: 1), for: fire, pixelSide: side, motion: .still)
        }
        return engine
    }

    private func hostedLabel(engine: EmoteEngine) -> (EmoteLabel, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.setEmoteText("so 🔥 good")
        window.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 300, height: 30)
        label.layoutIfNeeded()
        return (label, window)
    }

    /// The composer's emote view, on its own in a window: what the field
    /// overlays where TextKit put the attachment.
    private func hostedAttachment(engine: EmoteEngine) throws -> (EmoteAttachmentView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let fire = try #require(engine.catalog.emote(id: "noto:1f525"))
        let view = EmoteAttachmentView(emote: fire, engine: engine, still: nil, side: 22)
        view.frame.origin = CGPoint(x: 20, y: 20)
        window.addSubview(view)
        return (view, window)
    }

    private func playing(_ art: UIView?) -> Bool {
        guard let player = art as? AnimatedIconView else { return false }
        return player.isAnimating && !player.isPaused
    }

    // MARK: - The policy

    /// ⚠️ THE POINT OF #1072: a resting app rests decoration, not emotes.
    @Test func idleCalmDoesNotStillEmotes() {
        #expect(EmoteMotion.policy(for: Conditions()) == .full)
        #expect(EmoteMotion.policy(for: Conditions(idleCalm: true)) == .full)
        // Low Power keeps its half rate, resting or not.
        #expect(EmoteMotion.policy(for: Conditions(lowPower: true, idleCalm: true)) == .reduced)
    }

    enum Gate: String, CaseIterable, CustomTestStringConvertible {
        case reduceMotion, animateEmojisOff, powerSaving, overheated
        /// Each gate, with idle calm on too: it changes nothing.
        var conditions: EmoteMotion.Conditions {
            var gated = EmoteMotion.Conditions(idleCalm: true)
            switch self {
            case .reduceMotion: gated.reducesMotion = true
            case .animateEmojisOff: gated.animatesEmotes = false
            // Power Saving turns on Reduce Motion and turns off Animate
            // Emojis (`PowerSavingPreference`): both readings.
            case .powerSaving:
                gated.reducesMotion = true
                gated.animatesEmotes = false
            case .overheated: gated.overheated = true
            }
            return gated
        }
        var testDescription: String { rawValue }
    }

    /// What stilled every emote still does, on the policy.
    @Test(arguments: Gate.allCases)
    func eachGateStillStillsEmotes(_ gate: Gate) {
        #expect(EmoteMotion.policy(for: gate.conditions) == .still)
    }

    // MARK: - On the surfaces

    /// A label's emote plays through idle calm — dressed for its loop, and
    /// moving — and each gate stills it (an emoji's still is its glyph: no
    /// player at all).
    @Test func aLabelKeepsAnimatingThroughIdleCalm() throws {
        EmoteMotion.conditions = { Conditions(idleCalm: true) }
        defer { EmoteMotion.conditions = { .current } }
        let (label, window) = hostedLabel(engine: try warmEngine())
        defer { window.isHidden = true }
        #expect(label.showingEmoteCount == 1)
        let player = try #require(label.artViews.first as? AnimatedIconView)
        #expect(playing(player), "a resting app stilled a label's emote")
        #expect(player.playbackPolicy == .full)
    }

    @Test(arguments: Gate.allCases)
    func eachGateStillsALabelThroughIdleCalm(_ gate: Gate) throws {
        EmoteMotion.conditions = { gate.conditions }
        defer { EmoteMotion.conditions = { .current } }
        let (label, window) = hostedLabel(engine: try warmEngine())
        defer { window.isHidden = true }
        #expect(!label.artViews.contains { playing($0) }, "\(gate) left a label's emote playing")
    }

    /// The composer's emote plays through idle calm too, and each gate
    /// stills it.
    @Test func aComposerEmoteKeepsAnimatingThroughIdleCalm() throws {
        EmoteMotion.conditions = { Conditions(idleCalm: true) }
        defer { EmoteMotion.conditions = { .current } }
        let (view, window) = try hostedAttachment(engine: try warmEngine())
        defer { window.isHidden = true }
        #expect(view.isShowingArt, "\(view.debugState)")
        #expect(playing(view.artView), "a resting app stilled the composer's emote")
        #expect((view.artView as? AnimatedIconView)?.playbackPolicy == .full)
    }

    @Test(arguments: Gate.allCases)
    func eachGateStillsTheComposerThroughIdleCalm(_ gate: Gate) throws {
        EmoteMotion.conditions = { gate.conditions }
        defer { EmoteMotion.conditions = { .current } }
        let (view, window) = try hostedAttachment(engine: try warmEngine())
        defer { window.isHidden = true }
        #expect(!playing(view.artView), "\(gate) left the composer's emote playing")
    }

    /// THE OWNER'S SPLIT, side by side under one injected idle calm: an icon
    /// on the app's policy — how a map marker wears its emote face — rests,
    /// while a label's emote plays on.
    @Test func aMapIconRestsUnderIdleCalmWhileALabelPlays() throws {
        let original = AnimatedIconView.isIdleCalm
        let forced = AnimatedIconView.forcedPolicy
        AnimatedIconView.isIdleCalm = { true }
        AnimatedIconView.forcedPolicy = nil
        EmoteMotion.conditions = { Conditions(idleCalm: true) }
        defer {
            AnimatedIconView.isIdleCalm = original
            AnimatedIconView.forcedPolicy = forced
            EmoteMotion.conditions = { .current }
        }
        let marker = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        marker.setArt(EmoteLabelTests.syntheticArt(side: 64))
        #expect(!marker.isAnimating, "a map marker's emote face played through idle calm")

        let (label, window) = hostedLabel(engine: try warmEngine())
        defer { window.isHidden = true }
        #expect(playing(label.artViews.first), "a resting app stilled a label's emote")
    }

    /// Idle calm resting or waking tells the emotes nothing: a label's players
    /// are not reset (they used to be, onto the still frame, and back).
    @Test func idleCalmChangingResetsNoEmote() async throws {
        let (label, window) = hostedLabel(engine: try warmEngine())
        defer { window.isHidden = true }
        let before = try #require(label.artViews.first)
        try #require(playing(before))
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
        // A reset arrives on a main-actor task: give it a few turns to.
        let reset = await settle(looks: 40) { label.artViews.first !== before }
        #expect(!reset, "idle calm reset a label's emotes")
        #expect(playing(label.artViews.first))
    }
}
