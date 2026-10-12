import AVFoundation
import CacheKit
import Foundation
import Testing
@testable import MediaPlayback

/// The vertical feed's preload plan (#895): +1 warmed, +2/+3 head ranges,
/// depth by policy, P2 only after the playing video has buffered enough, and
/// every P2 cancelled on a swipe.
///
/// The lookahead is driven with an injected clock, an injected buffer probe
/// and a fake fetcher that never answers on its own, so every head preload
/// it starts stays visible as a fetch in flight.
@MainActor
struct VideoLookaheadTests {
    private let folder = VideoCacheFolder()

    private final class Recorder {
        var status: VideoBufferStatus?
        var failed = false

        var state: VideoPlayingState {
            if failed { return .failed }
            return status.map(VideoPlayingState.ready) ?? .notReady
        }
        var policy: PrefetchPolicy = .full
        var applied: [(next: VideoLookaheadItem?, previous: VideoLookaheadItem?, warm: Bool)] = []
    }

    private struct Harness {
        let lookahead: VideoLookahead
        let cache: VideoByteCache
        let fetcher: FakeRangeFetcher
        let clock: ManualLookaheadClock
        let recorder: Recorder
        let slots: CacheFillSlots
        let coordinator: CacheCoordinator
    }

    private func makeHarness(slots limit: Int = 2) throws -> Harness {
        let fetcher = FakeRangeFetcher(holds: true)
        for index in 0..<8 { fetcher.serve(videoBytes(3000), at: remote(index)) }
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let slots = CacheFillSlots(limit: limit)
        let cache = try VideoByteCache(
            coordinator: coordinator, root: folder.url, fetcher: fetcher, slots: slots, chunkSize: 1000, cancelGrace: 0
        )
        let recorder = Recorder()
        let clock = ManualLookaheadClock()
        let lookahead = VideoLookahead(
            cache: cache, name: "test-feed",
            policy: { recorder.policy },
            probe: { _ in recorder.state },
            resolve: { $0 },
            apply: { next, previous, warm in recorder.applied.append((next, previous, warm)) },
            release: { recorder.applied.append((nil, nil, false)) },
            clock: clock
        )
        return Harness(
            lookahead: lookahead, cache: cache, fetcher: fetcher, clock: clock, recorder: recorder, slots: slots,
            coordinator: coordinator
        )
    }

    private func remote(_ index: Int) -> URL { URL(string: "https://media.example.test/v/\(index).mp4")! }
    private func item(_ index: Int) -> VideoLookaheadItem { VideoLookaheadItem(url: remote(index), scope: "post-\(index)") }

    /// Settles on page `index` with +1…+3 and −1 around it.
    private func settle(_ harness: Harness, on index: Int, allowsPreload: Bool = true) {
        harness.lookahead.update(
            page: "post-\(index)", playing: item(index),
            ahead: [item(index + 1), item(index + 2), item(index + 3)],
            behind: index > 0 ? item(index - 1) : nil, allowsPreload: allowsPreload
        )
    }

    private static let buffered = VideoBufferStatus(bufferedAhead: 30, duration: 60, isComplete: false)

    // MARK: - Depth by policy

    /// ⚠️ DEPTH FOLLOWS THE POLICY. Wi-Fi preloads the heads of +2 and +3,
    /// cellular only +2's, Low Data / Low Power / thermal none (but still
    /// warms +1), offline nothing at all; the feed's data saver is nothing.
    @Test(arguments: [
        (PrefetchPolicy.full, [2, 3], true),
        (PrefetchPolicy.cellular, [2], true),
        (PrefetchPolicy.reduced, [], true),
        (PrefetchPolicy.off, [], false)
    ])
    func depthFollowsThePolicy(policy: PrefetchPolicy, heads: [Int], warmsNext: Bool) async throws {
        let harness = try makeHarness()
        harness.recorder.policy = policy
        harness.recorder.status = Self.buffered
        settle(harness, on: 0)
        #expect(await eventually { harness.lookahead.requestedHeads == Set(heads.map(item)) })
        #expect(await eventually { harness.fetcher.requests.count == heads.count })
        #expect(Set(harness.fetcher.requests.map(\.url)) == Set(heads.map(remote)))
        #expect(harness.fetcher.requests.allSatisfy { $0.speculative && $0.offset == 0 && $0.end == 1000 })
        let last = harness.recorder.applied.last
        #expect(last?.next == (warmsNext ? item(1) : nil))
        #expect(last?.warm == warmsNext)
    }

