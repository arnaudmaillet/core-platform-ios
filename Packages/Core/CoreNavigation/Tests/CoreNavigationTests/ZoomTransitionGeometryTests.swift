import CoreGraphics
import CoreNavigation
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
