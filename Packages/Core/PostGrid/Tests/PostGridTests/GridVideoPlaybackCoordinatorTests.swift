import CoreModels
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// A source that hands back a fixed URL without touching the disk, so the
/// coordinator's bookkeeping is tested independently of real playback.
private struct FixedVideoSource: VideoSource {
    let url: URL
    func playableURL(for url: URL) async throws -> URL { self.url }
}

@MainActor
struct GridVideoPlaybackCoordinatorTests {
    private func makePool(poolSize: Int = 3) -> VideoPlaybackController {
        VideoPlaybackController(
            source: FixedVideoSource(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("stub.mp4")),
            poolSize: poolSize
        )
    }

    private func makeCandidate(
        _ index: Int, distance: CGFloat
    ) -> GridVideoPlaybackCoordinator.Candidate {
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        return .init(
            id: PostID("post-\(index)"),
            url: URL(string: "mock://video/\(index)")!,
            cell: cell,
            distanceFromCentre: distance
        )
    }

    // MARK: - Flight surfaces (#83 Phase 2)

    /// A flight surface is only produced when it can actually DRAW.
    ///
    /// `attachSurface` succeeds whenever something is playing the URL, but a
    /// surface can only be primed if that playback has already decoded a frame.
    /// One that could not be primed flies as a hidden empty layer over the
    /// card's cover — the thumbnail pop traced in #83 — so the coordinator
    /// refuses it and lets the flight fall through to a producer whose surface
    /// is live.
    ///
    /// Nothing decodes in a unit-test environment, which makes this the case
    /// the suite can actually pin: playback is registered, the attach would
    /// succeed, and the guard still refuses because no frame exists. The
    /// released-when-windowless sweep needs a real decoded frame and is
    /// exercised in the simulator instead.
    @Test func noFlightSurfaceUntilThePlaybackHasDecodedAFrame() async {
        let pool = makePool()
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        coordinator.update(candidates: [candidate])
        await coordinator.debugAwaitStarts()

        // The tile IS registered as playing — the refusal below is about the
        // absence of a decoded frame, not the absence of playback.
        #expect(coordinator.playingIDs.contains(candidate.id))
        #expect(coordinator.makeAttachedSurface(for: candidate.id, url: candidate.url) == nil)
        // Refusing must not leave a surface attached behind it.
        #expect(pool.surfaceCount(for: candidate.url) == 1)
    }

