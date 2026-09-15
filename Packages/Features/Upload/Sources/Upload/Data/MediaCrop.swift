import CoreImage
import UIKit

/// How much of a picture the author kept, and how far they straightened it.
///
/// ⚠️ **NORMALISED, NEVER PIXELS.** The editor previews on a canvas-sized render
/// and the publish path bakes on a much larger one — `MediaFilter` already
/// records that the look is applied to the publish-sized image because "the
/// editor showed it on a canvas-sized render and a 56pt chip; neither of those is
/// what gets uploaded". A rectangle chosen in canvas pixels would be the wrong
/// rectangle at publish resolution. Fractions of the source survive both.
///
/// ⚠️ **ORIGIN TOP-LEFT, AS UIKit READS IT — AND CORE IMAGE DOES NOT.** The crop
/// UI will hand these down in view coordinates, so that is the convention stored.
/// Core Image's origin is bottom-left, so the renderer flips `rect` on its way in.
/// That conversion is silent when wrong — a top crop simply returns the bottom of
/// the picture — which is why `MediaCropTests` crops a two-colour image rather
/// than only checking that the dimensions changed.
struct MediaCrop: Equatable, Sendable {
    /// The kept rectangle, in fractions of the **straightened** picture's
    /// bounding box: `(0,0)` is its top-left corner and `(1,1)` its
    /// bottom-right.
    ///
    /// ⚠️ **"OF THE SOURCE" IS WHAT THIS COMMENT USED TO SAY, AND IT IS TRUE
    /// ONLY AT ZERO DEGREES.** `MediaCropRenderer` turns the picture FIRST and
    /// then cuts in fractions of `straightened.extent` — the upright box that
    /// CONTAINS the turned picture, which at any other angle is strictly larger
    /// than the source on both axes and carries four transparent corners. A crop
    /// UI written against the old wording lands a different photograph at every
    /// non-zero angle, and no test in `MediaCropTests` could see it: every case
    /// there but one uses angle zero, where the two readings coincide.
    /// `MediaCropGeometry` is where the distinction is actually honoured, and
    /// `MediaCropGeometryTests` is what pins it.
    var rect: CGRect

    /// Straightening, in degrees, **positive turns the picture clockwise** as the
    /// viewer sees it.
    ///
    /// ⚠️ THE SIGN IS A CONVENTION THIS FILE DECLARES, NOT ONE THE TESTS PROVE.
    /// Asserting a direction from rendered pixels is fragile; the suite pins that
    /// a non-zero angle changes the bounds, and the direction itself is checked on
    /// screen. If a future change makes straightening go the wrong way, no test
    /// here will catch it — look at the picture.
    var angle: CGFloat

    /// Whether the picture is shown as its own reflection, left for right.
    ///
    /// ⚠️ **THIS TYPE COULD NOT EXPRESS A MIRROR UNTIL IT HAD THIS FIELD, AND
    /// THAT WAS A DELIBERATE LIMIT, NOT AN OVERSIGHT.** A crop is a rectangle and
    /// an angle; both are similarities, and every piece of arithmetic in
    /// `MediaCropGeometry` assumes a positive uniform scale. A reflection is the
    /// one transform that breaks that assumption — it is why reading an angle back
    /// off a matrix needs a positive-determinant guard. It is carried as a flag
    /// rather than as a negative scale for exactly that reason: the flag is applied
    /// at one named moment on each side, and nothing else has to know.
    ///
    /// ⚠️ **MIRRORED FIRST, THEN TURNED — ON BOTH SIDES.** The renderer reflects
    /// the source before it straightens it, and the editing surface composes its
    /// transform in the same order (`rotation.scaledBy(x: -scale, …)` scales before
    /// it rotates). Reversing either one alone puts the reflection about a
    /// different axis, and the result is a photograph, not an error.
    var isMirrored: Bool

    /// The whole picture, unturned and unreflected: the absence of a crop rather
    /// than a crop that does nothing, so the renderer can hand the source straight
    /// back.
    static let untouched = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 0)

    var isUntouched: Bool { self == .untouched }

    init(
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        angle: CGFloat = 0,
        isMirrored: Bool = false
    ) {
        self.rect = rect
        self.angle = angle
        self.isMirrored = isMirrored
    }
}

