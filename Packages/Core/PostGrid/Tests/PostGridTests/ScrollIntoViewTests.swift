import Testing
import UIKit
@testable import PostGrid

/// ON SCREEN AND VISIBLE ARE NOT THE SAME RECTANGLE.
///
/// The chrome floats over the content, so the scrollable area is bigger than
/// the area a viewer can actually see. `adjustedContentInset` is the
/// difference, and an item inside it is present, hit-testable, and hidden.
///
/// These cover the cases that are awkward to produce by hand on a device, which
/// is most of the interesting ones: the clamp at either end of the content, an
/// item taller than the gap between the bars, and — the one a feature like this
/// gets wrong — an item that is already visible and must not move at all.
struct ScrollIntoViewTests {
    /// A 800pt viewport with a 100pt bar at the top and a 90pt one at the
    /// bottom, scrolled to `offsetY`. Visible band: offsetY+100 … offsetY+710.
    private func viewport(offsetY: CGFloat = 0, contentHeight: CGFloat = 5000)
        -> (bounds: CGRect, inset: UIEdgeInsets, size: CGSize) {
        (
            CGRect(x: 0, y: offsetY, width: 390, height: 800),
            UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            CGSize(width: 390, height: contentHeight)
        )
    }

    private func offset(for rect: CGRect, offsetY: CGFloat = 0,
                        contentHeight: CGFloat = 5000, padding: CGFloat = 12) -> CGPoint? {
        let v = viewport(offsetY: offsetY, contentHeight: contentHeight)
        return ScrollIntoView.offset(toReveal: rect, bounds: v.bounds,
                                     contentInset: v.inset, contentSize: v.size,
                                     padding: padding)
    }

    /// The case that must stay free: a fully visible item does not move. If
    /// this returned an offset, every ordinary tap would jolt the list.
    @Test func anItemAlreadyInSightDoesNotMove() {
        #expect(offset(for: CGRect(x: 0, y: 300, width: 390, height: 200)) == nil)
    }

    /// Flush against the inset edges, inside the padding — still no move, or
    /// the list would nudge on taps that need nothing.
    @Test func anItemExactlyInsideThePaddingDoesNotMove() {
        #expect(offset(for: CGRect(x: 0, y: 112, width: 390, height: 100)) == nil)
        #expect(offset(for: CGRect(x: 0, y: 598, width: 390, height: 100)) == nil)
    }

    /// Under the TOP bar: scroll up until it clears, plus padding.
    @Test func anItemUnderTheHeaderComesDownBelowIt() throws {
        // Visible band starts at 100. This item spans 60…260, so its top is
        // buried 40pt under the bar.
        let result = try #require(offset(for: CGRect(x: 0, y: 60, width: 390, height: 200)))
        // rect.minY - inset.top - padding. Bound as CGFloat on purpose: `#expect`
        // captures each operand separately, so a bare literal expression here
        // infers as Int and the comparison fails cross-type with both sides
        // printing the same number.
        let expected: CGFloat = 60 - 100 - 12
        #expect(result.y == expected)
    }

    /// Under the BOTTOM bar: scroll down until its lower edge clears.
    @Test func anItemUnderTheFooterComesUpAboveIt() throws {
        // Visible band ends at 710. This item spans 650…850.
        let result = try #require(offset(for: CGRect(x: 0, y: 650, width: 390, height: 200)))
        // rect.maxY + inset.bottom + padding - height
        let expected: CGFloat = 850 + 90 + 12 - 800
        #expect(result.y == expected)
    }

    /// Taller than the gap between the bars: both edges cannot clear, so show
    /// the top. Aligning the bottom would open an item by revealing its last
    /// few points.
    @Test func anItemTallerThanTheGapAlignsToItsTop() throws {
        let tall = CGRect(x: 0, y: 400, width: 390, height: 900)
        let result = try #require(offset(for: tall))
        let expected: CGFloat = 400 - 100 - 12
        #expect(result.y == expected)
    }

    /// The clamp at the start: an item at the very top cannot be pushed
    /// further down, and asking for it must not scroll into rubber band.
    @Test func theFirstItemCannotBeScrolledPastTheTop() {
        // Already at rest against the top inset, so nothing to do.
        #expect(offset(for: CGRect(x: 0, y: -100, width: 390, height: 150), offsetY: -100) == nil)
    }

