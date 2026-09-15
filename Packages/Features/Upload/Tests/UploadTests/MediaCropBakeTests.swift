import Testing
import UIKit
@testable import Upload

/// The one seam neither `MediaCropGeometryTests` nor `MediaCropTests` can see on
/// its own: that the rectangle the author framed on screen and the pixels that
/// get baked are the same rectangle.
///
/// ⚠️ **TWO CORRECT FILES CAN STILL DISAGREE, AND NOTHING WOULD SAY SO.**
/// `MediaCropGeometry` is proven against its own arithmetic and
/// `MediaCropRenderer` against its own; each is internally consistent under a
/// convention it states, and a mismatch BETWEEN the two conventions — a y
/// measured from the wrong edge, a denominator that is the source rather than
/// the turned bounding box, a rotation spent the other way — produces a
/// photograph, not an error. So this suite composes them end to end and asks the
/// only question that matters: **the box was over the red half, is what came back
/// red?** At a non-zero angle, where every one of those mistakes stops being
/// invisible.
struct MediaCropBakeTests {
    private static let source = CGSize(width: 400, height: 300)
    private static let surface = CGRect(x: 0, y: 0, width: 390, height: 500)

    /// Red on the LEFT, blue on the right — a colour that can only come from one
    /// side of the picture.
    private func redBesideBlue() -> UIImage {
        UIGraphicsImageRenderer(size: Self.source).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.source.width / 2, height: Self.source.height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: Self.source.width / 2, y: 0,
                                width: Self.source.width / 2, height: Self.source.height))
        }
    }

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

    /// A small box on the surface, centred over the point `local` of the picture
    /// — stated in the picture's own units so the caller can aim at a colour
    /// rather than at a coordinate.
    private func box(over local: CGPoint, side: CGFloat, placement: CropPlacement) -> CGRect {
        let arm = MediaCropGeometry.turned(
            CGPoint(x: local.x * placement.scale, y: local.y * placement.scale),
            by: placement.angle
        )
        let centre = CGPoint(x: placement.centre.x + arm.x, y: placement.centre.y + arm.y)
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    // MARK: - The question the whole feature turns on

    @Test func aBoxOverTheRedHalfBakesTheRedHalf() throws {
        let picture = redBesideBlue()
        let placement = CropPlacement(centre: CGPoint(x: 195, y: 250), scale: 1, angle: 10)
        // A 80pt box leaning ten degrees needs 80·(cos10+sin10) ≈ 92.7 of the
        // picture's own width; centred 100 in from the middle it spans local
        // x ∈ [-146, -54], comfortably inside the red half's [-200, 0].
        let framed = box(over: CGPoint(x: -100, y: 0), side: 80, placement: placement)

        #expect(MediaCropGeometry.covering(placement, source: Self.source, box: framed) == placement,
                "guard: the box must already sit on the picture, or this tests the clamp instead")

        let crop = MediaCropGeometry.crop(box: framed, placement: placement, source: Self.source)
        let baked = try #require(MediaCropRenderer.apply(crop, to: picture))
        let colour = average(baked)

        #expect(average(picture).r > 60 && average(picture).b > 60,
                "guard: the source must carry both colours")
        #expect(colour.r > colour.b + 60,
                "the box was over the red half: got r=\(colour.r) g=\(colour.g) b=\(colour.b), crop \(crop.rect)")
    }

    /// ⚠️ **THE MIRROR, THROUGH BOTH FILES AT ONCE.** The surface reflects with a
    /// negative x scale inside a UIKit transform; the renderer reflects with a
    /// Core Image transform in a y-up space, before rotating. Each is internally
    /// consistent under its own convention, and a mismatch between them shows up
    /// only as the wrong half of a photograph. Same placement and same box as the
    /// test above, reflected: the answer must be the OTHER colour.
    @Test func mirroringTheSamePlacementBakesTheOtherHalf() throws {
        let picture = redBesideBlue()
        let placement = CropPlacement(
            centre: CGPoint(x: 195, y: 250), scale: 1, angle: 10, isMirrored: true
        )
        let framed = box(over: CGPoint(x: -100, y: 0), side: 80, placement: placement)

        let crop = MediaCropGeometry.crop(box: framed, placement: placement, source: Self.source)
        let baked = try #require(MediaCropRenderer.apply(crop, to: picture))
        let colour = average(baked)

        #expect(crop.isMirrored, "guard: the reflection must survive into the crop")
        #expect(colour.b > colour.r + 60,
                "where the red half was, the blue half now is: r=\(colour.r) b=\(colour.b), crop \(crop.rect)")
    }

    /// The half that makes the line above mean something: move the box across the
    /// picture and the colour must change with it.
    @Test func aBoxOverTheBlueHalfBakesTheBlueHalf() throws {
        let picture = redBesideBlue()
        let placement = CropPlacement(centre: CGPoint(x: 195, y: 250), scale: 1, angle: 10)
        let framed = box(over: CGPoint(x: 100, y: 0), side: 80, placement: placement)

        let crop = MediaCropGeometry.crop(box: framed, placement: placement, source: Self.source)
        let baked = try #require(MediaCropRenderer.apply(crop, to: picture))
        let colour = average(baked)

        #expect(colour.b > colour.r + 60,
                "the box was over the blue half: got r=\(colour.r) g=\(colour.g) b=\(colour.b), crop \(crop.rect)")
    }

    /// ⚠️ **AND AT ZERO DEGREES TOO, BECAUSE THE TWO CASES FAIL DIFFERENTLY.** An
    /// upright crop catches a y measured from the wrong edge; only a leaning one
    /// catches a denominator that is the source instead of the turned bounding
    /// box. A suite with one of the two proves half the contract.
    @Test func anUprightBoxOverTheTopBakesTheTop() throws {
        let picture = UIGraphicsImageRenderer(size: Self.source).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.source.width, height: Self.source.height / 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: Self.source.height / 2,
                                width: Self.source.width, height: Self.source.height / 2))
        }
        let placement = CropPlacement(centre: CGPoint(x: 195, y: 250), scale: 1, angle: 0)
        let framed = box(over: CGPoint(x: 0, y: -80), side: 80, placement: placement)

        let crop = MediaCropGeometry.crop(box: framed, placement: placement, source: Self.source)
        let baked = try #require(MediaCropRenderer.apply(crop, to: picture))
        let colour = average(baked)

        #expect(colour.r > colour.b + 60,
                "a box above the middle is the top of the picture: got r=\(colour.r) b=\(colour.b)")
    }

    /// The shape of what is baked is the shape of the box, whatever the angle —
    /// the invariant the critique of this derivation asked for by name.
    @Test func theBakedPictureWearsTheBoxsProportions() throws {
        let picture = redBesideBlue()
        let placement = CropPlacement(centre: CGPoint(x: 195, y: 250), scale: 1, angle: 10)
        let framed = box(over: .zero, side: 0, placement: placement)
            .insetBy(dx: -60, dy: -40)   // 120 x 80, three to two

        let crop = MediaCropGeometry.crop(box: framed, placement: placement, source: Self.source)
        let baked = try #require(MediaCropRenderer.apply(crop, to: picture))
        let shape = baked.size.width / baked.size.height

        #expect(abs(shape - 120.0 / 80.0) < 0.02,
                "the box was 3:2, the picture came back \(shape): \(baked.size)")
    }
}
