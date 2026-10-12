import AVFoundation
import CacheKit
import Foundation
import Testing
@testable import MediaPlayback

/// The video byte cache (#895): ranges served from disk, gaps fetched and
/// written back, cancels honoured, heads preloaded, and the eviction order
/// that keeps played heads longest.
///
/// Loaders are driven with fake requests and a fake fetcher, so every byte
/// and every range asked of the network is visible. One test plays a real
/// asset through AVFoundation on the private scheme.
struct VideoByteCacheTests {
    private let folder = VideoCacheFolder()
    private let url = URL(string: "https://media.example.test/v/clip.mp4")!

    private func makeCache(_ fetcher: FakeRangeFetcher, chunkSize: Int64 = 1000, coordinator: CacheCoordinator? = nil) throws -> VideoByteCache {
        VideoByteCache(
            coordinator: coordinator, root: folder.url, fetcher: fetcher, chunkSize: chunkSize, cancelGrace: 0
        )
    }

    private func handle(_ request: FakeLoadingRequest, on loader: VideoRangeLoader, in cache: VideoByteCache) {
        cache.queue.sync { loader.handle(request, id: ObjectIdentifier(request)) }
    }

    private func isFinished(_ request: FakeLoadingRequest, in cache: VideoByteCache) -> Bool {
        cache.queue.sync { request.finished }
    }

    private func store(_ cache: VideoByteCache, chunk: Int, of source: Data, chunkSize: Int64, tier: CacheTier = .recent) throws {
        let key = CacheKey.media(url)
        let start = Int(Int64(chunk) * chunkSize)
        let end = min(start + Int(chunkSize), source.count)
        try cache.publicStore.write(source.subdata(in: start ..< end), for: VideoCacheKeys.chunk(key, chunk), tier: tier)
    }

    private func storeInfo(_ cache: VideoByteCache, length: Int) throws {
        let info = VideoContentInfo(length: Int64(length), contentType: "public.mpeg-4")
        try cache.publicStore.write(JSONEncoder().encode(info), for: VideoCacheKeys.info(CacheKey.media(url)), tier: .recent)
    }

    // MARK: - Serving

    /// ⚠️ ONLY THE GAPS. Chunks 0 and 2 are on disk; a request for the whole
    /// file fetches chunk 1 and the run 3–4, nothing else, and the player gets
    /// every byte in order.
    @Test func cachedRangesAreServedAndOnlyTheGapsAreFetched() async throws {
        let source = videoBytes(5000)
        let fetcher = FakeRangeFetcher()
        fetcher.serve(source, at: url)
        let cache = try makeCache(fetcher)
        try storeInfo(cache, length: 5000)
        try store(cache, chunk: 0, of: source, chunkSize: 1000)
        try store(cache, chunk: 2, of: source, chunkSize: 1000)

        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let request = FakeLoadingRequest(info: true, offset: 0, length: 5000, toEnd: true)
        handle(request, on: loader, in: cache)
        #expect(await eventually { isFinished(request, in: cache) })

        let (received, info, failure) = cache.queue.sync { (request.received, request.info, request.failure) }
        #expect(failure == nil)
        #expect(received == source)
        #expect(info == VideoContentInfo(length: 5000, contentType: "public.mpeg-4"))
        #expect(fetcher.requests.map { [$0.offset, $0.end ?? -1] } == [[1000, 2000], [3000, 5000]])
        #expect(fetcher.requests.allSatisfy { !$0.speculative })
        // The gaps were written back: a second player needs no network.
        let again = FakeLoadingRequest(info: true, offset: 0, length: 5000, toEnd: true)
        let second = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        handle(again, on: second, in: cache)
        #expect(await eventually { isFinished(again, in: cache) })
        #expect(cache.queue.sync { again.received } == source)
        #expect(fetcher.requests.count == 2)
    }

