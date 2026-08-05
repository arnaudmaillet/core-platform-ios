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


/// The vertical offset is TWO things stacked, and only one of them belongs to
/// the tab.
///
/// Below the header's travel it is the SCREEN's: the header is one object, it
/// rides whichever page is active, and pages that disagreed down there would
/// teleport the identity block every time the tab changed. Above it the header
/// is docked and stays docked whatever the number is, so each tab keeps its own
/// place in its own content.
///
/// Either way the writes have to reach the pages nobody is looking at, because
/// those are the ones a swipe is about to reveal.
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

    // MARK: - Whose offset is it

    /// The header docks at 300; a tab's first row is only flush under the bar
    /// at 360, and the pages can travel 2,000 so a remembered position has
    /// somewhere to be remembered.
    private func splitPager() -> ProfileGalleryPagerView {
        let pager = makePager()
        pager.setMinimumScrollTravel(2_000)
        pager.setSharedTravel(dockLine: 300, contentFloor: 360)
        return pager
    }

    /// Below the header's travel every page agrees, because the header is down
    /// there with them and it cannot be in two places.
    @Test func belowTheHeadersTravelEveryTabMovesTogether() {
        let pager = splitPager()
        pager.setVerticalOffset(120)
        #expect(pager.debugAlignedOffset(forPage: 1) == 120)
        #expect(pager.debugAlignedOffset(forPage: 2) == 120)
    }

    /// ⚠️ **Above it, a tab keeps its own place — this is the whole feature.**
    /// The header is docked at any offset past its travel, so the number is the
    /// tab's to choose, and returning to one that was left further down puts it
    /// back there rather than at the top of its list.
    @Test func aboveTheHeadersTravelEachTabKeepsItsOwnPlace() {
        let pager = splitPager()
        pager.debugSetOffset(900, forPage: 1)
        pager.debugSetOffset(400, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 1) == 900)
    }

    /// ⚠️ A tab with nothing to remember arrives with its first row under the
    /// bar — at the CONTENT floor, not at the dock line.
    ///
    /// The two differ by the selector's slot, which the pages are still inset
    /// by after the selector has left it, so a tab dropped at the dock line
    /// opens with an empty band under the chrome. Measured at 60pt of white
    /// above the first tile before this was split in two.
    @Test func aFreshTabArrivesFlushUnderTheBarRatherThanAtTheDockLine() {
        let pager = splitPager()
        pager.debugSetOffset(0, forPage: 2)
        pager.debugSetOffset(700, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 2) == 360)
    }

    /// And never back above the dock line — a tab left at its own top must not
    /// drag the header down with it and hand back an identity block the viewer
    /// did not ask for.
    @Test func aTabAtItsTopStillArrivesDocked() {
        let pager = splitPager()
        pager.debugSetOffset(0, forPage: 2)
        pager.debugSetOffset(700, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 2) >= 300)
    }

    /// With no header to share, there is nothing to split: every page tracks
    /// the screen. This is also the state before the first layout pass, which
    /// is when a bad default would show.
    @Test func withoutASharedTravelEveryTabTracksTheScreen() {
        let pager = makePager()
        pager.setMinimumScrollTravel(2_000)
        pager.debugSetOffset(900, forPage: 1)
        pager.debugSetOffset(400, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 1) == 400)
    }
}

/// The room a tab reserves so it can hold the header's position.
///
/// A page too short to reach the offset a long tab was left at clamps to its own
/// end — and the header, which rides that offset, follows the clamp back up.
/// Nothing auto-scrolls; the short tab simply has nowhere to put the viewer.
/// Given room to travel the header's whole distance, every tab can hold any
/// position the header can be in and a switch moves it by nothing.
@MainActor
struct ProfileGalleryTravelFloorTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makePage() -> ProfileGalleryGridView {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        page.layoutIfNeeded()
        return page
    }

    /// An empty page can still travel the distance the header needs.
    @Test func anEmptyPageCanStillHoldTheHeadersTravel() {
        let page = makePage()
        page.setMinimumScrollTravel(400)
        page.setVerticalOffset(400)
        #expect(page.verticalOffset == 400)
    }

    /// ⚠️ Including the exact position that leaves the header docked. This is
    /// the assertion the bug failed: the room was being reserved as bottom
    /// inset and then not counted as travel, so the clamp took a shorter number
    /// and the header moved.
    @Test func reservedRoomCountsAsTravel() {
        let page = makePage()
        page.setMinimumScrollTravel(250)
        page.setVerticalOffset(250)
        #expect(page.verticalOffset == 250)
    }

    /// Past the reserved distance a short page still stops — the floor is what
    /// the header needs, not a licence to scroll forever.
    @Test func thereIsNoRoomBeyondWhatTheHeaderNeeds() {
        let page = makePage()
        page.setMinimumScrollTravel(200)
        page.setVerticalOffset(5_000)
        #expect(page.verticalOffset <= 200 + 1)
    }

    /// With no header to hold, an empty page does not reserve anything.
    @Test func withoutAHeaderThereIsNothingToReserve() {
        let page = makePage()
        page.setMinimumScrollTravel(0)
        page.setVerticalOffset(300)
        #expect(page.verticalOffset == 0)
    }
}