    /// The clamp at the end: the last item's lower edge may be unreachable, and
    /// the answer is the furthest legal offset — never past it.
    @Test func theLastItemStopsAtTheEndOfTheContent() throws {
        // Content ends at 1000; the maximum resting offset is 1000+90-800 = 290.
        let result = try #require(offset(
            for: CGRect(x: 0, y: 900, width: 390, height: 100), offsetY: 0, contentHeight: 1000
        ))
        let expected: CGFloat = 290
        #expect(result.y == expected)
    }

    /// …and once parked there, tapping the same item asks for nothing more.
    @Test func anUnreachableEdgeSettlesRatherThanRepeating() {
        #expect(offset(for: CGRect(x: 0, y: 900, width: 390, height: 100),
                       offsetY: 290, contentHeight: 1000) == nil)
    }

    /// Degenerate geometry must not produce an offset: a view with no height
    /// has no visible band to reveal anything into.
    @Test func aCollapsedViewportAsksForNothing() {
        let result = ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 0, width: 390, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 390, height: 0),
            contentInset: .zero, contentSize: CGSize(width: 390, height: 500)
        )
        #expect(result == nil)
    }

    /// Insets larger than the viewport (a keyboard over a short sheet) leave no
    /// visible band at all — also nothing to do, rather than a wild offset.
    @Test func insetsThatSwallowTheViewportAskForNothing() {
        let result = ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 10, width: 390, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 390, height: 200),
            contentInset: UIEdgeInsets(top: 150, left: 0, bottom: 150, right: 0),
            contentSize: CGSize(width: 390, height: 900)
        )
        #expect(result == nil)
    }

    /// The horizontal offset is preserved, not zeroed — these grids do not
    /// scroll sideways, but zeroing it would be a silent jump if one ever did.
    @Test func theHorizontalOffsetIsLeftAlone() throws {
        let result = try #require(ScrollIntoView.offset(
            toReveal: CGRect(x: 0, y: 0, width: 390, height: 100),
            bounds: CGRect(x: 40, y: 300, width: 390, height: 800),
            contentInset: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0),
            contentSize: CGSize(width: 390, height: 5000)
        ))
        let expected: CGFloat = 40
        #expect(result.x == expected)
    }
}

/// THE REVEAL MUST NOT COST THE VIEWER A WAIT.
///
/// An earlier version animated the reveal and held the open until the scroll
/// settled, so the hero would measure a landed rect. That put a delay in front
/// of the one thing the tap asked for. Unanimated gets both: the offset is
/// already correct when the flight measures, and nothing is gated behind an
/// animation or the timer that would be needed to survive a missing callback.
@MainActor
struct ScrollIntoViewImmediateTests {
    private func scrollView(offsetY: CGFloat = 0) -> UIScrollView {
        let view = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0)
        view.contentSize = CGSize(width: 390, height: 5000)
        view.contentOffset = CGPoint(x: 0, y: offsetY)
        return view
    }

    /// The offset has landed by the time the call returns — synchronously, in
    /// the same turn as the tap, which is what lets the open follow at once.
    @Test func anObscuredItemIsRevealedSynchronously() {
        let view = scrollView()

        let moved = ScrollIntoView.revealImmediately(
            CGRect(x: 0, y: 40, width: 390, height: 200), in: view
        )

        #expect(moved)
        let expected: CGFloat = 40 - 100 - 12
        #expect(view.contentOffset.y == expected, "the reveal had not landed when the call returned")
    }

    /// A visible item is not touched, and says so — the caller can open
    /// without a second thought either way.
    @Test func aVisibleItemIsLeftExactlyWhereItIs() {
        let view = scrollView(offsetY: 200)

        let moved = ScrollIntoView.revealImmediately(
            CGRect(x: 0, y: 500, width: 390, height: 200), in: view
        )

        #expect(moved == false)
        #expect(view.contentOffset.y == 200)
    }

    /// No layout attributes is not a reason to move anything — and never a
    /// reason to fail, since the tap still has to open.
    @Test func anUnknownRectMovesNothing() {
        let view = scrollView(offsetY: 120)

        #expect(ScrollIntoView.revealImmediately(nil, in: view) == false)
        #expect(view.contentOffset.y == 120)
    }

    /// Never parks in rubber band: the reveal clamps to the last legal offset
    /// even when the item's far edge cannot be cleared.
    @Test func theRevealNeverLeavesTheScrollPastItsEnd() {
        let view = scrollView()
        view.contentSize = CGSize(width: 390, height: 1000)

        ScrollIntoView.revealImmediately(CGRect(x: 0, y: 900, width: 390, height: 100), in: view)

        let maximum: CGFloat = 1000 + 90 - 800
        #expect(view.contentOffset.y == maximum)
    }
}
