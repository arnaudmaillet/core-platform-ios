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

    /// Serves a small PNG for any poster.
    private struct PosterFetcher: ImageFetching {
        static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }

        func fetchImageData(for url: URL) async throws -> Data { Self.png }
    }

    private let pipeline = ImagePipeline(fetcher: SilentFetcher())

    /// Looks, not wall-clock time: a budget of looks spends nothing while the
    /// process is not scheduled.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

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

    @Test func aPlaceholderFilledInWithACachedPosterTradesItsBoneForItAtOnce() {
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        pipeline.store(poster, for: URL(string: "https://cdn.example/p1.jpg")!)

        cell.configure(tile("p1", loaded: true), pipeline: pipeline)

        #expect(cell.cover === poster)
        #expect(cell.showsPlaceholderBone == false)
    }

    @Test func aPlaceholderFilledInKeepsItsBoneUntilItsPosterLands() async {
        let pipeline = ImagePipeline(fetcher: PosterFetcher())
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)

        cell.configure(tile("p1", loaded: true), pipeline: pipeline)
        #expect(cell.showsPlaceholderBone, "no bare fill before the poster")
        #expect(cell.cover == nil)

        await settle { cell.cover != nil }
        #expect(cell.cover != nil)
        #expect(cell.showsPlaceholderBone == false, "the bone leaves as the poster lands")
    }

    @Test func aFilledInTextPostGivesItsBoneUpAtOnce() {
        let cell = cell()
        cell.configure(tile("p1", loaded: false), pipeline: pipeline)

        cell.configure(
            SoundSheetViewController.Tile(
                postID: PostID("p1"), thumbnailURL: nil, caption: "words", isCurrent: false
            ),
            pipeline: pipeline
        )

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
