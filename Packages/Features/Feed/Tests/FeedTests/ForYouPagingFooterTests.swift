import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The next-page spinner reserves a band below the content. Its whole
/// requirement is that opening and closing that band never moves the scroll,
/// which is exactly the sort of claim a screenshot cannot settle — the content
/// underneath changes at the same moment the band closes, so a pixel diff
/// cannot tell a jump from a page landing.
@MainActor
struct ForYouPagingFooterTests {
    /// The pages never load anything here; only geometry is under test.
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: SilentFetcher()) }

    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map {
            GalleryPost(
                id: PostID("p\($0)"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "", publishedAtMS: 0
            )
        }
    }

    /// Populated on purpose: an empty collection view has no scrollable height,
    /// so every `contentOffset` written to it clamps straight back to zero and
    /// the assertions below would pass without testing anything.
    private func page() -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: .grid)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.additionalBottomInset = 88
        page.render(.content(posts(40)))
        page.layoutIfNeeded()
        return page
    }

    private func scrollView(of page: ForYouGridPage) -> UIScrollView {
        page.subviews.compactMap { $0 as? UIScrollView }.first!
    }

    /// The band opens on top of the tray's clearance rather than replacing it —
    /// the tray's inset is exactly the height it floats over, so a spinner
    /// parked in it would sit behind the tray.
    @Test func pagingReservesABandOnTopOfTheTrayClearance() {
        let page = page()
        let scroll = scrollView(of: page)
        let resting = scroll.contentInset.bottom
        #expect(resting == 88)

        page.setPaging(true)
        #expect(scroll.contentInset.bottom > resting,
                "the footer band was not reserved")
        #expect(scroll.verticalScrollIndicatorInsets.bottom == scroll.contentInset.bottom)

        page.setPaging(false)
        // The inset animates back; drive it to completion.
        scroll.layoutIfNeeded()
        #expect(page.additionalBottomInset == 88, "the tray's own clearance was disturbed")
    }

    /// Reserving space below the content must not move what the viewer is
    /// looking at. Growing a scroll view's bottom inset never changes
    /// `contentOffset` — this pins that, because the obvious alternative
    /// (reserving the space by growing content) does move it.
    @Test func openingTheFooterDoesNotMoveTheScroll() {
        let page = page()
        let scroll = scrollView(of: page)
        #expect(scroll.contentSize.height > 1200, "not enough content to scroll")
        scroll.contentOffset = CGPoint(x: 0, y: 240)
        let before = scroll.contentOffset

        page.setPaging(true)
        #expect(scroll.contentOffset == before, "opening the footer moved the scroll")

        page.setPaging(false)
        #expect(scroll.contentOffset == before, "closing the footer moved the scroll")
    }

    /// Toggling to the state it is already in must not re-enter the animation
    /// or re-reserve the band — `onPagingChange` fires on every page load, and
    /// the pager forwards it to all three pages.
    @Test func repeatedTogglesAreIdempotent() {
        let page = page()
        let scroll = scrollView(of: page)

        page.setPaging(true)
        let reserved = scroll.contentInset.bottom
        page.setPaging(true)
        #expect(scroll.contentInset.bottom == reserved, "the band was reserved twice")

        page.setPaging(false)
        page.setPaging(false)
        page.setPaging(false)
        scroll.layoutIfNeeded()
        #expect(page.additionalBottomInset == 88)
    }

    /// A list page has no footer: it is a timeline, and pagination there is not
    /// this surface's concern.
    @Test func listPagesIgnorePaging() {
        let list = ForYouGridPage(imagePipeline: pipeline(), style: .list)
        list.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        list.additionalBottomInset = 88
        list.layoutIfNeeded()
        let scroll = list.subviews.compactMap { $0 as? UIScrollView }.first!

        list.setPaging(true)
        #expect(scroll.contentInset.bottom == 88, "a list page reserved a footer band")
    }
}
