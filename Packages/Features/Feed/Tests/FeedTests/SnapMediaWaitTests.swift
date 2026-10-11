import Testing
@testable import Feed

/// When a post page announces a wait for its media (`SnapMediaWait`): never
/// at once, only once the grace has run out, and only if the picture is
/// still missing then. The grace is run out by hand — no clock.
@MainActor
struct SnapMediaWaitTests {
    /// The page's side: whether it has its picture, and the loader it drives.
    private final class Page {
        var hasMedia = false
        var showing = false
        var switches: [Bool] = []
    }

    private static func wait(for page: Page) -> SnapMediaWait {
        SnapMediaWait(
            hasItsOwnMedia: { [page] in page.hasMedia },
            isShowingLoader: { [page] in page.showing },
            setLoading: { [page] loading in
                page.switches.append(loading)
                page.showing = loading
            }
        )
    }

    @Test func aPageWithItsPictureNeverWaits() {
        let page = Page()
        page.hasMedia = true
        let wait = Self.wait(for: page)

        wait.refresh()

        #expect(wait.isArmed == false)
        #expect(page.switches == [false])
    }

    @Test func aMissingPictureIsAnnouncedOnlyAfterTheGrace() {
        let page = Page()
        let wait = Self.wait(for: page)

        wait.refresh()
        #expect(wait.isArmed)
        #expect(page.switches.isEmpty)

        wait.debugElapseGrace()
        #expect(wait.isArmed == false)
        #expect(page.switches == [true])
    }

    @Test func aPictureThatArrivesDuringTheGraceIsNeverAnnounced() {
        let page = Page()
        let wait = Self.wait(for: page)
        wait.refresh()

        page.hasMedia = true
        wait.debugElapseGrace()

        #expect(page.switches == [false])
        #expect(page.showing == false)
    }

    @Test func theArrivalTakesTheSpinnerDownAndDisarms() {
        let page = Page()
        let wait = Self.wait(for: page)
        wait.refresh()
        wait.debugElapseGrace()

        page.hasMedia = true
        wait.refresh()

        #expect(page.switches == [true, false])
        #expect(wait.isArmed == false)
    }

    @Test func aSecondRefreshDuringTheGraceKeepsOneGrace() {
        let page = Page()
        let wait = Self.wait(for: page)

        wait.refresh()
        wait.refresh()

        #expect(wait.isArmed)
        #expect(page.switches.isEmpty)
        wait.cancel()
    }

    @Test func aSpinnerAlreadyUpIsNotArmedAgain() {
        let page = Page()
        page.showing = true
        let wait = Self.wait(for: page)

        wait.refresh()

        #expect(wait.isArmed == false)
        #expect(page.switches.isEmpty)
    }

    @Test func theRecycleDropsTheWaitAndTheSpinner() {
        let page = Page()
        let wait = Self.wait(for: page)
        wait.refresh()

        wait.cancel()

        #expect(wait.isArmed == false)
        #expect(page.switches == [false])
    }
}
