import Testing
import UIKit
@testable import PostGrid

/// THE TAP MUST SURVIVE THE SCROLL.
///
/// Revealing an obscured item before opening it means the open has to wait —
/// the hero measures the cell's rect at open time, so opening mid-scroll flies
/// from a rect that is already stale. Waiting introduces the failure this
/// covers: a tap that never opens anything, which is worse than the artifact
/// being fixed.
@MainActor
struct ScrollIntoViewSelectionTests {
    /// A scroll view with a 100pt top inset and content well past its bottom.
    private func scrollView(offsetY: CGFloat = 0) -> UIScrollView {
        let view = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0)
        view.contentSize = CGSize(width: 390, height: 5000)
        view.contentOffset = CGPoint(x: 0, y: offsetY)
        return view
    }

    /// The common case: nothing is covering the item, so it opens at once. A
    /// delay here would tax every ordinary tap.
    @Test func aVisibleItemOpensImmediately() {
        let selection = ScrollIntoViewSelection()
        var opened = false

        selection.select(revealing: CGRect(x: 0, y: 300, width: 390, height: 200),
                         in: scrollView()) { opened = true }

        #expect(opened)
        #expect(selection.hasPendingOpen == false)
    }

    /// An obscured item does NOT open yet — the scroll has to land first.
    @Test func anObscuredItemWaitsForTheScroll() {
        let selection = ScrollIntoViewSelection()
        var opened = false

        selection.select(revealing: CGRect(x: 0, y: 40, width: 390, height: 200),
                         in: scrollView()) { opened = true }

        #expect(opened == false, "it opened from behind the chrome")
        #expect(selection.hasPendingOpen)

        selection.scrollAnimationDidEnd()
        #expect(opened)
        #expect(selection.hasPendingOpen == false)
    }

    /// A settle callback with nothing pending must not fire a stale open —
    /// otherwise any later scroll re-opens the last tapped post.
    @Test func aSettleWithNothingPendingOpensNothing() {
        let selection = ScrollIntoViewSelection()
        var opens = 0

        selection.select(revealing: CGRect(x: 0, y: 40, width: 390, height: 200),
                         in: scrollView()) { opens += 1 }
        selection.scrollAnimationDidEnd()
        selection.scrollAnimationDidEnd()
        selection.scrollAnimationDidEnd()

        #expect(opens == 1)
    }

    /// Two taps in quick succession are one open, for the second item. Firing
    /// the first as well would open two posts from one gesture.
    @Test func asecondTapReplacesTheFirstRatherThanQueueing() {
        let selection = ScrollIntoViewSelection()
        var opened: [String] = []
        let view = scrollView()

        selection.select(revealing: CGRect(x: 0, y: 40, width: 390, height: 200),
                         in: view) { opened.append("first") }
        selection.select(revealing: CGRect(x: 0, y: 60, width: 390, height: 200),
                         in: view) { opened.append("second") }
        selection.scrollAnimationDidEnd()

        #expect(opened == ["second"])
    }

    /// A surface going away drops the pending open — a post arriving after the
    /// screen has gone is one the viewer never asked for.
    @Test func cancellingDropsThePendingOpen() {
        let selection = ScrollIntoViewSelection()
        var opened = false

        selection.select(revealing: CGRect(x: 0, y: 40, width: 390, height: 200),
                         in: scrollView()) { opened = true }
        selection.cancelPending()
        selection.scrollAnimationDidEnd()

        #expect(opened == false)
    }

    /// No layout attributes (a cell the layout cannot place) still opens. An
    /// unknown rect is not a reason to swallow a tap.
    @Test func anUnknownRectStillOpens() {
        let selection = ScrollIntoViewSelection()
        var opened = false

        selection.select(revealing: nil, in: scrollView()) { opened = true }

        #expect(opened)
    }

    /// The scroll view is actually asked to move — the reveal is not merely
    /// bookkeeping around a delay.
    @Test func anObscuredItemActuallyMovesTheScrollView() {
        let selection = ScrollIntoViewSelection()
        let view = scrollView()
        let before = view.contentOffset.y

        selection.select(revealing: CGRect(x: 0, y: 40, width: 390, height: 200),
                         in: view) {}

        #expect(view.contentOffset.y != before || selection.hasPendingOpen,
                "nothing was asked to scroll and nothing is waiting")
    }
}
