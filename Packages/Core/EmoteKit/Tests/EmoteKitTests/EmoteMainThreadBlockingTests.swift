import Foundation
import Testing
@testable import EmoteKit

/// The bake tests that BLOCK or hold the main thread (#1038), alone.
///
/// ⚠️ **ALONE (`.blocksMainThread`).** Swift Testing runs suites side by side
/// in one process. A main thread blocked here stalls every main-actor test
/// beside it, and `EmoteBakeCostTests` booked the block as bake cost: two red
/// EmoteKit lanes in a row (runs 38265001360 and 38269680355).
///
/// ⚠️ **THEIR OWN COUNTERS.** Each test reads the park counters of a bake
/// queue of its own (`EmoteBakeQueue.parks`), never a process-wide count that
/// other suites' bakes also move.
///
/// ⚠️ **LOOK BUDGETS, NOT CLOCKS.** A wait gives up after a number of looks, so
/// a starved runner, which stretches every look, waits longer, never less (the
/// 60 s deadline here ran out on a runner at 121 s).
@MainActor
@Suite(.serialized, .blocksMainThread)
struct EmoteMainThreadBlockingTests {
    private func animation(_ id: String) async throws -> LottieAnimationBox {
        let emote = try #require(EmoteCatalog.shared.emote(id: id))
        return LottieAnimationBox(try #require(await EmoteEngine.bundledAnimation(for: emote)))
    }

    /// THE CONTRACT (#1001): while the main thread is busy — here blocked
    /// outside its run loop — no bake commits anything. Bakes asked for from
    /// several tasks at once build their tree off the main thread and then
    /// WAIT; each commits once the main thread is back in its run loop, and
    /// finishes.
    @Test func noBakeCommitsWhileTheMainThreadIsBusy() async throws {
        let fire = try await animation("noto:1f525")
        let plan = EmoteBakePlan.make(seconds: 0.2, side: 48)
        let bakeQueue = EmoteBakeQueue()
        let parks = bakeQueue.parks
        let bakes = (0..<3).map { _ in
            Task.detached { await bakeQueue.bake(fire.animation, plan: plan) != nil }
        }
        // Busy from here: until a bake asks to commit, and half a second of
        // looks more.
        let asked = Self.blockMainThread(looks: 60_000, until: { parks.waitingCommits > 0 })
        Self.blockMainThread(looks: 500, until: { false })
        #expect(asked, "no bake built its tree and asked to commit it")
        #expect(parks.commits == 0, "a bake committed while the main thread was busy")
        #expect(parks.waitingCommits > 0, "the bake stopped waiting for the main thread")
        #expect(bakeQueue.drawingJobs == 0, "a bake drew from a tree it had not committed")
        for bake in bakes {
            #expect(await bake.value, "a bake that waited for the main thread did not finish")
        }
        #expect(parks.commits == 6, "three bakes commit twice each, parked")
    }

    /// LIVENESS (#1011): a main thread that stays out of the common modes —
    /// here a private run-loop mode — for longer than `retryInterval` never
    /// strands the bake thread on one request: it withdraws it and asks again
    /// (`retries`), commits nothing meanwhile, and the bake completes once the
    /// main thread is back. The bake after it runs as usual.
    @Test func aBakeOutwaitsAMainThreadInAPrivateRunLoopMode() async throws {
        let fire = try await animation("noto:1f525")
        let plan = EmoteBakePlan.make(seconds: 0.2, side: 48)
        let bakeQueue = EmoteBakeQueue()
        let parks = bakeQueue.parks
        let first = Task.detached { await bakeQueue.bake(fire.animation, plan: plan) != nil }
        let asked = Self.blockMainThread(looks: 60_000, until: { parks.waitingCommits > 0 })
        #expect(asked, "no bake built its tree and asked to commit it")
        let renewed = Self.runPrivateRunLoopMode(looks: 600, until: { parks.retries >= 2 })
        #expect(renewed, "the bake thread did not withdraw and renew its request")
        #expect(parks.commits == 0, "a bake committed while the main thread was out of the common modes")
        #expect(await first.value, "the bake did not complete once the main thread was back")
        let second = await bakeQueue.bake(fire.animation, plan: plan)
        #expect(second != nil, "the bake after it did not run")
    }

    /// VISIBILITY (#1011, #1037): a main thread that wakes during a commit
    /// waits for it at most `longestWait`; past that it goes on, and the path
    /// is counted (`cappedWaits`, logged once in DEBUG) and the hold timed
    /// (`holds`). The body wakes the main thread itself, so the main thread is
    /// sure to wake mid-commit. The next commit runs as usual.
    @Test func aCommitOutlastingTheMainThreadsWaitIsCounted() async throws {
        let bakeQueue = EmoteBakeQueue()
        let parks = bakeQueue.parks
        await bakeQueue.run {
            EmoteMainPark.whileParked {
                CFRunLoopWakeUp(CFRunLoopGetMain())
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        // At least once: after its cap the main thread goes on, and it may
        // wake again before the half second is out and wait anew.
        #expect(parks.cappedWaits >= 1, "a commit outlasted the main thread's wait uncounted")
        #expect(parks.holds.count >= parks.cappedWaits, "the main thread's wait went untimed")
        #expect(parks.holds.longest >= .milliseconds(200), "the main thread's wait was timed at \(parks.holds.longest), short of its 250 ms cap")
        await bakeQueue.run { EmoteMainPark.whileParked {} }
        #expect(parks.commits == 2)
    }

    /// THE MAIN-THREAD CONTRACT: a bake draws no frame on the main thread.
    /// Once its tree is built and the main thread has run the tree's birth
    /// redraw (`EmoteBakeSession.waitForBirthRedraw`), the main thread is
    /// BLOCKED here while the whole sheet is drawn; were a single frame drawn
    /// on it, this would run out of looks.
    ///
    /// ⚠️ **UNBLOCKED BEFORE THE BAKE ENDS.** Its last step commits the
    /// drawing while the main thread is parked in its run loop (#1001,
    /// `EmoteMainPark`), so the main thread is held only until the frames are
    /// drawn (`drawingJobs` back to 0), then the result is awaited.
    ///
    /// ⚠️ **BLOCK ONLY ONCE THIS BAKE IS DRAWING.** Before that, the bake
    /// NEEDS the main thread (the birth redraw), and blocking it is a
    /// deadlock until the budget runs out — the CI flake (runs 37073903752,
    /// 37121583833): `EmoteMapIconsTests` was drawing 🤗@128 on the SHARED
    /// queue, so `drawingJobs` was its job, not this one. So this bake gets a
    /// queue of its own — its counter is its own job — and the wait for its
    /// drawing is an async look budget that never blocks the main thread on
    /// a bake that has not got there.
    @Test func aBakeDrawsNoFrameOnTheMainThread() async throws {
        let cold = try #require(EmoteCatalog.shared.emote(id: "noto:1f976"))
        let animation = try #require(await EmoteEngine.bundledAnimation(for: cold))
        let plan = EmoteBakePlan.make(seconds: animation.duration, side: 48)
        let bakeQueue = EmoteBakeQueue()
        let result = BakeBox()
        let baking = Task.detached { result.set(await bakeQueue.bake(animation, plan: plan)) }
        let drawing = await settle(looks: 24_000) { bakeQueue.drawingJobs > 0 || result.isSet }
        try #require(drawing, "the bake never started drawing, with the main thread free")
        let drawn = Self.blockMainThread(looks: 60_000, until: { bakeQueue.drawingJobs == 0 })
        #expect(drawn, "the frames were not drawn while the main thread was blocked")
        await baking.value
        let baked = try #require(result.value)
        #expect(baked.image.width == plan.pixelWidth)
        #expect(baked.image.height == plan.pixelHeight)
    }

    /// Blocks the calling (main) thread until `condition` holds, looking up
    /// to `looks` times a millisecond apart — deliberately synchronous: the
    /// run loop does not turn meanwhile.
    @discardableResult
    private nonisolated static func blockMainThread(looks: Int, until condition: () -> Bool) -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            usleep(1000)
        }
        return condition()
    }

    /// Runs the main run loop in a mode of its own, 10 ms a look, until
    /// `condition` holds or `looks` run out: no common-mode observer fires and
    /// no main-actor job runs meanwhile. A timer in that mode keeps each look
    /// from returning at once.
    private nonisolated static func runPrivateRunLoopMode(looks: Int, until condition: () -> Bool) -> Bool {
        let mode = RunLoop.Mode("EmoteKitTests.private")
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in }
        RunLoop.current.add(timer, forMode: mode)
        defer { timer.invalidate() }
        for _ in 0..<looks {
            if condition() { return true }
            _ = RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
