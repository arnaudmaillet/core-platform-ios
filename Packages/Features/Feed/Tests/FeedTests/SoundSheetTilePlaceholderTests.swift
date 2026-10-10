import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A sound sheet tile whose post is still on its way wears a bone (#831),
/// and gives it up when the post is filled in.
///
/// A post that cannot be loaded is not drawn as a failed tile: the sheet
/// drops it and deals its sections again, by design
/// (`SnapFeedViewController.presentSoundSheet`, `SoundSheetSections`) — its
/// tile would lead nowhere. `SoundSheetTests` holds the re-dealing.
@MainActor
struct SoundSheetTilePlaceholderTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.cancelled) }
    }

    private let pipeline = ImagePipeline(fetcher: SilentFetcher())

    private func tile(_ id: String, loaded: Bool) -> SoundSheetViewController.Tile {
        SoundSheetViewController.Tile(
            postID: PostID(id),
            thumbnailURL: loaded ? URL(string: "https://cdn.example/\(id).jpg") : nil,
            caption: nil,
            isCurrent: false,
            isLoaded: loaded,
            likeCount: loaded ? 12 : nil
        )
    }

    private func cell() -> SoundSheetTileCell {
        let cell = SoundSheetTileCell(frame: CGRect(x: 0, y: 0, width: 123, height: 164))
        cell.layoutIfNeeded()
        return cell
    }

    @Test func aPlaceholderTileWearsABone() {
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)

        #expect(cell.showsPlaceholderBone)
    }

    @Test func aLoadedTileWearsNoBone() {
        let cell = cell()
        cell.configure(tile("p1", loaded: true), pipeline: pipeline)

        #expect(cell.showsPlaceholderBone == false)
    }

    @Test func aPlaceholderFilledInGivesItsBoneUp() {
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)

        cell.configure(tile("p1", loaded: true), pipeline: pipeline)

        #expect(cell.showsPlaceholderBone == false)
    }

    @Test func aReusedPlaceholderCellStandingForALoadedPostHasNoBone() {
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)

        cell.prepareForReuse()
        cell.configure(tile("p2", loaded: true), pipeline: pipeline)

        #expect(cell.showsPlaceholderBone == false)
    }
}
