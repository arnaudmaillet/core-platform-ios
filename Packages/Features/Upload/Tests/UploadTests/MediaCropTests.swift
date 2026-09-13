import Testing
import UIKit
@testable import Upload

/// Cutting and straightening a picture.
///
/// ⚠️ **THE TESTS THAT MATTER HERE ARE THE TWO-COLOUR ONES, NOT THE DIMENSIONS.**
/// `MediaCrop` stores its rectangle origin-top-left the way UIKit reads one, while
/// Core Image measures up from the bottom. Get that flip wrong and a crop of the
/// sky returns the ground: the dimensions are right, the render succeeds, and the
/// only symptom is a picture the author did not choose. A suite that asserted
/// only `width == half` would pass on exactly that bug, which is why each axis is
/// pinned with a colour that can only come from one end of the source.
struct MediaCropTests {
    private static let side: CGFloat = 40

    /// Red on TOP, blue underneath — `UIGraphicsImageRenderer` draws origin
    /// top-left, so the first rectangle filled is the one the viewer sees first.
    private func redOverBlue() -> UIImage {
        let size = CGSize(width: Self.side, height: Self.side)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
    }

    /// Red on the LEFT, blue on the right.
    private func redBesideBlue() -> UIImage {
        let size = CGSize(width: Self.side, height: Self.side)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// The whole picture averaged into one pixel, so "which half is this?" has a
    /// numeric answer rather than an opinion.
    private func average(_ image: UIImage) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cg = image.cgImage,
              let context = CGContext(
                  data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return (0, 0, 0) }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    // MARK: - The axis that silently lies

    @Test func keepingTheTopHalfReturnsTheTopHalf() throws {
        let source = redOverBlue()
        let crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5))

        let cut = try #require(MediaCropRenderer.apply(crop, to: source))
        let colour = average(cut)

        #expect(average(source).r > 60 && average(source).b > 60,
                "guard: the source must really carry BOTH colours, or neither test can fail")
        #expect(colour.r > colour.b + 60,
                "the top half is red: got r=\(colour.r) g=\(colour.g) b=\(colour.b)")
    }

    /// ⚠️ **THE OTHER HALF OF THE PAIR.** A renderer that ignored `rect.origin.y`
    /// entirely would pass the test above whenever it returned the top; only
    /// asking for the bottom separates "reads the origin" from "always cuts from
    /// the top".
    @Test func keepingTheBottomHalfReturnsTheBottomHalf() throws {
        let source = redOverBlue()
        let crop = MediaCrop(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))

        let cut = try #require(MediaCropRenderer.apply(crop, to: source))
        let colour = average(cut)

        #expect(colour.b > colour.r + 60,
                "the bottom half is blue: got r=\(colour.r) g=\(colour.g) b=\(colour.b)")
    }

    @Test func keepingTheLeftHalfReturnsTheLeftHalf() throws {
        let source = redBesideBlue()
        let crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))

        let cut = try #require(MediaCropRenderer.apply(crop, to: source))
        let colour = average(cut)

        #expect(colour.r > colour.b + 60,
                "the left half is red: got r=\(colour.r) g=\(colour.g) b=\(colour.b)")
    }

    @Test func keepingTheRightHalfReturnsTheRightHalf() throws {
        let source = redBesideBlue()
        let crop = MediaCrop(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

        let cut = try #require(MediaCropRenderer.apply(crop, to: source))
        let colour = average(cut)

        #expect(colour.b > colour.r + 60,
                "the right half is blue: got r=\(colour.r) g=\(colour.g) b=\(colour.b)")
    }

    // MARK: - Identity, and the witness that makes it mean something

    /// ⚠️ **PAIRED ON PURPOSE.** "An untouched crop changes nothing" is also true
    /// of a renderer that never does anything at all. The second half proves the
    /// renderer can change a picture, so the first half says something.
    @Test func anUntouchedCropHandsTheSourceStraightBack() throws {
        let source = redOverBlue()

        let same = MediaCropRenderer.apply(.untouched, to: source)
        #expect(same === source, "the very same object: no render, no GPU cost")

        let half = try #require(
            MediaCropRenderer.apply(MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)), to: source)
        )
        #expect(half !== source, "witness: a real crop does produce a new picture")
        #expect(half.cgImage!.height < source.cgImage!.height,
                "witness: and a shorter one — \(half.cgImage!.height) vs \(source.cgImage!.height)")
    }

    @Test func halvingTheWidthHalvesThePixels() throws {
        let source = redBesideBlue()
        let wide = try #require(source.cgImage?.width)

        let cut = try #require(
            MediaCropRenderer.apply(MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)), to: source)
        )

        let narrow = try #require(cut.cgImage?.width)
        #expect(abs(narrow - wide / 2) <= 1, "half the pixels across: \(narrow) vs \(wide)")
    }

    // MARK: - What travels with the render

    /// ⚠️ `UIImage(cgImage:)` ALONE LANDS AT SCALE 1 AND `.up`, which doubles a
    /// Retina thumbnail's apparent size and rotates anything the camera recorded
    /// sideways. `MediaFilterRenderer` carries the same note.
    @Test func theRenderKeepsTheSourcesScaleAndOrientation() throws {
        let base = redOverBlue()
        let sideways = UIImage(cgImage: try #require(base.cgImage), scale: 3, orientation: .right)

        let cut = try #require(
            MediaCropRenderer.apply(MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)), to: sideways)
        )

        #expect(cut.scale == 3, "scale carried: \(cut.scale)")
        #expect(cut.imageOrientation == .right, "orientation carried: \(cut.imageOrientation.rawValue)")
    }

    // MARK: - Straightening

    /// ⚠️ **THIS PINS THAT THE ANGLE DOES SOMETHING, NOT THAT IT TURNS THE RIGHT
    /// WAY.** Reading a direction out of rendered pixels is fragile, so the sign
    /// stays a declared convention checked on screen — see `MediaCrop.angle`. If
    /// straightening ever goes backwards, nothing in this file will notice.
    @Test func straighteningGrowsTheBoundingBox() throws {
        let source = redOverBlue()
        let square = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 0)
        let turned = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 20)

        #expect(square.isUntouched, "guard: the unturned case really is the identity")
        #expect(turned.isUntouched == false, "an angle alone makes a crop non-identity")

        let cut = try #require(MediaCropRenderer.apply(turned, to: source))
        let before = try #require(source.cgImage?.width)
        let after = try #require(cut.cgImage?.width)
        #expect(after > before, "a turned square needs a wider box: \(after) vs \(before)")
    }
}
