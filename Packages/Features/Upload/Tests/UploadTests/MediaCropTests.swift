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

    /// ⚠️ `UIImage(cgImage:)` ALONE LANDS AT SCALE 1, which doubles a Retina
    /// thumbnail's apparent size. `MediaFilterRenderer` carries the same note.
    ///
    /// ⚠️ **AND THIS TEST USED TO DEMAND THE OPPOSITE OF THE TRUTH ABOUT THE
    /// ORIENTATION.** It asserted `cut.imageOrientation == .right` — "orientation
    /// carried" — which is right for a FILTER, where the geometry is untouched
    /// and the flag still describes the buffer. A crop is not that: the renderer
    /// now spends the camera's turn before cutting, because `CIImage(image:)`
    /// reads the buffer and ignores the flag, so a crop taken in buffer space is
    /// a crop of somewhere else (measured: a half cut of a `.right` two-colour
    /// picture came back holding both colours, r=128 b=127). Once the turn is
    /// spent the buffer really is upright, and stamping `.right` back on would
    /// turn the photograph a second time. `.up` is the honest answer, and
    /// `keepingTheTopOfASidewaysPhotographReturnsItsTop` is the colour that says
    /// the picture itself is the right one.
    @Test func theRenderKeepsTheScaleAndSpendsTheCamerasTurn() throws {
        let base = redOverBlue()
        let sideways = UIImage(cgImage: try #require(base.cgImage), scale: 3, orientation: .right)

        let cut = try #require(
            MediaCropRenderer.apply(MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)), to: sideways)
        )

        #expect(cut.scale == 3, "scale carried: \(cut.scale)")
        #expect(cut.imageOrientation == .up, "the turn is spent, not carried: \(cut.imageOrientation.rawValue)")
    }

    /// The witness for the line above: an already-upright picture is not redrawn
    /// on the way through, so the cheap path is still the common one.
    @Test func anUprightPictureIsNotTurnedAtAll() throws {
        let source = redOverBlue()

        let cut = try #require(
            MediaCropRenderer.apply(MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)), to: source)
        )

        #expect(source.imageOrientation == .up, "guard: the source must start upright")
        #expect(cut.imageOrientation == .up)
    }

    // MARK: - The reflection

    @Test func mirroringPutsTheLeftHalfOnTheRight() throws {
        let source = redBesideBlue()
        let leftHalf = MediaCrop(
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), isMirrored: true
        )

        let cut = try #require(MediaCropRenderer.apply(leftHalf, to: source))
        let colour = average(cut)

        #expect(colour.b > colour.r + 60,
                "the left of a mirrored picture is its right half: r=\(colour.r) b=\(colour.b)")
    }

    /// The witness: the same rectangle without the reflection. Without it the line
    /// above would pass on a renderer that had simply cut the wrong half.
    @Test func andWithoutTheMirrorItIsStillTheLeftHalf() throws {
        let source = redBesideBlue()
        let leftHalf = MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))

        let cut = try #require(MediaCropRenderer.apply(leftHalf, to: source))
        let colour = average(cut)

        #expect(colour.r > colour.b + 60, "r=\(colour.r) b=\(colour.b)")
    }

    /// ⚠️ **MIRROR THEN TURN, NOT TURN THEN MIRROR — AND THE TWO ARE DIFFERENT
    /// PICTURES.** Reflecting a quarter-turned picture reflects it about the axis
    /// the TURN left pointing sideways, which is the other axis entirely. Red in
    /// the top-left quarter, mirrored and then turned clockwise, lands
    /// bottom-right; turned and then mirrored it would land top-left. Nothing but
    /// a colour can tell them apart, and the surface composes its own transform in
    /// the order this pins.
    @Test func theReflectionHappensBeforeTheTurn() throws {
        let corner = UIGraphicsImageRenderer(
            size: CGSize(width: Self.side, height: Self.side)
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side / 2))
        }
        let bottomRight = MediaCrop(
            rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), angle: 90, isMirrored: true
        )
        let topLeft = MediaCrop(
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), angle: 90, isMirrored: true
        )

        let landed = average(try #require(MediaCropRenderer.apply(bottomRight, to: corner)))
        let didNot = average(try #require(MediaCropRenderer.apply(topLeft, to: corner)))

        #expect(landed.r > landed.b + 60,
                "mirrored first, the corner ends bottom right: r=\(landed.r) b=\(landed.b)")
        #expect(didNot.b > didNot.r + 60,
                "and not top left, which is where turning first would have put it: r=\(didNot.r) b=\(didNot.b)")
    }

    @Test func aMirroredPictureIsNotAnUntouchedOne() {
        let mirrored = MediaCrop(isMirrored: true)

        #expect(!mirrored.isUntouched, "a reflection is a change: \(mirrored)")
        #expect(MediaCrop().isUntouched, "and the witness: nothing chosen is nothing done")
    }

    // MARK: - Which way it turns

    /// ⚠️ **THE DIRECTION THIS FILE SAYS IT CANNOT CHECK — CHECKED.** Both
    /// `MediaCrop.angle`'s comment and `straighteningGrowsTheBoundingBox` below
    /// disclaim any coverage of the SIGN: *"if a future change makes straightening
    /// go the wrong way, no test here will catch it — look at the picture"*. That
    /// is true at a small angle, where reading a direction out of resampled pixels
    /// is guesswork. It stops being true at a QUARTER TURN, where the mapping is
    /// exact and a colour can only have come from one corner.
    ///
    /// Red in the TOP-LEFT quarter. Turned clockwise, that corner lands
    /// top-RIGHT; turned the other way it lands bottom-LEFT. So a crop of the
    /// rotated picture's top-right quarter is red if and only if `angle` means
    /// clockwise, which is what the type declares and what the editor's dial
    /// shows on screen.
    @Test func aPositiveAngleTurnsThePictureClockwise() throws {
        let corner = UIGraphicsImageRenderer(
            size: CGSize(width: Self.side, height: Self.side)
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side / 2))
        }
        let topRightAfterAQuarterTurn = MediaCrop(
            rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), angle: 90
        )

        let cut = try #require(MediaCropRenderer.apply(topRightAfterAQuarterTurn, to: corner))
        let colour = average(cut)

        #expect(average(corner).b > 60, "guard: the source must really be mostly blue")
        #expect(colour.r > colour.b + 60,
                "clockwise carries the red top-left corner to the top right: r=\(colour.r) b=\(colour.b)")
    }

    /// The witness: the same corner, asked for where it would be had the turn
    /// gone the other way. It must NOT be red — otherwise the test above would
    /// pass on a renderer that returned red for every quarter.
    @Test func andNotAnticlockwise() throws {
        let corner = UIGraphicsImageRenderer(
            size: CGSize(width: Self.side, height: Self.side)
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side / 2))
        }
        let whereAnticlockwiseWouldHavePutIt = MediaCrop(
            rect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), angle: 90
        )

        let cut = try #require(MediaCropRenderer.apply(whereAnticlockwiseWouldHavePutIt, to: corner))
        let colour = average(cut)

        #expect(colour.b > colour.r + 60,
                "the bottom left is where the corner did NOT go: r=\(colour.r) b=\(colour.b)")
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

    // MARK: - The orientation the camera recorded

    /// ⚠️ **A PHOTOGRAPH OFF A CAMERA IS RARELY `.up`, AND THE FLAG ALONE IS NOT
    /// THE PICTURE.** `CIImage(image:)` reads `image.cgImage` — the raw buffer —
    /// while everything the author saw was drawn through `imageOrientation`. If
    /// the renderer cuts in buffer space and stamps the old flag back on, a crop
    /// of the sky returns the side of the frame: right dimensions, right flag,
    /// wrong photograph. `theRenderKeepsTheSourcesScaleAndOrientation` pins the
    /// FLAG and cannot see this; only a colour can.
    @Test func keepingTheTopOfASidewaysPhotographReturnsItsTop() throws {
        // Red over blue in the buffer, then declared `.right`: drawn, the picture
        // turns a quarter turn clockwise, so what the VIEWER sees on top is the
        // buffer's LEFT edge. A renderer that ignored the flag would hand back
        // the buffer's top — red — for a crop the viewer aimed at something else.
        let buffer = UIGraphicsImageRenderer(size: CGSize(width: Self.side, height: Self.side)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side))
            UIColor.blue.setFill()
            context.fill(CGRect(x: Self.side / 2, y: 0, width: Self.side / 2, height: Self.side))
        }
        let sideways = try #require(buffer.cgImage.map {
            UIImage(cgImage: $0, scale: buffer.scale, orientation: .right)
        })
        let crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5))

        let cut = try #require(MediaCropRenderer.apply(crop, to: sideways))
        let colour = average(cut)

        #expect(average(buffer).r > 60 && average(buffer).b > 60,
                "guard: the buffer must carry both colours, or nothing below can fail")
        #expect(colour.r > colour.b + 60,
                "a quarter turn clockwise puts the buffer's red LEFT edge on top: got r=\(colour.r) g=\(colour.g) b=\(colour.b)")
    }

}
