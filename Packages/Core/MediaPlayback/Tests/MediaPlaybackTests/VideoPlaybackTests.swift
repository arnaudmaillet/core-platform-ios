import AVFoundation
import Foundation
import Testing
import UIKit
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

    /// Remote assets pass straight through — the mock dataset's opt-in
    /// real-asset catalog seeds real HLS manifests and MP4s, and synthesizing
    /// over them would defeat the point. No request is made here: passthrough
    /// is a pure URL decision.
    @Test func remoteURLsPassThroughUnsynthesized() async throws {
        let fetcher = PlaceholderVideoFetcher(durationSeconds: 0.5)
        let manifest = URL(string: "https://example.com/stream/master.m3u8")!
        #expect(try await fetcher.playableURL(for: manifest) == manifest)

        let progressive = URL(string: "http://example.com/clip.mp4")!
        #expect(try await fetcher.playableURL(for: progressive) == progressive)
    }

    @Test func localFilesStillPassThrough() async throws {
        let fetcher = PlaceholderVideoFetcher(durationSeconds: 0.5)
        let file = URL(fileURLWithPath: "/tmp/already-playable.mp4")
        #expect(try await fetcher.playableURL(for: file) == file)
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

    // MARK: - Bit-rate cap

    @Test func playAppliesThePeakBitRateCapToTheItem() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: view, peakBitRate: 600_000)
        #expect(controller.peakBitRate(in: view) == 600_000)
    }

    @Test func playIsUncappedByDefault() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: view)
        #expect(controller.peakBitRate(in: view) == 0)
    }

    /// The whole point of re-capping in place: the item, and therefore the
    /// playhead, must survive. Replacing it would reset `currentTime` to zero.
    @Test func recappingKeepsTheSameItem() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: view, peakBitRate: 600_000)
        let item = controller.currentItem(in: view)

        controller.setPeakBitRate(0, in: view)
        #expect(controller.peakBitRate(in: view) == 0)
        #expect(controller.currentItem(in: view) === item)
    }

    /// ⚠️ THE RETURN VALUE IS THE POINT: it says whether there was anything to
    /// resume, and two states look identical from outside.
    ///
    /// A surface can be hosted on the page the viewer is looking at and have no
    /// player behind it — a post dismissed and reopened keeps its carousel, so
    /// the surface is still hanging where it was, while the player went back to
    /// the pool on the way out. A caller that treated "hosted" as "resumable"
    /// asked a player that no longer existed to play, and showed the page's
    /// thumbnail instead of the video.
    @Test func resumingAViewWithNoPlayerReportsThatItDidNothing() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()

        #expect(controller.setPaused(false, in: view) == false)

        await controller.play(URL(string: "mock://video/1")!, in: view)
        #expect(controller.setPaused(true, in: view))
        #expect(controller.setPaused(false, in: view))

        controller.stop(view)
        // Stopped, with the surface untouched — exactly the state that used to
        // be mistaken for "paused, ready to resume".
        #expect(controller.setPaused(false, in: view) == false)
    }

    /// ⚠️ A DETACH HIDES A VISIBLE SURFACE THAT HAS NO POSTER — and `play`
    /// detaches before it attaches.
    ///
    /// The rule is deliberate: it stops a stale cover sitting on screen through
    /// the whole buffering window. It also means that clearing a poster and
    /// then playing is a request to be hidden, which is what a carousel page did
    /// — the viewer got the page's thumbnail with a live player behind it.
    ///
    /// Both branches, because the fix is "hand it a poster" and a test that only
    /// checked the empty case would pass on a version that always hides.
    @Test func detachingHidesABareSurfaceAndSparesOneWithAPoster() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)

        // ⚠️ The hide is the SAMPLE-BUFFER backing's, and CI runs this suite a
        // second time on the other one (`AVSBDL_RENDER=0`), where a detached
        // surface stays visible. Asserted unconditionally, this was green here
        // and red on that second run — for a controller correct in both.
        //
        // Scoped rather than deleted, because the hide is exactly what made
        // `setPoster(nil)` a request to be hidden, and that is the defect the
        // collection path hit.
        if VideoRenderFlags.usesSampleBufferLayer {
            let bare = VideoRenderView()
            bare.isHidden = false
            await controller.play(URL(string: "mock://video/1")!, in: bare)
            controller.stop(bare)
            #expect(bare.isHidden)
        }

        // The other half holds on BOTH backings: a surface with something to
        // show is never hidden out from under it.
        let postered = VideoRenderView()
        postered.isHidden = false
        postered.setPoster(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
        await controller.play(URL(string: "mock://video/2")!, in: postered)
        controller.stop(postered)
        #expect(postered.isHidden == false)
    }

    /// ⚠️ ONE ASSET, ONE PLAYER — even when two surfaces want it at once.
    ///
    /// A card holding a clip paused on its page while the post opens the same
    /// clip is now an ordinary state, and it used to mint a second `AVPlayer`:
    /// two decoders on two clocks for one asset, with the surface a viewer is
    /// looking at bound to whichever a lookup happened to find.
    @Test func asecondSurfaceOnTheSameAssetJoinsTheSamePlayer() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/1")!
        let first = VideoRenderView()
        let second = VideoRenderView()

        await controller.play(url, in: first)
        await controller.play(url, in: second)

        #expect(controller.playerCountByURL[url] == 1)
        #expect(controller.activePlayer(in: first) === controller.activePlayer(in: second))
    }

    /// ⚠️ And ONE SURFACE LEAVING is not the end of the playback.
    ///
    /// Sharing the loan made this reachable: tearing the player down when the
    /// first surface stops would pause the asset — and return it to the idle
    /// pool — while the other is still rendering it. That is a frozen picture
    /// with no cause visible from the side that froze it.
    @Test func stoppingOneSurfaceLeavesTheOtherPlaying() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let url = URL(string: "mock://video/1")!
        let first = VideoRenderView()
        let second = VideoRenderView()
        await controller.play(url, in: first)
        await controller.play(url, in: second)
        let shared = controller.activePlayer(in: second)

        controller.stop(first)

        #expect(controller.activePlayer(in: first) == nil)
        #expect(controller.activePlayer(in: second) === shared)
        #expect(controller.isAdvancing(in: second))
        // Not handed back while it is still being watched.
        #expect(controller.idlePlayerCount == 0)

        // And the LAST surface leaving does end it.
        controller.stop(second)
        #expect(controller.activePlayer(in: second) == nil)
        #expect(controller.idlePlayerCount == 1)
    }

    /// Two DIFFERENT assets still get two players — the reuse must not collapse
    /// unrelated playbacks onto one.
    @Test func differentAssetsKeepTheirOwnPlayers() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let first = VideoRenderView()
        let second = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: first)
        await controller.play(URL(string: "mock://video/2")!, in: second)

        #expect(controller.activePlayer(in: first) !== controller.activePlayer(in: second))
    }

    @Test func recappingAViewWithNoPlayerIsANoOp() {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        controller.setPeakBitRate(0, in: VideoRenderView()) // must not trap
    }

    // MARK: - Handoff

    /// The grid → full-screen handoff: the destination adopts the *same*
    /// player and item, so playback continues instead of restarting.
    @Test func parkedPlaybackIsAdoptedByTheNextPlayOfTheSameURL() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let tile = VideoRenderView()
        let page = VideoRenderView()
        let url = URL(string: "mock://video/1")!

        await controller.play(url, in: tile, peakBitRate: 600_000)
        let player = controller.activePlayer(in: tile)
        let item = controller.currentItem(in: tile)

        #expect(controller.parkPlayback(from: tile))
        #expect(controller.activePlayer(in: tile) == nil)

        await controller.play(url, in: page) // uncapped, as a full-screen page plays
        #expect(controller.activePlayer(in: page) === player)
        #expect(controller.currentItem(in: page) === item)
        // Adoption is what lifts the cap — one step, so the two can't disagree.
        #expect(controller.peakBitRate(in: page) == 0)
    }

    /// A different asset must NOT adopt the parked player, or one post's video
    /// would appear under another's.
    @Test func aDifferentURLDoesNotAdoptTheParkedPlayer() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let tile = VideoRenderView()
        let page = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: tile)
        let item = controller.currentItem(in: tile)
        controller.parkPlayback(from: tile)

        await controller.play(URL(string: "mock://video/2")!, in: page)
        #expect(controller.currentItem(in: page) !== item)
    }

    @Test func parkingWithNothingPlayingReportsFalse() {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        #expect(controller.parkPlayback(from: VideoRenderView()) == false)
    }

    /// An unclaimed park must not strand a decoding player — it returns to the
    /// pool, ready for reuse.
    @Test func discardingAnUnclaimedParkReturnsThePlayerToThePool() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let tile = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: tile)
        controller.parkPlayback(from: tile)
        #expect(controller.idlePlayerCount == 0) // parked, not idle

        controller.discardParkedPlayback()
        #expect(controller.idlePlayerCount == 1)

        // And a later play of that URL now starts fresh rather than adopting.
        let page = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: page, peakBitRate: 600_000)
        #expect(controller.peakBitRate(in: page) == 600_000)
    }

    /// Parking twice must not strand the first player.
    @Test func asecondParkRetiresTheFirst() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let first = VideoRenderView()
        let second = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: first)
        await controller.play(URL(string: "mock://video/2")!, in: second)

        controller.parkPlayback(from: first)
        controller.parkPlayback(from: second)
        // The first went back to the pool rather than being lost.
        #expect(controller.idlePlayerCount == 1)
    }

    @Test func togglePlaybackFlipsPausedStateOfTheActivePlayer() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView()
        await controller.play(URL(string: "mock://video/1")!, in: view)

        // Playing → tap pauses.
        #expect(controller.togglePlayback(in: view) == true)
        #expect(controller.activePlayer(in: view)?.timeControlStatus == .paused)

        // Paused → tap resumes.
        #expect(controller.togglePlayback(in: view) == false)
        #expect(controller.activePlayer(in: view)?.timeControlStatus != .paused)
    }

    @Test func togglePlaybackIsANoOpWithoutAnActivePlayer() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let view = VideoRenderView() // never played
        #expect(controller.togglePlayback(in: view) == false)
    }

    @Test func mirrorAttachesTheSamePlayerToASecondSurface() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let primary = VideoRenderView()
        let mirror = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: primary)
        #expect(controller.mirror(from: primary, to: mirror) == true)
        // The mirror renders but holds no pool loan of its own.
        #expect(mirror.isAttached)
        #expect(controller.activePlayer(in: mirror) == nil)
        #expect(controller.activePlayer(in: primary) != nil)
    }

    @Test func reclaimReassertsTheOwningViewAndIgnoresStrangers() async {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let primary = VideoRenderView()
        let mirror = VideoRenderView()

        await controller.play(URL(string: "mock://video/1")!, in: primary)
        controller.mirror(from: primary, to: mirror)
        controller.reclaim(primary)
        // Still the same pool binding, and the view is attached again.
        #expect(primary.isAttached)
        #expect(controller.activePlayer(in: primary) != nil)
        // A view with no player is a no-op.
        let stranger = VideoRenderView()
        controller.reclaim(stranger)
        #expect(!stranger.isAttached)
    }

    @Test func mirrorFromAViewWithoutAPlayerIsRefused() {
        let controller = VideoPlaybackController(source: FixedVideoSource(url: stubURL), poolSize: 3)
        let mirror = VideoRenderView()
        #expect(controller.mirror(from: VideoRenderView(), to: mirror) == false)
        #expect(!mirror.isAttached)
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
