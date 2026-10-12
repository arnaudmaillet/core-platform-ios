import Dispatch
import Foundation
import Lottie
import QuartzCore
import Testing
@testable import EmoteKit

/// Where a bake's Core Animation work runs, and when it commits (#1001).
///
/// A commit on ANY thread lays out every window in the process. Committed at
/// a moment of its own choosing, the bake's transaction now and then met a
/// window the main thread was laying out, and laid it out on `EmoteKit.bake`:
/// AutoLayout threw under the commit in `EmoteFrameDrawer.init`, now and then
/// in a full Feed test run. A bake now commits only while the main thread is
/// parked in its run loop (`EmoteMainPark`), on a thread nothing else runs on
/// (`EmoteBakeThread`).
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteBakeThreadTests {
    private func animation(_ id: String) async throws -> LottieAnimationBox {
        let emote = try #require(EmoteCatalog.shared.emote(id: id))
        return LottieAnimationBox(try #require(await EmoteEngine.bundledAnimation(for: emote)))
    }

    /// THE CONTRACT: while the main thread is busy — here blocked outside its
    /// run loop — no bake commits anything. Bakes asked for from several
    /// tasks at once build their tree off the main thread and then WAIT; each
    /// commits once the main thread is back in its run loop, and finishes.
    /// Before the fix the first bake committed its new tree at once, from the
    /// bake queue, whatever the main thread was doing.
    @Test func noBakeCommitsWhileTheMainThreadIsBusy() async throws {
        let fire = try await animation("noto:1f525")
        let plan = EmoteBakePlan.make(seconds: 0.2, side: 48)
        let bakeQueue = EmoteBakeQueue()
        let committed = EmoteMainPark.parkedCommits
        let bakes = (0..<3).map { _ in
            Task.detached { await bakeQueue.bake(fire.animation, plan: plan) != nil }
        }
        // Busy from here: until a bake asks to commit, and half a second more.
        let asked = Self.blockMainThread(until: { EmoteMainPark.waitingCommits > 0 }, seconds: 60)
        Self.blockMainThread(until: { false }, seconds: 0.5)
        #expect(asked, "no bake built its tree and asked to commit it")
        #expect(EmoteMainPark.parkedCommits == committed, "a bake committed while the main thread was busy")
        #expect(EmoteMainPark.waitingCommits > 0, "the bake stopped waiting for the main thread")
        #expect(bakeQueue.drawingJobs == 0, "a bake drew from a tree it had not committed")
        for bake in bakes {
            #expect(await bake.value, "a bake that waited for the main thread did not finish")
        }
        #expect(EmoteMainPark.parkedCommits >= committed + 6, "three bakes commit twice each, parked")
    }

    /// Bakes asked for from many threads at once all run on the bake's own
    /// thread (the session asserts it at every step in Debug), one at a time,
    /// and each draws what the same bake draws alone (within 8/255, as
    /// `aBakeUnderMainThreadLottieLoadMatchesOneAlone`; a wrong frame is
    /// thousands of channels ~100 apart).
    @Test func concurrentBakesFromManyThreadsMatchABakeAlone() async throws {
        var jobs: [(LottieAnimationBox, EmoteBakePlan)] = []
        var alone: [CGImage] = []
        for id in ["noto:1f602", "noto:1f525", "noto:2764_fe0f"] {
            let box = try await animation(id)
            let plan = EmoteBakePlan.make(seconds: min(box.animation.duration, 1), side: 48)
            alone.append(try #require(await EmoteBakeQueue.shared.bake(box.animation, plan: plan)).image)
            jobs.append((box, plan))
        }
        let snapshot = jobs
        let results = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for round in 0..<3 {
                for (index, job) in snapshot.enumerated() {
                    group.addTask(priority: round.isMultiple(of: 2) ? .utility : .userInitiated) {
                        (index, await EmoteBakeQueue.shared.bake(job.0.animation, plan: job.1)?.image)
                    }
                }
            }
            var all: [(Int, CGImage?)] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 9)
        for (index, image) in results {
            let baked = try #require(image)
            let far = TestBitmap.channelsApart(alone[index], baked, by: 8)
            #expect(far == 0, "bake \(index): \(far) channels more than 8/255 from the same bake alone")
        }
    }

    /// The bake's thread is its own: never the main thread, never a GCD
    /// worker another queue's work can run on.
    @Test func theBakeThreadIsItsOwn() async throws {
        let bakeQueue = EmoteBakeQueue()
        let seen = await bakeQueue.run {
            (EmoteBakeThread.isCurrent, Thread.isMainThread, Thread.current.name ?? "")
        }
        #expect(seen.0)
        #expect(!seen.1)
        #expect(seen.2 == "EmoteKit.bake")
        #expect(!EmoteBakeThread.isCurrent)
        let onAWorker = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: EmoteBakeThread.isCurrent) }
        }
        #expect(!onAWorker)
    }

    /// Blocks the calling (main) thread until `condition` holds or `seconds`
    /// pass — deliberately synchronous: the run loop does not turn meanwhile.
    @discardableResult
    private nonisolated static func blockMainThread(until condition: () -> Bool, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            usleep(1000)
        }
        return true
    }
}

/// A `LottieAnimation` handed between tasks (Lottie declares it `Sendable`).
struct LottieAnimationBox: Sendable {
    let animation: LottieAnimation
    init(_ animation: LottieAnimation) { self.animation = animation }
}
