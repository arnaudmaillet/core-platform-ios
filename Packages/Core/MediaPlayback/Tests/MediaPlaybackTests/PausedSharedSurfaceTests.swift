import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// **A PAUSED SURFACE DOES NOT MIRROR A SHARED PLAYER** (#1914, the owner's
/// device, 2026-10-31).
///
/// One asset, one player: a profile's tile of the post Shots shows joins the
/// player Shots paused under the profile. Both surfaces were bound to it, so
/// when the tile played it, the post behind — at a fifth of the screen —
/// played in step. The paused surface now holds its frame, unbound, and takes
/// the player back when it resumes; the player pauses only when every surface
/// on it is paused.
@MainActor
struct PausedSharedSurfaceTests {
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

    private let url = URL(string: "mock://video/trailer")!

    /// Shots paused under the profile, then the profile's tile of the same
    /// post plays: the page holds a still, and reads paused.
    @Test func aPausedSurfaceHoldsAStillWhileAnotherPlaysItsPlayer() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let page = surface(), tile = surface()
        await pool.play(url, in: page, scope: "post-a")
        #expect(pool.setPaused(true, in: page))
        await pool.play(url, in: tile, scope: "post-a")

        #expect(page.isHoldingStill, "the paused page mirrored the tile's clip")
        #expect(pool.isPaused(in: page) == true)
        #expect(!pool.isAdvancing(in: page))
        #expect(pool.isAdvancing(in: tile), "the tile does not play")
        #expect(!tile.isHoldingStill)

        // Back over half: the page takes the player again.
        #expect(pool.setPaused(false, in: page))
        #expect(!page.isHoldingStill)
        #expect(pool.isAdvancing(in: page))
    }

    /// The other way: the tile paused while the page still plays the shared
    /// player — the player goes on for the page, the tile holds its frame.
    @Test func pausingOneSurfaceDoesNotStopTheOther() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let page = surface(), tile = surface()
        await pool.play(url, in: page, scope: "post-a")
        await pool.play(url, in: tile, scope: "post-a")

        #expect(pool.setPaused(true, in: tile))
        #expect(tile.isHoldingStill)
        #expect(pool.isAdvancing(in: page), "pausing the tile stopped the page")

        // Every surface paused: the player itself pauses.
        #expect(pool.setPaused(true, in: page))
        #expect(pool.isPaused(in: page) == true)
        #expect(!page.isHoldingStill, "the last surface held a still instead of pausing the player")
    }

    /// A surface stopped while it holds a still forgets it.
    @Test func aStoppedSurfaceForgetsItsStill() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let page = surface(), tile = surface()
        await pool.play(url, in: page, scope: "post-a")
        #expect(pool.setPaused(true, in: page))
        await pool.play(url, in: tile, scope: "post-a")
        #expect(page.isHoldingStill)
        pool.stop(page)
        #expect(!page.isHoldingStill)
        #expect(pool.isAdvancing(in: tile))
    }
}