    /// ⚠️ AIRPLANE MODE. A video watched to its end in this session replays
    /// with the network gone: every range, and the content information, come
    /// from disk, and nothing is asked of the network.
    @Test func aWatchedVideoReplaysWithTheNetworkGone() async throws {
        let source = videoBytes(4500)
        let fetcher = FakeRangeFetcher()
        fetcher.serve(source, at: url)
        let cache = try makeCache(fetcher)
        let watch = FakeLoadingRequest(info: true, offset: 0, length: 4500, toEnd: true)
        let first = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        handle(watch, on: first, in: cache)
        #expect(await eventually { isFinished(watch, in: cache) })
        cache.queue.sync { first.invalidate() }
        let fetched = fetcher.requests.count

        fetcher.goOffline()
        let replay = FakeLoadingRequest(info: true, offset: 0, length: 4500, toEnd: true)
        let offline = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        handle(replay, on: offline, in: cache)
        #expect(await eventually { isFinished(replay, in: cache) })
        let (received, info, failure) = cache.queue.sync { (replay.received, replay.info, replay.failure) }
        #expect(failure == nil)
        #expect(info?.length == 4500)
        #expect(received == source)
        #expect(fetcher.requests.count == fetched, "the replay went to the network")
    }

    /// An empty cache answers the content-information request from the first
    /// response, which fetches exactly the head chunk.
    @Test func contentInformationComesFromTheFirstResponse() async throws {
        let source = videoBytes(5000)
        let fetcher = FakeRangeFetcher()
        fetcher.serve(source, at: url, mime: "video/mp4")
        let cache = try makeCache(fetcher)
        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let probe = FakeLoadingRequest(info: true, offset: 0, length: 2)
        handle(probe, on: loader, in: cache)
        #expect(await eventually { isFinished(probe, in: cache) })

        let (info, received) = cache.queue.sync { (probe.info, probe.received) }
        #expect(info?.length == 5000)
        #expect(info?.contentType == UTType.mpeg4Movie.identifier)
        #expect(received == source.prefix(2))
        #expect(fetcher.requests.map { [$0.offset, $0.end ?? -1] } == [[0, 1000]])
        let key = CacheKey.media(url)
        #expect(await eventually { cache.publicStore.contains(VideoCacheKeys.chunk(key, 0)) })
        // A player's head is a PLAYED head: it ranks above every tail.
        #expect(cache.publicStore.tier(of: VideoCacheKeys.chunk(key, 0)) == .retained)
        #expect(cache.statisticsSnapshot.firstRangeMisses == 1)
    }

    // MARK: - Cancel

    /// ⚠️ `didCancel` STOPS THE NETWORK. A request cancelled mid-body cancels
    /// the fetch nobody else waits on, keeps the partial chunk it got, and the
    /// next request resumes from where it stopped instead of from the chunk's
    /// start.
    @Test func aCancelledRequestCancelsItsFetchAndKeepsThePartialChunk() async throws {
        let chunk: Int64 = 200_000
        let source = videoBytes(500_000)
        let fetcher = FakeRangeFetcher(holds: true)
        fetcher.serve(source, at: url)
        let cache = try makeCache(fetcher, chunkSize: chunk)
        try storeInfo(cache, length: 500_000)

        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let request = FakeLoadingRequest(offset: 0, length: 500_000, toEnd: true)
        handle(request, on: loader, in: cache)
        try #require(fetcher.requests.map { [$0.offset, $0.end ?? -1] } == [[0, 500_000]])
        fetcher.deliver(0, bytes: 100_000)
        cache.queue.sync {}
        #expect(cache.queue.sync { request.received.count } == 100_000)

        cache.queue.sync { loader.cancel(id: ObjectIdentifier(request)) }
        #expect(fetcher.task(0)?.isCancelled == true)
        #expect(cache.queue.sync { loader.fetchCount } == 0)
        let key = CacheKey.media(url)
        #expect(cache.publicStore.contains(VideoCacheKeys.partial(key, 0)))
        #expect(!cache.publicStore.contains(VideoCacheKeys.chunk(key, 0)))
        // Bytes after the cancel reach nobody.
        fetcher.deliver(0, bytes: 100_000)
        cache.queue.sync {}
        #expect(cache.queue.sync { request.received.count } == 100_000)

        // A new player resumes the chunk from the partial.
        let next = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let resumed = FakeLoadingRequest(offset: 0, length: chunk)
        handle(resumed, on: next, in: cache)
        try #require(fetcher.requests.last.map { [$0.offset, $0.end ?? -1] } == [100_000, 200_000])
        fetcher.deliver(1, bytes: .max)
        #expect(await eventually { isFinished(resumed, in: cache) })
        #expect(cache.queue.sync { resumed.received } == source.prefix(Int(chunk)))
        #expect(cache.publicStore.contains(VideoCacheKeys.chunk(key, 0)))
        #expect(!cache.publicStore.contains(VideoCacheKeys.partial(key, 0)), "the partial outlived its chunk")
    }

