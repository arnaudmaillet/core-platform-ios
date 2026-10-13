import Testing
import UIKit
@testable import MediaCore

/// Idle calm (#580/#650) rests an icon that plays under the app's policy —
/// the map's markers, which the owner keeps at rest (#1072) — and leaves one
/// whose owner states its own policy playing: every emote in text (EmoteKit
/// sets `playbackPolicy`).
///
/// ⚠️ IDLE CALM IS INJECTED (`AnimatedIconView.isIdleCalm`), never the app-wide
/// `IdleCalm`, and every test is SYNCHRONOUS: the seam is process-wide while
/// set.
@MainActor
@Suite(.serialized)
struct AnimatedIconViewIdleCalmTests {
    private func art(frames: Int = 8, step: CFTimeInterval = 0.1) -> AnimatedIconArt {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 8 * frames, height: 8),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8 * frames, height: 8))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: frames, columns: frames, frameDuration: step))
    }

    /// The device's answer is still while the app rests.
    @Test func theDevicePolicyRestsUnderIdleCalm() {
        let original = AnimatedIconView.isIdleCalm
        AnimatedIconView.isIdleCalm = { true }
        defer { AnimatedIconView.isIdleCalm = original }
        #expect(AnimatedIconView.devicePolicy == .still)
    }

    /// An icon on the app's policy — as a map marker is dressed — rests under
    /// idle calm: posed, nothing animating.
    @Test func anIconOnTheAppsPolicyRestsUnderIdleCalm() {
        let original = AnimatedIconView.isIdleCalm
        let forced = AnimatedIconView.forcedPolicy
        AnimatedIconView.isIdleCalm = { true }
        // A suite beside this one may hold a forced policy across an await:
        // set aside, and handed back before this synchronous test returns.
        AnimatedIconView.forcedPolicy = nil
        defer {
            AnimatedIconView.isIdleCalm = original
            AnimatedIconView.forcedPolicy = forced
        }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.setArt(art())
        #expect(!view.isAnimating, "a map marker's icon played through idle calm")
    }

    /// An icon whose owner states its own policy plays through idle calm:
    /// what EmoteKit does for every emote in text.
    @Test func anIconOnItsOwnPolicyPlaysThroughIdleCalm() {
        let original = AnimatedIconView.isIdleCalm
        let forced = AnimatedIconView.forcedPolicy
        AnimatedIconView.isIdleCalm = { true }
        // A suite beside this one may hold a forced policy across an await:
        // set aside, and handed back before this synchronous test returns.
        AnimatedIconView.forcedPolicy = nil
        defer {
            AnimatedIconView.isIdleCalm = original
            AnimatedIconView.forcedPolicy = forced
        }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.playbackPolicy = .full
        view.setArt(art())
        #expect(view.isAnimating, "an icon on its own policy rested with the decoration")
    }
}
