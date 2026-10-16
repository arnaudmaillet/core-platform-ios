import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Every host of a shelf (#1296, the owner 2026-10-16): its title over
/// skeleton cards until its posts land, then ten cards a row at most, each
/// row ending on the chevron card that runs the title's action.
@MainActor
struct ShelfHostsTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func posts(_ count: Int, prefix: String) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("\(prefix)\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/\(prefix)\(index).jpg"),
                caption: "post \(index)", publishedAtMS: Int64(index),
                authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
                reactionCount: Int64(100 - index), commentCount: 1
            )
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The landed shelf: ten a row at most, the chevron card last.
    private static func expectLanded(_ shelf: PostShelfSection, of total: Int) {
        #expect(!shelf.isLoading, "the skeleton outlived the posts")
        #expect(shelf.rowCounts.media == min(total, PostShelfSection.rowLimit))
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == shelf.rowCounts.media + 1,
                "the row does not end on the chevron card")
    }

    @Test func forYousFollowingLoadsThenDrawsTenAndTheChevron() {
        let screen = ForYouViewController(
            viewModel: ForYouViewModel(repository: EmptyForYouProvider()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeSnapFeed: { _ in UIViewController() },
            prewarm: { _ in }
        )
        screen.loadViewIfNeeded()
        let shelf = screen.debugShelf
        #expect(shelf.isLoading, "no skeleton before the first snapshot")
        #expect(shelf.title == "Following")
        var rows = ForYouViewModel.Rails()
        rows.following = Self.posts(14, prefix: "f")
        shelf.apply(.init(title: "Following", posts: rows.following))
        Self.expectLanded(shelf, of: 14)
    }

    @Test func thePlacePagesPopularLoadsThenDrawsTenAndTheChevron() async {
        let posts = Self.posts(14, prefix: "p")
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            openPost: { _, _, _ in }
        )
        place.loadViewIfNeeded()
        #expect(place.debugShelf.isLoading, "no skeleton before the place's posts")
        place.beginLoading()
        await Self.settle { !place.debugShelf.cards.isEmpty }
        Self.expectLanded(place.debugShelf, of: PlaceProfileViewController.popularRowCount)
    }

    @Test func theLeadRowLoadsThenDrawsTenAndTheChevron() async throws {
        let posts = Self.posts(14, prefix: "r")
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        surface.onLeadRowTitleTapped = {}
        surface.loadViewIfNeeded()
        let shelf = try #require(surface.debugShelf)
        surface.showLeadRow(.posts(posts.map(\.id)))
        #expect(shelf.isLoading, "no skeleton while the posts hydrate")
        await Self.settle { !shelf.cards.isEmpty }
        Self.expectLanded(shelf, of: 14)
    }
}