    /// A tile that is not playing has nothing to join, and must not mint a
    /// surface that would sit attached to nothing.
    @Test func noFlightSurfaceForATileThatIsNotPlaying() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        #expect(coordinator.makeAttachedSurface(for: candidate.id, url: candidate.url) == nil)
    }

    // MARK: - Selection

    /// The cap is the whole reason the grid is affordable: a mosaic can show a
    /// dozen video bricks, and only a few may hold players.
    @Test func playsAtMostMaxConcurrentTiles() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        #expect(coordinator.playingIDs.count == 3)
    }

    @Test func defaultsToSixConcurrentPlayers() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(poolSize: 6))
        coordinator.update(candidates: (0..<12).map { makeCandidate($0, distance: CGFloat($0)) })
        #expect(coordinator.playingIDs.count == 6)
    }

    // MARK: - Mid-fling gating

    /// During a hard fling nothing new starts — anything started is off screen
    /// before its first frame.
    @Test func noStartsWhileGated() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 6)
        coordinator.update(
            candidates: [makeCandidate(0, distance: 10)], allowingStarts: false
        )
        #expect(coordinator.playingIDs.isEmpty)
    }

    /// Stopping is never gated: a tile that left must give its player back
    /// whatever the scroll is doing, or the pool starves mid-fling.
    @Test func stopsStillHappenWhileGated() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 6)
        let candidate = makeCandidate(0, distance: 10)
        coordinator.update(candidates: [candidate])
        #expect(coordinator.playingIDs.count == 1)

        coordinator.update(candidates: [], allowingStarts: false)
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func startsResumeOnceUngated() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 6)
        let candidates = [makeCandidate(0, distance: 10)]
        coordinator.update(candidates: candidates, allowingStarts: false)
        #expect(coordinator.playingIDs.isEmpty)
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs.count == 1)
    }

    /// Closest to the viewport centre wins, regardless of the order the caller
    /// happened to enumerate visible cells in.
    @Test func choosesTheTilesNearestTheViewportCentre() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 2)
        coordinator.update(candidates: [
            makeCandidate(0, distance: 400),
            makeCandidate(1, distance: 10),
            makeCandidate(2, distance: 800),
            makeCandidate(3, distance: 50)
        ])
        #expect(coordinator.playingIDs == [PostID("post-1"), PostID("post-3")])
    }

    @Test func tilesThatLoseTheirSlotStopPlaying() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 1)
        let near = makeCandidate(0, distance: 10)
        let far = makeCandidate(1, distance: 900)
        coordinator.update(candidates: [near, far])
        #expect(coordinator.playingIDs == [PostID("post-0")])

        // The viewer scrolls: the far tile is now the central one.
        coordinator.update(candidates: [
            makeCandidate(0, distance: 900),
            .init(id: far.id, url: far.url, cell: far.cell, distanceFromCentre: 10)
        ])
        #expect(coordinator.playingIDs == [PostID("post-1")])
    }

    @Test func reconcilingWithTheSameSetIsIdempotent() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 2)
        let candidates = [makeCandidate(0, distance: 10), makeCandidate(1, distance: 20)]
        coordinator.update(candidates: candidates)
        let first = coordinator.playingIDs
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs == first)
    }

    @Test func anEmptyCandidateSetStopsEverything() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        coordinator.update(candidates: [])
        #expect(coordinator.playingIDs.isEmpty)
    }

    // MARK: - Visibility

    @Test func anInvisibleSurfacePlaysNothing() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.setSurfaceVisible(false)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func hidingTheSurfaceStopsPlayingTiles() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        #expect(!coordinator.playingIDs.isEmpty)
        coordinator.setSurfaceVisible(false)
        #expect(coordinator.playingIDs.isEmpty)
    }

    /// The tapped tile is exempt: its player is the one the hero flight carries,
    /// and stopping it mid-flight is exactly the restart the handoff prevents.
    @Test func hidingTheSurfaceKeepsTheFlightsTile() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [
            makeCandidate(0, distance: 10), makeCandidate(1, distance: 20)
        ])
        coordinator.setSurfaceVisible(false, keeping: PostID("post-0"))
        #expect(coordinator.playingIDs == [PostID("post-0")])
    }

    // MARK: - Recycling

    /// A recycled cell that kept its player would render the previous post's
    /// video under the new post's still.
    @Test func recyclingACellReturnsItsPlayer() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 10)
        coordinator.update(candidates: [candidate])
        #expect(!coordinator.playingIDs.isEmpty)

        coordinator.stop(cell: candidate.cell)
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func stoppingAnUnknownCellIsANoOp() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        coordinator.stop(cell: PostGridTileCell(frame: .zero))
        #expect(coordinator.playingIDs.count == 1)
    }

    // MARK: - Handoff

    @Test func parkingForHandoffReleasesTheTile() async {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 10)
        coordinator.update(candidates: [candidate])
        // The pool attaches asynchronously (the URL is resolved first), so wait
        // for the start rather than racing it.
        await coordinator.awaitPendingStarts()

        #expect(coordinator.parkForHandoff(candidate.id))
        // The tile no longer holds it — the parked player belongs to whatever
        // adopts it next.
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func parkingATileThatIsNotPlayingReportsFalse() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        #expect(coordinator.parkForHandoff(PostID("post-nope")) == false)
    }

    // MARK: - Cap

    /// Pinned against a real ladder rather than an abstract number: Apple's
    /// BipBop rungs are 264 / 578 / 916 / 1030 / 1924 kbps, so the tile cap must
    /// admit 578 and exclude 916.
    @Test func theTileCapSelectsALowLadderRung() {
        #expect(GridVideoPlaybackCoordinator.tileBitRateCap > 578_000)
        #expect(GridVideoPlaybackCoordinator.tileBitRateCap < 916_000)
        #expect(GridVideoPlaybackCoordinator.uncapped == 0)
    }

    // MARK: - Focus

    /// ⚠️ THE POST BEING OPENED PLAYS, WHATEVER IT IS WORTH ON DISTANCE.
    ///
    /// The hero can only fly a picture the grid is already decoding, so the
    /// tile under the finger is not a candidate among candidates. Pinned at the
    /// far end of the ranking — eighth of eight, budget of three — because that
    /// is where the ordinary rule would put a tap that landed on the edge of a
    /// wide row, and it is exactly the case that flew a thumbnail.
    @Test func theFocusedPostPlaysFromOutsideTheBudget() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidates = (0..<8).map { makeCandidate($0, distance: CGFloat($0)) }

        coordinator.focus(PostID("post-7"))
        coordinator.update(candidates: candidates)

        #expect(coordinator.playingIDs.contains(PostID("post-7")))
        // And it displaces one, rather than being added on top of the budget:
        // the cap is what makes the grid affordable.
        #expect(coordinator.playingIDs.count == 3)
    }

    /// ⚠️ AND IT STARTS DURING A FLING, when nothing else may.
    ///
    /// Suppressing starts at speed is right for every tile crossing the
    /// viewport. The one being opened is the opposite case: the scroll is about
    /// to stop existing and the flight is a few frames away, so the gate that
    /// protects a fling would otherwise deny the hero its picture.
    ///
    /// Both halves asserted together — a focus that started everything would
    /// pass a test that only looked at the focused post.
    @Test func aFlingStillStartsTheFocusedPost() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidates = (0..<4).map { makeCandidate($0, distance: CGFloat($0)) }

        coordinator.focus(PostID("post-2"))
        coordinator.update(candidates: candidates, allowingStarts: false)

        #expect(coordinator.playingIDs == [PostID("post-2")])
    }

    /// ⚠️ AND IT IS NEVER STOPPED TO MAKE ROOM.
    ///
    /// A grid keeps reconciling while the flight is being staged, and the tile
    /// the card is flying can leave the candidate list entirely — the page
    /// scrolls, the row recycles, the grid goes behind a covering screen.
    /// Stopping it there kills the player mid-flight, which is the thumbnail
    /// appearing PART WAY through a transition rather than at its start.
    @Test func theFocusedPostSurvivesLeavingTheViewport() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidates = (0..<4).map { makeCandidate($0, distance: CGFloat($0)) }
        coordinator.focus(PostID("post-0"))
        coordinator.update(candidates: candidates)

        coordinator.update(candidates: Array(candidates.dropFirst()))

        #expect(coordinator.playingIDs.contains(PostID("post-0")))
    }

    /// ⚠️ AND THE CLAIM IS RELEASED, or the grid would carry a player for a
    /// post nobody is looking at for the rest of the session.
    ///
    /// The release is what makes the claim affordable: it is held for the
    /// length of a transition, not the length of a screen.
    @Test func releasingTheFocusReturnsThePlayer() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidates = (0..<4).map { makeCandidate($0, distance: CGFloat($0)) }
        coordinator.focus(PostID("post-3"))
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs.contains(PostID("post-3")))

        coordinator.focus(nil)
        coordinator.update(candidates: candidates)

        #expect(coordinator.playingIDs.contains(PostID("post-3")) == false)
    }

    /// ⚠️ AND WHEN EVERY ORDINARY DOOR IS SHUT, THE FLIGHT KNOCKS ANYWAY.
    ///
    /// A handoff deliberately closes them all: `isSurfaceVisible` goes false so
    /// nothing new is chosen, and the flying post is filtered out of the
    /// ranking so reconcile can neither start nor stop it. That is right for a
    /// post whose player is already in the air — and wrong for the case this
    /// exists for, a tile that reached the flight holding nothing. Asked
    /// through `update`, it would wait forever; asked directly, it plays.
    @Test func aFlightCanDemandAPlayerAfterTheHandoffShutTheDoors() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        coordinator.beginHandoff(candidate.id)

        // The ordinary route is genuinely closed — this is the premise, not a
        // formality, and a change that reopened it would make the demand below
        // pass for the wrong reason.
        coordinator.update(candidates: [candidate])
        #expect(coordinator.playingIDs.isEmpty)

        coordinator.demandFlightPlayback(of: candidate.id, url: candidate.url, in: candidate.cell)

        #expect(coordinator.playingIDs.contains(candidate.id))
    }

    /// ⚠️ AND IT IS ASKED EVERY FRAME, so it must cost nothing after the first.
    ///
    /// The retry calls the producer once per display refresh for the length of
    /// a flight — twenty-odd times. A demand that restarted the clip on each
    /// one would rebuild the item, throw away the decode it just paid for, and
    /// begin the video again from zero, repeatedly, for the whole transition.
    @Test func demandingAPlayerEveryFrameStartsItOnce() async {
        let pool = makePool()
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        coordinator.beginHandoff(candidate.id)

        for _ in 0..<20 {
            coordinator.demandFlightPlayback(of: candidate.id, url: candidate.url, in: candidate.cell)
        }
        await coordinator.debugAwaitStarts()

        #expect(coordinator.playingIDs == [candidate.id])
        #expect(pool.itemCreations == 1)
    }
}
