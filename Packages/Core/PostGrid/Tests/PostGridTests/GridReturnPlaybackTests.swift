import CoreModels
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// The grid's half of the return player (#923): the tile a post was opened
/// from is parked at the tap, a close from another post flies it, and the
/// landing hands it back to the tile — within a bound that a stack of pushes
/// cannot break.
@MainActor
struct GridReturnPlaybackTests {
    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
    }

    private func makePool() -> VideoPlaybackController {
        VideoPlaybackController(
            source: FixedVideoSource(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("return-stub.mp4"))
        )
    }

    private func candidate(_ index: Int, distance: CGFloat = 0) -> GridVideoPlaybackCoordinator.Candidate {
        .init(
            id: PostID("return-\(index)"),
            url: URL(string: "mock://video/return-\(index)")!,
            cell: PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120)),
            distanceFromCentre: distance
        )
    }

    /// A visible grid already playing `tapped`, which is then opened.
    private func openedGrid(
        on pool: VideoPlaybackController, tapped: GridVideoPlaybackCoordinator.Candidate,
        others: [GridVideoPlaybackCoordinator.Candidate] = [], parkingReturn: Bool = true
    ) async -> GridVideoPlaybackCoordinator {
        let grid = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        grid.setSurfaceVisible(true)
        grid.update(candidates: [tapped] + others)
        await grid.debugAwaitStarts()
        grid.beginHandoff(tapped.id, parkingReturn: parkingReturn)
        await grid.debugAwaitReturnParks()
        return grid
    }

    // MARK: - Parked at the tap

    @Test func openingAPlayingTileParksItsReturnPlayer() async {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await openedGrid(on: pool, tapped: tapped)
        #expect(grid.hasReturnPlayback(for: tapped.id))
        #expect(pool.returnPlaybackCount == 1)
        // Not a loan: the tile's own player is still the only active one.
        #expect(pool.activePlayerCount == 1)
    }

    /// Opt-in: a grid whose close never asks parks nothing.
    @Test func aHandoffThatDoesNotAskParksNothing() async {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await openedGrid(on: pool, tapped: tapped, parkingReturn: false)
        #expect(!grid.hasReturnPlayback(for: tapped.id))
        #expect(pool.returnPlaybackCount == 0)
        #expect(grid.makeReturnSurface(for: tapped.id) == nil)
    }

    /// A tile that is not playing at the tap has no clip on screen to come
    /// back to: nothing is parked, and its close lands on the still.
    @Test func aTileThatIsNotPlayingParksNothing() async {
        let pool = makePool()
        let grid = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        grid.setSurfaceVisible(true)
        let tapped = candidate(0)
        grid.beginHandoff(tapped.id, parkingReturn: true)
        await grid.debugAwaitReturnParks()
        #expect(pool.returnPlaybackCount == 0)
        #expect(grid.makeReturnSurface(for: tapped.id) == nil)
    }

    // MARK: - Flown and landed

    /// The close flies the parked clip and the landing gives it to the tile:
    /// the tile ends up owning ITS OWN post's player, never the page's.
    @Test func theLandingHandsTheTileItsOwnClip() async throws {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await openedGrid(on: pool, tapped: tapped)

        let flying = try #require(grid.makeReturnSurface(for: tapped.id))
        #expect(grid.adoptAttachedSurface(
            for: tapped.id, url: tapped.url, cell: tapped.cell, drawnBy: flying
        ))
        #expect(pool.returnPlaybackCount == 0, "the landing did not claim the parked player")
        let tile = try #require(tapped.cell.loadedVideoRenderView)
        #expect(pool.hasPlayer(in: tile))
        #expect(grid.loanedCell(tapped.id) === tapped.cell)
        // ONE player for the tile: the one it held before the open (still
        // owned here, since no page took it in this test) was let go, not
        // left decoding behind the claimed one.
        #expect(pool.activePlayerCount == 1)

        // Closing the scope keeps the landed clip: it is the tile's loan now.
        grid.endHandoff()
        grid.update(candidates: [tapped])
        #expect(grid.playingIDs.contains(tapped.id))
        #expect(pool.hasPlayer(in: tile))
        #expect(pool.activePlayerCount == 1)
    }

    /// A close that went another way (same post, the card window, a push
    /// reversed) leaves the parked player unused: the scope's end releases it.
    @Test func closingTheScopeReleasesAnUnusedReturnPlayer() async {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await openedGrid(on: pool, tapped: tapped)
        grid.endHandoff()
        #expect(pool.returnPlaybackCount == 0)
        #expect(!grid.hasReturnPlayback(for: tapped.id))
    }

    /// An abandoned close pauses the clip and keeps it for the next one.
    @Test func anAbandonedCloseKeepsTheClipForTheNextOne() async throws {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await openedGrid(on: pool, tapped: tapped)
        let first = try #require(grid.makeReturnSurface(for: tapped.id))
        grid.pauseReturnPlayback(of: tapped.id)
        #expect(!pool.isAdvancing(in: first))
        #expect(grid.makeReturnSurface(for: tapped.id) != nil)
    }

    // MARK: - The bound across a stack of pushes

    /// ⚠️ N STACKED PUSHES FROM VIDEOS NEVER STARVE THE PLAYBACK POOL.
    ///
    /// Four screens deep, each opened from a playing tile of its own grid:
    /// the ledger holds the two most recent, the deepest closes still fly
    /// their clip, the oldest falls back to its still (`makeReturnSurface` is
    /// nil), and a grid asked to play its full budget afterwards gets every
    /// slot — none was taken by a parked player.
    @Test func stackedPushesNeverStarveThePlaybackPool() async {
        let pool = makePool()
        var grids: [GridVideoPlaybackCoordinator] = []
        var tapped: [GridVideoPlaybackCoordinator.Candidate] = []
        for depth in 0..<4 {
            let tile = candidate(depth)
            tapped.append(tile)
            grids.append(await openedGrid(on: pool, tapped: tile))
            #expect(pool.returnPlaybackCount <= VideoPlaybackController.returnPlaybackCapacity)
        }
        #expect(pool.returnPlaybackCount == VideoPlaybackController.returnPlaybackCapacity)
        // The oldest two were evicted: their closes land on the still.
        #expect(grids[0].makeReturnSurface(for: tapped[0].id) == nil)
        #expect(grids[1].makeReturnSurface(for: tapped[1].id) == nil)
        // The two most recent still fly their own clip.
        #expect(grids[2].makeReturnSurface(for: tapped[2].id) != nil)
        #expect(grids[3].makeReturnSurface(for: tapped[3].id) != nil)

        // A fresh grid's full budget is granted.
        let fresh = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        fresh.setSurfaceVisible(true)
        let tiles = (10..<13).map { candidate($0, distance: CGFloat($0)) }
        fresh.update(candidates: tiles)
        await fresh.debugAwaitStarts()
        #expect(fresh.playingIDs == Set(tiles.map(\.id)))
    }
}
