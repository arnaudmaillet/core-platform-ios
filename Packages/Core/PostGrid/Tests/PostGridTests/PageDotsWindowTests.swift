import Testing
import UIKit
@testable import PostGrid

/// The indicator's window: it is the one chip of the preview's bottom row that
/// may be shown PARTIALLY and still mean something, so it is the one that
/// absorbs a squeeze. A window of dots still says "there are more, you are
/// here"; half a count or half a date says nothing.
struct PageDotsWindowTests {
    @Test func everyDotShowsWhenThereIsRoom() {
        let full = PageDotsView.width(forDots: 5)

        #expect(PageDotsView.visibleDots(in: full, count: 5) == 5)
        #expect(PageDotsView.visibleDots(in: full + 40, count: 5) == 5)
    }

    /// ⚠️ TWO is the floor, at any width including none.
    ///
    /// One dot says nothing a single page would not, and the chip has to keep
    /// saying "there is more than one" however hard the counters squeeze. Below
    /// the floor the dots are clipped rather than reduced further, which is the
    /// honest end of the scale.
    @Test func twoDotsIsTheFloor() {
        #expect(PageDotsView.visibleDots(in: 0, count: 8) == 2)
        #expect(PageDotsView.visibleDots(in: 4, count: 8) == 2)
        #expect(PageDotsView.visibleDots(in: -20, count: 8) == 2)
    }

    /// A width between the two shows what fits and no more.
    @Test func aSqueezedChipShowsWhatFits() {
        #expect(PageDotsView.visibleDots(in: PageDotsView.width(forDots: 4), count: 8) == 4)
        // Just under five dots' worth is still four.
        #expect(PageDotsView.visibleDots(in: PageDotsView.width(forDots: 5) - 1, count: 8) == 4)
    }

    /// Never more dots than pages, whatever the room.
    @Test func thereAreNeverMoreDotsThanPages() {
        #expect(PageDotsView.visibleDots(in: 400, count: 3) == 3)
    }

    /// ⚠️ The window is CENTRED on the current page, not anchored at the start.
    ///
    /// A clipped row would hide exactly the dot the viewer is looking for the
    /// moment there are more pages than room — which is when an indicator starts
    /// earning its place.
    @Test func theWindowFollowsTheCurrentPage() {
        #expect(PageDotsView.windowStart(current: 5, visible: 3, count: 10) == 4)
        #expect(PageDotsView.windowStart(current: 0, visible: 3, count: 10) == 0)
    }

    /// And it never runs off either end: at the last page the window sits on the
    /// tail rather than half past it.
    @Test func theWindowStopsAtBothEnds() {
        #expect(PageDotsView.windowStart(current: 9, visible: 3, count: 10) == 7)
        #expect(PageDotsView.windowStart(current: 0, visible: 4, count: 4) == 0)
        // Nothing to window when everything fits.
        #expect(PageDotsView.windowStart(current: 2, visible: 5, count: 5) == 0)
    }

    /// ⚠️ A touch maps across the WHOLE run of pages, even when only a window is
    /// drawn — the chip is a scrubber, not a row of discrete targets.
    ///
    /// Mapping onto the visible dots would make the far right mean "the last dot
    /// I can see" rather than "the end", and which page that is would change as
    /// the window moved. One rule at every width, every page reachable at every
    /// width.
    @Test func aTouchReachesEveryPageEvenWhenTheWindowIsShort() {
        #expect(MediaPageIndicatorView.page(at: 100, width: 100, count: 10) == 9)
        #expect(MediaPageIndicatorView.page(at: 0, width: 100, count: 10) == 0)
    }
}
