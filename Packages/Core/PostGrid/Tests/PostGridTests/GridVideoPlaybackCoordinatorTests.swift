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

    // MARK: - Selection

    /// The cap is the whole reason the grid is affordable: a mosaic can show a
    /// dozen video bricks, and only a few may hold players.
    @Test func playsAtMostMaxConcurrentTiles() {
        let coordinator = GridVideoPlaybackCoordinator(pool: makePool(), maxConcurrent: 3)
        coordinator.update(candidates: (0..<8).map { makeCandidate($0, distance: CGFloat($0)) })
        #expect(coordinator.playingIDs.count == 3)
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
}
