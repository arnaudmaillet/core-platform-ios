import AVFoundation
import CacheKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MediaPlayback

/// Songs and sound previews on the video byte cache (#895): a progressive
/// MP3 or M4A over HTTP(S) opens through the same resource loader as a clip,
/// lands in the same namespaces with the same tiers, and is fetched once.
@MainActor
struct SoundByteCacheTests {
    private let folder = VideoCacheFolder()
    private let song = URL(string: "https://media.example.test/s/song.m4a")!

    private struct IdentitySource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func makePool(_ fetcher: FakeRangeFetcher) -> (VideoPlaybackController, VideoByteCache) {
        let cache = VideoByteCache(
            coordinator: nil, root: folder.url, fetcher: fetcher, chunkSize: VideoByteCache.chunkSize, cancelGrace: 0
        )
        return (VideoPlaybackController(source: IdentitySource(), byteCache: cache), cache)
    }

    /// ⚠️ THE REAL PLAYER, ON A SONG. A pool's `soundItem` opens a remote M4A
    /// on the private scheme: AVFoundation loads its length and its audio
    /// track from bytes the cache fetched, the head lands on disk as a played
    /// head (`retained`), and a second item for the same song (the next page
    /// set to it, a preview of it) loads with no network at all.
    @Test func aSongReadsThroughTheByteCacheAndIsFetchedOnce() async throws {
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
        #expect(await eventually { cache.publicStore.contains(head) })
        #expect(cache.publicStore.tier(of: head) == .retained)

        let second = pool.soundItem(for: song)
        let again = try await second.asset.load(.duration)
        #expect(abs(again.seconds - duration.seconds) < 0.01)
        _ = try await second.asset.loadTracks(withMediaType: .audio)
        #expect(fetcher.requests.count == fetched, "a cached range of the song went back to the network")
        #expect(cache.statisticsSnapshot.firstRangeHits >= 1)
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
