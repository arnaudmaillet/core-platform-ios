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
    /// the picture FIRST and then cuts in fractions of the turned picture's
    /// bounding box — the upright box that CONTAINS it, which at any other angle
    /// is strictly larger than the source on both axes and carries four
    /// transparent corners. Upload's `MediaCropGeometry` is where the distinction
    /// is honoured, and `MediaCropGeometryTests` is what pins it.
    public var rect: CGRect

    /// Straightening, in degrees, **positive turns the picture clockwise** as the
    /// viewer sees it.
    ///
    /// ⚠️ THE SIGN IS A CONVENTION THIS FILE DECLARES — and a quarter turn,
    /// where a colour can only have come from one corner, is what proves it
    /// (Upload's `MediaCropTests.aPositiveAngleTurnsThePictureClockwise`).
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
    /// ⚠️ **THE RESULT IS EXACTLY `(0, 0, outputSize(forUpright:))`, ON WHOLE
    /// PIXELS.** A compositor renders into `(0, 0, renderWidth, renderHeight)`
    /// and the photo path renders `from: extent`; the two draw the same picture
    /// only if the cut's extent IS that rectangle. So the cut is taken on whole
    /// pixels, as wide as `outputSize` says (even sides), centred on what the
    /// author framed — at most a pixel off at each edge — and moved to the
    /// origin by whole pixels. A merely cut photograph is therefore never
    /// resampled.
    ///
    /// ⚠️ **AND THE FRACTIONS ARE OF THE EXACT TURNED BOX, NOT OF CORE IMAGE'S
    /// EXTENT.** Core Image rounds a turned picture's extent OUT to whole pixels
    /// — measured with Core Image on the Mac, 400×300 turned ten degrees
    /// reports 447×366 where the box is 446.02×364.90 — and
    /// `MediaCropGeometry` measures in the exact box.
    /// Cutting fractions of the rounded one aimed up to two pixels wide of what
    /// the author framed and left the cut a fraction of a pixel off the origin;
    /// measured, the photo then baked a picture of another size than the
    /// compositor renders (`MediaCropSharedGraphTests` compares the two).
    public func applied(to image: CIImage) -> CIImage? {
        guard !isUntouched else { return image }
        let source = image.extent
        guard !source.isInfinite, source.width > 0, source.height > 0 else { return nil }
        // ⚠️ REFLECTED BEFORE ANYTHING ELSE — see `isMirrored`.
        let facing = isMirrored
            ? image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            : image

        let straightened: CIImage
        let box: CGRect
        if angle == 0 {
            straightened = facing
            box = facing.extent
        } else {
            // ⚠️ NEGATED. Core Image's y axis points up, so a positive rotation
            // there turns the image anticlockwise — the opposite of the clockwise
            // convention `angle` declares.
            let turn = CGAffineTransform(rotationAngle: -angle * .pi / 180)
            straightened = facing.transformed(by: turn)
            // The exact box, sized by the same arithmetic as `outputSize` so
            // the two can never disagree by a rounding.
            box = CGRect(
                origin: facing.extent.applying(turn).origin, size: turnedSize(of: source.size)
            )
        }

        guard let kept = kept(in: box) else { return nil }
        return straightened.cropped(to: kept)
            .transformed(by: CGAffineTransform(translationX: -kept.minX, y: -kept.minY))
    }

    /// How many pixels the kept picture has, for an upright picture of `size`:
    /// the straightened bounding box times the kept fractions, rounded to an
    /// even number on each axis — video encoders want even sides — never under
    /// two, and never more than the box holds. `applied(to:)` cuts exactly this
    /// much from a picture of that size.
    public func outputSize(forUpright size: CGSize) -> CGSize {
        let turned = turnedSize(of: size)
        return kept(in: CGRect(origin: .zero, size: turned))?.size
            ?? CGSize(width: Self.even(turned.width * rect.width), height: Self.even(turned.height * rect.height))
    }

    /// The width and height of the box that holds a picture of `size` once it
    /// is turned by `angle`.
    private func turnedSize(of size: CGSize) -> CGSize {
        let radians = angle * .pi / 180
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(
            width: size.width * cosine + size.height * sine,
            height: size.width * sine + size.height * cosine
        )
    }

    /// What `rect` keeps of `box`, in the box's own coordinates, on whole pixels
    /// and with even sides. Nil when the author's rectangle is under a pixel on
    /// either axis.
    ///
    /// ⚠️ **THE Y FLIP.** `rect` measures down from the top; `box` measures up
    /// from the bottom. Taking `rect.origin.y` straight would return the mirror
    /// of what the author kept — a failure that looks like a picture, not like
    /// an error.
    private func kept(in box: CGRect) -> CGRect? {
        let framed = CGRect(
            x: box.minX + rect.minX * box.width,
            y: box.minY + (1 - rect.maxY) * box.height,
            width: rect.width * box.width,
            height: rect.height * box.height
        )
        guard framed.width.isFinite, framed.height.isFinite,
              framed.width >= 1, framed.height >= 1 else { return nil }

        /// One axis: an even length no longer than the box holds, placed on a
        /// whole pixel as close to the framed centre as the box allows.
        ///
        /// ⚠️ **THE LENGTH IS WORKED OUT FROM `span` ALONE, NEVER FROM THE
        /// BOX'S EDGES.** `outputSize` asks with a box at the origin and
        /// `applied` with the turned box wherever it lies; `span` is the same
        /// number in both, while `maxX - minX` can differ from it in the last
        /// bit once an origin is added and taken away — and a quarter turn of
        /// 1920×1080 is 1080.0000000000002 wide, where the last bit decides
        /// which way a rounding goes.
        func axis(start: CGFloat, length: CGFloat, low: CGFloat, span: CGFloat) -> (CGFloat, CGFloat) {
            let room = max(2, (span / 2).rounded(.down) * 2)
            let side = min(Self.even(length), room)
            let first = low.rounded(.up)
            let last = (low + span).rounded(.down) - side
            let centred = (start + length / 2 - side / 2).rounded()
            // ⚠️ A TURNED BOX HAS FRACTIONAL EDGES, and the whole pixels inside
            // it can be one short of `room`: the cut then starts on the first
            // whole pixel and reaches into the pixel Core Image's rounded-out
            // extent adds, which holds only the transparent corner the author
            // never framed.
            return (last < first ? first : min(max(centred, first), last), side)
        }
        let (x, width) = axis(start: framed.minX, length: framed.width, low: box.minX, span: box.width)
        let (y, height) = axis(start: framed.minY, length: framed.height, low: box.minY, span: box.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `value` rounded to an even number, never under two.
    private static func even(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return max(2, (value / 2).rounded() * 2)
    }
}
