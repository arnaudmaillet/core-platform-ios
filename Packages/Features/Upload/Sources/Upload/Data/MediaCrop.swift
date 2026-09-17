import CoreImage
import MediaPlayback
import UIKit

/// How much of a picture the author kept, and how far they straightened it.
///
/// ⚠️ **THE VALUE LIVES IN MEDIAPLAYBACK NOW (`FrameCrop`), WITH ITS WHOLE
/// DOCUMENTATION, AND THIS NAME STAYS.** A video's crop is drawn by that
/// package's compositor, which may not import a feature; every screen here
/// keeps saying `MediaCrop`. Read `FrameCrop` for what `rect`, `angle` and
/// `isMirrored` mean — in particular that `rect` is a fraction of the
/// STRAIGHTENED picture's bounding box, which `MediaCropGeometry` honours.
typealias MediaCrop = FrameCrop

/// Cuts and straightens a picture.
///
/// ⚠️ **THE CUT IS `FrameCrop.applied(to:)`, AND THE RENDER IS THE SHARED
/// CONTEXT'S** — the graph a video's crop is drawn with. What stays here is the
/// `UIImage` side: turning the photograph upright first, and wrapping the
/// result.
///
/// ⚠️ **ORDER MATTERS AT PUBLISH: CROP BEFORE FILTER.** Both are baked in
/// `NewPostViewController.post()`. Cropping first hands the filter fewer pixels,
/// and for the `CIPhotoEffect` family the result is identical either way — so the
/// cheaper order is free. Reversing it is not wrong, merely wasteful; doing both
/// on the preview instead of the publish image would be wrong.
enum MediaCropRenderer {
    /// Nil only when the source cannot be read as a `CIImage`, or the kept
    /// rectangle is under a pixel; an untouched crop always returns the source
    /// itself and pays no GPU cost.
    static func apply(_ crop: MediaCrop, to image: UIImage) -> UIImage? {
        guard !crop.isUntouched else { return image }
        let upright = upturned(image)
        guard let source = CIImage(image: upright),
              let cut = crop.applied(to: source),
              let rendered = EditingRenderContext.shared.createCGImage(cut, from: cut.extent)
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
    /// usually vends. Internal because `MediaEdits.applied` turns a photograph
    /// the same way before it cuts it.
    static func upturned(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