    /// The asset going away (its loader invalidated) ends every fetch too.
    @Test func anInvalidatedLoaderCancelsItsFetches() throws {
        let fetcher = FakeRangeFetcher(holds: true)
        fetcher.serve(videoBytes(5000), at: url)
        let cache = try makeCache(fetcher)
        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let request = FakeLoadingRequest(info: true, offset: 0, length: 2)
        handle(request, on: loader, in: cache)
        try #require(fetcher.requests.count == 1)
        cache.queue.sync { loader.invalidate() }
        #expect(fetcher.task(0)?.isCancelled == true)
        #expect(cache.queue.sync { request.finished && request.failure != nil })
    }

    // MARK: - Head preload

    /// ⚠️ THE +2/+3 PRELOAD. A head preload writes the first chunk (1 MB in
    /// the app) as a SPECULATIVE entry with one speculative range request and
    /// no player; the player that comes later reads it with no network, and
    /// its first range counts as a hit.
    @Test func aHeadPreloadIsServedToThePlayerWithoutNetwork() async throws {
        let source = videoBytes(3000)
        let fetcher = FakeRangeFetcher()
        fetcher.serve(source, at: url)
        let cache = try makeCache(fetcher)
        let owner = CacheOwner("test")
        let interest = cache.preloadHead(of: url, owner: owner)
        #expect(interest != nil)
        #expect(await cache.headPreloadLanded(of: url))
        #expect(fetcher.requests == [.init(url: url, offset: 0, end: 1000, speculative: true)])
        let key = CacheKey.media(url)
        #expect(cache.publicStore.tier(of: VideoCacheKeys.chunk(key, 0)) == .speculative)
        #expect(cache.publicStore.tier(of: VideoCacheKeys.info(key)) == .speculative)
        #expect(cache.statisticsSnapshot.headPreloads == 1, "counted before the preload ends")
        // Nothing to do a second time.
        #expect(cache.preloadHead(of: url, owner: owner) == nil)

        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let first = FakeLoadingRequest(info: true, offset: 0, length: 1000)
        handle(first, on: loader, in: cache)
        #expect(await eventually { isFinished(first, in: cache) })
        #expect(cache.queue.sync { first.received } == source.prefix(1000))
        #expect(fetcher.requests.count == 1, "the player fetched a head that was on disk")
        #expect(cache.statisticsSnapshot.firstRangeHits == 1)
        // Played now: it ranks as a played head.
        #expect(cache.publicStore.tier(of: VideoCacheKeys.chunk(key, 0)) == .retained)
    }

    /// A preload whose owner is revoked (the swipe) is cancelled on the wire.
    @Test func aRevokedOwnerCancelsItsHeadPreload() async throws {
        let fetcher = FakeRangeFetcher(holds: true)
        fetcher.serve(videoBytes(3000), at: url)
        let cache = try makeCache(fetcher)
        let owner = CacheOwner("swipe")
        cache.preloadHead(of: url, owner: owner)
        await fetcher.requestsArrived(1)
        owner.revoke()
        #expect(await eventually { fetcher.task(0)?.isCancelled == true })
        #expect(await eventually { !cache.isPreloadingHead(of: url) })
        #expect(!cache.hasHead(of: url))
    }

    // MARK: - Eviction

