import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// A PREROLL THAT DOES NOT BUFFER IS NOT A PREROLL.
///
/// `preroll` used to resolve the source URL and stop, on the reasoning that
/// resolution was the expensive part. It is not: an `AVPlayerItem` does not
/// buffer on its own, it buffers because a player holds it, and no player was
/// loaned. So the two costs that actually delay a `play` — minting the item and
/// filling a cold forward buffer — were still paid at activation, which is the
/// pause a viewer sees when the next video scrolls in.
///
/// These tests are about the STATE the warm set holds, not about pixels: the
/// difference between a warmed page and a cold one is invisible to a screenshot
/// and shows up only as a delay, which is exactly the thing a test can pin and
/// an eye cannot.
@MainActor
struct VideoPrerollWarmingTests {
    private var stubURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("preroll-stub.mp4")
    }

    /// Waits for a condition rather than for a duration.
    ///
    /// `preroll` resolves the source in a detached task, so the warm lands a
    /// hop or two after the call returns. A fixed `Task.yield()` sometimes
    /// caught it and sometimes did not — the exact shape of time-dependent
    /// flakiness this repo has been bitten by before. Polling a predicate is
    /// deterministic: it passes as soon as the state is true and fails only if
    /// it never becomes true.
    private func settle(until condition: () -> Bool, ticks: Int = 200) async {
        for _ in 0..<ticks {
            if condition() { return }
            await Task.yield()
        }
    }

    private func controller(poolSize: Int = 3) -> VideoPlaybackController {
        VideoPlaybackController(source: FixedSource(url: stubURL), poolSize: poolSize)
    }

    /// Draining the pool is how the test observes the warm: a player that is
    /// being held for an upcoming page is a player the pool cannot lend, and
    /// that is the whole mechanism.
    private func drainIdlePlayers(_ controller: VideoPlaybackController, count: Int) async -> [VideoRenderView] {
        var views: [VideoRenderView] = []
        for index in 0..<count {
            let view = VideoRenderView()
            await controller.play(URL(string: "mock://video/drain-\(index)")!, in: view)
            views.append(view)
        }
        return views
    }

    @Test func aPrerolledPageHoldsAPlayerReadyForIt() async {
        let controller = controller(poolSize: 3)
        let upcoming = URL(string: "mock://video/upcoming")!

        controller.preroll(upcoming)
        await settle { controller.debugWarmedURLs.contains(upcoming) }

        #expect(controller.debugWarmedURLs.contains(upcoming),
                "preroll resolved the URL and loaned nothing — the item is still cold")
    }

    /// The payoff: `play` of a warmed URL must not go back to the source. It
    /// adopts what is already buffered, the way the flight's parked player is
    /// adopted.
    @Test func playingAWarmedPageConsumesTheWarmPlayer() async {
        let controller = controller(poolSize: 3)
        let upcoming = URL(string: "mock://video/upcoming")!
        controller.preroll(upcoming)
        await settle { controller.debugWarmedURLs.contains(upcoming) }
        #expect(controller.debugWarmedURLs.contains(upcoming), "precondition")

        await controller.play(upcoming, in: VideoRenderView())

        #expect(controller.debugWarmedURLs.isEmpty,
                "the warm player was left behind and a second one was started for the same asset")
    }

    /// ⚠️ Warming must never starve what is on screen. The pool is app-wide and
    /// shared with the grids; a warm taken from an empty pool would be a warm
    /// taken from a surface that needs it.
    @Test func warmingDeclinesWhenThePoolHasNoSpare() async {
        let controller = controller(poolSize: 2)
        // Two concurrent surfaces exhaust a pool of two.
        let held = await drainIdlePlayers(controller, count: 2)
        #expect(held.count == 2)

        controller.preroll(URL(string: "mock://video/upcoming")!)
        await Task.yield()

        #expect(controller.debugWarmedURLs.isEmpty,
                "warming took a player the active surfaces needed")
    }

    /// The working set is the pages either side of the active one. Holding more
    /// would keep pool slots for pages two swipes away.
    @Test func theWarmSetIsBoundedToTheAdjacentPages() async {
        let controller = controller(poolSize: 6)

        for index in 0..<4 {
            let ahead = URL(string: "mock://video/ahead-\(index)")!
            controller.preroll(ahead)
            await settle { controller.debugWarmedURLs.contains(ahead) }
        }

        #expect(controller.debugWarmedURLs.count <= 2,
                "the warm set grew past the adjacent pages")
    }

    /// A page already on screen is not "upcoming", and re-warming it would mint
    /// a second item for an asset that already has a running one.
    @Test func aPlayingPageIsNotWarmedAgain() async {
        let controller = controller(poolSize: 3)
        let onScreen = URL(string: "mock://video/onscreen")!
        await controller.play(onScreen, in: VideoRenderView())

        controller.preroll(onScreen)
        await Task.yield()

        #expect(controller.debugWarmedURLs.contains(onScreen) == false)
    }

    /// Warming holds real resources, so it is the first thing given back.
    @Test func warmedPlayersAreReleasedOnDemand() async {
        let controller = controller(poolSize: 3)
        controller.preroll(URL(string: "mock://video/upcoming")!)
        await settle { controller.debugWarmedURLs.isEmpty == false }
        #expect(controller.debugWarmedURLs.isEmpty == false, "precondition")

        controller.discardWarmedPlayback()

        #expect(controller.debugWarmedURLs.isEmpty)
    }
}

/// Hands back a fixed URL without touching the disk, so the warm set's
/// bookkeeping is tested independently of real synthesis.
private struct FixedSource: VideoSource {
    let url: URL
    func playableURL(for url: URL) async throws -> URL { self.url }
}
