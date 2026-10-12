import AVFoundation
import CacheKit
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import Testing
@testable import Feed

/// A page's song and the sound sheet's preview read through the device's
/// byte cache (#895), as the clips do: both take their item from the playback
/// pool (`soundItem(for:)`), which opens a remote song on the cache's private
/// scheme. What the cache then does with the bytes is MediaPlayback's
/// `SoundByteCacheTests`.
@MainActor
struct FeedSoundCacheTests {
    /// ONE cache for the process (`DiskStore`: one store per namespace), in
    /// the test host's own `Caches`. Nothing is fetched: the song's host does
    /// not exist, and each test lets its player go at once.
    private static let cache = VideoByteCache(
        coordinator: CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
    )

    private struct IdentitySource: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private let song = URL(string: "https://media.example.test/s/song.mp3")!

    private func pool() -> VideoPlaybackController {
        VideoPlaybackController(source: IdentitySource(), byteCache: Self.cache)
    }

    @Test func aPagesSongReadsThroughTheByteCache() throws {
        let player = FeedSongPlayer(playback: pool())
        player.play(song)
        defer { player.stop() }
        let item = try #require(player.currentItem)
        #expect(Self.cache.isCached(item.asset), "the page's song opened its URL, not the cache")
    }

    @Test func aSoundPreviewReadsThroughTheByteCache() throws {
        let sheet = SoundSheetViewController(
            sound: PostSound(id: "song-1", title: "Song", artist: nil, previewURL: song, artworkURL: nil, duration: 30),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            sections: [],
            tiles: [],
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool()
        )
        let player = sheet.makePreviewPlayer(for: song)
        defer { player.replaceCurrentItem(with: nil) }
        let item = try #require(player.currentItem)
        #expect(Self.cache.isCached(item.asset), "the sound sheet's preview opened its URL, not the cache")
    }

    /// No pool (a preview, a test), no cache: the song opens its URL.
    @Test func withoutAPoolASongOpensItsURL() throws {
        let player = FeedSongPlayer(playback: nil)
        player.play(song)
        defer { player.stop() }
        let asset = try #require(player.currentItem?.asset as? AVURLAsset)
        #expect(asset.url == song)
        #expect(!Self.cache.isCached(asset))
    }
}
