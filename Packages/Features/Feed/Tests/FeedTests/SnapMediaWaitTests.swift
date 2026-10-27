import DesignSystem
import Foundation
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

    /// A clock a test steps by hand: the loader's minimum.
    @MainActor
    private final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var clock: LoadingClock {
            LoadingClock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                pending.remove(at: index).work()
            }
        }
    }

    private static func wait(for page: Page, clock: LoadingClock = .system) -> SnapMediaWait {
        SnapMediaWait(
            hasItsOwnMedia: { [page] in page.hasMedia },
            isShowingLoader: { [page] in page.showing },
            setLoading: { [page] loading in
                page.switches.append(loading)
                page.showing = loading
            },
            clock: clock
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

        #expect(page.switches.isEmpty, "the loader moved for a picture already there")
        #expect(page.showing == false)
    }

    /// At once, on the kit's gate (#1768) with no minimum: the picture is
    /// what replaces the loader.
    @Test func theArrivalTakesTheSpinnerDownAndDisarms() {
        let time = ManualClock()
        let page = Page()
        let wait = Self.wait(for: page, clock: time.clock)
        wait.refresh()
        time.advance(SnapMediaWait.grace)
        #expect(page.switches == [true])

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
