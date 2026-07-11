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

    /// The interactive-dismiss progress for a directional drag: translation
    /// along the dismiss axis over the view's span on that axis, clamped to
    /// 0...1. Kept pure so the scrub curve is testable.
    static func dismissProgress(translation: CGFloat, span: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        return min(max(translation / span, 0), 1)
    }

    /// The release contract: a grab completes when it was dragged past the
    /// progress threshold, or released as a flick above the velocity threshold
    /// (in the dismiss direction) — otherwise it cancels and springs back.
    static func shouldCompleteDismissal(
        progress: CGFloat,
        velocity: CGFloat,
        progressThreshold: CGFloat,
        flickVelocity: CGFloat
    ) -> Bool {
        progress >= progressThreshold || velocity >= flickVelocity
    }
}
