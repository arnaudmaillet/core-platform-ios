import AVFoundation
import CacheKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MediaPlayback

/// Songs and sound previews on the video byte cache (#895): a progressive
/// MP3 or M4A over HTTP(S) opens through the same resource loader as a clip,
/// with the same chunks and tiers, and is fetched once. Its bytes go to the
/// sound namespaces, counted and cleared as Music & Sounds (#1068), not as
/// Videos.
@MainActor
struct SoundByteCacheTests {
    private let folder = VideoCacheFolder()
    private let song = URL(string: "https://media.example.test/s/song.m4a")!
    private let clip = URL(string: "https://media.example.test/v/clip.mp4")!

    private struct IdentitySource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func makeCache(
        _ fetcher: FakeRangeFetcher, chunkSize: Int64 = VideoByteCache.chunkSize, coordinator: CacheCoordinator? = nil
    ) -> VideoByteCache {
        VideoByteCache(coordinator: coordinator, root: folder.url, fetcher: fetcher, chunkSize: chunkSize, cancelGrace: 0)
    }

    private func makePool(_ fetcher: FakeRangeFetcher) -> (VideoPlaybackController, VideoByteCache) {
        let cache = makeCache(fetcher)
        return (VideoPlaybackController(source: IdentitySource(), byteCache: cache), cache)
    }

    private func makeCoordinator() -> CacheCoordinator {
        CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
    }

    /// Plays `url`'s first `length` bytes through a playback loader for
    /// `content`, as a player would, then lets the loader go (its leases
    /// end, as when the player is released).
    private func play(
        _ url: URL, as content: VideoByteCache.Content, length: Int64, in cache: VideoByteCache
    ) async throws {
        let loader = cache.makeLoader(for: url, mode: .playback, priority: .visible, content: content)
        let request = FakeLoadingRequest(info: true, offset: 0, length: length)
        let queue = cache.queue
        queue.sync { loader.handle(request, id: ObjectIdentifier(request)) }
        try #require(await eventually { queue.sync { request.finished } })
        #expect(queue.sync { request.failure } == nil)
        queue.sync { loader.invalidate() }
    }

    /// ⚠️ THE REAL PLAYER, ON A SONG. A pool's `soundItem` opens a remote M4A
    /// on the private scheme: AVFoundation loads its length and its audio
    /// track from bytes the cache fetched, the head lands in the SOUND
    /// namespace as a played head (`retained`, the clips' tier), none in the
    /// clips', and a second item for the same song (the next page set to it,
    /// a preview of it) starts from cached bytes with no network at all.
    @Test func aSongLandsInTheSoundNamespaceAndIsFetchedOnce() async throws {
        let file = try ToneWriter.tone(named: "byte-cache-song", seconds: 4, compressed: true) { _ in (440, 0.5) }
        let fetcher = FakeRangeFetcher()
        fetcher.serve(try Data(contentsOf: file), at: song, mime: "audio/mp4")
        let (pool, cache) = makePool(fetcher)

        let first = pool.soundItem(for: song)
        #expect(cache.isCached(first.asset))
        let duration = try await first.asset.load(.duration)
        #expect(abs(duration.seconds - 4) < 0.2)
        #expect(try await first.asset.loadTracks(withMediaType: .audio).count == 1)
        let fetched = fetcher.requests.count
        #expect(fetched > 0)
        #expect(fetcher.requests.allSatisfy { $0.url == song && !$0.speculative })
        let head = VideoCacheKeys.chunk(CacheKey.media(song), 0)
        #expect(await eventually { cache.soundStore.contains(head) })
        #expect(cache.soundStore.tier(of: head) == .retained)
        #expect(!cache.publicStore.contains(head), "a song's bytes landed with the clips")
        #expect(!cache.publicStore.contains(VideoCacheKeys.info(CacheKey.media(song))))

        let second = pool.soundItem(for: song)
        let again = try await second.asset.load(.duration)
        #expect(abs(again.seconds - duration.seconds) < 0.01)
        _ = try await second.asset.loadTracks(withMediaType: .audio)
        #expect(fetcher.requests.count == fetched, "a cached range of the song went back to the network")
        #expect(cache.statisticsSnapshot.firstRangeHits >= 1)
    }

