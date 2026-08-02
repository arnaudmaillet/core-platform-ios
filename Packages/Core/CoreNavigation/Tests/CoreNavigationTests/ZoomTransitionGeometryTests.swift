import CoreGraphics
@testable import CoreNavigation
import Testing

struct ZoomTransitionGeometryTests {
    @Test func sharedReleaseContractDefaults() {
        // Both dismissals (pin grab, timeline slide) release on these; a tune
        // here is a deliberate, app-wide decision.
        #expect(ZoomTransitionGeometry.completionThreshold == 0.35)
        #expect(ZoomTransitionGeometry.flickVelocity == 900)
    }

    @Test func centeredFallbackIsASquareAtTheMiddle() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rect = ZoomTransitionGeometry.centeredFallback(in: bounds, side: 56)
        #expect(rect.width == 56)
        #expect(rect.height == 56)
        #expect(rect.midX == bounds.midX)
        #expect(rect.midY == bounds.midY)
    }

    @Test func dismissProgressIsFractionOfSpan() {
        #expect(ZoomTransitionGeometry.dismissProgress(translation: 100, span: 400) == 0.25)
        #expect(ZoomTransitionGeometry.dismissProgress(translation: 200, span: 400) == 0.5)
    }

    @Test func dismissProgressClampsAndIgnoresBackwardOrZeroSpan() {
        // Past the far edge → clamped to 1.
        #expect(ZoomTransitionGeometry.dismissProgress(translation: 900, span: 400) == 1)
        // Drag against the dismiss direction → no progress.
        #expect(ZoomTransitionGeometry.dismissProgress(translation: -100, span: 400) == 0)
        // Degenerate span → safe zero, no divide-by-zero.
        #expect(ZoomTransitionGeometry.dismissProgress(translation: 100, span: 0) == 0)
    }

    @Test func rubberBandFollowsCloselyNearTheOriginAndPreservesSign() {
        // Small drags pass nearly 1:1 (slope 1 at the origin)...
        let small = ZoomTransitionGeometry.rubberBand(10, limit: 140)
        #expect(small > 9 && small <= 10)
        // ...and the sign follows the drag direction.
        #expect(ZoomTransitionGeometry.rubberBand(-10, limit: 140) == -small)
    }

    @Test func rubberBandIsMonotonicAndAsymptoticToTheLimit() {
        let mid = ZoomTransitionGeometry.rubberBand(140, limit: 140)
        let far = ZoomTransitionGeometry.rubberBand(10_000, limit: 140)
        #expect(mid == 70) // at offset == limit, exactly half the cap
        #expect(far > mid)
        #expect(far < 140) // never reaches the cap
        #expect(ZoomTransitionGeometry.rubberBand(100, limit: 0) == 0)
    }

    @Test func releaseCompletesPastTheProgressThreshold() {
        #expect(ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: 0.35, velocity: 0, progressThreshold: 0.35, flickVelocity: 900
        ))
        #expect(!ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: 0.34, velocity: 0, progressThreshold: 0.35, flickVelocity: 900
        ))
    }

    @Test func releaseCompletesOnAForwardFlickRegardlessOfDistance() {
        #expect(ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: 0.05, velocity: 1200, progressThreshold: 0.35, flickVelocity: 900
        ))
        // A backward (negative) flick never completes a short drag.
        #expect(!ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: 0.05, velocity: -1200, progressThreshold: 0.35, flickVelocity: 900
        ))
    }
}

/// The grab's scale channel had a 180ms hole in it: the detach dip animated to
/// a constant while the drag interpolated a curve, so every point the finger
/// travelled during the dip accumulated with nothing applying it, and the first
/// ungated pan event discharged the lot in one frame. Measured on a scripted
/// grab, the card's height fell 830pt to 774pt between two frames against
/// ~5.5pt/frame either side.
///
/// The fix is structural — one curve, shared by the dip and the drag — and
/// these pin the curve's shape so a future edit cannot reintroduce a second
/// definition that disagrees at the seam.
@MainActor
struct GrabScaleCurveTests {
    /// The dip's endpoint and the drag's starting value must be THE SAME
    /// number, arrived at through the same function. The old code stated this
    /// as a comment ("its endpoint is this function at progress 0") while the
    /// two sides computed it separately.
    @Test func theCurveStartsAtTheDetachScale() {
        #expect(ZoomDismissInteractionController.grabScale(at: 0) == ZoomFlight.detachScale)
    }

    /// Monotonic and continuous: no step anywhere the finger can put it.
    @Test func theCurveNeverSteps() {
        var previous = ZoomDismissInteractionController.grabScale(at: 0)
        for step in 1...1000 {
            let scale = ZoomDismissInteractionController.grabScale(at: CGFloat(step) / 1000)
            #expect(scale <= previous + 1e-9, "the curve rose at \(step)")
            // The whole curve spans 0.35 over 1000 samples; anything an order of
            // magnitude above the even rate is a step.
            #expect(previous - scale < 0.01, "a step of \(previous - scale) at \(step)")
            previous = scale
        }
    }

    /// A held card stays recognisably the page — the clamp is what stops it
    /// shrinking to thumbnail size under the hand.
    @Test func theCurveClampsAtTheMinimum() {
        #expect(ZoomDismissInteractionController.grabScale(at: 1) == ZoomFlight.minimumGrabScale)
        #expect(ZoomDismissInteractionController.grabScale(at: 4) == ZoomFlight.minimumGrabScale)
    }
}
