import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// THE PAGER MUST NOT DISAGREE WITH THE SCROLL VIEW ABOUT WHICH PAGE IS ON.
///
/// Two indices track the active page: `activeIndex` (which page is live, and
/// therefore the only one allowed to autoplay) and `reportedIndex` (the last
/// page announced through `onPageSettled`). They are separate for a good
/// reason — a tab tap sets the target immediately and arrives a beat later — and
/// they used to be able to drift apart at exactly one moment.
///
/// `viewDidLoad` restores the persisted format before first layout. With no
/// width there is no offset to move, so `setActivePage` returned early having
/// moved `activeIndex` and not `reportedIndex`. From then on a settle back onto
/// the ORIGINAL page matched the stale `reportedIndex`, was dismissed as "no
/// change", and skipped both `syncAutoplay` and `onPageSettled` — leaving the
/// page the viewer was looking at marked inactive, so it never autoplayed, and
/// the view model's format wrong, which also gates pagination.
///
/// Only reachable when the restored format is NOT the pager's FIRST page:
/// restoring that one returns at the `index != activeIndex` guard and moves
/// neither index. That is why the default path looked fine while Discover
/// led — and why these tests speak in `pageOrder` rather than in formats:
/// since Following moved to the left (2026-09-28) the DEFAULT restore
/// (Discover) is the one that takes the early return.
@MainActor
struct ForYouPagerActivePageTests {
    private func pager() -> ForYouPagerView {
        ForYouPagerView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
    }

    /// Drives a real settle: lay the pager out, scroll to `index`, and end
    /// deceleration the way a finger does.
    private func swipe(_ pager: ForYouPagerView, to index: Int) {
        pager.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        pager.layoutIfNeeded()
        guard let scrollView = pager.subviews.compactMap({ $0 as? UIScrollView }).first else {
            Issue.record("the pager has no scroll view to drive")
            return
        }
        scrollView.contentOffset = CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0)
        pager.scrollViewDidEndDecelerating(scrollView)
    }

    /// The regression. Restore the second page before layout, then swipe back
    /// to the first: the settle must be seen, not swallowed.
    @Test func aSwipeBackToTheFirstPageIsReportedAfterRestoringAnother() {
        let pager = pager()
        var settled: [GalleryFilter.Format] = []
        pager.onPageSettled = { settled.append($0) }

        // `viewDidLoad`: no layout has happened yet.
        #expect(pager.bounds.width == 0, "the premise is a pre-layout restore")
        pager.setActivePage(ForYouPagerView.pageOrder[1], animated: false)

        swipe(pager, to: 0)

        #expect(settled == [ForYouPagerView.pageOrder[0]],
                "the page the viewer landed on was never reported — autoplay and the format stay on the other page")
    }

    /// The same trip in the other direction still reports exactly once, so the
    /// fix cannot have been "report everything".
    @Test func aSettleOnThePageAlreadyActiveIsNotReportedTwice() {
        let pager = pager()
        var settled: [GalleryFilter.Format] = []
        pager.onPageSettled = { settled.append($0) }

        pager.setActivePage(ForYouPagerView.pageOrder[1], animated: false)
        swipe(pager, to: 1)   // land where the restore already put us
        swipe(pager, to: 1)   // and settle there again

        #expect(settled.isEmpty,
                "settling on the page already active is a no-op, not a repeat announcement")
    }

    /// A restore — the default one included, which is Discover and no longer
    /// the first page — must not announce a page change nobody made: every
    /// launch goes through it.
    @Test func restoringAFormatBeforeLayoutAnnouncesNothing() {
        for format in ForYouPagerView.pageOrder {
            let pager = pager()
            var settled: [GalleryFilter.Format] = []
            pager.onPageSettled = { settled.append($0) }

            pager.setActivePage(format, animated: false)

            #expect(settled.isEmpty, "restoring \(format) was announced")
        }
    }

    /// And the default restore lands where the screen opens: a settle on
    /// Discover right after it is the page already active, not news.
    @Test func theDefaultRestoreIsThePageTheFirstSettleFinds() {
        let pager = pager()
        var settled: [GalleryFilter.Format] = []
        pager.onPageSettled = { settled.append($0) }

        pager.setActivePage(ForYouViewModel.defaultFormat, animated: false)
        let index = ForYouPagerView.pageOrder.firstIndex(of: ForYouViewModel.defaultFormat) ?? 0
        swipe(pager, to: index)

        #expect(settled.isEmpty)
    }
}
