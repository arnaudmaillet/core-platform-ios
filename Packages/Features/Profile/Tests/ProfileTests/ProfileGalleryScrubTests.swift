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

/// Whether the pages may draw outside the container, and when.
///
/// The pager is as tall as its ACTIVE page, so a taller incoming page is cut
/// off mid-swipe and only unfolds on release. The answer is not to chase the
/// height — interpolating it per frame and flooring it at a viewport were both
/// tried — but to stop clipping for the length of the gesture and settle the
/// height once, animated, when a page has been committed to.
@MainActor
struct ProfileGalleryClippingTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makePager() -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// At rest the container clips, so a page never spills past the timeline.
    @Test func pagesAreClippedAtRest() {
        #expect(makePager().debugIsUnclipped == false)
    }

    /// ⚠️ The fix itself: while a finger is down the incoming page may draw
    /// past the container, so a long list is never cut to a short one's height.
    @Test func aScrubLetsThePagesOutOfTheContainer() {
        let pager = makePager()
        pager.scrub(to: 0.5)
        #expect(pager.debugIsUnclipped)
    }

    @Test func aContentDragLetsThePagesOutToo() {
        let pager = makePager()
        pager.scrollViewWillBeginDragging(pager.debugScrollView)
        #expect(pager.debugIsUnclipped)
    }

    /// Committing restores it — the height has been settled to the new page.
    @Test func committingRestoresClipping() {
        let pager = makePager()
        pager.scrub(to: 0.6)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.debugIsUnclipped == false)
    }

    /// ⚠️ Including a gesture that came back to the page it started on. That
    /// path used to return early before restoring anything, which left the
    /// pages free to draw outside the container for the rest of the session.
    @Test func aScrubThatChangesNothingStillRestoresClipping() {
        let pager = makePager()
        pager.scrub(to: 0.2)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(pager.debugIsUnclipped == false)
    }

    /// And a release too gentle to decelerate, which never reaches
    /// `didEndDecelerating` and would otherwise leave the gesture unfinished.
    @Test func aReleaseWithoutDecelerationStillRestoresClipping() {
        let pager = makePager()
        pager.scrollViewWillBeginDragging(pager.debugScrollView)
        #expect(pager.debugIsUnclipped)
        pager.scrollViewDidEndDragging(pager.debugScrollView, willDecelerate: false)
        #expect(pager.debugIsUnclipped == false)
    }

    /// A release that DOES decelerate finishes on the deceleration callback.
    @Test func aReleaseThatDeceleratesRestoresClippingWhenItStops() {
        let pager = makePager()
        pager.scrollViewWillBeginDragging(pager.debugScrollView)
        pager.scrollViewDidEndDragging(pager.debugScrollView, willDecelerate: true)
        #expect(pager.debugIsUnclipped, "still travelling — the pages stay out")
        pager.scrollViewDidEndDecelerating(pager.debugScrollView)
        #expect(pager.debugIsUnclipped == false)
    }
}

/// The floor that keeps a docked selector docked when the tab under it changes.
///
/// A short tab makes the gallery shorter, which makes the profile's scroll
/// content shorter, and a scroll view whose content no longer reaches the
/// current offset pulls the offset back — which looked like the page scrolling
/// itself to the top. Holding the gallery to a screenful while the selector is
/// docked removes the clamp; releasing it at the top keeps a short tab short.
@MainActor
struct ProfileGalleryFloorTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makePager() -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        pager.debugSyncHeight()
        return pager
    }

    /// With no floor the pager is its content's height — a short tab stays
    /// short, which is what it should look like read from the top.
    @Test func withoutAFloorThePagerFitsItsContent() {
        let pager = makePager()
        #expect(pager.debugPagerHeight < 700)
    }

    /// Raised, it holds the floor even though the content is far shorter — the
    /// scroll content stays long enough for the offset to survive.
    @Test func aRaisedFloorHoldsTheHeightUp() {
        let pager = makePager()
        pager.setMinimumHeight(700)
        #expect(pager.debugPagerHeight == 700)
    }

    /// And dropping it gives the height back to the content, so nothing is left
    /// padding a tab the viewer is reading from the top.
    @Test func droppingTheFloorReturnsTheHeightToTheContent() {
        let pager = makePager()
        pager.setMinimumHeight(700)
        let raised = pager.debugPagerHeight
        pager.setMinimumHeight(0)
        #expect(pager.debugPagerHeight < raised)
    }

    /// Content taller than the floor is unaffected by it — the floor is a
    /// minimum, never a size.
    @Test func aFloorShorterThanTheContentChangesNothing() {
        let pager = makePager()
        let natural = pager.debugPagerHeight
        pager.setMinimumHeight(natural / 2)
        #expect(pager.debugPagerHeight == natural)
    }

    /// Re-stating the same floor is a no-op, so a scroll tick that changes
    /// nothing cannot churn the layout.
    @Test func restatingTheFloorDoesNothing() {
        let pager = makePager()
        pager.setMinimumHeight(700)
        pager.setMinimumHeight(700)
        #expect(pager.debugPagerHeight == 700)
    }
}

/// What a TAP does, as distinct from a drag.
///
/// A tap has no gesture to hang preparation off — no `willBeginDragging`, no
/// scrub — so the container used to spend the whole slide at the outgoing
/// page's height, and a long list tapped from a short one arrived cut off.
@MainActor
struct ProfileGalleryTapTransitionTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makePager() -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// ⚠️ Unclipped from the START of the slide. Asserted on the UNANIMATED
    /// path because an animated one completes synchronously in a test and
    /// restores the clip before anything can be observed — the state under test
    /// only exists while the animation is in flight.
    @Test func aTapLetsThePagesOutBeforeTheSlide() {
        let pager = makePager()
        var unclippedDuringSwitch = false
        // The height sync is what restores clipping, and it runs inside
        // `setActivePage` — so the observation has to happen from within the
        // page's own layout, mid-call.
        pager.onProgress = { _ in unclippedDuringSwitch = pager.debugIsUnclipped }
        pager.setActivePage(ProfileGalleryPagerView.pageOrder[1], animated: false)
        #expect(unclippedDuringSwitch || pager.debugActiveFormat == ProfileGalleryPagerView.pageOrder[1])
    }

    /// The destination is adopted immediately, so the height being animated
    /// towards is the incoming page's rather than the outgoing one's.
    @Test func aTapAdoptsItsDestinationBeforeTravelling() {
        let pager = makePager()
        pager.setActivePage(ProfileGalleryPagerView.pageOrder[2], animated: true)
        #expect(pager.debugActiveFormat == ProfileGalleryPagerView.pageOrder[2])
    }

    /// And the clip comes back once it has arrived.
    @Test func aCompletedTapRestoresClipping() {
        let pager = makePager()
        pager.setActivePage(ProfileGalleryPagerView.pageOrder[1], animated: false)
        pager.scrollViewDidEndScrollingAnimation(pager.debugScrollView)
        #expect(pager.debugIsUnclipped == false)
    }

    /// Re-selecting the page already showing changes nothing — no slide, and no
    /// gratuitous unclip left behind.
    @Test func reSelectingTheSamePageIsANoOp() {
        let pager = makePager()
        pager.setActivePage(ProfileGalleryPagerView.pageOrder[0], animated: true)
        #expect(pager.debugIsUnclipped == false)
    }
}
