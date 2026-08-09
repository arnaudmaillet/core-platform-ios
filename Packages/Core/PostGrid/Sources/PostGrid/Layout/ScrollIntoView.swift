import UIKit

/// Where a scroll view has to be for a given item to be fully in sight.
///
/// A grid's chrome floats OVER its content — a nav bar at the top, a tab bar or
/// composer at the bottom — so the scrollable area and the *visible* area are
/// not the same rectangle. The difference is `adjustedContentInset`, and an
/// item sitting inside it is on screen in the geometric sense and hidden in the
/// one that matters. Tapping such an item opened it from behind the chrome.
///
/// Pure arithmetic, and deliberately so: the interesting cases are the ones
/// that are awkward to produce by hand on a device — an item taller than the
/// gap between the bars, one at the very end of the content where the clamp
/// bites, one already visible that must not move at all.
public enum ScrollIntoView {
    /// Breathing room between the item and the chrome it was hiding under, so
    /// it lands *next to* the bar rather than flush against it.
    public static let defaultPadding: CGFloat = 12

    /// The content offset that brings `rect` fully into the visible area, or
    /// `nil` if it is already there and nothing should move.
    ///
    /// `rect` is in the scroll view's CONTENT coordinates — the space
    /// `layoutAttributesForItem` reports in — which is the same space as
    /// `bounds`, so the two can be compared directly.
    ///
    /// Returning `nil` rather than the current offset is load-bearing: callers
    /// use it to decide whether to wait for a scroll before acting, and an
    /// offset that happens to equal the current one would have them waiting for
    /// an animation that never runs.
    public static func offset(
        toReveal rect: CGRect,
        bounds: CGRect,
        contentInset: UIEdgeInsets,
        contentSize: CGSize,
        padding: CGFloat = defaultPadding
    ) -> CGPoint? {
        guard bounds.height > 0 else { return nil }
        let visibleTop = bounds.minY + contentInset.top
        let visibleBottom = bounds.maxY - contentInset.bottom
        guard visibleBottom > visibleTop else { return nil }

        // The furthest the content can legitimately be scrolled. Beyond this is
        // rubber-band territory, which is a place a scroll may be dragged to
        // but never a place to leave it parked.
        let minimumY = -contentInset.top
        let maximumY = max(minimumY, contentSize.height + contentInset.bottom - bounds.height)

        let targetY: CGFloat
        let visibleHeight = visibleBottom - visibleTop
        if rect.height > visibleHeight - padding * 2 {
            // Taller than the gap between the bars: both edges cannot clear, so
            // show the TOP of it. Aligning the bottom instead would open an
            // item by showing the viewer its last few points.
            targetY = rect.minY - contentInset.top - padding
        } else if rect.minY < visibleTop + padding {
            targetY = rect.minY - contentInset.top - padding
        } else if rect.maxY > visibleBottom - padding {
            targetY = rect.maxY + contentInset.bottom + padding - bounds.height
        } else {
            return nil
        }

        let clamped = min(max(targetY, minimumY), maximumY)
        // Clamping can land exactly where the scroll already is — an item at
        // the very top or bottom of the content, whose obscured edge simply
        // cannot be revealed. Nothing to animate, so say so.
        guard abs(clamped - bounds.minY) > 0.5 else { return nil }
        return CGPoint(x: bounds.minX, y: clamped)
    }

    /// Reveals `rect` NOW — no animation, no waiting — and reports whether
    /// anything moved.
    ///
    /// Instant on purpose. A tap on these grids starts a hero flight, and the
    /// flight measures the cell's rect as it opens, so the reveal has to be
    /// finished by then or the card departs from a rect that is already stale.
    /// The alternatives were both worse: animating and opening together flies
    /// from the pre-scroll position, and waiting for the animation puts a
    /// delay in front of every obscured tap — friction before the one thing
    /// the viewer asked for.
    ///
    /// Unanimated also means there is nothing to see. The offset changes in
    /// the same turn as the tap, one frame before the card lifts off the cell
    /// and covers it, and the grid is on its way to being hidden anyway.
    @discardableResult
    public static func revealImmediately(
        _ rect: CGRect?,
        in scrollView: UIScrollView,
        padding: CGFloat = defaultPadding
    ) -> Bool {
        guard let rect, let offset = offset(
            toReveal: rect,
            bounds: scrollView.bounds,
            contentInset: scrollView.adjustedContentInset,
            contentSize: scrollView.contentSize,
            padding: padding
        ) else { return false }
        scrollView.setContentOffset(offset, animated: false)
        // Settle the geometry in this turn too. The offset lands immediately,
        // but cells the move brought into range are realized on the next
        // layout pass — and the hero is about to ask the page where things
        // are.
        scrollView.layoutIfNeeded()
        return true
    }
}
