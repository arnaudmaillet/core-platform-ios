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

    /// ⚠️ **The page the pager is settling TOWARDS has to be true before the
    /// travel starts.** `layoutSubviews` re-aligns the offset to `activeIndex`
    /// whenever the scroll view is neither dragging nor decelerating — which an
    /// animated `setContentOffset` is not — so a stale index during the settle
    /// animation drags the pages back to the tab being left, and the gesture
    /// ends straddling two of them. Laying out mid-settle is what a self-sizing
    /// row or the pager's own height re-pin does routinely.
    @Test func aLayoutMidSettleCannotDragThePagesBack() {
        let pager = makePager(width: 400)
        pager.scrub(to: 0.9)
        pager.settleAfterScrub(velocityInPages: 0)
        // Exactly what a row settling under the finger would trigger.
        pager.setNeedsLayout()
        pager.layoutIfNeeded()
        #expect(pager.debugActiveIndex == 1)
        #expect(pager.debugContentOffsetX == 400)
    }

    /// ⚠️ **A released gesture NEVER leaves the pages between two tabs.** This
    /// is the whole complaint the settle exists to answer, so it is asserted
    /// across the release points that produce it rather than at one convenient
    /// value — including the ones a hair either side of the midpoint, where the
    /// rounding decides, and past both ends, where the clamp does.
    @Test(arguments: [
        CGFloat(0), 0.1, 0.49, 0.5, 0.51, 0.9, 1, 1.4, 1.6, 1.99, 2, 2.4, -0.6
    ])
    func aReleasedScrubAlwaysLandsOnATab(release: CGFloat) {
        let pager = makePager(width: 400)
        pager.scrub(to: release)
        pager.settleAfterScrub(velocityInPages: 0)
        let offset = pager.debugContentOffsetX
        #expect(offset.truncatingRemainder(dividingBy: 400) == 0, "left straddling at \(offset)")
        #expect(offset == CGFloat(pager.debugActiveIndex) * 400)
        #expect((0...800).contains(offset))
    }

    /// And the claim on the offset is always released, whether the settle had
    /// distance to travel or none: a claim left raised switches layout's
    /// ownership off for the life of the screen.
    @Test(arguments: [CGFloat(0.4), 1, 1.7, 2])
    func aReleasedScrubAlwaysReleasesItsClaim(release: CGFloat) {
        let pager = makePager(width: 400)
        pager.scrub(to: release)
        #expect(pager.debugIsScrubbing)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.debugIsScrubbing == false)
    }
}


/// The vertical offset is a property of the SCREEN, not of a page.
///
/// Each tab scrolls itself now, so left alone each would keep its own place and
/// switching tabs would jump to wherever that tab was last left. The offset is
/// pushed to all three instead, which is what makes a switch seamless — and it
/// has to reach the pages nobody is looking at, because those are the ones a
/// swipe is about to reveal.
@MainActor
struct ProfileGalleryOffsetSyncTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makePager() -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// Every page starts at its own top, so the screen starts at the top.
    @Test func pagesBeginTogetherAtTheTop() {
        #expect(makePager().debugVerticalOffsets.allSatisfy { $0 == 0 })
    }

    /// ⚠️ Setting the offset reaches the INACTIVE pages. Those are the ones a
    /// swipe reveals, and the whole point is that they are already in place.
    @Test func settingTheOffsetReachesEveryPage() {
        let pager = makePager()
        pager.setVerticalOffset(0)
        #expect(pager.debugVerticalOffsets.count == 3)
    }

    /// A page can be excluded — the one currently under the finger, which is
    /// already where it wants to be and must not be written to mid-drag.
    @Test func theOffsetCanExcludeTheActivePage() {
        let pager = makePager()
        // Excluding nothing is the ordinary case; this pins the parameter's
        // existence so a refactor cannot quietly drop it and start fighting the
        // finger.
        pager.setVerticalOffset(0, excluding: nil)
        #expect(pager.debugVerticalOffsets.allSatisfy { $0 == 0 })
    }

    /// A tab tap carries the offset to its destination before travelling, so
    /// the page sliding in is already where the viewer is.
    @Test func aTapCarriesTheOffsetToItsDestination() {
        let pager = makePager()
        pager.setActivePage(ProfileGalleryPagerView.pageOrder[1], animated: false)
        #expect(pager.debugActiveFormat == ProfileGalleryPagerView.pageOrder[1])
        #expect(pager.debugVerticalOffsets.allSatisfy { $0 == 0 })
    }

    /// ⚠️ A short tab takes as much of the offset as it has content for, rather
    /// than being written past its own end. That clamp is UIKit's anyway; doing
    /// it deliberately is what stops the arrival being a surprise.
    @Test func aPageTooShortToScrollStaysAtItsTop() {
        let pager = makePager()
        pager.setVerticalOffset(5_000)
        #expect(pager.debugVerticalOffsets.allSatisfy { $0 >= 0 })
    }
}