    @Test func theFeedsDataSaverPreloadsNothing() async throws {
        let harness = try makeHarness()
        harness.recorder.status = Self.buffered
        settle(harness, on: 0, allowsPreload: false)
        harness.clock.tick()
        #expect(harness.lookahead.requestedHeads.isEmpty)
        #expect(harness.recorder.applied.last?.next == nil)
        // −1 is still kept: it costs no network.
        settle(harness, on: 1, allowsPreload: false)
        #expect(harness.recorder.applied.last?.previous == item(0))
    }

    /// A policy that changes under a page (Low Power switched on) takes
    /// effect at the next tick: the heads it no longer wants are cancelled.
    @Test func aPolicyChangeDropsTheHeadsItNoLongerWants() async throws {
        let harness = try makeHarness()
        harness.recorder.status = Self.buffered
        settle(harness, on: 0)
        #expect(await eventually { harness.fetcher.requests.count == 2 })
        harness.recorder.policy = .reduced
        harness.clock.tick()
        #expect(harness.lookahead.requestedHeads.isEmpty)
        #expect(await eventually { harness.fetcher.cancelledCount == 2 })
    }

    // MARK: - The 20 s start rule

    /// ⚠️ P2 WAITS FOR THE PLAYING VIDEO. Nothing is preloaded until the
    /// playing video has buffered MORE than 20 s ahead, ticked by an injected
    /// clock; then +2 and +3 start.
    @Test func headPreloadsWaitForTwentySecondsOfBuffer() async throws {
        let harness = try makeHarness()
        harness.recorder.status = nil
        settle(harness, on: 0)
        for ahead in [0.0, 5, 12, 19.9, 20] {
            harness.recorder.status = VideoBufferStatus(bufferedAhead: ahead, duration: 60, isComplete: false)
            harness.clock.tick()
            #expect(harness.lookahead.requestedHeads.isEmpty, "preloaded at \(ahead) s of buffer")
        }
        harness.recorder.status = VideoBufferStatus(bufferedAhead: 20.5, duration: 60, isComplete: false)
        harness.clock.tick()
        #expect(harness.lookahead.requestedHeads == [item(2), item(3)])
        // Latched: a dip after the start does not cancel what started.
        harness.recorder.status = VideoBufferStatus(bufferedAhead: 4, duration: 60, isComplete: false)
        harness.clock.tick()
        #expect(harness.lookahead.requestedHeads == [item(2), item(3)])
    }

    /// A clip under 20 s needs 10 s; a clip buffered to its end needs nothing
    /// more.
    @Test(arguments: [
        (VideoBufferStatus(bufferedAhead: 9.5, duration: 15, isComplete: false), false),
        (VideoBufferStatus(bufferedAhead: 10.5, duration: 15, isComplete: false), true),
        (VideoBufferStatus(bufferedAhead: 6, duration: 60, isComplete: true), true),
        (VideoBufferStatus(bufferedAhead: 15, duration: 60, isComplete: false), false)
    ])
    func shortAndCompleteClipsOpenTheGateSooner(status: VideoBufferStatus, opens: Bool) throws {
        #expect(VideoLookaheadGate.allowsSpeculative(status) == opens)
    }

