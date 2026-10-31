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
/// played in step. A paused surface now holds its frame, unbound, while
/// another plays the player, and takes it back when it resumes. A pause still
/// stops the shared clock.
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

    /// A pause still stops the shared clock — the viewer's pause on a page
    /// must stop the card behind it too, sound and all. No still: there is
    /// nothing playing to mirror.
    @Test func aPauseStillStopsTheSharedClock() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let page = surface(), tile = surface()
        await pool.play(url, in: page, scope: "post-a")
        await pool.play(url, in: tile, scope: "post-a")

        #expect(pool.setPaused(true, in: tile))
        #expect(!pool.isAdvancing(in: page))
        #expect(!tile.isHoldingStill)
        #expect(!page.isHoldingStill)
    }

    /// The surface playing the shared player leaves while the only other one
    /// holds a still: the player pauses, so no sound runs under a still.
    @Test func theLastPlayingSurfaceLeavingPausesThePlayer() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let page = surface(), tile = surface()
        await pool.play(url, in: page, scope: "post-a")
        #expect(pool.setPaused(true, in: page))
        await pool.play(url, in: tile, scope: "post-a")
        #expect(page.isHoldingStill)

        pool.stop(tile)
        #expect(pool.isPaused(in: page) == true)
        // Resumed, the page takes its player back.
        #expect(pool.setPaused(false, in: page))
        #expect(!page.isHoldingStill)
        #expect(pool.isAdvancing(in: page))
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

    /// The page of a post opened from a grid tile only JOINS the tile's player
    /// (no loan of its own). Paused, then played by another surface, it holds
    /// a still too, and takes the player back when it resumes.
    @Test func aJoinedSurfaceHoldsAStillToo() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let tile = surface(), page = surface(), card = surface()
        await pool.play(url, in: tile, scope: "post-a")
        #expect(pool.attachSurface(page, to: url, scope: "post-a"))
        #expect(!pool.hasPlayer(in: page), "the premise: the page holds no loan")
        #expect(pool.setPaused(true, in: page))
        await pool.play(url, in: card, scope: "post-a")

        #expect(page.isHoldingStill, "the joined page mirrored the card's clip")
        #expect(pool.isPaused(in: page) == true)
        #expect(pool.setPaused(false, in: page))
        #expect(!page.isHoldingStill)
        #expect(pool.isAdvancing(in: page))
    }
}
