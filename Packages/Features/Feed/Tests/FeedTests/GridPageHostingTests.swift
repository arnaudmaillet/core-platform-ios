import CoreModels
import CoreStorage
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// What `ForYouGridPage` gained to host the profile's pages (#1273, PR A):
/// snap detents, an animated offset, a status under a hosted header, counts
/// updated in place, one near-end ask per content length, injectable
/// bookmarks and one close window for every host. All of it is off — or
/// unchanged — for a host that does not ask.
@MainActor
struct GridPageHostingTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func posts(
        _ count: Int, kind: GalleryPost.Kind = .photo, likes: Int64 = 10, caption: String = "post"
    ) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: kind, isRepost: false,
                thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "\(caption) \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: likes, commentCount: 2
            )
        }
    }

    private func page(
        style: ForYouGridPage.Style, posts: [GalleryPost], height: CGFloat = 874,
        bookmarks: PostBookmarkStore? = .shared
    ) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style, bookmarks: bookmarks
        )
        page.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        return page
    }

    // MARK: - Detents

    /// A release heading just past a detent lands on it; with no detents the
    /// target is left alone.
    @Test func aReleaseIsDrawnOntoTheNearestDetent() {
        let page = page(style: .grid, posts: posts(40))
        var target = CGPoint(x: 0, y: 130 - page.collectionView.adjustedContentInset.top)
        page.scrollViewWillEndDragging(page.collectionView, withVelocity: CGPoint(x: 0, y: 1),
                                       targetContentOffset: &target)
        #expect(abs(target.y - (130 - page.collectionView.adjustedContentInset.top)) < 0.5, "free without detents")

        page.snapDetents = [0, 120]
        page.scrollViewWillEndDragging(page.collectionView, withVelocity: CGPoint(x: 0, y: 1),
                                       targetContentOffset: &target)
        #expect(abs(target.y + page.collectionView.adjustedContentInset.top - 120) < 0.5)
    }

    // MARK: - Status under a hosted header

    /// Hosted, the status sits in the room under the header — never behind
    /// it — and the empty page offers no travel.
    @Test func aHostedStatusSitsUnderTheHeader() throws {
        let page = page(style: .discover, posts: [])
        page.setHostedInsets(top: 400, bottom: 34)
        page.setMinimumScrollTravel(300)
        page.render(.empty(.init(title: "Nothing yet", subtitle: "Posts appear here")))
        page.layoutIfNeeded()
        let frame = try #require(page.debugStatusFrame)
        #expect(frame.minY >= 400 - 0.5, "the status went behind the header: \(frame)")
        #expect(frame.maxY <= 874 - 34 + 0.5)
        #expect(page.debugOfferedTravel == 0, "an empty page offered travel")

        page.render(.content(posts(30)))
        #expect(page.debugStatusFrame == nil)
        #expect(page.debugOfferedTravel == 300)
    }

    /// A host's own words show as the status.
    @Test func aHostShowsItsOwnStatus() throws {
        let page = page(style: .grid, posts: posts(3))
        page.showStatus(symbolName: "lock", title: "This account is private")
        #expect(page.debugStatusFrame != nil)
        #expect(page.posts.isEmpty)
    }

    /// ⚠️ A HEADER THAT GROWS DURING A FLIGHT (#1656): the inset pinned for
    /// the flight is not what the thaw puts back — the hosted top set while
    /// pinned is — so a page at rest comes back at rest, not pulled down by
    /// the difference (a place page staged off a window, then shown).
    @Test func aHostedTopSetDuringAFreezeSurvivesTheThaw() {
        let page = page(style: .discover, posts: posts(30))
        page.setHostedInsets(top: 232, bottom: 34)
        page.restAtTop()
        page.beginHeroFreeze()
        page.setHostedInsets(top: 348, bottom: 34)
        page.endHeroFreeze()
        #expect(abs(page.verticalOffset) < 0.5, "the thaw left the page pulled by \(page.verticalOffset)")
        #expect(page.collectionView.contentInset.top == 348)
    }

    // MARK: - Counts in place

    /// The same posts with new counts re-dress nothing: the visible cells take
    /// the numbers in place, and the model carries them.
    @Test(arguments: [ForYouGridPage.Style.grid, .list, .discover])
    func newCountsAreWrittenInPlace(style: ForYouGridPage.Style) throws {
        let before = posts(12, likes: 10)
        let page = page(style: style, posts: before)
        let after = posts(12, likes: 99)
        page.render(.content(after))
        #expect(page.posts.allSatisfy { $0.reactionCount == 99 })
        #expect(page.debugRecountedItems + page.debugReconfiguredItems == 12)
        #expect(page.debugRecountedItems > 0, "no visible cell took its count in place")
    }

    @Test func aRealChangeIsNotACountsOnlyChange() {
        #expect(ForYouGridPage.differOnlyInCounts(posts(1, likes: 1)[0], posts(1, likes: 5)[0]))
        #expect(!ForYouGridPage.differOnlyInCounts(posts(1)[0], posts(1, caption: "changed")[0]))
    }

    // MARK: - Near end

    /// From a scroll, the next page is asked for once per content length.
    @Test func theNextPageIsAskedOncePerContentLength() {
        let page = page(style: .grid, posts: posts(60))
        var asks = 0
        page.onNearEnd = { asks += 1 }
        let bottom = page.collectionView.contentSize.height - page.collectionView.bounds.height
        page.collectionView.contentOffset.y = bottom
        page.scrollViewDidScroll(page.collectionView)
        page.scrollViewDidScroll(page.collectionView)
        page.scrollViewDidScroll(page.collectionView)
        #expect(asks == 1, "asked \(asks) times: never, or at every scroll tick")
    }

    // MARK: - Bookmarks

    /// A host with no saved pile draws no save control.
    @Test func noBookmarksNoSaveControl() throws {
        let page = page(style: .list, posts: posts(4), bookmarks: nil)
        let row = try #require(page.debugCell(for: PostID("p0")) as? PostGridListRowCell)
        #expect(row.onBookmarkTapped == nil)
        let saving = self.page(style: .list, posts: posts(4))
        let savingRow = try #require(saving.debugCell(for: PostID("p0")) as? PostGridListRowCell)
        #expect(savingRow.onBookmarkTapped != nil)
    }

    // MARK: - One close window

    /// A row's window aligns caption on caption only when asked; a tile's is
    /// the tile's own window.
    @Test func theCloseWindowFollowsTheHostsAlignment() throws {
        let page = page(style: .list, posts: posts(4, kind: .text))
        let post = try #require(page.posts.first)
        let aligned = try #require(page.closeWindow(
            for: post, alignsPageToSource: true, willStageDismissal: {}, dismissalDidEnd: { _ in }
        ))
        #expect(aligned.alignsPageToSource)
        let still = try #require(page.closeWindow(
            for: post, alignsPageToSource: false, willStageDismissal: {}, dismissalDidEnd: { _ in }
        ))
        #expect(!still.alignsPageToSource)
        #expect(still.captionEnd == nil && still.authorBand == nil)
    }
}
