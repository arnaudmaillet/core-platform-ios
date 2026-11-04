import CoreModels
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// ⚠️ A FAST FLING GLIDES THROUGH A PAGE LANDING (#2097). For You ends its
/// pages' refresh controls whenever a load settles, a next page included,
/// and UIKit's end wrote the list's offset — which stops a deceleration dead
/// (`_endRefreshingAnimated:` → `_stopScrollingNotify:`, the stack
/// `-scroll-stop-trace` caught on the simulator: a 5,000 pt/s fling cut at
/// the landing). A simulator can't fling in a unit test, so this pins the
/// two halves: the landing is an insert that leaves the offset where it is,
/// and the end the host then asks for never reaches UIKit's.
@MainActor
struct ForYouFlingThroughLandingTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = index % 3 == 2
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: isText ? .text : .photo,
                isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: index % 2 == 0 ? 9.0 / 16.0 : 1.5,
                caption: "post \(index)",
                publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 12, commentCount: 3
            )
        }
    }

    @Test func aPageLandingLeavesAMovingListAlone() throws {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .discover)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(corpus(20)))
        page.layoutIfNeeded()
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        list.layoutIfNeeded()
        let control = try #require(list.refreshControl as? AppRefreshControl)
        let offset = CGPoint(x: 0, y: min(1200, list.contentSize.height - list.bounds.height))
        list.contentOffset = offset

        page.render(.content(corpus(40)))
        page.endRefreshing()
        list.layoutIfNeeded()

        #expect(list.contentOffset == offset, "the landing moved the list")
        #expect(control.debugEndsPassedToUIKit == 0, "the load's end reached UIKit's, which stops a fling")
    }
}
