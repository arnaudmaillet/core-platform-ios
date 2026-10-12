import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The pool's lookahead ledger (#895): the vertical feed's +1 player warmed,
/// its −1 player kept, both adopted whole by the page's `play`, and never
/// more than three players around the page.
///
/// Real clips (`ColourClipWriter`), so an item lives long enough to be
/// adopted rather than failing on a missing file.
@MainActor
struct LookaheadPlaybackTests {
    private struct ClipSource: VideoSource {
        let file: URL
        func playableURL(for url: URL) async throws -> URL { file }
    }

    private func pool() async throws -> VideoPlaybackController {
        VideoPlaybackController(source: ClipSource(file: try await ColourClipWriter.clip()), poolSize: 4, capacity: 4)
    }

    private func clip(_ index: Int) -> URL { URL(string: "mock://video/lookahead-\(index)")! }
    private func item(_ index: Int) -> VideoLookaheadItem { VideoLookaheadItem(url: clip(index), scope: "post-\(index)") }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    /// ⚠️ THE NEXT PAGE STARTS WARM. The +1 clip gets a player of its own,
    /// outside the working set, and the page's `play` adopts it whole: no new
    /// item, no resolution.
    @Test func theNextClipIsWarmedAndAdoptedWhole() async throws {
        let controller = try await pool()
        controller.setLookahead(next: item(1), previous: nil)
        #expect(await eventually { controller.lookaheadPlaybackCount == 1 })
        #expect(controller.hasLookaheadPlayback(of: clip(1), scope: "post-1"))
        #expect(controller.activePlayerCount == 0)
        let items = controller.itemCreations

        let page = surface()
        await controller.play(clip(1), in: page, scope: "post-1")
        defer { controller.stop(page) }
        #expect(controller.lookaheadPlaybackCount == 0)
        #expect(controller.activePlayerCount == 1)
        #expect(controller.itemCreations == items, "the swipe minted a new item over the warmed one")
        #expect(controller.isBound(clip(1), in: page))
    }

    /// The warm player is the clip under THAT post only: the same file under
    /// another post mints its own.
    @Test func aWarmPlayerBelongsToItsPost() async throws {
        let controller = try await pool()
        controller.setLookahead(next: item(1), previous: nil)
        #expect(await eventually { controller.lookaheadPlaybackCount == 1 })
        let other = surface()
        await controller.play(clip(1), in: other, scope: "post-9")
        defer { controller.stop(other) }
        #expect(controller.lookaheadPlaybackCount == 1)
    }

    /// ⚠️ THE PAGE LEFT IS KEPT. A page the lookahead wants (−1) hands its
    /// player to the ledger instead of retiring it, paused where it stood, and
    /// a swipe back adopts it.
    @Test func thePageLeftIsKeptAndASwipeBackAdoptsIt() async throws {
        let controller = try await pool()
        let page = surface()
        await controller.play(clip(0), in: page, scope: "post-0")
        controller.setLookahead(next: nil, previous: item(0))
        let items = controller.itemCreations

        #expect(controller.stop(page, keepingLookahead: true))
        #expect(controller.activePlayerCount == 0)
        #expect(controller.lookaheadPlaybackCount == 1)
        #expect(!controller.hasPlayer(in: page))

        let back = surface()
        await controller.play(clip(0), in: back, scope: "post-0")
        defer { controller.stop(back) }
        #expect(controller.lookaheadPlaybackCount == 0)
        #expect(controller.itemCreations == items)
        #expect(controller.isBound(clip(0), in: back))
    }

    /// A page the lookahead does not want is stopped as before.
    @Test func aPageNobodyWantsIsStopped() async throws {
        let controller = try await pool()
        let page = surface()
        await controller.play(clip(0), in: page, scope: "post-0")
        controller.setLookahead(next: item(1), previous: nil, warmNext: false)
        #expect(!controller.stop(page, keepingLookahead: true))
        #expect(controller.lookaheadPlaybackCount == 0)
        #expect(controller.activePlayerCount == 0)
        #expect(controller.idlePlayerCount == 1)
    }

    /// ⚠️ AT MOST THREE PLAYERS. The playing page, +1 and −1; moving the
    /// window gives back what it left, and the ledger never holds more than
    /// `lookaheadCapacity`.
    @Test func neverMoreThanThreePlayersAroundThePage() async throws {
        let controller = try await pool()
        var pages: [VideoRenderView] = []
        for index in 0..<4 {
            let page = surface()
            pages.append(page)
            await controller.play(clip(index), in: page, scope: "post-\(index)")
            controller.setLookahead(next: item(index + 1), previous: index > 0 ? item(index - 1) : nil)
            if index > 0 { controller.stop(pages[index - 1], keepingLookahead: true) }
            #expect(await eventually { controller.lookaheadPlaybackCount == (index > 0 ? 2 : 1) })
            #expect(controller.activePlayerCount == 1)
            #expect(controller.activePlayerCount + controller.lookaheadPlaybackCount <= 3)
            #expect(controller.lookaheadPlaybackCount <= VideoPlaybackController.lookaheadCapacity)
        }
        #expect(controller.hasLookaheadPlayback(of: clip(2), scope: "post-2"))
        #expect(controller.hasLookaheadPlayback(of: clip(4), scope: "post-4"))
        controller.setLookahead(next: nil, previous: nil)
        #expect(controller.lookaheadPlaybackCount == 0)
        controller.stop(pages[3])
        #expect(controller.activePlayerCount == 0)
    }

    /// A memory warning gives every lookahead player back, as it does the
    /// return players.
    @Test func lookaheadPlayersGoOnRelease() async throws {
        let controller = try await pool()
        controller.setLookahead(next: item(1), previous: nil)
        #expect(await eventually { controller.lookaheadPlaybackCount == 1 })
        controller.releaseAllLookaheadPlaybacks()
        #expect(controller.lookaheadPlaybackCount == 0)
        #expect(controller.idlePlayerCount == 1)
        // The lookahead asks again on its next tick: the clip released for
        // memory is not warmed again for the same page, the next page's is.
        controller.setLookahead(next: item(1), previous: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.lookaheadPlaybackCount == 0)
        controller.setLookahead(next: item(2), previous: nil)
        #expect(await eventually { controller.lookaheadPlaybackCount == 1 })
    }

    /// A feed leaving the screen clears only what IT set: the feed pushed
    /// over it keeps its warmed player.
    @Test func aCoveredFeedDoesNotClearTheFeedAboveIt() async throws {
        let controller = try await pool()
        let below = ObjectIdentifier(NSObject.self), above = ObjectIdentifier(NSString.self)
        controller.setLookahead(next: item(1), previous: nil, client: below)
        controller.setLookahead(next: item(2), previous: nil, client: above)
        #expect(await eventually { controller.hasLookaheadPlayback(of: clip(2), scope: "post-2") })
        controller.clearLookahead(for: below)
        #expect(controller.lookaheadPlaybackCount == 1)
        controller.clearLookahead(for: above)
        #expect(controller.lookaheadPlaybackCount == 0)
    }

    /// A clip another surface already plays is never warmed a second time:
    /// one asset, one player.
    @Test func aClipAlreadyPlayingIsNotWarmed() async throws {
        let controller = try await pool()
        let page = surface()
        await controller.play(clip(1), in: page, scope: "post-1")
        defer { controller.stop(page) }
        controller.setLookahead(next: item(1), previous: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.lookaheadPlaybackCount == 0)
    }
}
