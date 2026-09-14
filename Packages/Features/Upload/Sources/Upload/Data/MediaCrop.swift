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
    /// The kept rectangle, in fractions of the source: `(0,0)` is its top-left
    /// corner and `(1,1)` its bottom-right.
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

    /// The whole picture, unturned: the absence of a crop rather than a crop that
    /// does nothing, so the renderer can hand the source straight back.
    static let untouched = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1), angle: 0)

    var isUntouched: Bool { self == .untouched }

    init(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), angle: CGFloat = 0) {
        self.rect = rect
        self.angle = angle
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
        guard let source = CIImage(image: image) else { return nil }

        // Straighten first, so the kept rectangle is expressed against the
        // picture the author was actually looking at.
        let straightened: CIImage
        if crop.angle == 0 {
            straightened = source
        } else {
            // ⚠️ NEGATED. Core Image's y axis points up, so a positive rotation
            // there turns the image anticlockwise — the opposite of the clockwise
            // convention `angle` declares.
            let radians = -crop.angle * .pi / 180
            straightened = source.transformed(by: CGAffineTransform(rotationAngle: radians))
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

        // ⚠️ SCALE AND ORIENTATION CARRIED OVER, NOT DEFAULTED — `UIImage(cgImage:)`
        // alone lands at scale 1 and `.up`, which doubles a Retina thumbnail's
        // apparent size and rotates anything the camera recorded sideways. Stated
        // in `MediaFilterRenderer` for the same reason.
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
