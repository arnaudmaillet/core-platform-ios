import Testing
import UIKit
@testable import MediaCore

/// Pausing stops the clock where it is and resuming plays on from there; a
/// paused install rests on its first frame.
///
/// ⚠️ EVERY VIEW STATES ITS OWN POLICY (`playbackPolicy`, #1676), never the
/// process-wide `AnimatedIconView.forcedPolicy`: a test that forced it and
/// then awaited left it to whatever a suite beside it did in between, and
/// the device's own answer (thermal, Low Power) stays out of it too. Where a
/// test needs the loop to move, it moves the media clock
/// (`AnimatedIconView.mediaTime`) synchronously rather than sleeping on the
/// wall clock (`playing(_:)`).
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

    /// A view playing under `policy` whatever the app's answer is.
    private func makeView(_ policy: AnimatedIconView.MotionPolicy = .full) -> AnimatedIconView {
        let view = AnimatedIconView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.playbackPolicy = policy
        return view
    }

    @Test func aPausedInstallRestsOnItsPhase() {
        let view = makeView()
        view.setArt(art(frames: 10, step: 0.1), phase: 3, paused: true)
        #expect(view.isPaused)
        #expect(!view.isAnimating, "posed on the model, nothing left for a renderer to play")
        #expect(view.displayedFrame == 3)
        view.setArt(art(frames: 10, step: 0.1), phase: 3)
        #expect(!view.isPaused, "a plain install plays")
    }

    /// ⚠️ #1676: this slept 200 ms on the wall clock with the policy forced
    /// process-wide, and once held frame 0 on CI — the loop had not run on
    /// screen. The clock is now moved by the test, with no await.
    @Test func pauseHoldsTheFrameAndResumePlaysOnFromIt() throws {
        let frames = 40
        let view = makeView()
        view.setArt(art(frames: frames, step: 0.1), paused: true)
        #expect(view.displayedFrame == 0)

        try playing { advance in
            view.resume()
            #expect(!view.isPaused)
            advance(0.25) // two and a half keys, from wherever in its key it resumed
            view.pause()
            let held = try #require(view.displayedFrame)
            #expect((2...3).contains(held), "the clock ran while it played: \(held)")

            advance(0.3)
            #expect(view.displayedFrame == held, "held, not reset")

            view.resume()
            let resumed = try #require(view.displayedFrame)
            #expect(resumed == held, "from \(held), got \(resumed)")
            advance(0.1)
            #expect(view.displayedFrame == (held + 1) % frames, "plays on from the held frame")
        }
    }

    /// Runs `body` with the media clock standing still, moved only by the
    /// `advance` it is handed, and puts the clock back before returning —
    /// with no `await` in between: other suites read it.
    private func playing(_ body: (_ advance: (CFTimeInterval) -> Void) throws -> Void) throws {
        let previous = AnimatedIconView.mediaTime
        defer { AnimatedIconView.mediaTime = previous }
        var now = previous()
        AnimatedIconView.mediaTime = { now }
        try body { now += $0 }
    }

    /// Finishing the loop (#559) plays out the loop on screen, then rests on
    /// the frame the art was dressed on — never mid-gesture.
    @Test func finishingTheLoopRestsOnTheDressedFrame() async throws {
        let view = makeView()
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
        let view = makeView()
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
        let view = makeView()
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
        let view = makeView(.reduced)
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
    ///
    /// ⚠️ AT A POSITION THE TEST CHOOSES (#1030). Read off the wall clock,
    /// this ran wherever the shared 10 s loop happened to be, and failed the
    /// ~15% of runs that landed in its last 1.5 s. The clock now stands at
    /// the start of the loop (mid-key: never on a grid edge).
    @Test func aLongLoopHoldsAtOnce() throws {
        try atLoopTime(0.05, of: 10) { view in
            let remaining = try #require(view.remainingLoopTime)
            #expect(remaining > AnimatedIconView.maxFinishWait)
            var finished = false
            view.finishLoop { finished = true }
            #expect(finished, "completed at once")
            #expect(view.isPaused)
            #expect(!view.isFinishingLoop)
        }
    }

    /// With no cap (the feed's shortcut rail, #2004), the same long loop is
    /// waited for: it plays on, finishing, and holds nothing yet.
    @Test func anUncappedFinishWaitsForALongLoop() throws {
        try atLoopTime(0.05, of: 10) { view in
            let remaining = try #require(view.remainingLoopTime)
            #expect(remaining > AnimatedIconView.maxFinishWait)
            var finished = false
            view.finishLoop(maxWait: nil) { finished = true }
            #expect(!finished, "a long loop was cut short")
            #expect(view.isFinishingLoop)
            #expect(!view.isPaused)
            view.cancelFinish()
        }
    }

    /// Over the whole cycle of a 10 s loop: with more than `maxFinishWait`
    /// left it holds at once; with less it plays out the loop first.
    @Test func aLongLoopFinishesByWhatIsLeftAcrossItsCycle() throws {
        for tenth in 0..<100 {
            let time = CFTimeInterval(tenth) / 10 + 0.05 // mid-key: no grid edge
            try atLoopTime(time, of: 10) { view in
                let remaining = try #require(view.remainingLoopTime)
                #expect(abs(remaining - (10 - time)) < 0.001, "at \(time) s: \(remaining) left")
                var finished = false
                view.finishLoop { finished = true }
                if remaining > AnimatedIconView.maxFinishWait {
                    #expect(finished && view.isPaused, "at \(time) s: held at once")
                } else {
                    #expect(!finished && view.isFinishingLoop, "at \(time) s: plays out its \(remaining) s")
                    view.cancelFinish()
                }
            }
        }
    }

    /// A playing `loop`-second icon (100 frames) with the media clock
    /// standing `time` seconds into its loop. The clock is put back before
    /// returning, with no `await` in between: other suites read it.
    private func atLoopTime(
        _ time: CFTimeInterval, of loop: CFTimeInterval, _ body: (AnimatedIconView) throws -> Void
    ) throws {
        let previous = AnimatedIconView.mediaTime
        defer { AnimatedIconView.mediaTime = previous }
        let view = makeView()
        view.setArt(art(frames: 100, step: loop / 100), phase: 0)
        // Frozen now, then moved on by what is left of the loop — to its
        // next start — plus `time`.
        let now = previous()
        AnimatedIconView.mediaTime = { now }
        let left = try #require(view.remainingLoopTime)
        AnimatedIconView.mediaTime = { now + left + time }
        try body(view)
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
