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

    /// ⚠️ EVERY PAGE IS REACHABLE THOUGH ONLY FIVE DOTS ARE DRAWN, and the
    /// chip's width is not what bounds it.
    ///
    /// The drag is a rate, not a position: one dot slot per page, tracked by a
    /// long press whose movement limit is lifted, so the finger keeps counting
    /// well outside the chip. A ten-page post is crossed in nine slots — about
    /// a hundred points — on a chip that only draws five dots.
    ///
    /// ⚠️ `@MainActor` ON THE TEST, because this suite is not. Every other test
    /// here calls a pure static function, so nothing forced the question — and a
    /// UIKit view built from a nonisolated test COMPILES (the package defaults
    /// its own code to the main actor) and then dies on a cooperative queue at
    /// `UIView.init`. The failure reads as "the whole run crashed", not as this
    /// test's own.
    @MainActor
    @Test func everyPageIsReachableThoughOnlyAWindowIsDrawn() {
        let indicator = MediaPageIndicatorView()
        indicator.frame = CGRect(x: 0, y: 0, width: PageDotsView.chipWidth(forDots: 5), height: 20)
        indicator.configure(count: 10, current: 0)
        var requested: [Int] = []
        indicator.onPageRequested = { requested.append($0) }

        let slot = MediaPageIndicatorView.pointsPerPage
        indicator.debugScrub(.began, atX: 0)
        for step in 1...9 {
            indicator.debugScrub(.changed, atX: slot * CGFloat(step))
        }

        #expect(requested == Array(1...9))
    }
}
