import Testing
import UIKit
@testable import DesignSystem

/// The Points heart (#1128): the gradient once liked, the ink at rest, and
/// the heart's shape is what paints.
@MainActor
struct PointsHeartViewTests {
    /// The view's pixels at 1×, RGBA premultiplied-last, rows top-down.
    private struct Bitmap {
        let width: Int
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let i = (y * width + x) * 4
            let a = CGFloat(bytes[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (CGFloat(bytes[i]) / 255 / a, CGFloat(bytes[i + 1]) / 255 / a, CGFloat(bytes[i + 2]) / 255 / a, a)
        }
    }

    private func render(_ view: UIView) -> Bitmap {
        let side = 40
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.layoutIfNeeded()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // UIKit's top-down space.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            view.layer.render(in: context)
        }
        return Bitmap(width: side, bytes: bytes)
    }

    /// Liked: the system red (#1169, solid — two equal stops on the layer
    /// built for a gradient). At rest: the content's ink.
    @Test func likedDrawsTheRedAndRestTheInk() {
        let heart = PointsHeartView()
        heart.ink = .black
        #expect(heart.drawnColours.count == 2)
        #expect(Set(heart.drawnColours.map { $0.cgColor.components ?? [] }).count == 1, "at rest: one ink")
        heart.setLiked(true, animated: false)
        #expect(heart.drawnColours.count == 2)
        #expect(heart.drawnColours == Palette.pointsGradient(for: heart.traitCollection))
    }

    /// The SHAPE paints: the heart's middle carries the colour, a corner of
    /// its square nothing at all.
    @Test func theHeartIsTheMask() {
        let heart = PointsHeartView(configuration: AppSymbol.fixed(30, weight: .semibold))
        heart.setLiked(true, animated: false)
        let image = render(heart)
        let middle = image.pixel(20, 22)
        #expect(middle.a > 0.9, "nothing painted inside the heart")
        // Warm: red well above blue, as every stop of the gradient is.
        #expect(middle.r > middle.b + 0.2, "the heart is not the gradient: \(middle)")
        #expect(image.pixel(1, 1).a < 0.1, "the gradient leaked outside the heart")
    }

    @Test func itSizesToItsGlyph() {
        let heart = PointsHeartView(configuration: AppSymbol.fixed(15, weight: .semibold))
        let size = heart.intrinsicContentSize
        #expect(size == AppSymbol.like.image(AppSymbol.fixed(15, weight: .semibold))?.size)
    }

    @Test func likingTwiceChangesNothing() {
        let heart = PointsHeartView()
        heart.setLiked(true, animated: false)
        let colours = heart.drawnColours
        heart.setLiked(true, animated: true)
        #expect(heart.drawnColours == colours)
    }
}

/// The button's side (#1128): selected, the gradient heart stands for the
/// glyph; at rest there is none.
@MainActor
struct AppButtonPointsHeartTests {
    @Test func aSelectedLikeDrawsTheGradientHeart() {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol(PointsSymbol.glyph))
        button.drawsPointsHeart = true
        #expect(button.pointsHeart == nil, "at rest the glyph is the button's own")
        button.setSelected(true, animated: false)
        #expect(button.pointsHeart?.isLiked == true)
        button.frame = CGRect(x: 0, y: 0, width: 60, height: 30)
        button.layoutIfNeeded()
        #expect(button.pointsHeart?.frame.isEmpty == false)
        button.setSelected(false, animated: false)
        #expect(button.pointsHeart == nil)
    }

    @Test func offByDefault() {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol(PointsSymbol.glyph))
        button.setSelected(true, animated: false)
        #expect(button.pointsHeart == nil)
    }
}
