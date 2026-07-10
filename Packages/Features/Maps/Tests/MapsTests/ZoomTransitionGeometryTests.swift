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

    @Test func collapseTransformRendersTheCardExactlyOntoThePin() {
        let full = CGRect(x: 0, y: 0, width: 390, height: 844)
        let pin = CGRect(x: 120, y: 300, width: 56, height: 56)

        let t = ZoomTransitionGeometry.collapseTransform(of: full, onto: pin)

        // UIKit applies `view.transform` about the (default, centered) anchor:
        // the rendered size is bounds scaled by (a, d), and the rendered center
        // is the view's center displaced by (tx, ty). Both must land on the pin.
        let rendered = CGRect(
            x: full.midX + t.tx - full.width * t.a / 2,
            y: full.midY + t.ty - full.height * t.d / 2,
            width: full.width * t.a,
            height: full.height * t.d
        )
        #expect(abs(rendered.minX - pin.minX) < 1e-9)
        #expect(abs(rendered.minY - pin.minY) < 1e-9)
        #expect(abs(rendered.width - pin.width) < 1e-9)
        #expect(abs(rendered.height - pin.height) < 1e-9)
    }

    @Test func collapseTransformOfZeroSizedRectFallsBackToIdentity() {
        let t = ZoomTransitionGeometry.collapseTransform(
            of: .zero,
            onto: CGRect(x: 10, y: 10, width: 56, height: 56)
        )
        #expect(t == .identity)
    }
}
