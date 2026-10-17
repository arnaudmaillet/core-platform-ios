import Testing
import UIKit
@testable import DesignSystem

/// Circular thumbnails aspect-fill (#1339): a picture that is not square is
/// cropped to the circle, never squeezed into it — the Profile tab's avatar
/// went oval-faced when avatars started coming from portrait photos.
@MainActor
struct CircularThumbnailTests {
    /// A 2:1 picture covering a square: drawn at the square's HEIGHT, its
    /// width overflowing equally on both sides.
    @Test func aWidePictureIsCroppedNotSqueezed() {
        let rect = UIImage.aspectFillRect(for: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 30, height: 30))
        #expect(rect.height == 30)
        #expect(rect.width == 60, "squeezed into the square")
        #expect(rect.midX == 15 && rect.midY == 15, "not centred")
    }

    @Test func aTallPictureIsCroppedNotSqueezed() {
        let rect = UIImage.aspectFillRect(for: CGSize(width: 90, height: 160), in: CGRect(x: 0, y: 0, width: 36, height: 36))
        #expect(rect.width == 36)
        #expect(abs(rect.height - 64) < 0.001)
        #expect(rect.midY == 18)
    }

    /// Rendered: a picture whose left and right thirds are red and whose
    /// middle third is blue fills the circle's middle with BLUE — the red
    /// edges fall outside, as aspect fill crops them. Squeezed, red would sit
    /// a quarter of the way in.
    @Test func theRenderedCircleKeepsTheCentre() throws {
        let stripes = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        let thumbnail = stripes.circularThumbnail(side: 30)
        #expect(thumbnail.size == CGSize(width: 30, height: 30))
        #expect(thumbnail.renderingMode == .alwaysOriginal)
        // A quarter in, on the middle row: blue when cropped, red when squeezed.
        let pixel = try #require(color(in: thumbnail, at: CGPoint(x: 8, y: 15)))
        #expect(pixel.blue > 0.8 && pixel.red < 0.2, "the picture was squeezed into the square")
    }

    private func color(in image: UIImage, at point: CGPoint) -> (red: CGFloat, blue: CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let scale = image.scale
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(
            x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale),
            width: CGFloat(cg.width), height: CGFloat(cg.height)
        ))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[2]) / 255)
    }
}
