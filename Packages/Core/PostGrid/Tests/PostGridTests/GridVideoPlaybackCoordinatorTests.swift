import CoreModels
import DesignSystem
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
    /// A coordinator that has been told it is on screen.
    ///
    /// ⚠️ Construction alone no longer permits playback: `isSurfaceVisible` is
    /// FALSE at birth, so a coordinator nobody has told about takes no loans on
    /// the shared pool. Every test below is about what a VISIBLE grid does, so
    /// they all go through here; the gated cases assert `false` explicitly
    /// afterwards, which now reads as the state change it is.
    private func makeVisibleCoordinator(
        pool: VideoPlaybackController, maxConcurrent: Int? = nil
    ) -> GridVideoPlaybackCoordinator {
        let coordinator = maxConcurrent.map {
            GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: $0)
        } ?? GridVideoPlaybackCoordinator(pool: pool)
        coordinator.setSurfaceVisible(true)
        return coordinator
    }

    @Test func noFlightSurfaceUntilThePlaybackHasDecodedAFrame() async {
        let pool = makePool()
        let coordinator = makeVisibleCoordinator(pool: pool, maxConcurrent: 3)
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

    /// With autoplay off — the viewer's setting, or Power Saving — a grid plays
    /// nothing, and tiles already playing give their players back on the
    /// next reconcile (#580).
    @Test func withAutoplayOffNoTilePlays() async {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        var allowed = true
        coordinator.autoplayAllowed = { allowed }
        let candidates = [makeCandidate(0, distance: 0), makeCandidate(1, distance: 10)]
        coordinator.update(candidates: candidates)
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs.count == 2)

        allowed = false
        coordinator.update(candidates: candidates)
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs.isEmpty)

        let fresh = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        fresh.autoplayAllowed = { false }
        fresh.update(candidates: [makeCandidate(2, distance: 0)])
        await fresh.debugAwaitStarts()
        #expect(fresh.playingIDs.isEmpty)
    }

    /// The app resting (`IdleCalm`) neither stops nor pauses a grid's tiles
    /// (#882): a tile playing is a video on screen, not decoration. The rest
    /// is broadcast, and a reconcile that lands while the app rests — a cover
    /// arriving, a layout pass — keeps every tile it was keeping.
    ///
    /// The DEFAULT gate, as every grid in the app has it (For You, the rails,
    /// the profile gallery): an injected one would prove nothing about what
    /// the coordinator itself consults.
    ///
    /// ⚠️ `IdleCalm` is app-wide, so it is set and put back in ONE main-actor
    /// turn, with no `await` between: nothing running beside this suite can
    /// be scheduled while it is set (memory `global-test-state-await-trap`),
    /// and an observer that reads it later reads it awake again.
    @Test func restingNeitherStopsNorPausesTheTiles() async {
        let pool = makePool()
        let coordinator = makeVisibleCoordinator(pool: pool, maxConcurrent: 3)
        let candidates = [makeCandidate(0, distance: 0), makeCandidate(1, distance: 10)]
        let ids = Set(candidates.map(\.id))
        coordinator.update(candidates: candidates)
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs == ids, "guard: the tiles play")
        let surfaces = candidates.compactMap { $0.cell.loadedVideoRenderView }
        #expect(surfaces.count == 2 && surfaces.allSatisfy { pool.hasPlayer(in: $0) }, "guard: bound")
        let pausedBefore = surfaces.map { pool.isPaused(in: $0) }

        // One turn: rest, reconcile, read, wake.
        let wasCalm = IdleCalm.isCalm
        IdleCalm.set(true)
        let gateWhileResting = coordinator.autoplayAllowed()
        let powerSavingGate = GridVideoPlaybackCoordinator.allowsAutoplay()
        let playingAfterRest = coordinator.playingIDs
        coordinator.update(candidates: candidates)
        let playingAfterReconcile = coordinator.playingIDs
        let boundWhileResting = surfaces.map { pool.hasPlayer(in: $0) }
        let pausedWhileResting = surfaces.map { pool.isPaused(in: $0) }
        IdleCalm.set(wasCalm)

        #expect(gateWhileResting == powerSavingGate, "the gate read the app's rest")
        #expect(playingAfterRest == ids, "the rest stopped the tiles")
        #expect(playingAfterReconcile == ids, "a reconcile at rest stopped the tiles")
        #expect(boundWhileResting == [true, true], "a tile gave its player back at rest")
        #expect(pausedWhileResting == pausedBefore, "the rest paused a tile")
    }

    /// A tile that is not playing has nothing to join, and must not mint a
    /// surface that would sit attached to nothing.
    @Test func noFlightSurfaceForATileThatIsNotPlaying() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        #expect(coordinator.makeAttachedSurface(for: candidate.id, url: candidate.url) == nil)
    }

    // MARK: - Selection

    /// The cap is the whole reason the grid is affordable: a mosaic can show a
    /// dozen video bricks, and only a few may hold players.
    @Test func playsAtMostMaxConcurrentTiles() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        #expect(coordinator.playingIDs.count == 3)
    }

    @Test func defaultsToSixConcurrentPlayers() {
        let coordinator = makeVisibleCoordinator(pool: makePool(poolSize: 6))
        coordinator.update(candidates: (0..<12).map { makeCandidate($0, distance: CGFloat($0)) })
        #expect(coordinator.playingIDs.count == 6)
    }

    // MARK: - The birth state

    /// A coordinator nobody has told about takes NO loans.
    ///
    /// This is the whole bug in one assertion. The default used to be
    /// "visible", so merely constructing a grid could start players — and the
    /// Profile gallery is constructed at launch on a tab nobody selects, then
    /// forces a layout off-window and reconciles. Its only release is a
    /// `viewWillDisappear` that never fires for a tab never entered, so the
    /// loans were unreclaimable for the life of the process. Measured on
    /// develop: four players held at rest with no grid ever on screen.
    ///
    /// ⚠️ Do NOT route this through `makeVisibleCoordinator` — the point is the
    /// state before anyone speaks.
    @Test func aCoordinatorNobodyHasToldAboutTakesNoLoans() async {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 6)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs.isEmpty)
    }

    /// ...and starts as soon as it is told, so the fix cannot pass by refusing
    /// to ever play. A guard that is always closed satisfies the test above.
    @Test func andPlaysOnceItIsToldItIsOnScreen() async {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 6)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs.isEmpty)

        coordinator.setSurfaceVisible(true)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        await coordinator.debugAwaitStarts()
        #expect(coordinator.playingIDs.count == 6)
    }

    // MARK: - Mid-fling gating

    /// During a hard fling nothing new starts — anything started is off screen
    /// before its first frame.
    @Test func noStartsWhileGated() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 6)
        coordinator.update(
            candidates: [makeCandidate(0, distance: 10)], allowingStarts: false
        )
        #expect(coordinator.playingIDs.isEmpty)
    }

    /// Stopping is never gated: a tile that left must give its player back
    /// whatever the scroll is doing, or the pool starves mid-fling.
    @Test func stopsStillHappenWhileGated() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 6)
        let candidate = makeCandidate(0, distance: 10)
        coordinator.update(candidates: [candidate])
        #expect(coordinator.playingIDs.count == 1)

        coordinator.update(candidates: [], allowingStarts: false)
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func startsResumeOnceUngated() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 6)
        let candidates = [makeCandidate(0, distance: 10)]
        coordinator.update(candidates: candidates, allowingStarts: false)
        #expect(coordinator.playingIDs.isEmpty)
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs.count == 1)
    }

    /// Closest to the viewport centre wins, regardless of the order the caller
    /// happened to enumerate visible cells in.
    @Test func choosesTheTilesNearestTheViewportCentre() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 2)
        coordinator.update(candidates: [
            makeCandidate(0, distance: 400),
            makeCandidate(1, distance: 10),
            makeCandidate(2, distance: 800),
            makeCandidate(3, distance: 50)
        ])
        #expect(coordinator.playingIDs == [PostID("post-1"), PostID("post-3")])
    }

    @Test func tilesThatLoseTheirSlotStopPlaying() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 1)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 2)
        let candidates = [makeCandidate(0, distance: 10), makeCandidate(1, distance: 20)]
        coordinator.update(candidates: candidates)
        let first = coordinator.playingIDs
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs == first)
    }

    @Test func anEmptyCandidateSetStopsEverything() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        coordinator.update(candidates: [])
        #expect(coordinator.playingIDs.isEmpty)
    }

    // MARK: - Visibility

    @Test func anInvisibleSurfacePlaysNothing() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.setSurfaceVisible(false)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func hidingTheSurfaceStopsPlayingTiles() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        #expect(!coordinator.playingIDs.isEmpty)
        coordinator.setSurfaceVisible(false)
        #expect(coordinator.playingIDs.isEmpty)
    }

    /// ⚠️ A START STOPPED BEFORE ITS TASK RAN BINDS NOTHING (#884). Above, the
    /// loans go; here, the POOL: the start's task had not called `play` when
    /// the stop came, so the stop found nothing to detach — and the task, run
    /// later, bound a player no loan knew about. Found by the sound sheet's
    /// suite: a reconcile the app-wide gate turned down landed between the
    /// sheet's start and its task, and six players outlived the sheet.
    ///
    /// Watched for a while rather than once: the leak lands only after the
    /// stub source resolves, and an early look reads zero either way.
    @Test func aStartStoppedBeforeItsTaskRanBindsNoPlayer() async {
        let pool = makePool()
        let coordinator = makeVisibleCoordinator(pool: pool, maxConcurrent: 3)
        let candidates = [makeCandidate(0, distance: 0), makeCandidate(1, distance: 10)]
        coordinator.update(candidates: candidates)
        #expect(coordinator.playingIDs.count == 2, "guard: started")
        // The same turn: neither start's task has run.
        coordinator.setSurfaceVisible(false)

        var leaked = 0
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(5))
            leaked = pool.activePlayerCount
            if leaked > 0 { break }
        }
        #expect(leaked == 0, "a stopped start bound \(leaked) player(s) after its stop")
    }

    /// The tapped tile is exempt: its player is the one the hero flight carries,
    /// and stopping it mid-flight is exactly the restart the handoff prevents.
    @Test func hidingTheSurfaceKeepsTheFlightsTile() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 10)
        coordinator.update(candidates: [candidate])
        #expect(!coordinator.playingIDs.isEmpty)

        coordinator.stop(cell: candidate.cell)
        #expect(coordinator.playingIDs.isEmpty)
    }

    @Test func stoppingAnUnknownCellIsANoOp() {
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: [makeCandidate(0, distance: 10)])
        coordinator.stop(cell: PostGridTileCell(frame: .zero))
        #expect(coordinator.playingIDs.count == 1)
    }

    // MARK: - Handoff


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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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
        let coordinator = makeVisibleCoordinator(pool: makePool(), maxConcurrent: 3)
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

    /// ⚠️ A LANDING TILE KEEPS THE LOAN IT WAS HANDED, even when it never
    /// played before the landing.
    ///
    /// The place page's first tile is exactly that: the viewer arrived from a
    /// map marker, so the tile a dismissal lands on had no player of its own.
    /// `adoptAttachedSurface` recorded the loan and not the stream, and the
    /// reconcile that runs the instant the tile is unhidden read the missing
    /// stream as "this row paged to another clip" — and STOPPED it, retiring
    /// the player under the landing card and the page behind it, then minting
    /// the same clip again from its resume point.
    @Test func aLandingTileThatNeverPlayedKeepsTheLoanItAdopted() async {
        let pool = makePool()
        let coordinator = makeVisibleCoordinator(pool: pool, maxConcurrent: 3)
        let candidate = makeCandidate(0, distance: 0)
        // The feed page's playback, which the dismissal flies home.
        let page = VideoRenderView()
        await pool.play(candidate.url, in: page, scope: candidate.id.rawValue)
        #expect(pool.itemCreations == 1)

        #expect(coordinator.adoptAttachedSurface(for: candidate.id, url: candidate.url, cell: candidate.cell))
        // The tile is unhidden, and the grid reconciles.
        coordinator.update(candidates: [candidate])
        await coordinator.debugAwaitStarts()

        #expect(coordinator.playingIDs == [candidate.id])
        // Still the playback the card flew: nothing stopped, nothing minted.
        #expect(pool.itemCreations == 1)
        #expect(pool.playerCountByURL[candidate.url] == 1)
        #expect(pool.isAdvancing(in: page))
    }

    /// ⚠️ AND IT IS ASKED EVERY FRAME, so it must cost nothing after the first.
    ///
    /// The retry calls the producer once per display refresh for the length of
    /// a flight — twenty-odd times. A demand that restarted the clip on each
    /// one would rebuild the item, throw away the decode it just paid for, and
    /// begin the video again from zero, repeatedly, for the whole transition.
    @Test func demandingAPlayerEveryFrameStartsItOnce() async {
        let pool = makePool()
        let coordinator = makeVisibleCoordinator(pool: pool, maxConcurrent: 3)
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

/// A coordinator's tiles play under the post's own scope by default, and
/// under a tagged one when the surface asks (#1547), so they never join
/// the same post's player elsewhere.
@MainActor
struct GridPlaybackScopeTests {
    @Test func tilesShareThePostsScopeUnlessTagged() {
        let pool = VideoPlaybackController(source: FixedVideoSource(url: FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")), poolSize: 1)
        let coordinator = GridVideoPlaybackCoordinator(pool: pool)
        #expect(coordinator.playbackScope(for: PostID("p1")) == "p1")
        coordinator.playbackScopeTag = "side-list"
        #expect(coordinator.playbackScope(for: PostID("p1")) == "side-list:p1")
    }
}

