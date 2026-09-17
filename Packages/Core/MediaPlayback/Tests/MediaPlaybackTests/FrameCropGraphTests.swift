import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MediaPlayback

/// **A CUT IS EXACTLY WHAT THE COMPOSITOR WILL RENDER.**
///
/// The compositor renders into `(0, 0, outputSize)` and the photo path renders
/// `from: extent`; they draw the same picture only if the cut's extent is that
/// very rectangle, on whole pixels. Upload's `MediaCropTests` pins WHICH part of
/// the picture is kept; this pins where it lands and how big it is.
struct FrameCropGraphTests {
    static let sizes = [CGSize(width: 400, height: 300), CGSize(width: 1001, height: 999), CGSize(width: 64, height: 36)]

    static let crops: [FrameCrop] = [
        FrameCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        FrameCrop(rect: CGRect(x: 0.137, y: 0.29, width: 0.611, height: 0.333)),
        FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), isMirrored: true),
        FrameCrop(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), angle: 10),
        FrameCrop(rect: CGRect(x: 0.1, y: 0.2, width: 0.73, height: 0.51), angle: -7.3, isMirrored: true),
        FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 90),
        FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 180),
        FrameCrop(rect: CGRect(x: 0.2, y: 0, width: 0.6, height: 1), angle: 270),
        FrameCrop(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), angle: -90, isMirrored: true),
        FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 33)
    ]

    @Test(arguments: FrameCropGraphTests.crops, FrameCropGraphTests.sizes)
    func aCutIsExactlyItsOutputSizeAtTheOrigin(_ crop: FrameCrop, _ size: CGSize) throws {
        let picture = TestPicture.flat(200, 100, 50, width: Int(size.width), height: Int(size.height))
        let cut = try #require(crop.applied(to: picture), "\(crop) cut nothing from \(size)")
        let expected = CGRect(origin: .zero, size: crop.outputSize(forUpright: size))

        #expect(cut.extent == expected, "\(crop) of \(size) came back \(cut.extent), not \(expected)")
        #expect(Int(expected.width) % 2 == 0 && Int(expected.height) % 2 == 0, "sides are even: \(expected)")
    }

    /// ⚠️ **A MERELY CUT PICTURE IS NEVER RESAMPLED.** Every pixel of an
    /// upright cut is a pixel of the source, at a whole-pixel offset — even
    /// when the author's fractions land between pixels.
    @Test(arguments: LookSurface.allCases)
    func anUprightCutCopiesWholePixels(_ surface: LookSurface) throws {
        // Every pixel a colour of its own.
        let picture = TestPicture.make(width: 101, height: 77) { x, y in ((x * 7) % 256, (y * 11) % 256, (x * y) % 256) }
        let crop = FrameCrop(rect: CGRect(x: 0.2137, y: 0.3411, width: 0.5213, height: 0.4077))
        let cut = try #require(crop.applied(to: picture))
        let source = surface.draw(picture)
        let drawn = surface.draw(cut)

        // Where the cut came from, found by its first pixel.
        let corner = drawn.rgb(0, 0)
        let origins = (0..<source.width).flatMap { x in (0..<source.height).map { (x, $0) } }
            .filter { source.rgb($0.0, $0.1) == corner }
        let (dx, dy) = try #require(origins.first, "the cut's corner \(corner) is no pixel of the source")
        #expect(origins.count == 1, "guard: the source's colours are unique enough, \(origins)")
        for x in 0..<drawn.width {
            for y in 0..<drawn.height where drawn.rgb(x, y) != source.rgb(x + dx, y + dy) {
                Issue.record("(\(x),\(y)) is \(drawn.rgb(x, y)), the source's (\(x + dx),\(y + dy)) is \(source.rgb(x + dx, y + dy))")
                return
            }
        }
        // The framed rectangle starts 0.2137 × 101 = 21.6 across and, measured
        // up from the bottom, (1 - 0.7488) × 77 = 19.3 up.
        #expect(abs(dx - 22) <= 1 && abs(dy - 19) <= 1, "the cut starts where the author framed it: \(dx),\(dy)")
    }
}
