import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// **A SURFACE ANSWERS FOR THE PLAYBACK IT IS DRAWING — whether or not it owns
/// it.**
///
/// ⚠️ The distinction this suite exists to keep, because collapsing it is how
/// the defect happened: the pool answers TWO different questions about a
/// surface, and only one of them is about ownership.
///
/// * *Who holds the loan* — `hasPlayer(in:)`. Bookkeeping: which surface the
///   pool will bill for a player, and whose `stop` retires it.
/// * *What is this surface showing* — `isAdvancing`, `setPaused`,
///   `togglePlayback`. The viewer's question, asked of the picture in front of
///   them.
///
/// Every one of the second kind was written against the loan table, so a
/// surface that JOINED an existing playback (`attachSurface`, no loan — the
/// mechanism behind every hero landing, mirror and flight card) answered
/// "nothing is playing here" while visibly playing. The controls did not fail:
/// they returned `false` and did nothing, which is a defect with no error in
/// it. Reported as the post screen's tap-to-pause doing nothing at all, on a
/// clip the viewer could watch moving.
///
/// So the rule is: **ask the surface what it draws.** Its own loan first, and
/// failing that, the playback it joined.
@MainActor
struct JoinedSurfaceControlTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        return view
    }

    /// The shape of a hero landing: a grid tile is playing the clip, and the
    /// full-screen page joins that playback rather than minting a second
    /// decoder for it.
    private func landedPage() async -> (pool: VideoPlaybackController,
                                        tile: VideoRenderView,
                                        page: VideoRenderView,
                                        url: URL) {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let url = URL(string: "mock://video/trailer")!
        let tile = surface(), page = surface()
        await pool.play(url, in: tile, scope: "post-a")
        #expect(pool.attachSurface(page, to: url))
        return (pool, tile, page, url)
    }

    @Test func aJoinedSurfaceReportsThePlaybackItDraws() async {
        let (pool, _, page, _) = await landedPage()
        #expect(pool.isAdvancing(in: page))
    }

    /// The tap, from the page's side: one clip, so stopping it from the page
    /// stops it everywhere it is drawn.
    @Test func pausingAJoinedSurfaceStopsTheClipItDraws() async {
        let (pool, tile, page, _) = await landedPage()

        #expect(pool.setPaused(true, in: page))
        #expect(pool.isAdvancing(in: page) == false)
        #expect(pool.isAdvancing(in: tile) == false)
    }

    /// And back again — the second tap.
    @Test func togglingFromAJoinedSurfaceFlipsTheOnePlayback() async {
        let (pool, tile, page, _) = await landedPage()

        #expect(pool.togglePlayback(in: page) == true) // playing → paused
        #expect(pool.isAdvancing(in: tile) == false)

        #expect(pool.togglePlayback(in: page) == false) // paused → playing
        #expect(pool.isAdvancing(in: tile))
    }

    /// ⚠️ AND THE LOAN DOES NOT MOVE. Pinned in the same suite as the controls
    /// above so the two questions cannot be quietly merged: joining is still
    /// not owning, and the surface that owns the player is the one that will
    /// hand it back.
    @Test func drawingAClipIsNotOwningIt() async {
        let (pool, tile, page, _) = await landedPage()

        #expect(pool.hasPlayer(in: tile))
        #expect(pool.hasPlayer(in: page) == false)
        #expect(pool.playerCountByURL[URL(string: "mock://video/trailer")!] == 1)
    }

    /// The floor: a surface showing nothing still answers no, rather than
    /// reaching for whatever the pool happens to be running.
    @Test func aSurfaceDrawingNothingAnswersNoToEveryControl() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let playing = surface(), bare = surface()
        await pool.play(URL(string: "mock://video/trailer")!, in: playing, scope: "post-a")

        #expect(pool.isAdvancing(in: bare) == false)
        #expect(pool.setPaused(true, in: bare) == false)
        #expect(pool.togglePlayback(in: bare) == false)
        // …and the clip that IS playing was not touched by any of it.
        #expect(pool.isAdvancing(in: playing))
    }

    /// A surface that has been detached goes back to answering for nothing —
    /// the state a recycled cell is in, and the one where reaching for a
    /// stale binding would pause a clip the viewer is watching elsewhere.
    @Test func aDetachedSurfaceStopsAnsweringForTheClip() async {
        let (pool, _, page, _) = await landedPage()
        pool.detachSurface(page)

        #expect(pool.isAdvancing(in: page) == false)
        #expect(pool.togglePlayback(in: page) == false)
    }
}
