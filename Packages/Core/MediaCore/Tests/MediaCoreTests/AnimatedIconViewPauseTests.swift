import Testing
import UIKit
@testable import MediaCore

/// Pausing stops the clock where it is and resuming plays on from there; a
/// paused install rests on its first frame.
@MainActor
@Suite(.serialized)
struct AnimatedIconViewPauseTests {
    /// `frames` cells of `step` seconds.
    private func art(frames: Int, step: CFTimeInterval) -> AnimatedIconArt {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 8 * frames, height: 8),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8 * frames, height: 8))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: frames, columns: frames, frameDuration: step))
    }

    @Test func aPausedInstallRestsOnItsPhase() {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 10, step: 0.1), phase: 3, paused: true)
        #expect(view.isPaused)
        #expect(!view.isAnimating, "posed on the model, nothing left for a renderer to play")
        #expect(view.displayedFrame == 3)
        view.setArt(art(frames: 10, step: 0.1), phase: 3)
        #expect(!view.isPaused, "a plain install plays")
    }

    @Test func pauseHoldsTheFrameAndResumePlaysOnFromIt() async throws {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let frames = 40
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: frames, step: 0.1), paused: true)
        #expect(view.displayedFrame == 0)

        view.resume()
        #expect(!view.isPaused)
        try await Task.sleep(for: .milliseconds(200))
        view.pause()
        let held = try #require(view.displayedFrame)
        #expect(held > 0, "the clock ran while it played")

        try await Task.sleep(for: .milliseconds(300))
        #expect(view.displayedFrame == held, "held, not reset")

        view.resume()
        let resumed = try #require(view.displayedFrame)
        #expect(resumed == held || resumed == (held + 1) % frames, "from \(held), got \(resumed)")
    }

    /// A reinstall (foreground, policy change) keeps a paused view paused.
    @Test func reinstallKeepsAPausedViewPaused() {
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 4, step: 0.1), phase: 1, paused: true)
        view.reinstall()
        #expect(view.isPaused)
        #expect(view.displayedFrame == 1)
    }
}
