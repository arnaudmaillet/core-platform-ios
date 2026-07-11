import CoreGraphics
import Testing
@testable import Maps

struct ZoomTransitionGeometryTests {
    @Test func centeredFallbackIsASquareAtTheMiddle() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rect = ZoomTransitionGeometry.centeredFallback(in: bounds, side: 56)
        #expect(rect.width == 56)
        #expect(rect.height == 56)
        #expect(rect.midX == bounds.midX)
        #expect(rect.midY == bounds.midY)
    }

    @Test func dismissProgressIsFractionOfHeight() {
        #expect(ZoomTransitionGeometry.dismissProgress(translationY: 200, viewHeight: 800) == 0.25)
        #expect(ZoomTransitionGeometry.dismissProgress(translationY: 400, viewHeight: 800) == 0.5)
    }

    @Test func dismissProgressClampsAndIgnoresUpwardOrZeroHeight() {
        // Past the bottom → clamped to 1.
        #expect(ZoomTransitionGeometry.dismissProgress(translationY: 2000, viewHeight: 800) == 1)
        // Upward drag → no dismissal progress.
        #expect(ZoomTransitionGeometry.dismissProgress(translationY: -100, viewHeight: 800) == 0)
        // Degenerate height → safe zero, no divide-by-zero.
        #expect(ZoomTransitionGeometry.dismissProgress(translationY: 100, viewHeight: 0) == 0)
    }

}
