import CoreGraphics

/// Where a re-grab picks up a card the cancel spring is carrying home (#2362).
///
/// Grab, let go short, grab again: the second grab used to wait for the first
/// cancel to finish and then start from the page at full screen, dip, and
/// shrink — the jump the owner felt on every quick cycle. It now catches the
/// card where it IS, its presented pose, and the drag carries on from there.
///
/// The pose a cancel spring presents is not on the drag's own curves: the
/// spring moves position and size together, linearly in one clock, while the
/// drag bands the position and eases the size. So a caught pose is read back
/// into the drag's terms here:
///
/// - **Position** is exact: the presented offset run backwards through the
///   rubber band gives the translation the drag continues from, so the card
///   stays under the finger with no step.
/// - **Size** is exact at the catch and rejoins the curve as the finger
///   moves: `easeOffset` is the gap between the caught shrink and the curve's
///   at that translation, and it fades out linearly toward both ends — none
///   at the page (the card is whole again there), none at the full span (the
///   floor). Every other channel the drag drives is a function of the same
///   shrink — corners, dim, presenter depth, the destination, UIKit's percent
///   — and the cancel spring moved each of them linearly in it too, so one
///   number catches them all.
struct ZoomGrabCatch: Equatable {
    /// The drag translation the caught position stands for.
    let translation: CGPoint
    /// The progress (`ZoomTransitionGeometry.dismissProgress`) of that
    /// translation along the grab's axis.
    let progress: CGFloat
    /// The caught shrink minus the curve's at `progress`.
    let easeOffset: CGFloat

    /// A grab from rest: nothing to continue from.
    static let none = ZoomGrabCatch(translation: .zero, progress: 0, easeOffset: 0)

    init(translation: CGPoint, progress: CGFloat, easeOffset: CGFloat) {
        self.translation = translation
        self.progress = progress
        self.easeOffset = easeOffset
    }

    /// Reads a presented pose back into the drag's terms.
    /// - Parameters:
    ///   - offset: the card's presented centre minus the page's centre.
    ///   - scale: the card's presented width over the page's.
    ///   - axis: the grab's axis, kept from the grab that was let go.
    ///   - span: the axis's span (`ZoomDismissAxis.span(of:)`).
    init(offset: CGPoint, scale: CGFloat, axis: ZoomDismissAxis, span: CGFloat) {
        let bandedAlong = axis.along(offset)
        let alongLimit = bandedAlong >= 0
            ? ZoomTransitionGeometry.forwardDragLimit(forSpan: span)
            : ZoomTransitionGeometry.backDragLimit
        let travel = ZoomTransitionGeometry.inverseRubberBand(bandedAlong, limit: alongLimit)
        let drift = ZoomTransitionGeometry.inverseRubberBand(
            axis.across(offset), limit: ZoomTransitionGeometry.crossDriftLimit
        )
        let caughtProgress = ZoomTransitionGeometry.dismissProgress(translation: travel, span: span)
        self.translation = axis.offset(along: travel, across: drift)
        self.progress = caughtProgress
        self.easeOffset = ZoomDismissInteractionController.grabEase(forScale: scale)
            - ZoomDismissInteractionController.grabEase(at: caughtProgress)
    }

    /// The shrink for a drag progress, continuing from the catch: the caught
    /// shrink at the caught progress, the curve's at both ends.
    func ease(at dragProgress: CGFloat) -> CGFloat {
        let onCurve = ZoomDismissInteractionController.grabEase(at: dragProgress)
        guard easeOffset != 0 else { return onCurve }
        return onCurve + easeOffset * weight(at: dragProgress)
    }

    /// How much of a gap measured at the catch is still owed at a drag
    /// progress: all of it at the caught progress, none at the page or at
    /// the full span, linear between.
    func weight(at dragProgress: CGFloat) -> CGFloat {
        let clamped = min(max(dragProgress, 0), 1)
        if clamped <= progress {
            return progress > 0 ? clamped / progress : 1
        }
        return progress < 1 ? (1 - clamped) / (1 - progress) : 0
    }
}
