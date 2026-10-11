import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The pool's return ledger (#923): players parked on a tile's clip for a
/// close that pages on and comes home to that tile.
///
/// What is pinned is the BOUND. A return player is a second decoder on a clip
/// that is already playing somewhere else, so the ledger must never grow past
/// `returnPlaybackCapacity`, must never be seen by anything that sizes itself
/// against the pool, and must give its players back on every way out:
/// eviction, release, a landing claiming one, a memory warning.
///
/// `.serialized` because one test posts the app-wide memory warning: it is
/// delivered to every live pool, and a neighbour parking in parallel would
/// have its player released under it.
@Suite(.serialized)
@MainActor
struct ReturnPlaybackTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("r.mp4") }

    private func pool() -> VideoPlaybackController {
        VideoPlaybackController(source: StubSource(url: stubURL))
    }

    private func clip(_ index: Int) -> URL { URL(string: "mock://video/return-\(index)")! }

    // MARK: - The bound

    /// ⚠️ THE STACK OF PUSHES. Every post opened from a playing tile parks one
    /// player; a viewer who keeps opening videos from inside videos would park
    /// one per screen. The ledger keeps the two most recent and evicts the
    /// oldest, whatever the depth.
    @Test func aDeepStackOfParksKeepsOnlyTheMostRecentTwo() async {
        let controller = pool()
        for index in 0..<5 {
            #expect(await controller.parkReturnPlayback(of: clip(index), scope: "post-\(index)", at: 1))
            #expect(controller.returnPlaybackCount <= VideoPlaybackController.returnPlaybackCapacity)
        }
        #expect(controller.returnPlaybackCount == 2)
        #expect(!controller.hasReturnPlayback(of: clip(0), scope: "post-0"))
        #expect(!controller.hasReturnPlayback(of: clip(2), scope: "post-2"))
        #expect(controller.hasReturnPlayback(of: clip(3), scope: "post-3"))
        #expect(controller.hasReturnPlayback(of: clip(4), scope: "post-4"))
        // Evicted players went back to the idle cache, not on the floor: each
        // park after the third reused the player the previous eviction freed,
        // so the five parks minted three players and one is idle now.
        #expect(controller.idlePlayerCount == 1)
    }

    /// ⚠️ NEVER A SLOT. Nothing that budgets against this pool may count a
    /// parked return player: not the active players (the grids' spare and the
    /// sound sheet's "held by others" read it), not the per-asset census.
    @Test func parkedReturnPlayersTakeNoSlotFromThePlaybackPool() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        await controller.parkReturnPlayback(of: clip(1), scope: "post-1", at: 0)
        #expect(controller.returnPlaybackCount == 2)
        #expect(controller.activePlayerCount == 0)
        #expect(controller.playerCountByURL.isEmpty)

        // And a page playing the same clip for the same post mints its own
        // player: it neither joins nor adopts the parked one.
        let page = VideoRenderView()
        await controller.play(clip(0), in: page, scope: "post-0")
        #expect(controller.activePlayerCount == 1)
        #expect(controller.returnPlaybackCount == 2)
        #expect(controller.hasReturnPlayback(of: clip(0), scope: "post-0"))
    }

    /// An evicted clip has nothing to resume: the close falls back to the
    /// tile's still, and says so by answering false.
    @Test func anEvictedClipCannotBeResumed() async {
        let controller = pool()
        for index in 0..<3 {
            await controller.parkReturnPlayback(of: clip(index), scope: "post-\(index)", at: 0)
        }
        #expect(!controller.attachReturnSurface(VideoRenderView(), of: clip(0), scope: "post-0"))
        #expect(controller.attachReturnSurface(VideoRenderView(), of: clip(2), scope: "post-2"))
    }

    /// Resuming a clip makes it the youngest: the next park evicts the other
    /// one, not the clip a close is flying.
    @Test func resumingAClipProtectsItFromTheNextEviction() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        await controller.parkReturnPlayback(of: clip(1), scope: "post-1", at: 0)
        #expect(controller.attachReturnSurface(VideoRenderView(), of: clip(0), scope: "post-0"))
        await controller.parkReturnPlayback(of: clip(2), scope: "post-2", at: 0)
        #expect(controller.hasReturnPlayback(of: clip(0), scope: "post-0"))
        #expect(!controller.hasReturnPlayback(of: clip(1), scope: "post-1"))
    }

    /// ⚠️ TWO SURFACES CAN PARK ONE POST (#951) — a Following card and the
    /// sound sheet tile opened from it. Each park is its owner's: neither
    /// replaces, resumes nor releases the other's.
    @Test func twoOwnersParkingOneClipKeepTheirOwnPlayers() async {
        final class Owner {}
        let first = Owner(), second = Owner()
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", owner: ObjectIdentifier(first), at: 0)
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", owner: ObjectIdentifier(second), at: 0)
        #expect(controller.returnPlaybackCount == 2)

        controller.releaseReturnPlayback(of: clip(0), scope: "post-0", owner: ObjectIdentifier(first))
        #expect(!controller.hasReturnPlayback(of: clip(0), scope: "post-0", owner: ObjectIdentifier(first)))
        #expect(controller.hasReturnPlayback(of: clip(0), scope: "post-0", owner: ObjectIdentifier(second)))
        #expect(!controller.attachReturnSurface(
            VideoRenderView(), of: clip(0), scope: "post-0", owner: ObjectIdentifier(first)
        ))
        #expect(controller.attachReturnSurface(
            VideoRenderView(), of: clip(0), scope: "post-0", owner: ObjectIdentifier(second)
        ))
    }

    // MARK: - The landing claims it

    /// A close that flew the clip lands it: the tile's surface takes the
    /// player by identity, and from then on it is an ordinary loan, filed
    /// under the post it was parked for.
    @Test func aLandingClaimsTheParkedPlayerForTheTile() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        let flying = VideoRenderView()
        #expect(controller.attachReturnSurface(flying, of: clip(0), scope: "post-0"))
        let parkedPlayer = flying.boundPlayer
        #expect(parkedPlayer != nil)
        #expect(controller.activePlayerCount == 0, "a resumed return player is still not a loan")

        let tile = VideoRenderView()
        #expect(controller.transferOwnership(of: clip(0), drawnBy: flying, to: tile))
        #expect(controller.returnPlaybackCount == 0)
        #expect(controller.activePlayerCount == 1)
        #expect(controller.hasPlayer(in: tile))
        #expect(tile.boundPlayer === parkedPlayer)
        // Filed under its post, so a later page of the same post joins it.
        let page = VideoRenderView()
        await controller.play(clip(0), in: page, scope: "post-0")
        #expect(page.boundPlayer === parkedPlayer)
    }

    /// ⚠️ IDENTITY ONLY. A landing that asks by URL alone (no flying surface)
    /// must not stumble on a parked player: the URL lookup cannot see one.
    @Test func aLandingByURLAloneNeverTakesAParkedPlayer() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        #expect(!controller.transferOwnership(of: clip(0), to: VideoRenderView()))
        #expect(controller.returnPlaybackCount == 1)
    }

    // MARK: - Every other way out

    @Test func releasingAClipGivesItsPlayerBack() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        controller.releaseReturnPlayback(of: clip(0), scope: "post-0")
        #expect(controller.returnPlaybackCount == 0)
        #expect(controller.idlePlayerCount == 1)
        #expect(controller.debugPausedAnchorCount == 0, "a released player kept its pause anchor")
    }

    /// A park still resolving when its owner lets go must not land later.
    @Test func aReleaseOvertakesAParkStillResolving() async {
        let gate = GateSource(url: stubURL)
        let controller = VideoPlaybackController(source: gate)
        let park = Task { await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0) }
        await gate.waitForRequest()
        controller.releaseReturnPlayback(of: clip(0), scope: "post-0")
        await gate.release()
        #expect(await park.value == false)
        #expect(controller.returnPlaybackCount == 0)
    }

    /// Under memory pressure the return players go first.
    @Test func aMemoryWarningReleasesEveryReturnPlayer() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        await controller.parkReturnPlayback(of: clip(1), scope: "post-1", at: 0)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(controller.returnPlaybackCount == 0)
        #expect(controller.idlePlayerCount == 2)
    }

    /// An abandoned close pauses the clip again and keeps it parked.
    @Test func pausingKeepsTheClipParked() async {
        let controller = pool()
        await controller.parkReturnPlayback(of: clip(0), scope: "post-0", at: 0)
        let flying = VideoRenderView()
        controller.attachReturnSurface(flying, of: clip(0), scope: "post-0")
        controller.pauseReturnPlayback(of: clip(0), scope: "post-0")
        #expect(controller.returnPlaybackCount == 1)
        #expect(flying.boundPlayer?.timeControlStatus == .paused)
    }
}

/// Resolves every URL to one local stub, so the tests exercise the POOL rather
/// than a fetcher. Duplicated per suite by convention.
private struct StubSource: VideoSource {
    let url: URL
    func playableURL(for mediaURL: URL) async throws -> URL { url }
}

/// A source that answers only when told to — holds a park mid-resolution.
private actor GateSource: VideoSource {
    private let url: URL
    private var waiter: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false

    init(url: URL) { self.url = url }

    func playableURL(for mediaURL: URL) async throws -> URL {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { waiter = $0 }
        return url
    }

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
