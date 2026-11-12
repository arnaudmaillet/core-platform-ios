import CoreGraphics
@testable import CoreNavigation
import Testing

struct ZoomTransitionGeometryTests {
    @Test func sharedReleaseContractDefaults() {
        // Both dismissals (pin grab, timeline slide) release on these; a tune
        // here is a deliberate, app-wide decision.
        #expect(ZoomTransitionGeometry.completionThreshold == 0.5)
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

/// The grab's scale curve (#2362): no zoom out at the grab, a gentle eased
/// shrink, the floor only at the full span.
///
/// Filmed against Instagram's Explore post, ours dropped to ~0.88 within a
/// few frames of the grab: a 0.95 detach dip at `.began`, then 0.35 of scale
/// per span, linear. The dip is gone and the curve is `progress²` of the way
/// to `minimumGrabScale`; these pin its shape — and, as before, that it is ONE
/// function, so a second definition cannot disagree with it at a seam (the
/// dip's once put a 56pt hole in the scale channel).
@MainActor
struct GrabScaleCurveTests {
    private typealias Grab = ZoomDismissInteractionController

    /// A grab at rest is the page, at its size: no detach dip.
    @Test func theCurveStartsAtTheFullPage() {
        #expect(Grab.grabScale(at: 0) == 1)
        #expect(Grab.grabEase(at: 0) == 0)
    }

    /// Flat at the start: the first ~60pt of a drag barely shrink the card,
    /// along either axis — it first just follows the finger.
    @Test func theCurveIsFlatAtTheStart() {
        let width: CGFloat = 402
        let height: CGFloat = 874
        let acrossTheWidth = Grab.grabScale(at: 60 / width)
        let downTheHeight = Grab.grabScale(at: 60 / height)
        #expect(acrossTheWidth > 0.99, "60pt across the width shrank the card to \(acrossTheWidth)")
        #expect(downTheHeight > 0.995, "60pt down the height shrank the card to \(downTheHeight)")
        // And flatter than a linear curve over the same floor, everywhere in
        // the first half.
        for step in 1..<50 {
            let progress = CGFloat(step) / 100
            let linear = 1 - (1 - ZoomFlight.minimumGrabScale) * progress
            #expect(Grab.grabScale(at: progress) > linear, "not eased at \(progress)")
        }
    }

    /// About 0.9 at half the span.
    @Test func theCurveIsAboutPointNineAtHalfTheSpan() {
        #expect(abs(Grab.grabScale(at: 0.5) - 0.9) < 0.005)
    }

    /// Monotonic and continuous: no step anywhere the finger can put it.
    @Test func theCurveNeverSteps() {
        var previous = Grab.grabScale(at: 0)
        for step in 1...1000 {
            let scale = Grab.grabScale(at: CGFloat(step) / 1000)
            #expect(scale <= previous + 1e-9, "the curve rose at \(step)")
            // The whole curve spans 0.4 over 1000 samples; its steepest slope
            // (at the full span) is 0.8 per unit, 0.0008 per sample.
            #expect(previous - scale < 0.001, "a step of \(previous - scale) at \(step)")
            previous = scale
        }
    }

    /// A held card stays recognisably the page — the clamp is what stops it
    /// shrinking to thumbnail size under the hand. It is reached only at the
    /// full span.
    @Test func theCurveClampsAtTheMinimum() {
        #expect(abs(Grab.grabScale(at: 1) - ZoomFlight.minimumGrabScale) < 1e-9)
        #expect(abs(Grab.grabScale(at: 4) - ZoomFlight.minimumGrabScale) < 1e-9)
        #expect(Grab.grabScale(at: 0.9) > ZoomFlight.minimumGrabScale + 0.07)
        #expect(Grab.grabScale(at: -1) == 1, "a back-drag grew the card")
    }

    /// Scale and shrink are one number read two ways: what a re-grab reads
    /// off a presented card is exactly what the drag would have posed.
    @Test func theShrinkRoundTripsThroughTheScale() {
        for step in 0...20 {
            let ease = CGFloat(step) / 20
            let scale = Grab.grabScale(forEase: ease)
            #expect(abs(Grab.grabEase(forScale: scale) - ease) < 1e-9)
        }
    }
}