    @Test func theBufferIsReadAtThePlayhead() {
        let ranges = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 8, preferredTimescale: 600)),
            CMTimeRange(start: CMTime(seconds: 12, preferredTimescale: 600), duration: CMTime(seconds: 30, preferredTimescale: 600))
        ]
        let status = VideoBufferStatus(current: 14, duration: 60, loaded: ranges)
        #expect(abs(status.bufferedAhead - 28) < 0.001)
        #expect(!status.isComplete)
        let done = VideoBufferStatus(current: 14, duration: 42, loaded: ranges)
        #expect(done.isComplete)
    }

    // MARK: - Under-buffered

    /// While the playing video is under-buffered, no P2 starts anywhere in the
    /// app and the +1 player is not warmed yet; both resume once it is under
    /// way, and leaving the feed lifts the pause.
    @Test func anUnderBufferedVideoPausesP2AndHoldsTheWarmUp() async throws {
        let harness = try makeHarness()
        harness.recorder.status = VideoBufferStatus(bufferedAhead: 1, duration: 60, isComplete: false)
        settle(harness, on: 0)
        #expect(harness.coordinator.fillSlots.isPaused)
        #expect(harness.recorder.applied.last?.next == item(1))
        #expect(harness.recorder.applied.last?.warm == false)

        harness.recorder.status = VideoBufferStatus(bufferedAhead: 6, duration: 60, isComplete: false)
        harness.clock.tick()
        #expect(!harness.coordinator.fillSlots.isPaused)
        #expect(harness.recorder.applied.last?.warm == true)

        harness.recorder.status = VideoBufferStatus(bufferedAhead: 1, duration: 60, isComplete: false)
        harness.clock.tick()
        #expect(harness.coordinator.fillSlots.isPaused)
        harness.lookahead.stop()
        #expect(!harness.coordinator.fillSlots.isPaused)
        #expect(harness.recorder.applied.last.map { $0.next == nil && $0.previous == nil } == true)
    }

    /// ⚠️ A CLIP THAT NEVER BECOMES READY DOES NOT HOLD THE APP'S PREFETCH.
    /// Not ready yet counts as under-buffered for 5 s of the injected clock,
    /// then the pause is released and +1 is warmed; a failed item never
    /// pauses anything, and opens the page's P2 at once.
    @Test func aClipThatNeverGetsReadyReleasesThePauseAfterAGrace() async throws {
        let harness = try makeHarness()
        harness.recorder.status = nil
        settle(harness, on: 0)
        #expect(harness.coordinator.fillSlots.isPaused)
        harness.clock.advance(by: 4.9)
        #expect(harness.coordinator.fillSlots.isPaused)
        #expect(harness.recorder.applied.last?.warm == false)
        harness.clock.advance(by: 0.2)
        #expect(!harness.coordinator.fillSlots.isPaused, "a stuck item held P2 for the whole app")
        #expect(harness.recorder.applied.last?.warm == true)
        #expect(harness.lookahead.requestedHeads.isEmpty, "the page's own P2 still waits for a buffer")

        // A new page starts its own grace.
        settle(harness, on: 1)
        #expect(harness.coordinator.fillSlots.isPaused)

        // Failed: nothing to protect, and the page's P2 opens.
        harness.recorder.failed = true
        harness.clock.tick()
        #expect(!harness.coordinator.fillSlots.isPaused)
        #expect(harness.recorder.applied.last?.warm == true)
        #expect(harness.lookahead.requestedHeads == [item(3), item(4)])
    }

    // MARK: - Cancel on swipe

    /// ⚠️ A SWIPE CANCELS EVERY P2. The heads in flight for the page left are
    /// cancelled on the wire, and the new page asks for nothing until its own
    /// video has buffered enough.
    @Test func aSwipeCancelsEveryHeadPreload() async throws {
        let harness = try makeHarness()
        harness.recorder.status = Self.buffered
        settle(harness, on: 0)
        #expect(await eventually { harness.fetcher.requests.count == 2 })
        #expect(harness.lookahead.activeHeadInterests == 2)

        harness.recorder.status = nil
        settle(harness, on: 1)
        #expect(await eventually { harness.fetcher.cancelledCount == 2 })
        #expect(harness.lookahead.requestedHeads.isEmpty)
        #expect(!harness.cache.isPreloadingHead(of: remote(2)))
        #expect(!harness.cache.isPreloadingHead(of: remote(3)))
        #expect(harness.recorder.applied.last?.previous == item(0))

        harness.recorder.status = Self.buffered
        harness.clock.tick()
        #expect(harness.lookahead.requestedHeads == [item(3), item(4)])
    }

    /// The pool's P2 allowance holds across every head: with one slot, the
    /// second head waits for the first.
    @Test func headPreloadsShareTheCoordinatorsAllowance() async throws {
        let harness = try makeHarness(slots: 1)
        harness.recorder.status = Self.buffered
        settle(harness, on: 0)
        try #require(await eventually { harness.fetcher.requests.count == 1 })
        #expect(await eventually { harness.slots.waitingCount == 1 })
        harness.fetcher.deliver(0, bytes: .max)
        #expect(await eventually { harness.fetcher.requests.count == 2 })
    }
}
