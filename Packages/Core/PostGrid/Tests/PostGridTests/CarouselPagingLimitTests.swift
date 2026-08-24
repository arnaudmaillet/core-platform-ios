import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// One gesture moves one page, and the dots stay small until touched.
@MainActor
struct CarouselPagingLimitTests {
    private func carousel(pages count: Int) -> MediaCarouselView {
        let view = MediaCarouselView(
            style: .card, frame: CGRect(x: 0, y: 0, width: 358, height: 240)
        )
        view.configure(
            with: (0..<count).map {
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"))
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    /// ⚠️ MOMENTUM DECIDES HOW FAST, NEVER HOW FAR.
    ///
    /// The snap read the PROJECTED offset, which on a hard flick is three or
    /// four pages away — a scroll, not paging. The viewer asked for the next
    /// photograph and got a blur and a stranger. A violent swipe and a careful
    /// one must land on the same page.
    @Test func aViolentFlickStillMovesOnlyOnePage() {
        let view = carousel(pages: 12)
        view.setPage(4, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 4), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 11), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: 9, y: 0), targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 5))
    }

    /// And the same in the other direction, asserted beside it: a rule applied
    /// to one sign only is half a rule.
    @Test func aViolentFlickBackwardsAlsoMovesOnlyOnePage() {
        let view = carousel(pages: 12)
        view.setPage(6, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 6), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 0), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: -9, y: 0), targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 5))
    }

    /// A gentle drag that lands short still settles where it was let go, so the
    /// clamp has not turned every gesture into a page change.
    @Test func aDragThatGoesNowhereStaysPut() {
        let view = carousel(pages: 12)
        view.setPage(4, animated: false)
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: view.debugOffset(forPage: 4), y: 0)

        var target = CGPoint(x: view.debugOffset(forPage: 4), y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: .zero, targetContentOffset: $0
            )
        }

        #expect(target.x == view.debugOffset(forPage: 4))
    }

    // MARK: - The dots

    /// ⚠️ FOUR AT REST, however many pages there are.
    ///
    /// Twelve dots on a card is a smudge — legible as "many", useless as
    /// "where" — and it crowds the counters beside it for information nobody
    /// reads at rest. The rest exist and are one touch away.
    @Test func aLongGalleryRestsOnFourDots() {
        let dots = PageDotsView()
        dots.configure(count: 12)

        #expect(dots.intrinsicContentSize.width
                == PageDotsView.width(forDots: PageDotsView.maximumRestingDots))
    }

    @Test func touchingItAsksForAllOfThem() {
        let dots = PageDotsView()
        dots.configure(count: 12)
        dots.isExpanded = true

        #expect(dots.intrinsicContentSize.width == PageDotsView.width(forDots: 12))
    }

    /// A gallery under the cap asks for exactly what it has — the cap must not
    /// pad a short run out to four.
    @Test func aShortGalleryAsksForItsOwnDots() {
        let dots = PageDotsView()
        dots.configure(count: 3)

        #expect(dots.intrinsicContentSize.width == PageDotsView.width(forDots: 3))
    }
}
