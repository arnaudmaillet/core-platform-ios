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

    /// Finishing the loop (#559) plays out the loop on screen, then rests on
    /// the frame the art was dressed on — never mid-gesture.
    @Test func finishingTheLoopRestsOnTheDressedFrame() async throws {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 8, step: 0.05), phase: 2) // a 0.4 s loop
        try await Task.sleep(for: .milliseconds(120))
        var finished = false
        view.finishLoop { finished = true }
        #expect(view.isFinishingLoop)
        #expect(!view.isPaused, "still playing out the loop")
        for _ in 0..<40 where !finished { try await Task.sleep(for: .milliseconds(25)) }
        #expect(finished)
        #expect(view.isPaused)
        #expect(view.displayedFrame == 2, "rests on the frame it was dressed on")
    }

    /// Asked to play again before the loop ends, it just carries on.
    @Test func cancellingTheFinishKeepsItPlaying() async throws {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 8, step: 0.05), phase: 0)
        var finished = false
        view.finishLoop { finished = true }
        view.cancelFinish()
        try await Task.sleep(for: .milliseconds(600))
        #expect(!finished)
        #expect(!view.isPaused)
        #expect(view.isAnimating, "no restart, no hold")
    }

    /// The time left is the loop minus how far the clock is into it, on the
    /// same grid `displayedFrame` reads.
    @Test func theRemainingTimeIsWhatIsLeftOfTheLoop() throws {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 10, step: 0.1), phase: 0) // a 1 s loop
        let remaining = try #require(view.remainingLoopTime)
        let frame = try #require(view.displayedFrame)
        #expect(remaining > 0 && remaining <= 1)
        // Frame k shows during [k, k+1) × 0.1 s of the loop.
        let elapsed = 1 - remaining
        #expect(Int((elapsed / 0.1).rounded(.down)) == frame || Int((elapsed / 0.1).rounded(.up)) == frame,
                "elapsed \(elapsed) s is on frame \(frame)")
        view.pause()
        #expect(view.remainingLoopTime == nil, "nothing plays")
    }

    /// Low Power decimates the keys (stride 2), not the loop's duration: the
    /// finish still ends on the last key and rests on the dressed frame.
    @Test func aDecimatedLoopFinishesWhereItsKeysEnd() async throws {
        AnimatedIconView.forcedPolicy = .reduced
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 8, step: 0.05), phase: 4) // 0.4 s, four keys of 0.1 s
        let remaining = try #require(view.remainingLoopTime)
        #expect(remaining > 0 && remaining <= 0.4, "the loop keeps its duration")
        var finished = false
        view.finishLoop { finished = true }
        for _ in 0..<40 where !finished { try await Task.sleep(for: .milliseconds(25)) }
        #expect(finished)
        #expect(view.displayedFrame == 4)
    }

    /// A loop longer than `maxFinishWait` is not waited for: it holds where
    /// it is at once, as a stop always did.
    @Test func aLongLoopHoldsAtOnce() throws {
        AnimatedIconView.forcedPolicy = .full
        defer { AnimatedIconView.forcedPolicy = nil }
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 100, step: 0.1), phase: 0) // a 10 s loop
        let remaining = try #require(view.remainingLoopTime)
        try #require(remaining > AnimatedIconView.maxFinishWait, "this run sits early enough in the loop")
        var finished = false
        view.finishLoop { finished = true }
        #expect(finished, "completed at once")
        #expect(view.isPaused)
        #expect(!view.isFinishingLoop)
    }

    /// Nothing playing: the finish completes at once.
    @Test func aPausedViewFinishesAtOnce() {
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.setArt(art(frames: 4, step: 0.1), phase: 1, paused: true)
        var finished = false
        view.finishLoop { finished = true }
        #expect(finished)
        #expect(view.displayedFrame == 1)
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
