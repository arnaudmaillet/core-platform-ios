import AVFoundation
import CacheKit
import FeedInterface
import Foundation
import MediaCore
@testable import MediaPlayback
import Synchronization
import Testing
@testable import Feed

/// A page's song and the sound sheet's preview read through the device's
/// byte cache (#895), as the clips do: both take their item from the playback
/// pool (`soundItem(for:)`), which opens a remote song on the cache's private
/// scheme, into the sound namespaces (Music & Sounds in Settings → Storage,
/// #1068). What the cache then does with the bytes is MediaPlayback's
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

    private func makeSheet(previewURL: URL, videoPlayback: VideoPlaybackController?) -> SoundSheetViewController {
        SoundSheetViewController(
            sound: PostSound(id: "song-1", title: "Song", artist: nil, previewURL: previewURL, artworkURL: nil, duration: 30),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            sections: [],
            tiles: [],
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: videoPlayback
        )
    }

    @Test func aPagesSongReadsThroughTheByteCache() throws {
        let player = FeedSongPlayer(playback: pool())
        player.play(song)
        defer { player.stop() }
        let item = try #require(player.currentItem)
        #expect(Self.cache.isCached(item.asset), "the page's song opened its URL, not the cache")
    }

    @Test func aSoundPreviewReadsThroughTheByteCache() throws {
        let player = makeSheet(previewURL: song, videoPlayback: pool()).makePreviewPlayer(for: song)
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

    // MARK: - From cached bytes (#1068)

    /// A cache of its own, over a fetcher that serves a real AAC song and
    /// counts requests, with a coordinator to read the categories from.
    private struct Served {
        let folder: URL
        let fetcher: SongFetcher
        let coordinator: CacheCoordinator
        let cache: VideoByteCache
        let pool: VideoPlaybackController
        let song: URL
    }

    private func makeServed(_ name: String) throws -> Served {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "FeedSoundCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let remote = try #require(URL(string: "https://media.example.test/s/\(name).m4a"))
        let fetcher = SongFetcher(data: try SongFile.data(), at: remote)
        let coordinator = CacheCoordinator(device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { nil }))
        let cache = VideoByteCache(coordinator: coordinator, root: folder, fetcher: fetcher, cancelGrace: 0)
        let pool = VideoPlaybackController(source: IdentitySource(), byteCache: cache)
        return Served(folder: folder, fetcher: fetcher, coordinator: coordinator, cache: cache, pool: pool, song: remote)
    }

    /// Loads what a player needs to start: the length and the audio track.
    private func loadStart(of item: AVPlayerItem) async throws {
        let duration = try await item.asset.load(.duration)
        #expect(duration.seconds > 1)
        #expect(try await item.asset.loadTracks(withMediaType: .audio).count == 1)
    }

    /// The feed's page song: the second page set to the same song starts from
    /// the bytes the first one cached, with no request, and those bytes count
    /// as Music & Sounds, not Videos.
    @Test func aPagesSongStartsFromCachedBytesCountedAsSounds() async throws {
        let served = try makeServed("page-song")
        defer { try? FileManager.default.removeItem(at: served.folder) }
        let first = FeedSongPlayer(playback: served.pool)
        first.play(served.song)
        try await loadStart(of: try #require(first.currentItem))
        first.stop()
        let fetched = served.fetcher.requestCount
        #expect(fetched > 0)

        let next = FeedSongPlayer(playback: served.pool)
        next.play(served.song)
        defer { next.stop() }
        try await loadStart(of: try #require(next.currentItem))
        #expect(served.fetcher.requestCount == fetched, "the next page's song went back to the network")
        let usage = served.coordinator.usage()
        #expect(usage.bytes(in: .sounds) > 0)
        #expect(usage.bytes(in: .videos) == 0, "a song counted as Videos")
    }

    /// The sound sheet's preview: a second preview of the same sound starts
    /// from cached bytes, counted as Music & Sounds.
    @Test func aSoundPreviewStartsFromCachedBytesCountedAsSounds() async throws {
        let served = try makeServed("preview")
        defer { try? FileManager.default.removeItem(at: served.folder) }
        let sheet = makeSheet(previewURL: served.song, videoPlayback: served.pool)
        let first = sheet.makePreviewPlayer(for: served.song)
        try await loadStart(of: try #require(first.currentItem))
        first.replaceCurrentItem(with: nil)
        let fetched = served.fetcher.requestCount
        #expect(fetched > 0)

        let again = sheet.makePreviewPlayer(for: served.song)
        defer { again.replaceCurrentItem(with: nil) }
        try await loadStart(of: try #require(again.currentItem))
        #expect(served.fetcher.requestCount == fetched, "a second preview went back to the network")
        let usage = served.coordinator.usage()
        #expect(usage.bytes(in: .sounds) > 0)
        #expect(usage.bytes(in: .videos) == 0, "a preview counted as Videos")
    }
}

/// A 3 s AAC song in an M4A, written once per process.
private enum SongFile {
    private static let written = Mutex<Data?>(nil)

    static func data() throws -> Data {
        if let data = written.withLock({ $0 }) { return data }
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-song-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000],
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let frames = Int(3 * rate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0]
            else { throw CocoaError(.fileWriteUnknown) }
            for index in 0..<frames {
                channel[index] = Float(sin(2 * .pi * 440 * Double(index) / rate) * 0.5)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: url)
        written.withLock { $0 = data }
        return data
    }
}

/// Serves one file by range, at once, and counts the requests.
private final class SongFetcher: VideoRangeFetching, @unchecked Sendable {
    // `@unchecked`: the only mutable field is behind `lock`.
    private final class Task: VideoRangeTask, @unchecked Sendable {
        func cancel() {}
        func setPriority(_ priority: Float) {}
    }

    private let data: Data
    private let url: URL
    private let lock = NSLock()
    private var requests = 0
    private let queue = DispatchQueue(label: "SongFetcher", qos: .userInitiated)

    init(data: Data, at url: URL) {
        self.data = data
        self.url = url
    }

    var requestCount: Int { lock.withLock { requests } }

    func fetch(
        _ url: URL, from offset: Int64, to end: Int64?, speculative: Bool, priority: Float,
        events: VideoRangeFetchEvents
    ) -> any VideoRangeTask {
        lock.withLock { requests += 1 }
        let bytes = self.data
        let file = self.url
        queue.async {
            guard url == file else {
                events.finish(VideoRangeFetchFailure(URLError(.fileDoesNotExist)))
                return
            }
            let total = Int64(bytes.count)
            let stop = min(end ?? total, total)
            events.response(VideoRangeResponse(offset: offset, totalLength: total, mimeType: "audio/mp4"))
            if offset < stop { events.data(bytes.subdata(in: Int(offset) ..< Int(stop))) }
            events.finish(nil)
        }
        return Task()
    }
}
