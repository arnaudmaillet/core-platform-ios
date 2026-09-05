import CoreGraphics
import Foundation
import Lottie
import QuartzCore

/// Renders Lottie frames to bitmaps, offline.
///
/// The main-thread rendering engine is REQUIRED here, not preferred. The
/// Core Animation engine expresses the animation as CA animations on a layer
/// tree and reads its state from the render server, so `currentFrame` does not
/// change what `render(in:)` flattens — every frame would come out identical and
/// the sheet would be 24 copies of frame zero. Nothing about that failure looks
/// like an error.
@MainActor
final class Rasteriser {

    private let layer: LottieAnimationLayer
    let sourceFrameCount: Double
    let inPoint: Double

    /// How artwork is fitted into a cell that will be clipped to a disc.
    enum Fit {
        /// Scale so the whole composition fits INSIDE the circle. Nothing is
        /// cut, and rectangular artwork loses 29% of its linear size — which is
        /// the honest price of putting a square picture on a round marker, and a
        /// reason to commission round artwork rather than to reuse stickers.
        case inscribe
        /// Fill the cell and let the disc clip. Correct only when the artwork is
        /// already round or its edges are expendable.
        case fill

        var factor: CGFloat { self == .inscribe ? 1 / 2.0.squareRoot() : 1 }
    }

    init(document: LottieDocument, side: Int, fit: Fit = .inscribe) throws {
        let animation = try LottieAnimation.from(data: document.rawJSON)
        layer = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.contentsScale = 1
        // `LottieAnimationLayer` has no `contentMode`; the fit is expressed as a
        // sublayer transform. Without it a composition authored at 512 square is
        // drawn at 512 into a 136 cell and the sheet is a crop of the middle —
        // which looks like framing, not like a bug.
        let width = animation.size.width, height = animation.size.height
        if width > 0, height > 0 {
            let scale = min(CGFloat(side) / width, CGFloat(side) / height) * fit.factor
            layer.sublayerTransform = CATransform3DConcat(
                CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeTranslation(
                    (CGFloat(side) - width * scale) / 2, (CGFloat(side) - height * scale) / 2, 0
                )
            )
        }
        inPoint = document.json["ip"] as? Double ?? 0
        sourceFrameCount = document.sourceFrameCount
    }

    func image(atProgress progress: Double, side: Int) -> CGImage? {
        layer.currentFrame = inPoint + sourceFrameCount * progress
        layer.layoutIfNeeded()
        layer.displayIfNeeded()

        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // ⚠️ FLIP. `CALayer.render(in:)` assumes the caller handed it a
        // UIKit/AppKit context — origin top-left, y growing downwards. A bare
        // `CGContext` is the opposite, so without this the whole sheet comes out
        // upside down and mirrored. It is obvious on artwork with text in it
        // (the taxi's "TAXI" reads backwards) and completely invisible on a
        // symmetric mark, which is most icons — so it would have shipped.
        //
        // Note this does NOT generalise: the app's own `AtlasCanvas` composites
        // with `CGContext.draw(image:in:)`, which handles orientation itself and
        // needs no flip. Adding one there was a real defect. The rule is the
        // call, not the context.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return context.makeImage()
    }
}
