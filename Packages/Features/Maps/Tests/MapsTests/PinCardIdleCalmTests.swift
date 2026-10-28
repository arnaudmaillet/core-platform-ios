import Testing
import UIKit
import EmoteKit
import MediaCore
@testable import Maps

/// ⚠️ A MAP MARKER'S EMOTE FACE PLAYS THROUGH IDLE CALM (#1504, the owner
/// 2026-10-21, reversing the map part of #1072): it follows the one emote
/// contract (`EmoteMapIcons.playbackPolicy`) — still under Reduce Motion,
/// Animate Emojis off and Low Power Mode, never for idleness.
///
/// ⚠️ IDLE CALM IS INJECTED (`AnimatedIconView.isIdleCalm`), never the app-wide
/// `IdleCalm`, and the test is SYNCHRONOUS: the seam is process-wide while set.
@MainActor
struct PinCardIdleCalmTests {
    /// Eight frames: art that moves when it may.
    private func movingArt() -> AnimatedIconArt {
        let frames = 8
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 8 * frames, height: 8),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()
        ).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8 * frames, height: 8))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: frames, columns: frames, frameDuration: 0.1))
    }

    @Test func aMarkersEmoteFacePlaysThroughIdleCalm() throws {
        let original = AnimatedIconView.isIdleCalm
        let forced = AnimatedIconView.forcedPolicy
        AnimatedIconView.isIdleCalm = { true }
        AnimatedIconView.forcedPolicy = nil
        defer {
            AnimatedIconView.isIdleCalm = original
            AnimatedIconView.forcedPolicy = forced
        }
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        card.setFace(.icon)
        card.setIcon((movingArt(), 0))
        let face = try #require(card.debugIconFace as? AnimatedIconView)
        #expect(card.debugIconFaceIsVisible)
        // The face states the emote policy; idleness is not one of its gates.
        #expect(card.debugIconPlaybackPolicy == EmoteMapIcons.playbackPolicy)
        // The host may run with Reduce Motion or Low Power on: only then is
        // the face still, and never for idleness.
        if EmoteMapIcons.playbackPolicy == .full {
            #expect(face.isAnimating, "a map marker's emote face rested under idle calm")
        }
    }
}
