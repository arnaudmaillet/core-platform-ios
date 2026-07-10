import CoreGraphics

/// Pure geometry for the zoom transition, split out so the frame math is
/// unit-tested without a live map or view hierarchy.
enum ZoomTransitionGeometry {
    /// The rect a hero shrinks to when its source is off-screen (a panned-away
    /// pin): a small square centered in `bounds`. Dismissing to this reads as
    /// "collapse away" rather than flying to an invisible off-screen point.
    static func centeredFallback(in bounds: CGRect, side: CGFloat = 56) -> CGRect {
        CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// The interactive-dismiss progress for a downward drag: vertical translation
    /// over a full-height threshold, clamped to 0...1. Kept pure so the scrub
    /// curve is testable.
    static func dismissProgress(translationY: CGFloat, viewHeight: CGFloat) -> CGFloat {
        guard viewHeight > 0 else { return 0 }
        return min(max(translationY / viewHeight, 0), 1)
    }

    /// The transform that renders a view laid out at `rect` exactly onto
    /// `target`: translate center-to-center (in superview points, applied
    /// before the scale so the scale can't skew it), then scale size-to-size
    /// about the default centered anchor. Because UIKit interpolates the matrix
    /// components linearly, animating this to/from `.identity` sweeps the same
    /// rects as a frame animation between `rect` and `target` at every step.
    static func collapseTransform(of rect: CGRect, onto target: CGRect) -> CGAffineTransform {
        guard rect.width > 0, rect.height > 0 else { return .identity }
        return CGAffineTransform(translationX: target.midX - rect.midX, y: target.midY - rect.midY)
            .scaledBy(x: target.width / rect.width, y: target.height / rect.height)
    }
}
