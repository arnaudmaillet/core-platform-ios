import AVFoundation
import CacheKit
import Foundation
import Testing
@testable import MediaPlayback

/// The video cache opens its disk stores off the caller's thread (#1018):
/// the app creates it on main, with its first playback pool, and opening a
/// store reads an index and lists a folder.
@MainActor
struct VideoStoreOpeningTests {
    private let folder = VideoCacheFolder()
    private let publicURL = URL(string: "https://media.example.test/v/open.mp4")!
    private let signedURL = URL(string: "https://media.example.test/v/own.mp4?X-Amz-Signature=abc&X-Amz-Expires=60")!

    private struct ClipSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    /// ⚠️ **NEVER AN INDEX ON MAIN.** The cache and the first playback pool
    /// are created on the main actor, as `AppContainer` creates them; the
    /// stores still open on the cache's queue.
    @Test func creatingTheFirstPlaybackPoolOpensNoIndexOnMain() async throws {
        // On the main actor, as `AppContainer` (the suite is `@MainActor`).
        let cache = VideoByteCache(coordinator: nil, root: folder.url, fetcher: FakeRangeFetcher())
        let pool = VideoPlaybackController(source: ClipSource(), byteCache: cache)
        #expect(pool.byteCache === cache)
        await cache.waitUntilStoresAreOpen()
        #expect(cache.storesOpenedOnMainThread == false, "a video store opened its index on the main thread")
    }

    /// Writes a public and a signed head under `folder`, with one cache that
    /// is gone afterwards: one store per namespace per folder at a time.
    private func seedHeads() async throws {
        let seeding = VideoByteCache(coordinator: nil, root: folder.url, fetcher: FakeRangeFetcher())
        await seeding.waitUntilStoresAreOpen()
        let info = try JSONEncoder().encode(VideoContentInfo(length: 1500, contentType: "public.mpeg-4"))
        for url in [publicURL, signedURL] {
            let store = try #require(seeding.store(for: url))
            let key = CacheKey.media(url)
            try store.write(info, for: VideoCacheKeys.info(key), tier: .retained)
            try store.write(videoBytes(1000), for: VideoCacheKeys.chunk(key, 0), tier: .retained)
            store.flush()
        }
        #expect(seeding.hasHead(of: publicURL) && seeding.hasHead(of: signedURL), "guard: the seed was not written")
    }

    /// ⚠️ **A LOGOUT DURING THE OPEN STILL WIPES SIGNED VIDEO.** The open is
    /// held; meanwhile the synchronous check answers "not cached", and the
    /// coordinator's viewer change is kept and applied when the stores
    /// attach. Public video stays.
    @Test func aLogoutDuringTheOpenStillWipesSignedVideo() async throws {
        try await seedHeads()
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let gate = DispatchSemaphore(value: 0)
        let cache = VideoByteCache(
            coordinator: coordinator, root: folder.url, fetcher: FakeRangeFetcher(), beforeOpen: { gate.wait() }
        )
        let registered = coordinator.registeredCaches.map(\.namespace)
        #expect(registered.contains(VideoByteCache.signedNamespace), "the signed namespace waited for its store to register")
        #expect(!cache.hasHead(of: publicURL), "a check answered from a store still opening")
        #expect(cache.storesOpenedOnMainThread == nil)

        coordinator.trim(.viewerChanged)
        gate.signal()
        await cache.waitUntilStoresAreOpen()

        #expect(!cache.hasHead(of: signedURL), "the logout during the open left signed video on disk")
        #expect(cache.hasHead(of: publicURL), "the logout wiped public video")
        #expect(cache.storesOpenedOnMainThread == false)
    }

    /// A load waits for the open: a player's first request, made while the
    /// stores are still opening, is answered from disk once they are.
    @Test func aLoadMadeDuringTheOpenIsServedFromDisk() async throws {
        try await seedHeads()
        let fetcher = FakeRangeFetcher()
        let gate = DispatchSemaphore(value: 0)
        let cache = VideoByteCache(
            coordinator: nil, root: folder.url, fetcher: fetcher, chunkSize: 1000, beforeOpen: { gate.wait() }
        )
        let loader = cache.makeLoader(for: publicURL, mode: .playback, priority: .visible)
        let request = FakeLoadingRequest(info: true, offset: 0, length: 1000)
        let queue = cache.queue
        queue.async { loader.handle(request, id: ObjectIdentifier(request)) }
        gate.signal()
        try #require(await eventually { queue.sync { request.finished } })
        #expect(queue.sync { request.received } == videoBytes(1000))
        #expect(fetcher.requests.isEmpty, "a load during the open went to the network")
        withExtendedLifetime(loader) {}
    }
}