    /// ⚠️ TAILS GO BEFORE HEADS. Under a shrinking budget the store evicts the
    /// speculative heads first (never played), then the watched tails, and the
    /// played heads last: a replay or a swipe back needs the head.
    @Test func speculativeHeadsGoFirstThenWatchedTailsThenPlayedHeads() async throws {
        let played = url
        let preloaded = URL(string: "https://media.example.test/v/next.mp4")!
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(3000), at: played)
        fetcher.serve(videoBytes(3000, seed: 9), at: preloaded)
        let cache = try makeCache(fetcher)

        let loader = cache.makeLoader(for: played, mode: .playback, priority: .visible)
        let watch = FakeLoadingRequest(info: true, offset: 0, length: 3000, toEnd: true)
        handle(watch, on: loader, in: cache)
        #expect(await eventually { isFinished(watch, in: cache) })
        // Held: an owner revokes itself when it goes.
        let owner = CacheOwner("preload")
        cache.preloadHead(of: preloaded, owner: owner)
        #expect(await cache.headPreloadLanded(of: preloaded))
        withExtendedLifetime(owner) {}
        // The player let go: its chunks are no longer pinned.
        cache.queue.sync { loader.invalidate() }

        let store = cache.publicStore
        let playedKey = CacheKey.media(played), preloadedKey = CacheKey.media(preloaded)
        let playedHead = VideoCacheKeys.chunk(playedKey, 0)
        let tails = [VideoCacheKeys.chunk(playedKey, 1), VideoCacheKeys.chunk(playedKey, 2)]
        let speculativeHead = VideoCacheKeys.chunk(preloadedKey, 0)
        #expect(store.tier(of: playedHead) == .retained)
        #expect(tails.allSatisfy { store.tier(of: $0) == .recent })
        #expect(store.tier(of: speculativeHead) == .speculative)