    /// Settings → Storage reads the coordinator's categories: a song's bytes
    /// count as Music & Sounds, and Videos holds the clip's alone. A signed
    /// song goes to `sound.signed`, still Music & Sounds.
    @Test func songBytesAreCountedAsSoundsNotVideos() async throws {
        let signedSong = URL(string: "https://media.example.test/s/own.m4a?X-Amz-Signature=abc&X-Amz-Expires=60")!
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(1500), at: song, mime: "audio/mp4")
        fetcher.serve(videoBytes(1200, seed: 5), at: signedSong, mime: "audio/mp4")
        fetcher.serve(videoBytes(2500, seed: 3), at: clip)
        let coordinator = makeCoordinator()
        let cache = makeCache(fetcher, chunkSize: 1000, coordinator: coordinator)

        try await play(song, as: .sound, length: 1500, in: cache)
        try await play(signedSong, as: .sound, length: 1200, in: cache)
        try await play(clip, as: .clip, length: 2500, in: cache)

        let usage = coordinator.usage()
        let clipBytes = cache.publicStore.usage.bytes
        #expect(clipBytes >= 2500)
        #expect(usage.bytes(in: .videos) == clipBytes, "Videos counts the clip's bytes and nothing else")
        #expect(usage.bytes(in: .sounds) == cache.soundStore.usage.bytes + cache.signedSoundStore.usage.bytes)
        #expect(cache.soundStore.usage.bytes >= 1500)
        #expect(cache.signedSoundStore.usage.bytes >= 1200, "a signed song is a sound too")
        #expect(cache.signedStore.usage.bytes == 0)
    }

    /// Clear Music & Sounds removes the songs and leaves the clips; Clear
    /// Videos removes the clips and leaves the songs.
    @Test func eachCategorysClearRemovesItsOwnBytesOnly() async throws {
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(1500), at: song, mime: "audio/mp4")
        fetcher.serve(videoBytes(2500, seed: 3), at: clip)
        let coordinator = makeCoordinator()
        let cache = makeCache(fetcher, chunkSize: 1000, coordinator: coordinator)
        let songHead = VideoCacheKeys.chunk(CacheKey.media(song), 0)
        let clipHead = VideoCacheKeys.chunk(CacheKey.media(clip), 0)

        try await play(song, as: .sound, length: 1500, in: cache)
        try await play(clip, as: .clip, length: 2500, in: cache)
        try #require(cache.soundStore.contains(songHead) && cache.publicStore.contains(clipHead))

        coordinator.trim(.clear(.videos))
        #expect(!cache.publicStore.contains(clipHead), "Clear Videos left the clip")
        #expect(cache.soundStore.contains(songHead), "Clear Videos removed a song")
        #expect(coordinator.usage().bytes(in: .videos) == 0)
        #expect(coordinator.usage().bytes(in: .sounds) == cache.soundStore.usage.bytes)
        #expect(cache.soundStore.usage.bytes >= 1500)

        try await play(clip, as: .clip, length: 2500, in: cache)
        coordinator.trim(.clear(.sounds))
        #expect(!cache.soundStore.contains(songHead), "Clear Music & Sounds left the song")
        #expect(coordinator.usage().bytes(in: .sounds) == 0)
        #expect(cache.publicStore.contains(clipHead), "Clear Music & Sounds removed a clip")
    }

    /// The sounds keep the clips' place in the budget: the same `.video`
    /// pool (the 5 of the 3:5:1 split) and the same `standard` class, so
    /// every memory and disk signal treats them as it treats clips, and the
    /// same scopes (a signed song goes with the viewer). Their namespaces
    /// take a fifth of the pool's shared bytes.
    @Test func soundsKeepTheVideoPoolTheClipsClassAndTheirScopes() async throws {
        let coordinator = makeCoordinator()
        let cache = makeCache(FakeRangeFetcher(), coordinator: coordinator)
        await cache.waitUntilStoresAreOpen()

        let sound = VideoByteCache.soundNamespace
        let signedSound = VideoByteCache.signedSoundNamespace
        #expect(sound.category == .sounds && signedSound.category == .sounds)
        #expect(sound.priorityClass == VideoByteCache.publicNamespace.priorityClass)
        #expect(signedSound.priorityClass == VideoByteCache.signedNamespace.priorityClass)
        #expect(sound.scope == .public && signedSound.scope == .signed)
        #expect(VideoByteCache.soundDiskBudget.pool == .video && VideoByteCache.signedSoundDiskBudget.pool == .video)
        #expect(!VideoByteCache.soundDiskBudget.isReserved)

        let registered = coordinator.registeredCaches.map(\.namespace)
        #expect(registered.contains(sound) && registered.contains(signedSound))
        coordinator.waitForDiskWork()
        let usage = coordinator.usage()
        func limit(_ name: String) -> Int { usage.usage(of: name, medium: .disk)?.byteLimit ?? 0 }
        let pool = coordinator.diskPoolBudgets.video
        #expect(limit("video") + limit("video.signed") + limit("sound") + limit("sound.signed") == pool)
        #expect(limit("sound") + limit("sound.signed") == pool / 5)
        #expect(limit("sound") == 3 * limit("sound.signed"), "public 3 : signed 1, as the clips")
    }

    /// A signed song is wiped with the viewer; a public one is kept, as the
    /// clips are.
    @Test func aViewerChangeWipesSignedSongsAndKeepsPublicOnes() async throws {
        let signedSong = URL(string: "https://media.example.test/s/own.m4a?X-Amz-Signature=abc&X-Amz-Expires=60")!
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(1500), at: song, mime: "audio/mp4")
        fetcher.serve(videoBytes(1500, seed: 5), at: signedSong, mime: "audio/mp4")
        let coordinator = makeCoordinator()
        let cache = makeCache(fetcher, chunkSize: 1000, coordinator: coordinator)
        try await play(song, as: .sound, length: 1500, in: cache)
        try await play(signedSong, as: .sound, length: 1500, in: cache)
        let signedHead = VideoCacheKeys.chunk(CacheKey.media(signedSong), 0)
        try #require(cache.signedSoundStore.contains(signedHead))

        coordinator.trim(.viewerChanged)
        #expect(!cache.signedSoundStore.contains(signedHead))
        #expect(cache.soundStore.contains(VideoCacheKeys.chunk(CacheKey.media(song), 0)))
    }

    /// A post's original sound IS its clip: once the clip played, a preview
    /// of its sound reads the clip's copy, with no network and no second
    /// copy in the sound namespace.
    @Test func aPostsOriginalSoundReadsItsClipsCopy() async throws {
        let fetcher = FakeRangeFetcher()
        fetcher.serve(videoBytes(2500, seed: 3), at: clip)
        let cache = makeCache(fetcher, chunkSize: 1000)
        try await play(clip, as: .clip, length: 2500, in: cache)
        let fetched = fetcher.requests.count
        #expect(fetched > 0)

        try await play(clip, as: .sound, length: 2500, in: cache)
        #expect(fetcher.requests.count == fetched, "the original sound fetched its clip again")
        #expect(cache.soundStore.usage.bytes == 0, "a second copy of the clip landed in the sound namespace")
    }

    /// A local song (the mock catalogue's, a file the author picked) opens
    /// directly: there is nothing to cache.
    @Test func aLocalSongOpensDirectly() throws {
        let file = try ToneWriter.steady(seconds: 1)
        let (pool, cache) = makePool(FakeRangeFetcher())
        let item = pool.soundItem(for: file)
        #expect(!cache.isCached(item.asset))
        #expect((item.asset as? AVURLAsset)?.url == file)
        // And a pool without a cache opens a remote song directly too.
        let bare = VideoPlaybackController(source: IdentitySource())
        #expect((bare.soundItem(for: song).asset as? AVURLAsset)?.url == song)
    }

    /// An MP3 is answered as an MP3: by its MIME type, or by its extension
    /// when the server sends a generic one.
    @Test func anMP3IsAnsweredAsAudio() {
        let mp3 = URL(string: "https://media.example.test/s/track.mp3")!
        #expect(VideoRangeLoader.contentType(mime: "audio/mpeg", url: mp3) == UTType.mp3.identifier)
        #expect(VideoRangeLoader.contentType(mime: "application/octet-stream", url: mp3) == UTType.mp3.identifier)
        #expect(VideoRangeLoader.contentType(mime: "audio/mp4", url: song) == UTType.mpeg4Audio.identifier)
        #expect(VideoByteCache.isCacheable(mp3))
    }
}
