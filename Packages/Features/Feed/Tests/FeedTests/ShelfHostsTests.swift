import CoreStorage
import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// Every host of a shelf (#1296, the owner 2026-10-16): its title over
/// skeleton cards until its posts land, then ten cards a row at most — a row
/// ending on the chevron card that runs "View all" only when its list holds
/// more than it shows (#1671, the owner 2026-10-24).
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

    /// The landed shelf showing every post it has: no chevron card.
    private static func expectLandedWhole(_ shelf: PostShelfSection, of total: Int) {
        #expect(!shelf.isLoading, "the skeleton outlived the posts")
        #expect(shelf.rowCounts.media == total)
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == total,
                "a row showing all its posts ends on the chevron card")
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

    /// The hashtag's lead row: a few posts and nothing past them draw no
    /// chevron; told its list goes on, the row ends on it, and it pushes.
    @Test func theLeadRowEndsOnTheChevronOnlyWithMore() async throws {
        let posts = Self.posts(3, prefix: "r")
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        var pushed = 0
        surface.onLeadRowTitleTapped = { pushed += 1 }
        surface.loadViewIfNeeded()
        let shelf = try #require(surface.debugShelf)
        surface.showLeadRow(.posts(posts.map(\.id)), hasMore: false)
        await Self.settle { !shelf.cards.isEmpty }
        Self.expectLandedWhole(shelf, of: 3)

        surface.showLeadRow(.posts(posts.map(\.id)), hasMore: true)
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == 4, "a list that goes on drew no chevron")
        #expect(shelf.debugTapViewAll())
        #expect(pushed == 1, "the chevron did not push the destination")
    }
}
