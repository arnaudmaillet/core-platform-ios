import CoreModels
import CoreStorage
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

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

    private func page(withheld: UnavailablePosts) -> PostGridPageView {
        let page = PostGridPageView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid,
        bookmarks: PostBookmarkStore(scope: StorageScope()),
        withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents()))
        page.withheldPosts = withheld
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        return page
    }

    @Test func aPostAlreadyKnownUnavailableIsNeverShown() {
        let withheld = UnavailablePosts(viewerEvents: ViewerEvents())
        withheld.insert([PostID("g1")])
        let page = page(withheld: withheld)
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(page.posts.map(\.id.rawValue) == ["g0", "g2", "g3"])
    }

    @Test func aPostLearntUnavailableWhileUpLeaves() {
        let withheld = UnavailablePosts(viewerEvents: ViewerEvents())
        let page = page(withheld: withheld)
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(page.posts.count == 4)

        withheld.insert([PostID("g2")])
        #expect(page.posts.map(\.id.rawValue) == ["g0", "g1", "g3"], "the tile stayed")

        // Another record's news is not this page's.
        UnavailablePosts(viewerEvents: ViewerEvents()).insert([PostID("g0")])
        #expect(page.posts.count == 3)
    }

    /// ⚠️ FOR THIS VIEWER ONLY (#2376): a viewer change on the app's channel
    /// forgets every post learnt, at once — a post withheld from a guest may
    /// be the member's to see.
    @Test func aViewerChangeForgetsThePostsLearnt() {
        let viewerEvents = ViewerEvents()
        let withheld = UnavailablePosts(viewerEvents: viewerEvents)
        withheld.insert([PostID("g1"), PostID("g2")])
        #expect(withheld.contains(PostID("g1")))

        viewerEvents.publishViewerChange()

        #expect(!withheld.contains(PostID("g1")) && !withheld.contains(PostID("g2")))
        // Another channel's viewer is not this record's.
        withheld.insert([PostID("g3")])
        ViewerEvents().publishViewerChange()
        #expect(withheld.contains(PostID("g3")))
    }

    /// The page hears the record it holds: handed another one, it stops
    /// hearing the first and hears that one.
    @Test func thePageHearsTheRecordItHolds() {
        let first = UnavailablePosts(viewerEvents: ViewerEvents())
        let second = UnavailablePosts(viewerEvents: ViewerEvents())
        let page = page(withheld: first)
        page.show(.content(posts(4)))
        page.layoutIfNeeded()
        #expect(first.debugObservationCount == 1, "guard: a shown page hears its record")

        page.withheldPosts = second

        #expect(first.debugObservationCount == 0)
        #expect(second.debugObservationCount == 1)
        first.insert([PostID("g0")])
        #expect(page.posts.count == 4, "the page heard the record it no longer holds")
        second.insert([PostID("g1")])
        #expect(page.posts.map(\.id.rawValue) == ["g0", "g2", "g3"])
    }
}
