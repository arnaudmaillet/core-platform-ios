import CacheKit
import Foundation
import Testing
@testable import MediaPlayback

/// The byte cache's pin on the ranges around a parked playhead (#895, the
/// #923 follow-up): what a resumed return player reads survives a budget cut
/// while the post is open, and goes back to the LRU once it is let go.
struct VideoRangePinTests {
    private let folder = VideoCacheFolder()
    private let url = URL(string: "https://media.example.test/v/tile.mp4")!
    private let chunkSize: Int64 = 1000
    private let length = 10_000

    private func makeCache() -> VideoByteCache {
        VideoByteCache(coordinator: nil, root: folder.url, fetcher: FakeRangeFetcher(), chunkSize: chunkSize, cancelGrace: 0)
    }

    private var media: String { CacheKey.media(url) }
    private func chunk(_ index: Int) -> String { VideoCacheKeys.chunk(media, index) }

    /// The whole file on disk as a player leaves it: content information, a
    /// played head (`retained`), watched tails (`recent`). Chunk 6 is only a
    /// cancelled fetch's prefix.
    private func seed(_ cache: VideoByteCache) throws {
        let store = cache.publicStore
        let source = videoBytes(length)
        let info = try JSONEncoder().encode(VideoContentInfo(length: Int64(length), contentType: "public.mpeg-4"))
        try store.write(info, for: VideoCacheKeys.info(media), tier: .retained)
        for index in 0..<10 {
            let start = index * Int(chunkSize)
            let bytes = source.subdata(in: start ..< start + Int(chunkSize))
            if index == 6 {
                try store.write(bytes.prefix(300), for: VideoCacheKeys.partial(media, 6), tier: .recent)
            } else {
                try store.write(bytes, for: chunk(index), tier: index == 0 ? .retained : .recent)
            }
        }
    }

    /// ⚠️ THE RANGES A RESUME READS, AND ONLY THOSE. Parked halfway through,
    /// the pin holds the content information, the head, the tail, and the
    /// chunks from one before the playhead's to three after it (the partial
    /// chunk 6 by its prefix). A budget cut to nothing then takes everything
    /// else, and the pinned ranges stay.
    @Test func aPinHoldsTheRangesAroundThePlayheadThroughABudgetCut() async throws {
        let cache = makeCache()
        try seed(cache)
        let store = cache.publicStore
        let pin = try #require(cache.pinRanges(of: url, near: 0.5))
        let pinned = [VideoCacheKeys.info(media), chunk(0), chunk(4), chunk(5), VideoCacheKeys.partial(media, 6),
                      chunk(7), chunk(8), chunk(9)]
        #expect(await eventually { pin.leaseCount == pinned.count })
        #expect(pinned.allSatisfy(store.isLeased))
        // A pin keeps tiers as they were: a watched range stays `recent`.
        #expect(store.tier(of: chunk(5)) == .recent)
        #expect(store.tier(of: chunk(0)) == .retained)

        store.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(pinned.allSatisfy(store.contains), "a budget cut dropped a range the parked clip will read")
        #expect([1, 2, 3].allSatisfy { !store.contains(chunk($0)) })

        // Let go, they are ordinary entries again: under a budget of nothing,
        // they go too.
        pin.release()
        #expect(pinned.allSatisfy { !store.isLeased($0) })
        store.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect(!store.contains(chunk(5)))
    }

    /// No playhead known: the ends only, where a player finds the file's index.
    @Test func aPinWithoutAPlayheadHoldsTheEndsOnly() async throws {
        let cache = makeCache()
        try seed(cache)
        let pin = try #require(cache.pinRanges(of: url, near: nil))
        #expect(await eventually { pin.leaseCount == 3 })
        #expect([VideoCacheKeys.info(media), chunk(0), chunk(9)].allSatisfy(cache.publicStore.isLeased))
        #expect(!cache.publicStore.isLeased(chunk(5)))
    }

    /// A release that overtakes the pinning (the player claimed or evicted
    /// before the cache's queue got to it) wins: nothing stays leased.
    @Test func aReleaseThatOvertakesThePinningWins() async throws {
        let cache = makeCache()
        try seed(cache)
        let gate = DispatchSemaphore(value: 0)
        cache.queue.async { gate.wait() }
        let pin = try #require(cache.pinRanges(of: url, near: 0.5))
        pin.release()
        gate.signal()
        await cache.waitUntilStoresAreOpen()
        #expect(pin.leaseCount == 0)
        #expect(!cache.publicStore.isLeased(chunk(5)))
        #expect(!cache.publicStore.isLeased(chunk(0)))
    }

    /// Nothing to pin for a file the cache never holds.
    @Test func aLocalFileIsNeverPinned() {
        let cache = makeCache()
        #expect(cache.pinRanges(of: FileManager.default.temporaryDirectory.appendingPathComponent("a.mp4"), near: 0.5) == nil)
    }
}
