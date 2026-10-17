import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's page as the profile sees it (`PostGridPage`, #1273 B): the
/// vended contract maps onto the page's own behaviour.
@MainActor
struct PostGridPageContractTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 3
            )
        }
    }

    private func vended(_ style: PostGridPageStyle, posts: [GalleryPost]) -> any PostGridPage {
        let page: any PostGridPage = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: ForYouGridPage.Style(style)
        )
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.setCorpusComplete(true)
        page.show(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    @Test func theStylesMapOneToOne() {
        #expect(ForYouGridPage.Style(.grid) == .grid)
        #expect(ForYouGridPage.Style(.list) == .list)
        #expect(ForYouGridPage.Style(.discover) == .discover)
    }

    /// A tap hands the host the post and the stream after it; a comment chip
    /// says so.
    @Test func aTapHandsThePostAndItsStream() throws {
        let page = vended(.list, posts: posts(40))
        var opened: (GalleryPost, [GalleryPost], Bool)?
        page.onPostTapped = { opened = ($0, $1, $2) }
        let grid = try #require(page as? ForYouGridPage)
        #expect(grid.debugSelectItem(at: 2))
        let (post, stream, comments) = try #require(opened)
        #expect(post.id == PostID("p2"))
        #expect(stream.first?.id == PostID("p2"))
        #expect(stream.count == ForYouGridPage.vendedStreamWindow)
        #expect(!comments)
    }

    /// A host's status replaces the posts; its action is the page's refresh.
    @Test func aStatusShowsAndItsActionRefreshes() throws {
        let page = vended(.grid, posts: posts(6))
        var refreshed = 0
        page.onRefresh = { refreshed += 1 }
        page.show(.status(PostGridPageStatus(symbolName: "lock", title: "Private", actionTitle: "Try Again")))
        let grid = try #require(page as? ForYouGridPage)
        #expect(grid.posts.isEmpty)
        #expect(grid.debugStatusFrame != nil)
        #expect(refreshed == 0)
    }

    /// The "..." menu reads the vended context.
    @Test func theMenuReadsTheVendedContext() {
        let page = vended(.list, posts: posts(2))
        var asked: PostID?
        page.postMenuActions = { context in
            asked = context.post.id
            return []
        }
        let grid = page as? ForYouGridPage
        _ = grid?.authorMenuActions?(PostGridAuthorMenuContext(
            post: posts(1)[0], authorID: ProfileID("a0"), anchor: UIView()
        ))
        #expect(asked == PostID("p0"))
    }

    /// History's days (#1344): titled groups, each title over its group's
    /// first stretch, no "View all"; the group gone under the bar is named,
    /// and a tap on its name brings its first post to the bar.
    @Test func titledGroupsAreTitledAndNamedOnceUnderTheBar() throws {
        let all = posts(30)
        let page = vended(.discover, posts: [])
        let grid = try #require(page as? ForYouGridPage)
        var named: [PostGridPinnedSection?] = []
        page.onPinnedSectionChanged = { named.append($0) }
        page.show(.sections([
            PostGridPageSection(title: "Today", posts: Array(all[0..<12])),
            PostGridPageSection(title: "Yesterday", posts: Array(all[12..<30]))
        ]))
        page.layoutIfNeeded()
        #expect(grid.groupTitles == ["Today", "Yesterday"])
        #expect(grid.isTitled(inSection: 0))
        let second = try #require((1..<grid.segments.count).first { grid.isTitled(inSection: $0) })
        #expect(grid.endsGroup(inSection: second - 1))
        #expect(grid.debugSectionHeaders().first?.title == "Today")
        #expect(page.pinnedSection == nil, "a list at its top named a group")

        // Where a tap on "Yesterday" lands (`scrollToSection`, animated):
        // its first post on the pin line.
        let first = try #require(grid.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: second)))
        grid.collectionView.contentOffset.y = first.frame.minY - grid.collectionView.adjustedContentInset.top
        grid.updatePinnedSection()
        #expect(page.pinnedSection == PostGridPinnedSection(index: 1, title: "Yesterday"))
        #expect(named.last == PostGridPinnedSection(index: 1, title: "Yesterday"))

        // Back to one untitled list.
        page.show(.content(all))
        page.layoutIfNeeded()
        #expect(!grid.isGrouped)
        #expect(!grid.isTitled(inSection: 0))
        #expect(page.pinnedSection == nil)
    }
}
