import UIKit
import Testing
@testable import DesignSystem

/// A horizontal drag that starts on content with somewhere left to go IN THAT
/// DIRECTION belongs to that content, not to the tab pager.
///
/// Two `UIScrollView` pans do not recognise simultaneously and UIKit picks no
/// winner by depth, so the outer one took every drag: a post card's media
/// carousel could not be swiped at all — the tab changed instead. Reported
/// exactly that way, and invisible to a screenshot, which is why it is pinned
/// here rather than left to a capture.
///
/// ⚠️ The direction half arrived later, from the opposite complaint: a carousel
/// parked on its first page took the rightward drag it could only rubber-band
/// on, and nothing happened. The tests below that pass no velocity are asking
/// the "direction unknown" question on purpose — it is the answer this rule gave
/// before it could tell the two apart, and a caller holding a location and no
/// pan still gets it.
@MainActor
struct PagerGestureYieldingTests {
    /// A drag hard enough to be unambiguous, in each direction. The rule reads
    /// the sign only, but a velocity a real finger could not produce would prove
    /// nothing about the one it will.
    private static let rightward = CGPoint(x: 820, y: 0)
    private static let leftward = CGPoint(x: -820, y: 0)

    private func pager(
        withNestedContentWidth width: CGFloat, parkedAt offsetX: CGFloat = 0
    ) -> HorizontalPagerView {
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
        nested.contentOffset = CGPoint(x: offsetX, y: 0)
        return pager
    }

    /// Asks the decision directly. `gestureRecognizerShouldBegin` only fires for
    /// the scroll view's OWN pan, and a real recognizer cannot be made to report
    /// a location or a velocity — which is why the rule lives in a method of its
    /// own.
    private func shouldBegin(
        _ pager: HorizontalPagerView, at point: CGPoint, velocity: CGPoint = .zero
    ) -> Bool {
        guard let scrollView = pager.pagingScrollView as? HorizontalPagerScrollView
        else { return true }
        return !scrollView.shouldYield(at: point, velocity: velocity)
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

    /// ⚠️ AND IT IS ASKED FIRST, ahead of the travel test — which is the only
    /// reason it survived direction becoming part of the rule. A rightward drag
    /// on content parked at its start is exactly the case the new half hands
    /// BACK to the pager, so an edge test asked second would have been overruled
    /// by it here, on the strip the platform reserves.
    @Test func theEdgeStripWinsWhicheverWayTheDragIsGoing() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 8, y: 450), velocity: Self.rightward) == false)
        #expect(shouldBegin(pager, at: CGPoint(x: 8, y: 450), velocity: Self.leftward) == false)
    }

    /// ⚠️ THE HALF THE CONTENT-WIDTH TEST WAS MISSING.
    ///
    /// Content parked at its start still scrolls horizontally, so the old rule
    /// gave it every drag — including the rightward one it could only
    /// rubber-band on. A carousel on its first photograph swallowed the movement
    /// and nothing happened, which is how it was reported.
    @Test func thePagerKeepsARightwardDragOnContentParkedAtItsStart() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200), velocity: Self.rightward))
    }

    /// And gives that same drag straight back the moment there IS a photograph
    /// to its left. The tenant wins its own territory.
    @Test func thePagerYieldsARightwardDragOnContentWithSomewhereBackToGo() {
        let pager = pager(withNestedContentWidth: 900, parkedAt: 350)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200), velocity: Self.rightward) == false)
    }

    /// The mirror, and it is written HERE rather than in the carousel: at the
    /// end of the run a leftward drag has somewhere real to land, because
    /// leftward is the direction this pager moves forward in.
    @Test func thePagerKeepsALeftwardDragOnContentParkedAtItsEnd() {
        let pager = pager(withNestedContentWidth: 900, parkedAt: 550)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200), velocity: Self.leftward))
    }

    /// Both halves, or the test passes on a rule that refuses everything: a
    /// leftward drag with pages still ahead of it belongs to the content.
    @Test func thePagerYieldsALeftwardDragOnContentWithSomewhereOnToGo() {
        let pager = pager(withNestedContentWidth: 900)

        #expect(shouldBegin(pager, at: CGPoint(x: 200, y: 200), velocity: Self.leftward) == false)
    }

    /// ⚠️ A DECLARED OWNER KEEPS EVERY DRAG, at any offset and in any direction.
    ///
    /// A scrubber handles its drag with a pan recognizer and has no content size
    /// to measure, so the travel test would answer from a `contentOffset` of
    /// zero it never moves — reading as "parked at the start" and quietly taking
    /// every rightward drag away from it.
    @Test func aDeclaredOwnerIsNeverAskedAboutTravel() {
        let page = UIView()
        let scrubber = Scrubber(frame: CGRect(x: 20, y: 100, width: 350, height: 200))
        page.addSubview(scrubber)
        let pager = HorizontalPagerView(pages: [page])
        pager.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        pager.layoutIfNeeded()
        scrubber.frame = CGRect(x: 20, y: 100, width: 350, height: 200)

        let point = CGPoint(x: 200, y: 200)
        #expect(shouldBegin(pager, at: point, velocity: Self.rightward) == false)
        #expect(shouldBegin(pager, at: point, velocity: Self.leftward) == false)
        #expect(shouldBegin(pager, at: point) == false)
    }
}

/// A control that scrubs with a pan rather than by scrolling — the case the
/// measured test cannot see.
private final class Scrubber: UIView, HorizontalDragOwning {}
