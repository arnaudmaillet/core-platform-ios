import Testing
import UIKit
@testable import DesignSystem

/// `PagerMode.instant` (#1748, every host): the pages do not move with the
/// pill. A tap or a released drag selects, and the host shows that page
/// directly; swiping the pages still moves the pill fractionally.
@MainActor
struct PagedTabBarInstantPagesTests {
    private func bar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.layoutIfNeeded()
        return bar
    }

    /// Where the model sits on a segment, in the viewport — the space the
    /// drag is read in — measured on a bar of its own, so the one under test
    /// is not moved by the measuring.
    private func segmentCentre(_ bar: PagedTabBar, _ index: Int) -> CGFloat {
        let ruler = self.bar()
        ruler.setProgress(CGFloat(index))
        return ruler.debugPillInViewport.midX
    }

    @Test func instantIsTheDefaultAndPagesDoNotAnimate() {
        let bar = bar()
        #expect(bar.pagerMode == .instant)
        #expect(!bar.animatesPageChanges)
        bar.pagerMode = .scrolling
        #expect(bar.animatesPageChanges)
    }

    /// The model goes to the tapped segment at once, whether or not a pager
    /// echoes the page back — the lens flies there on its own.
    @Test func aTapSelectsAndPlacesTheModelAtOnce() {
        let bar = bar()
        var changed: [Int] = []
        bar.addAction(UIAction { [weak bar] _ in changed.append(bar?.selectedIndex ?? -1) }, for: .valueChanged)
        bar.debugSimulateTap(at: 2)
        #expect(changed == [2])
        #expect(abs(bar.debugPillInViewport.midX - segmentCentre(bar, 2)) < 1)
        // The pager's report of the page it now shows changes nothing.
        bar.setProgress(2)
        #expect(changed == [2])
    }

    @Test func draggingThePillNeverScrubsThePages() {
        let bar = bar()
        var scrubbed = 0
        var released = 0
        bar.onScrub = { _ in scrubbed += 1 }
        bar.onScrubEnd = { _ in released += 1 }
        let start = bar.debugPillInViewport.midX
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + 40)
        bar.debugDragPill(toViewportX: start + 90)
        bar.debugEndPillDrag()
        #expect(scrubbed == 0 && released == 0)
    }

    /// The release lands on the segment under the pill and selects it —
    /// no throw by velocity: the native control takes the segment under the
    /// finger.
    @Test func theReleaseSelectsTheSegmentUnderThePill() {
        let bar = bar()
        var changed: [Int] = []
        bar.addAction(UIAction { [weak bar] _ in changed.append(bar?.selectedIndex ?? -1) }, for: .valueChanged)
        let start = bar.debugPillInViewport.midX
        let next = segmentCentre(bar, 1)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + (next - start) * 0.5)
        bar.debugDragPill(toViewportX: next + 6, after: 0.004)
        bar.debugEndPillDrag()
        #expect(changed == [1])
        #expect(bar.selectedIndex == 1)
        #expect(abs(bar.debugPillInViewport.midX - next) < 1, "the model lands on it")
    }

    @Test func aReleaseShortOfHalfWayStaysAndAnnouncesNothing() {
        let bar = bar()
        var changed = 0
        bar.addAction(UIAction { _ in changed += 1 }, for: .valueChanged)
        let start = bar.debugPillInViewport.midX
        let next = segmentCentre(bar, 1)
        #expect(bar.debugBeginPillDrag(atViewportX: start))
        bar.debugDragPill(toViewportX: start + (next - start) * 0.3, after: 0.004)
        bar.debugEndPillDrag()
        #expect(changed == 0)
        #expect(bar.selectedIndex == 0)
        #expect(abs(bar.debugPillInViewport.midX - start) < 1, "the model goes back")
    }

    @Test func swipedPagesStillMoveThePillFractionally() {
        let bar = bar()
        let start = bar.debugPillInViewport.midX
        let next = segmentCentre(bar, 1)
        bar.setProgress(0.5)
        let half = bar.debugPillInViewport.midX
        #expect(abs(half - (start + next) / 2) < 1, "half way: \(half)")
    }
}
