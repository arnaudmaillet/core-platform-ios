import Testing
@testable import Feed

/// #1738 (the owner, 2026-10-25): after a while, a full-screen post's
/// carousel would no longer page left or right.
@MainActor
struct CarouselFreezeLedgerTests {
    private final class Page {
        var scrolls = true
    }

    private func apply(_ page: Page, _ enabled: Bool) { page.scrolls = enabled }

    /// ⚠️ The freeze saw two cells (a page still settling), the thaw only
    /// one: the other kept its frozen carousel and was recycled for other
    /// posts. The thaw reaches every cell the freeze touched.
    @Test func theThawReachesACellThatLeftTheScreen() {
        let ledger = CarouselFreezeLedger<Page>()
        let leaving = Page()
        let arriving = Page()
        ledger.freeze([leaving, arriving], apply: apply)
        #expect(!leaving.scrolls && !arriving.scrolls)

        ledger.thaw([arriving], apply: apply)
        #expect(arriving.scrolls)
        #expect(leaving.scrolls, "the cell that left the screen kept a frozen carousel")
    }

    /// A cell coming on while the content is frozen is frozen with it, and
    /// thawed with the rest.
    @Test func aCellShownDuringTheFreezeFollowsIt() {
        let ledger = CarouselFreezeLedger<Page>()
        ledger.freeze([], apply: apply)
        let late = Page()
        ledger.display(late, apply: apply)
        #expect(!late.scrolls)
        ledger.thaw([], apply: apply)
        #expect(late.scrolls)

        // Outside a freeze, a cell shown scrolls — whatever it carried.
        let stale = Page()
        stale.scrolls = false
        ledger.display(stale, apply: apply)
        #expect(stale.scrolls)
    }

    /// A thaw with nothing frozen is harmless, and a double freeze keeps one
    /// entry per cell.
    @Test func freezesAndThawsAreIdempotent() {
        let ledger = CarouselFreezeLedger<Page>()
        let page = Page()
        ledger.thaw([page], apply: apply)
        #expect(page.scrolls)
        ledger.freeze([page], apply: apply)
        ledger.freeze([page], apply: apply)
        #expect(ledger.isFrozen)
        ledger.thaw([], apply: apply)
        #expect(page.scrolls)
        #expect(!ledger.isFrozen)
    }
}
