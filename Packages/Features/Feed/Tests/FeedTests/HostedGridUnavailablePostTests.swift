import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A grid hosted by another screen — a profile's gallery — never shows a post
/// the server withholds (#2048): not the ones already learnt when it is
/// handed its posts, and not one learnt while it is up.
@MainActor
struct HostedGridUnavailablePostTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("g\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/\(index).jpg"), aspectRatio: 1,
                caption: "caption \(index)", publishedAtMS: 0
            )
        }
    }

    private func page(withheld: UnavailablePosts) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid)
        page.withheldPosts = withheld
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        return page
    }

    @Test func aPostAlreadyKnownUnavailableIsNeverShown() {
        let withheld = UnavailablePosts()
        withheld.insert([PostID("g1")])
        let page = page(withheld: withheld)
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(page.posts.map(\.id.rawValue) == ["g0", "g2", "g3"])
    }

    @Test func aPostLearntUnavailableWhileUpLeaves() {
        let withheld = UnavailablePosts()
        let page = page(withheld: withheld)
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(page.posts.count == 4)

        withheld.insert([PostID("g2")])
        #expect(page.posts.map(\.id.rawValue) == ["g0", "g1", "g3"], "the tile stayed")

        // Another record's news is not this page's.
        UnavailablePosts().insert([PostID("g0")])
        #expect(page.posts.count == 3)
    }
}
