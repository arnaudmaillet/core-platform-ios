import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// Where a scrub lands when the finger lets go.
///
/// The selector's capsule can be grabbed and dragged, which writes the pager's
/// offset directly, frame by frame — so the scroll view never decelerates and
/// its own settle callback never fires. This arithmetic is the only thing that
/// decides where the pages end up, and it is easy to get wrong in ways a
/// screenshot will not show: an off-by-one clamp only bites at the ends, and a
/// wrong throw only bites on a flick.
@MainActor
struct ProfileGalleryScrubTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A pager with real bounds, so offsets and page widths are meaningful.
    private func makePager(width: CGFloat = 400) -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        pager.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// Released without a flick, past the halfway point: it commits forward.
    @Test func aSlowDragPastHalfwayCommits() {
        let pager = makePager()
        pager.scrub(to: 0.6)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.debugActiveIndex == 1)
    }

    /// Released without a flick, short of halfway: it falls back to where it
    /// came from. The pages still travel — from wherever the finger left them.
    @Test func aSlowDragShortOfHalfwayFallsBack() {
        let pager = makePager()
        pager.scrub(to: 0.4)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.debugActiveIndex == 0)
    }

    /// A flick commits even when the finger barely moved — half a page of
    /// throw per unit velocity.
    @Test func aFlickCommitsFromShortOfHalfway() {
        let pager = makePager()
        pager.scrub(to: 0.2)
        pager.settleAfterScrub(velocityInPages: 2)
        #expect(pager.debugActiveIndex == 1)
    }

    /// ⚠️ A hard flick at the last page has nowhere to go and must not land
    /// outside the pages — an unclamped landing indexes past the end.
    @Test func aFlickPastTheEndClampsToTheLastPage() {
        let pager = makePager()
        pager.scrub(to: 2)
        pager.settleAfterScrub(velocityInPages: 8)
        #expect(pager.debugActiveIndex == 2)
    }

    @Test func aFlickBeforeTheStartClampsToTheFirstPage() {
        let pager = makePager()
        pager.scrub(to: 0)
        pager.settleAfterScrub(velocityInPages: -8)
        #expect(pager.debugActiveIndex == 0)
    }

    /// Scrubbing past the ends is clamped too, so the finger cannot drag the
    /// pages into empty space beyond the first or last.
    @Test func scrubbingIsClampedToTheAvailablePages() {
        let pager = makePager(width: 400)
        pager.scrub(to: 9)
        #expect(pager.debugContentOffsetX == 800)
        pager.scrub(to: -4)
        #expect(pager.debugContentOffsetX == 0)
    }

    /// The selector is told, so a scrub that changes the page updates the
    /// bar and the view model exactly as a swipe does.
    @Test func committingToANewPageReportsIt() {
        let pager = makePager()
        var settled: [GalleryFilter.Format] = []
        pager.onPageSettled = { settled.append($0) }
        pager.scrub(to: 1.7)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(settled == [ProfileGalleryPagerView.pageOrder[2]])
    }

    /// A scrub that returns to the page it started on is not a page change, so
    /// it announces nothing — the bar and the view model already agree.
    @Test func fallingBackToTheSamePageReportsNothing() {
        let pager = makePager()
        var settled: [GalleryFilter.Format] = []
        pager.onPageSettled = { settled.append($0) }
        pager.scrub(to: 0.3)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(settled.isEmpty)
    }
}
