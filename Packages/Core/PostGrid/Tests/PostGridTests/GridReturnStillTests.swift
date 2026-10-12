import CoreModels
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// A close whose return player went (a deeper stack evicted it, memory
/// pressure released it) lands on the frame it was parked on (#895, the #923
/// follow-up): the card fades in that exact picture at once, the tile wears
/// it as its cover, and the tile's next player starts from it.
@MainActor
struct GridReturnStillTests {
    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
    }

    private func makePool() -> VideoPlaybackController {
        VideoPlaybackController(
            source: FixedVideoSource(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("return-still-stub.mp4"))
        )
    }

    private func candidate(_ index: Int) -> GridVideoPlaybackCoordinator.Candidate {
        .init(
            id: PostID("return-still-\(index)"),
            url: URL(string: "mock://video/return-still-\(index)")!,
            cell: PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120)),
            distanceFromCentre: 0
        )
    }

    private func picture(_ colour: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// A grid playing `tapped`, opened with a return park, whose parked
    /// player then went under memory pressure, leaving `frame` as its still,
    /// and whose tile player the page has retired.
    private func gridWhoseReturnPlayerWent(
        pool: VideoPlaybackController, tapped: GridVideoPlaybackCoordinator.Candidate, frame: UIImage
    ) async -> GridVideoPlaybackCoordinator {
        let grid = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        grid.setSurfaceVisible(true)
        grid.update(candidates: [tapped])
        await grid.debugAwaitStarts()
        grid.beginHandoff(tapped.id, parkingReturn: true)
        await grid.debugAwaitReturnParks()
        // A stub clip decodes nothing: the frame a capture would have kept.
        pool.debugKeepReturnStill(frame, at: 2.5, of: tapped.url, scope: tapped.id.rawValue, owner: grid.debugReturnOwner)
        pool.releaseAllReturnPlaybacks()
        // The tile's own player went to the page, which retired it when the
        // viewer paged on.
        if let tile = tapped.cell.loadedVideoRenderView { pool.stop(tile) }
        return grid
    }

    /// ⚠️ THE FRAME, AT ONCE. With the player gone, the close's arriving
    /// surface shows the parked frame instead of nothing; the landing makes it
    /// the tile's cover over the thumbnail it had, the hold lets the card go
    /// without waiting, and the tile's next player starts at that frame.
    @Test func aCloseWhosePlayerWentLandsOnItsParkedFrame() async throws {
        let pool = makePool()
        let tapped = candidate(0)
        let frame = picture(.blue)
        let grid = await gridWhoseReturnPlayerWent(pool: pool, tapped: tapped, frame: frame)
        tapped.cell.applyCover(picture(.red))
        #expect(!grid.hasReturnPlayback(for: tapped.id))

        let arriving = try #require(grid.makeReturnSurface(for: tapped.id), "no picture for a close whose player went")
        #expect(arriving.currentStill === frame)

        #expect(grid.landReturnPlayback(arriving, for: tapped.id, cell: tapped.cell))
        #expect(tapped.cell.renderedCover === frame, "the tile kept its thumbnail over the parked frame")
        // `viewDidAppear` in the landing's own turn (#963): the hold still
        // knows the tile wears its frame.
        grid.endHandoff()
        #expect(grid.isReturnLandingReady(for: tapped.id, cell: tapped.cell, hasThumbnail: true))
        let start = try #require(pool.debugFiledStart(of: tapped.url, scope: tapped.id.rawValue))
        #expect(abs(start - 2.5) < 0.01)
    }

    /// The owner's release (the scope ended with no close from another post)
    /// drops the frame: the next close has nothing stale to show.
    @Test func aReleasedScopeLeavesNoFrameBehind() async {
        let pool = makePool()
        let tapped = candidate(0)
        let grid = await gridWhoseReturnPlayerWent(pool: pool, tapped: tapped, frame: picture(.blue))
        grid.endHandoff()
        #expect(pool.returnStill(of: tapped.url, scope: tapped.id.rawValue, owner: grid.debugReturnOwner) == nil)
        #expect(grid.makeReturnSurface(for: tapped.id) == nil)
    }
}
