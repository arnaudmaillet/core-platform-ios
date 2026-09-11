import Testing
import UIKit
@testable import DesignSystem

/// Where a scrub lands when the finger lets go.
///
/// The tab bar's selection pill can be picked up and dragged, which writes this
/// pager's offset directly, frame by frame — so the scroll view never
/// decelerates and its own settle callback never fires. This arithmetic is the
/// only thing that decides where the pages end up, and it is easy to get wrong
/// in ways a screenshot will not show: an off-by-one clamp only bites at the
/// ends, and a wrong throw only bites on a flick.
@MainActor
struct HorizontalPagerScrubTests {
    private func pager(pages: Int = 3, width: CGFloat = 400) -> HorizontalPagerView {
        let pager = HorizontalPagerView(pages: (0..<pages).map { _ in UIView() }, initialIndex: 0)
        pager.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// Released without a flick, past the halfway point: it commits forward.
    @Test func aSlowDragPastHalfwayCommits() {
        let pager = pager()
        pager.scrub(to: 0.6)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.activeIndex == 1)
    }

    /// Released without a flick, short of halfway: it falls back to where it
    /// came from. The pages still travel — from wherever the finger left them.
    @Test func aSlowDragShortOfHalfwayFallsBack() {
        let pager = pager()
        pager.scrub(to: 0.4)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.activeIndex == 0)
    }

    /// A flick commits even when the finger barely moved — half a page of throw
    /// per unit velocity.
    @Test func aFlickCommitsFromShortOfHalfway() {
        let pager = pager()
        pager.scrub(to: 0.2)
        pager.settleAfterScrub(velocityInPages: 2)
        #expect(pager.activeIndex == 1)
    }

    /// ⚠️ A hard flick at the last page has nowhere to go and must not land
    /// outside the pages — an unclamped landing indexes past the end.
    @Test func aFlickPastTheEndClampsToTheLastPage() {
        let pager = pager()
        pager.scrub(to: 2)
        pager.settleAfterScrub(velocityInPages: 8)
        #expect(pager.activeIndex == 2)
    }

    @Test func aFlickBeforeTheStartClampsToTheFirstPage() {
        let pager = pager()
        pager.scrub(to: 0)
        pager.settleAfterScrub(velocityInPages: -8)
        #expect(pager.activeIndex == 0)
    }

    /// Scrubbing past the ends is clamped too, so the finger cannot drag the
    /// pages into empty space beyond the first or last.
    @Test func scrubbingIsClampedToTheAvailablePages() {
        let pager = pager()
        pager.scrub(to: 9)
        #expect(pager.pagingScrollView.contentOffset.x == 800)
        pager.scrub(to: -4)
        #expect(pager.pagingScrollView.contentOffset.x == 0)
    }

    /// Every frame of the scrub reports progress, which is what carries the
    /// lens back to the bar that is driving it.
    @Test func aScrubReportsProgressLikeASwipe() {
        let pager = pager()
        var reported: [CGFloat] = []
        pager.onProgress = { reported.append($0) }
        for step in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) { pager.scrub(to: step) }
        #expect(reported.count >= 9)
        #expect(reported == reported.sorted())
    }

    /// ⚠️ **A released scrub NEVER leaves the pages between two tabs.** This is
    /// the whole complaint the settle exists to answer, so it is asserted across
    /// the release points that produce it rather than at one convenient value —
    /// including the ones a hair either side of the midpoint, where the rounding
    /// decides, and past both ends, where the clamp does.
    @Test(arguments: [CGFloat(0), 0.1, 0.49, 0.5, 0.51, 0.9, 1, 1.4, 1.6, 1.99, 2, 2.4, -0.6])
    func aReleasedScrubAlwaysLandsOnAPage(release: CGFloat) {
        let pager = pager()
        pager.scrub(to: release)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect((0...2).contains(pager.activeIndex))
        // The travel is animated, so the offset arrives later; the index is the
        // commitment, and it is made before the animation starts.
        #expect(CGFloat(pager.activeIndex) == (release.rounded()).clamped(to: 0...2))
    }

    /// ⚠️ **A release with nothing to travel still ANNOUNCES.** A drag let go
    /// past the last tab clamps to an offset the pages are already on, and the
    /// settle animation that normally carries the landing to `onSettled` has no
    /// distance to cover. Five of the six hosts commit their model from that
    /// callback, so this is the difference between the screen and its view model
    /// agreeing and not.
    @Test func aReleaseWithNothingToTravelStillAnnounces() {
        let pager = pager()
        var settled: [Int] = []
        pager.onSettled = { settled.append($0) }
        pager.scrub(to: 2)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(settled == [2])
    }

    /// ⚠️ **Why `settleAfterScrub` exists at all**, stated as the contrast: the
    /// call a host would reach for first CANNOT bring a scrubbed pager home. It
    /// returns early on an unchanged index, and the pages stay parked between
    /// two of them.
    ///
    /// Asserted on the OFFSET, because the index is unchanged in this case
    /// whatever happens — the version of this test that asserted `activeIndex
    /// == 0` after a fall-back was asserting a value that was already 0 before
    /// the call, and would have passed against a `settleAfterScrub` that did
    /// nothing whatsoever.
    @Test func theCallThatCannotBringAScrubHome() {
        let pager = pager()
        pager.scrub(to: 0.3)
        #expect(pager.pagingScrollView.contentOffset.x == 120)
        pager.setActivePage(0, animated: true)
        #expect(pager.pagingScrollView.contentOffset.x == 120, "setActivePage settled a scrub it should refuse")
    }

    /// ⚠️ **A flick never skips a page.** The bar measures velocity in pages per
    /// second against a SEGMENT's width, which is about a quarter of a page of
    /// travel — so an ordinary flick across one tab reports six or seven pages a
    /// second, and an unclamped throw hands it three.
    @Test(arguments: [CGFloat(4), 8, 20, 100])
    func aHardFlickStillAdvancesOnlyOnePage(velocity: CGFloat) {
        let pager = pager(pages: 5)
        pager.scrub(to: 1)
        pager.settleAfterScrub(velocityInPages: velocity)
        #expect(pager.activeIndex == 2)
    }

    @Test(arguments: [CGFloat(-4), -8, -20, -100])
    func aHardFlickBackwardsAlsoAdvancesOnlyOnePage(velocity: CGFloat) {
        let pager = pager(pages: 5)
        pager.scrub(to: 3)
        pager.settleAfterScrub(velocityInPages: velocity)
        #expect(pager.activeIndex == 2)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
