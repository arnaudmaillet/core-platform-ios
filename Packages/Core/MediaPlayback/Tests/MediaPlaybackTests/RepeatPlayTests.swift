import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// `play` on a view already on that clip carries on, and a start asked while
/// the clip runs is not filed (#646).
///
/// ⚠️ A JOIN COMPLETES WITH NO AWAIT. A post page starts from two doors two
/// milliseconds apart; while every start awaited its resolution the second
/// cancelled the first. Once the page's start is a join — a map marker warmed
/// its player at touch-down — the second call found the view's own player,
/// fell through and minted a fresh one at zero over it.
@MainActor
struct RepeatPlayTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private let clip = URL(string: "mock://video/clip-46")!

    @Test("A second play on a joined view keeps the player it joined")
    func aJoinedViewIsNotReminted() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let warm = VideoRenderView(), page = VideoRenderView()
        await pool.play(clip, in: warm, scope: "post-a")
        await pool.play(clip, in: page, scope: "post-a")
        let joined = page.boundPlayer
        #expect(joined != nil && joined === warm.boundPlayer, "the premise: the page joined")

        await pool.play(clip, in: page, scope: "post-a")
        #expect(page.boundPlayer === joined)
        #expect(pool.playerCountByURL[clip] == 1)
    }

    @Test("A second play on the owner keeps its player")
    func anOwnerIsNotReminted() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let view = VideoRenderView()
        await pool.play(clip, in: view, scope: "post-a")
        let first = view.boundPlayer
        await pool.play(clip, in: view, scope: "post-a")
        #expect(first != nil && view.boundPlayer === first)
    }

    @Test("A start asked while the post's clip is running is not filed: the next play joins and would never spend it")
    func aStartWhileRunningIsNotFiled() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        await pool.play(clip, in: VideoRenderView(), scope: "post-a")
        pool.prepareStart(of: clip, scope: "post-a", at: 3)
        #expect(pool.takeResume(scope: "post-a", url: clip) == nil)
        // Another post's start is its own business.
        pool.prepareStart(of: clip, scope: "post-b", at: 3)
        #expect(pool.takeResume(scope: "post-b", url: clip)?.seconds == 3)
    }

    @Test("forgetStart drops a filed start")
    func forgetStart() {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        pool.prepareStart(of: clip, scope: "post-a", at: 3)
        pool.forgetStart(of: clip, scope: "post-a")
        #expect(pool.takeResume(scope: "post-a", url: clip) == nil)
    }
}
