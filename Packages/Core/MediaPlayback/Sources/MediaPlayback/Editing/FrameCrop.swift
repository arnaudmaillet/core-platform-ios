import CoreGraphics
import CoreImage

/// How much of a picture the author kept, and how far they straightened it.
///
/// ⚠️ **MOVED HERE FROM UPLOAD, WHERE IT WAS `MediaCrop`, AND UPLOAD STILL SAYS
/// `MediaCrop`** (a typealias) — for the reason `LookPreset` gives: a video's
/// crop is drawn by this package's compositor, which may not import a feature.
///
/// ⚠️ **NORMALISED, NEVER PIXELS.** The editor previews on a canvas-sized render
/// and the publish path bakes on a much larger one. A rectangle chosen in canvas
/// pixels would be the wrong rectangle at publish resolution. Fractions of the
/// picture survive both — and a video's frames, at yet another size.
///
/// ⚠️ **ORIGIN TOP-LEFT, AS UIKit READS IT — AND CORE IMAGE DOES NOT.** The crop
/// UI hands these down in view coordinates, so that is the convention stored.
/// Core Image's origin is bottom-left, so `applied(to:)` flips `rect` on its way
/// in. That conversion is silent when wrong — a top crop simply returns the
/// bottom of the picture — which is why `MediaCropTests` crops a two-colour image
/// rather than only checking that the dimensions changed.
public struct FrameCrop: Equatable, Sendable {
    /// The kept rectangle, in fractions of the **straightened** picture's
    /// bounding box: `(0,0)` is its top-left corner and `(1,1)` its
    /// bottom-right.
    ///
    /// ⚠️ **"OF THE SOURCE" IS TRUE ONLY AT ZERO DEGREES.** `applied(to:)` turns
    /// the picture FIRST and then cuts in fractions of `straightened.extent` —
    /// the upright box that CONTAINS the turned picture, which at any other angle
    /// is strictly larger than the source on both axes and carries four
    /// transparent corners. Upload's `MediaCropGeometry` is where the distinction
    /// is honoured, and `MediaCropGeometryTests` is what pins it.
    public var rect: CGRect

    /// Straightening, in degrees, **positive turns the picture clockwise** as the
    /// viewer sees it.
    ///
    /// ⚠️ THE SIGN IS A CONVENTION THIS FILE DECLARES, NOT ONE THE TESTS PROVE.
    /// The suite pins that a non-zero angle changes the bounds, and the direction
    /// itself is checked on screen.
    public var angle: CGFloat

    /// Whether the picture is shown as its own reflection, left for right.
    ///
    /// ⚠️ **A FLAG, NOT A NEGATIVE SCALE.** Every piece of crop arithmetic
    /// assumes a positive uniform scale; a reflection is the one transform that
    /// breaks it, so it is applied at one named moment on each side and nothing
    /// else has to know.
    ///
    /// ⚠️ **MIRRORED FIRST, THEN TURNED — ON BOTH SIDES.** `applied(to:)` reflects
    /// before it straightens, and the editing surface composes its transform in
    /// the same order. Reversing either one alone puts the reflection about a
    /// different axis, and the result is a photograph, not an error.
    public var isMirrored: Bool

    public init(
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        angle: CGFloat = 0,
        isMirrored: Bool = false
    ) {
        self.rect = rect
        self.angle = angle
        self.isMirrored = isMirrored
    }

    /// The whole picture, unturned and unreflected: the absence of a crop rather
    /// than a crop that does nothing, so a renderer can hand the source straight
    /// back.
    public static let untouched = FrameCrop()

    public var isUntouched: Bool { self == .untouched }

    /// The graph that mirrors, straightens and cuts an UPRIGHT picture. Builds a
    /// graph and renders nothing.
    ///
    /// Nil when the kept rectangle is degenerate — under a pixel on either axis
    /// — or the picture has no finite extent. An untouched crop returns `image`
    /// itself.
    ///
    /// ⚠️ **THE RESULT STARTS AT THE ORIGIN, TO WITHIN A PIXEL.** A compositor
    /// draws into `(0, 0, renderWidth, renderHeight)`, so the cut is moved back
    /// there — by WHOLE pixels only. A fractional shift would resample every
    /// pixel of a photograph that is merely cut, and the photo path renders
    /// `from: extent` anyway, so the sub-pixel remainder moves nothing it draws.
    public func applied(to image: CIImage) -> CIImage? {
        guard !isUntouched else { return image }
        // ⚠️ REFLECTED BEFORE ANYTHING ELSE — see `isMirrored`.
        let facing = isMirrored
            ? image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            : image

        let straightened: CIImage
        if angle == 0 {
            straightened = facing
        } else {
            // ⚠️ NEGATED. Core Image's y axis points up, so a positive rotation
            // there turns the image anticlockwise — the opposite of the clockwise
            // convention `angle` declares.
            let radians = -angle * .pi / 180
            straightened = facing.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        let extent = straightened.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return nil }

        // ⚠️ **THE Y FLIP.** `rect` measures down from the top; `extent` measures
        // up from the bottom. Taking `rect.origin.y` straight would return the
        // mirror of what the author kept — a failure that looks like a picture,
        // not like an error.
        let kept = CGRect(
            x: extent.minX + rect.minX * extent.width,
            y: extent.minY + (1 - rect.maxY) * extent.height,
            width: rect.width * extent.width,
            height: rect.height * extent.height
        )
        let cut = straightened.cropped(to: kept)
        guard cut.extent.width >= 1, cut.extent.height >= 1 else { return nil }
        return cut.transformed(by: CGAffineTransform(
            translationX: -cut.extent.minX.rounded(.down), y: -cut.extent.minY.rounded(.down)
        ))
    }

    /// How many pixels the kept picture has, for an upright picture of `size`:
    /// the straightened bounding box times the kept fractions, rounded to an
    /// even number on each axis — video encoders want even sides — and never
    /// under two.
    public func outputSize(forUpright size: CGSize) -> CGSize {
        let turned = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: angle * .pi / 180))
        func even(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 2 }
            return max(2, (value / 2).rounded() * 2)
        }
        return CGSize(
            width: even(abs(turned.width) * rect.width),
            height: even(abs(turned.height) * rect.height)
        )
    }
}
