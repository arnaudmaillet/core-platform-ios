import CoreGraphics

/// Pure geometry for interactive dismissals, split out so the frame math is
/// unit-tested without a live map or view hierarchy.
///
/// Lives in CoreNavigation so every dismissal — the pin feed's free-floating
/// grab (Maps) and the timeline feed's slide-back (app shell) — releases on
/// the SAME contract: one progress curve, one completion threshold, one flick
/// velocity. Tune them here, never per-surface.
public enum ZoomTransitionGeometry {
    /// Fraction of the view's *width* a drag must cover to complete on release.
    public static let completionThreshold: CGFloat = 0.35
    /// A rightward flick above this speed (pt/s) completes regardless of distance.
    public static let flickVelocity: CGFloat = 900

    /// The rect a hero shrinks to when its source is off-screen (a panned-away
    /// pin): a small square centered in `bounds`. Dismissing to this reads as
    /// "collapse away" rather than flying to an invisible off-screen point.
    /// The uniform scale that makes a `surface`-sized video layer COVER a
    /// `size`-sized window — the flight-video analog of `scaleAspectFill`.
    ///
    /// Public because two drivers need it and must not each carry their own
    /// copy: the flight card poses the surface while it is inside the card, and
    /// the dismissal's host poses it after the surface is hoisted out. When
    /// those two disagreed about the fill rule the media stopped covering
    /// mid-flight, so the rule lives in exactly one place.
    public static func mediaFillScale(covering size: CGSize, surface: CGSize) -> CGFloat {
        guard surface.width > 0, surface.height > 0 else { return 1 }
        return max(size.width / surface.width, size.height / surface.height)
    }

    public static func centeredFallback(in bounds: CGRect, side: CGFloat = 56) -> CGRect {
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
    public static func dismissProgress(translation: CGFloat, span: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        return min(max(translation / span, 0), 1)
    }

    /// Scroll-view-style rubber banding for the axes a grab may drift along
    /// but not travel: 1:1 slope at the origin, asymptotic to ±`limit`. Sign
    /// is preserved, so one call serves upward/downward drift and back-drag.
    public static func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        return limit * offset / (limit + abs(offset))
    }

    /// The release contract: a drag completes when it passed the progress
    /// threshold, or was released as a flick above the velocity threshold
    /// (in the dismiss direction) — otherwise it cancels and springs back.
    public static func shouldCompleteDismissal(
        progress: CGFloat,
        velocity: CGFloat,
        progressThreshold: CGFloat = completionThreshold,
        flickVelocity: CGFloat = flickVelocity
    ) -> Bool {
        progress >= progressThreshold || velocity >= flickVelocity
    }

    /// How far along its flight a caught transition must have been for a bare
    /// release to let it keep going. The midpoint: whichever state the catch
    /// was nearer is the state a release returns to.
    public static let caughtCompletionThreshold: CGFloat = 0.5

    /// The release contract for a flight CAUGHT mid-air, where — unlike a
    /// grab from rest — a decisive flick wins in EITHER direction and a bare
    /// release is decided by WHERE THE FLIGHT WAS CAUGHT, not by the drag.
    ///
    /// `shouldCompleteDismissal` measures drag distance, which is right for a
    /// grab from rest: the viewer dragged the whole distance themselves, so
    /// the distance is their intent. A caught flight's distance is mostly the
    /// ANIMATION's, and the drag afterwards is exploration — the card in the
    /// hand, not a commitment. So below flick speed the outcome is the state
    /// the catch was nearer: caught early, the open had barely begun and a
    /// release puts it back; caught late, it was practically open and a
    /// release lets it land. Commitment against that default is expressed the
    /// only unambiguous way a caught flight offers — a flick, which wins in
    /// either direction regardless of anything else.
    public static func caughtReleaseCompletes(
        caughtAt caughtFraction: CGFloat,
        velocityTowardEnd: CGFloat,
        caughtThreshold: CGFloat = caughtCompletionThreshold,
        flickVelocity: CGFloat = flickVelocity
    ) -> Bool {
        if velocityTowardEnd >= flickVelocity { return true }
        if velocityTowardEnd <= -flickVelocity { return false }
        return caughtFraction >= caughtThreshold
    }
}