/// Cuts and straightens a picture.
///
/// ⚠️ **ONE CONTEXT, CREATED ONCE** — the same argument `MediaFilterRenderer`
/// carries: a `CIContext` allocates its own GPU resources and building one per
/// call is the documented way to make a cheap render expensive. Thread-safe by
/// contract, so one static serves every caller.
///
/// ⚠️ **ORDER MATTERS AT PUBLISH: CROP BEFORE FILTER.** Both are baked in
/// `NewPostViewController.post()`. Cropping first hands the filter fewer pixels,
/// and for the `CIPhotoEffect` family the result is identical either way — so the
/// cheaper order is free. Reversing it is not wrong, merely wasteful; doing both
/// on the preview instead of the publish image would be wrong.
enum MediaCropRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Nil only when the source cannot be read as a `CIImage`; an untouched crop
    /// always returns the source itself and pays no GPU cost.
    static func apply(_ crop: MediaCrop, to image: UIImage) -> UIImage? {
        guard !crop.isUntouched else { return image }
        let upright = upturned(image)
        guard let source = CIImage(image: upright) else { return nil }

        // ⚠️ REFLECTED BEFORE ANYTHING ELSE — see `MediaCrop.isMirrored`. The
        // surface composes its transform in the same order, and the two agree only
        // because both do this first.
        let facing = crop.isMirrored
            ? source.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            : source

        // Straighten next, so the kept rectangle is expressed against the
        // picture the author was actually looking at.
        let straightened: CIImage
        if crop.angle == 0 {
            straightened = facing
        } else {
            // ⚠️ NEGATED. Core Image's y axis points up, so a positive rotation
            // there turns the image anticlockwise — the opposite of the clockwise
            // convention `angle` declares.
            let radians = -crop.angle * .pi / 180
            straightened = facing.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        let extent = straightened.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return nil }

        // ⚠️ **THE Y FLIP.** `rect` measures down from the top; `extent` measures
        // up from the bottom. Taking `rect.origin.y` straight would return the
        // mirror of what the author kept — a failure that looks like a picture,
        // not like an error.
        let kept = CGRect(
            x: extent.minX + crop.rect.minX * extent.width,
            y: extent.minY + (1 - crop.rect.maxY) * extent.height,
            width: crop.rect.width * extent.width,
            height: crop.rect.height * extent.height
        )
        let cut = straightened.cropped(to: kept)
        guard cut.extent.width >= 1, cut.extent.height >= 1,
              let rendered = context.createCGImage(cut, from: cut.extent)
        else { return nil }

        // ⚠️ SCALE CARRIED OVER, NOT DEFAULTED — `UIImage(cgImage:)` alone lands at
        // scale 1, which doubles a Retina thumbnail's apparent size. Stated in
        // `MediaFilterRenderer` for the same reason.
        //
        // ⚠️ AND THE ORIENTATION IS `upright`'s, WHICH IS ALWAYS `.up`. A filter
        // leaves the geometry alone, so carrying the source's flag through is
        // right there; a crop does not, and `upturned` has already spent the
        // turn. Stamping the original flag back on would turn the picture a
        // second time.
        return UIImage(cgImage: rendered, scale: upright.scale, orientation: upright.imageOrientation)
    }

    /// The same photograph with the camera's turn spent, so the pixels are laid
    /// out the way the author saw them.
    ///
    /// ⚠️ **`CIImage(image:)` READS THE BUFFER AND NOT THE FLAG — MEASURED, NOT
    /// ASSUMED.** A two-colour picture declared `.right` and cut down its top
    /// half came back holding BOTH colours in equal measure (r=128, b=127): the
    /// cut had been taken across the raw buffer while the author had aimed it at
    /// the picture as drawn. Nothing about that failure looks like a failure —
    /// the dimensions are right, the render succeeds, the orientation flag comes
    /// back intact, and the post simply carries a rectangle nobody chose.
    /// `keepingTheTopOfASidewaysPhotographReturnsItsTop` is the colour that
    /// catches it.
    ///
    /// ⚠️ **AND `image.size` IS ALREADY THE TURNED SIZE.** For a `.left` or
    /// `.right` photograph UIKit reports the size the viewer sees, with the axes
    /// swapped relative to the buffer — so drawing into a context of that size
    /// is what makes the two agree, and it is also why a crop UI may go on using
    /// `image.size` as the source's proportions without a second thought.
    ///
    /// Free for a picture that is already upright, which is what `PHImageManager`
    /// usually vends.
    private static func upturned(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