        let total = store.usage.bytes
        // One chunk's worth less: the speculative head goes, nothing else.
        store.setLimits(CacheLimits(bytes: total - 1000, speculativeBytes: total))
        #expect(!store.contains(speculativeHead))
        #expect(store.contains(playedHead) && tails.allSatisfy(store.contains))
        // Two more: both tails, before the played head.
        store.setLimits(CacheLimits(bytes: total - 3000, speculativeBytes: total))
        #expect(tails.allSatisfy { !store.contains($0) })
        #expect(store.contains(playedHead))
    }

    /// While a player holds the asset, its chunks are pinned: a budget cut
    /// takes everything else first.
    @Test func thePlayingVideosChunksArePinned() async throws {
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(3000), at: url)
        let cache = try makeCache(fetcher)
        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let watch = FakeLoadingRequest(info: true, offset: 0, length: 3000, toEnd: true)
        handle(watch, on: loader, in: cache)
        #expect(await eventually { isFinished(watch, in: cache) })
        let key = CacheKey.media(url)
        #expect(await eventually { cache.publicStore.isLeased(VideoCacheKeys.chunk(key, 2)) })
        cache.publicStore.setLimits(CacheLimits(bytes: 0, speculativeBytes: 0))
        #expect((0..<3).allSatisfy { cache.publicStore.contains(VideoCacheKeys.chunk(key, $0)) })
        cache.queue.sync { loader.invalidate() }
        #expect((0..<3).allSatisfy { !cache.publicStore.contains(VideoCacheKeys.chunk(key, $0)) })
    }

    // MARK: - Scope and policy

    /// ⚠️ LOGOUT KEEPS PUBLIC MEDIA. A signed URL's bytes live in the signed
    /// namespace, which the coordinator wipes on a viewer change; a public
    /// one's stay.
    @Test func aViewerChangeWipesSignedVideoAndKeepsPublicVideo() async throws {
        let signed = URL(string: "https://media.example.test/v/own.mp4?X-Amz-Signature=abc&X-Amz-Expires=60")!
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(1500), at: url)
        fetcher.serve(videoBytes(1500, seed: 3), at: signed)
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let cache = try makeCache(fetcher, coordinator: coordinator)
        #expect(CacheKey.isSigned(signed))
        #expect(!CacheKey.isSigned(url))
        let registered = coordinator.registeredCaches.map(\.namespace)
        #expect(registered.contains(VideoByteCache.publicNamespace))
        #expect(registered.contains(VideoByteCache.signedNamespace))

        let owner = CacheOwner("logout")
        cache.preloadHead(of: url, owner: owner)
        cache.preloadHead(of: signed, owner: owner)
        #expect(await cache.headPreloadLanded(of: url))
        #expect(await cache.headPreloadLanded(of: signed))
        withExtendedLifetime(owner) {}
        #expect(cache.signedStore.contains(VideoCacheKeys.chunk(CacheKey.media(signed), 0)))

        coordinator.trim(.viewerChanged)
        #expect(!cache.hasHead(of: signed))
        #expect(cache.hasHead(of: url))
    }

    /// The coordinator's prefetch counters (#900) see every playback's first
    /// range, hit or miss, for `-cache-audit`'s `nextVideoFirstRange`.
    @Test func firstRangesReachTheCoordinatorsCounters() async throws {
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(3000), at: url)
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let cache = try makeCache(fetcher, coordinator: coordinator)
        // Held: in the app the asset keeps its loader; a loader nobody holds
        // ends with its fetch events.
        let coldLoader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let cold = FakeLoadingRequest(info: true, offset: 0, length: 2)
        handle(cold, on: coldLoader, in: cache)
        try #require(await eventually { isFinished(cold, in: cache) })
        let warmLoader = cache.makeLoader(for: url, mode: .playback, priority: .visible)
        let warm = FakeLoadingRequest(info: true, offset: 0, length: 2)
        handle(warm, on: warmLoader, in: cache)
        try #require(await eventually { isFinished(warm, in: cache) })
        withExtendedLifetime((coldLoader, warmLoader)) {}
        let counters = coordinator.prefetchCounters.snapshot
        #expect(counters.nextVideoFirstRangeHits == 1)
        #expect(counters.nextVideoFirstRangeMisses == 1)
        cache.recordTimeToFirstFrame(0.25)
        #expect(coordinator.prefetchCounters.snapshot.firstFrame.count == 1)
    }

    /// HLS stays on the network path: a resource loader cannot serve its
    /// segments. Progressive HTTP(S) files go through the private scheme.
    @Test func onlyProgressiveHTTPFilesReadThroughTheCache() throws {
        let cache = try makeCache(FakeRangeFetcher())
        let hls = URL(string: "https://media.example.test/v/master.m3u8")!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("local.mp4")
        #expect(!VideoByteCache.isCacheable(hls))
        #expect(!VideoByteCache.isCacheable(file))
        #expect(VideoByteCache.isCacheable(url))
        #expect(!cache.isCached(cache.asset(for: hls)))
        #expect(cache.asset(for: hls).url == hls)
        let asset = cache.asset(for: url)
        #expect(cache.isCached(asset))
        #expect(asset.url.scheme == "cpvideo+https")
    }

    /// ⚠️ THE REAL PLAYER. AVFoundation opens an asset on the private scheme
    /// through the resource loader: the clip's duration loads from bytes the
    /// cache fetched, and a second asset for the same URL loads with no
    /// network at all.
    @Test func avFoundationLoadsAnAssetThroughTheCache() async throws {
        let clip = try await ColourClipWriter.clip()
        let data = try Data(contentsOf: clip)
        let fetcher = FakeRangeFetcher()
        let remote = URL(string: "https://media.example.test/v/colour.mov")!
        fetcher.serve(data, at: remote, mime: "video/quicktime")
        let cache = try makeCache(fetcher, chunkSize: VideoByteCache.chunkSize)

        let first = cache.asset(for: remote)
        let duration = try await first.load(.duration)
        #expect(abs(duration.seconds - Double(ColourClipWriter.seconds)) < 0.2)
        let tracks = try await first.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let fetched = fetcher.requests.count
        #expect(fetched > 0)

        let second = cache.asset(for: remote)
        let again = try await second.load(.duration)
        #expect(abs(again.seconds - duration.seconds) < 0.01)
        _ = try await second.loadTracks(withMediaType: .video)
        #expect(fetcher.requests.count == fetched, "a cached range went back to the network")
        #expect(cache.statisticsSnapshot.firstRangeHits >= 1)
    }
}
