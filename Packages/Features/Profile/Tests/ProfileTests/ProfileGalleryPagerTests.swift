import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

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
        pager.setActivePage(pager.pageOrder[1], animated: false)
        #expect(pager.debugActiveFormat == pager.pageOrder[1])
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

    // MARK: - Back to the top of the tab you are on

    /// ⚠️ **The top of the TAB, not of the profile.** A tab starts at its first
    /// row under the docked bar now that each keeps its own place; carrying on
    /// up to the identity block would answer a different question, and it would
    /// drag the other two tabs with it, because below the dock line the offset
    /// belongs to the screen rather than to the tab.
    @Test func reselectingReturnsToTheTabsOwnTop() {
        let pager = splitPager()
        pager.debugSetOffset(1_500, forPage: 0)
        pager.scrollActivePageToTop()
        #expect(abs(pager.debugVerticalOffsets[0] - 360) < 1)
    }

    /// And it leaves the others exactly where they were — a tab's own top is
    /// its own business.
    @Test func reselectingLeavesTheOtherTabsAlone() {
        let pager = splitPager()
        pager.debugSetOffset(900, forPage: 1)
        pager.debugSetOffset(700, forPage: 2)
        pager.debugSetOffset(1_500, forPage: 0)
        pager.scrollActivePageToTop()
        #expect(abs(pager.debugVerticalOffsets[1] - 900) < 1)
        #expect(abs(pager.debugVerticalOffsets[2] - 700) < 1)
    }

    /// ⚠️ Never downwards. From above the dock line the list is already showing
    /// its first row, and a "back to the top" that scrolled DOWN to reach the
    /// docked position would be a surprise rather than a service.
    @Test func reselectingFromAboveTheLineDoesNothing() {
        let pager = splitPager()
        pager.debugSetOffset(120, forPage: 0)
        pager.scrollActivePageToTop()
        #expect(abs(pager.debugVerticalOffsets[0] - 120) < 1)
    }

    /// Asking again once it is already there is a no-op rather than a nudge.
    @Test func reselectingAtTheTopIsIdempotent() {
        let pager = splitPager()
        pager.debugSetOffset(1_500, forPage: 0)
        pager.scrollActivePageToTop()
        pager.scrollActivePageToTop()
        #expect(abs(pager.debugVerticalOffsets[0] - 360) < 1)
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
