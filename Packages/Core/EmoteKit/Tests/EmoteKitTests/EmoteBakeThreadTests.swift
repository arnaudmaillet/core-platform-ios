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
///
/// The tests that block or hold the main thread are in
/// `EmoteMainThreadBlockingTests`, which runs alone (#1038).
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteBakeThreadTests {
    private func animation(_ id: String) async throws -> LottieAnimationBox {
        let emote = try #require(EmoteCatalog.shared.emote(id: id))
        return LottieAnimationBox(try #require(await EmoteEngine.bundledAnimation(for: emote)))
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
}

/// A `LottieAnimation` handed between tasks (Lottie declares it `Sendable`).
struct LottieAnimationBox: Sendable {
    let animation: LottieAnimation
    init(_ animation: LottieAnimation) { self.animation = animation }
}
