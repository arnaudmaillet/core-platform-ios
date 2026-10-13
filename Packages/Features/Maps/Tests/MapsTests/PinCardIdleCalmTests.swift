import Testing
import UIKit
import MediaCore
@testable import Maps

/// A map marker's emote face RESTS under idle calm (#580/#650), as it always
/// has: the owner kept the map at rest when emotes in text started playing
/// through it (#1072) — a map holds far more of them than any caption.
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

    @Test func aMarkersEmoteFaceRestsUnderIdleCalm() throws {
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
        #expect(!face.isAnimating, "a map marker's emote face played through idle calm")

        // Witness: the same face plays when the app's policy lets it, so the
        // rest above is the policy's and not a face that never moves.
        AnimatedIconView.forcedPolicy = .full
        let awake = PinCardView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        awake.setFace(.icon)
        awake.setIcon((movingArt(), 0))
        let awakeFace = try #require(awake.debugIconFace as? AnimatedIconView)
        #expect(awakeFace.isAnimating, "witness: the face never plays")
    }
}
