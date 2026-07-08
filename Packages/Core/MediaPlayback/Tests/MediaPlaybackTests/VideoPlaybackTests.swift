import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

struct PlaceholderVideoFetcherTests {
    @Test func synthesizesAPlayableClipWithAVideoTrack() async throws {
        let fetcher = PlaceholderVideoFetcher(durationSeconds: 0.5)
        let url = URL(string: "mock://video/7?w=180&h=320")!

        let fileURL = try await fetcher.playableURL(for: url)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty)
    }

    @Test func cachesByURLSoTheSecondResolveReturnsTheSameFile() async throws {
        let fetcher = PlaceholderVideoFetcher(durationSeconds: 0.5)
        let url = URL(string: "mock://video/9?w=120&h=120")!
        let first = try await fetcher.playableURL(for: url)
        let second = try await fetcher.playableURL(for: url)
        #expect(first == second)
    }
}

/// A source that hands back a fixed URL without touching the disk, so pool
/// bookkeeping is tested independently of real synthesis/playback.
private struct FixedVideoSource: VideoSource {
    let url: URL
    func playableURL(for url: URL) async throws -> URL { self.url }
}

@MainActor
struct VideoPlaybackControllerTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4") }

    @Test func stoppingReturnsThePlayerToThePoolForReuse() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: view)
        let first = controller.activePlayer(in: view)
        #expect(first != nil)
        #expect(controller.idlePlayerCount == 0)

        controller.stop(view)
        #expect(controller.activePlayer(in: view) == nil)
        #expect(controller.idlePlayerCount == 1)

        await controller.play(URL(string: "mock://video/2")!, in: view)
        #expect(controller.activePlayer(in: view) === first) // reused from the pool
        #expect(controller.idlePlayerCount == 0)
    }

    @Test func concurrentViewsGetDistinctPlayers() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let viewA = VideoRenderView()
        let viewB = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: viewA)
        await controller.play(URL(string: "mock://video/2")!, in: viewB)

        #expect(controller.activePlayer(in: viewA) !== controller.activePlayer(in: viewB))
    }
}
