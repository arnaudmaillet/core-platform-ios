import UIKit
import Testing
@testable import DesignSystem

/// A horizontal drag that starts on horizontally-scrollable content belongs to
/// that content, not to the tab pager.
///
/// Two `UIScrollView` pans do not recognise simultaneously and UIKit picks no
/// winner by depth, so the outer one took every drag: a post card's media
/// carousel could not be swiped at all — the tab changed instead. Reported
/// exactly that way, and invisible to a screenshot, which is why it is pinned
/// here rather than left to a capture.
@MainActor
struct PagerGestureYieldingTests {
    private func pager(withNestedContentWidth width: CGFloat) -> HorizontalPagerView {
        let page = UIView()
        let nested = UIScrollView(frame: CGRect(x: 20, y: 100, width: 350, height: 200))
        nested.contentSize = CGSize(width: width, height: 200)
        page.addSubview(nested)
        let pager = HorizontalPagerView(pages: [page])
        pager.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        pager.layoutIfNeeded()
        // Re-stated after layout: pinning the page to the pager resizes it, and
        // an autoresized subview would land somewhere else.
        nested.frame = CGRect(x: 20, y: 100, width: 350, height: 200)
        nested.contentSize = CGSize(width: width, height: 200)
        return pager
    }

    /// Asks the decision directly. `gestureRecognizerShouldBegin` only fires for
    /// the scroll view's OWN pan, and a real recognizer cannot be made to report
    /// a location — which is why the rule lives in a method of its own.
    private func shouldBegin(_ pager: HorizontalPagerView, at point: CGPoint) -> Bool {
        guard let scrollView = pager.pagingScrollView as? HorizontalPagerScrollView
        else { return true }
        return !scrollView.shouldYield(at: point)
    }

    @Test func thePagerYieldsToScrollableContentUnderTheTouch() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200)) == false)
    }

    /// ⚠️ The content-width test is the whole of the rule, not a detail.
    ///
    /// The feed's own vertical collection view is a scroll view on this path
    /// too, and its content is exactly as wide as it is. Yielding to any nested
    /// scroll view would have made the pager refuse every drag in the list —
    /// trading one broken gesture for a worse one.
    @Test func thePagerKeepsDragsOverContentWithNowhereHorizontalToGo() {
        let pager = pager(withNestedContentWidth: 350)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200)))
    }

    /// Outside the nested view, the pager is the pager.
    @Test func thePagerKeepsDragsThatMissTheContent() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 450)))
    }

    /// The leading-edge strip still outranks everything: an interactive pop owns
    /// that zone whatever is under it.
    @Test func theEdgeStripStillWins() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 8, y: 450)) == false)
    }
}
