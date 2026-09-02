import AVFoundation
import Foundation
import Testing
import UIKit
@testable import MediaPlayback

/// Two posts that happen to carry the same file.
///
/// ⚠️ THE FIXTURES MADE THIS VISIBLE; PRODUCTION WOULD HIT IT ON A REPOST.
///
/// "One asset, one player" was written for a real case — a card holding a clip
/// paused on its page while the post opens the SAME clip, where a second player
/// would give one asset two decoders on two clocks. But the rule was applied by
/// URL alone. Three mock posts share `trailer.mp4`, so they shared a player and
/// a clock: pausing one froze the others, each left attached and still, which is
/// how "after the carousel post the others do not autoplay, the player is
/// attached but the image stays frozen" was reported.
///
/// Both halves are asserted, because the fix is a narrowing and a narrowing can
/// go too far: sharing must stop between posts and must survive within one.
@MainActor
struct PlaybackScopeTests {
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

    /// ⚠️ THE POST IDENTITY SURVIVES THE HAND-BACK, and for a long time it did
    /// not. `transferOwnership` moved the player, the URL and the surface and
    /// left `playingScope` behind — so the tile that ended a dismissal owning
    /// the asset owned it under no post at all, and the next present could not
    /// match it. Minting beside a player already running the asset is exactly
    /// the "one asset, two clocks" this suite exists for, so it is asserted the
    /// same way: by counting players.
    @Test func ownershipHandedBackKeepsThePostIdentity() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let clip = URL(string: "mock://video/trailer")!
        let page = surface(), tile = surface(), reopened = surface()

        await pool.play(clip, in: page, scope: "post-a")
        pool.transferOwnership(of: clip, to: tile)
        await pool.play(clip, in: reopened, scope: "post-a")

        #expect(pool.playerCountByURL[clip] == 1)
    }

    @Test func twoPostsSharingAFileDoNotShareAPlayer() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let shared = URL(string: "mock://video/trailer")!
        let first = surface(), second = surface()

        await pool.play(shared, in: first, scope: "post-a")
        await pool.play(shared, in: second, scope: "post-b")

        #expect(pool.hasPlayer(in: first))
        #expect(pool.hasPlayer(in: second))
        // The claim that matters: pausing one post leaves the other running.
        pool.setPaused(true, in: first)
        #expect(pool.isAdvancing(in: first) == false)
        #expect(pool.isAdvancing(in: second))
    }

    /// And the case the rule exists FOR still holds: one post's card and its
    /// full-screen page name the same scope, so they share the clock instead of
    /// giving one asset two decoders.
    @Test func onePostsTwoSurfacesStillShareOnePlayer() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let clip = URL(string: "mock://video/trailer")!
        let card = surface(), page = surface()

        await pool.play(clip, in: card, scope: "post-a")
        await pool.play(clip, in: page, scope: "post-a")

        #expect(pool.playerCountByURL[clip] == 1)
        // One clock: stopping it stops both pictures, which is the point.
        pool.setPaused(true, in: card)
        #expect(pool.isAdvancing(in: page) == false)
    }
}
