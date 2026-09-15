import UIKit

/// Everything the author decided about one picture in the editor.
///
/// ⚠️ **ONE DICTIONARY, NOT THREE PARALLEL ONES.** Fit and look already
/// travelled as `[String: ContentFit]` and `[String: MediaFilter]` keyed by the
/// same identifiers, threaded through the same closure, defaulted in the same
/// places. A crop would have made a third, and the next decision a fourth: every
/// one of them a separate chance to carry two of the three and drop the rest,
/// with the compiler content either way. The type is the list of what an author
/// can decide, and it grows by a field rather than by a parameter.
///
/// ⚠️ **TWO OF THESE THREE REACH THE SERVER'S PIXELS AND ONE DOES NOT.** The
/// crop and the look are baked into the uploaded image in
/// `NewPostViewController.post()`; the fit is a `UIView.ContentMode` — how a
/// picture is laid in a frame it does not fill — and is honoured by screens, not
/// by the encoder. Anything reading this type to decide what to upload wants the
/// first two only.
///
/// ⚠️ **ABSENT MUST KEEP MEANING "UNTOUCHED".** The editor hands on only the
/// entries it actually wrote, and `MediaEditorTests` pins that a screen nobody
/// edited carries nothing — so no read path may use `edits[id, default:]`, which
/// would quietly fill the dictionary with no-ops on every page that scrolled by.
struct MediaEdits: Equatable, Sendable {
    /// Whether the picture fills its frame or is shown whole. Absent means
    /// `.fill`, which is where the canvas starts.
    var fit: ContentFit = .fill

    /// The look. Absent means `.original`, the picture undressed.
    var filter: MediaFilter = .original

    /// What the author kept of the picture, and how far they straightened it.
    var crop: MediaCrop = .untouched

    /// What the author kept of a CLIP. Meaningless on a photograph, and left
    /// `.whole` there rather than made optional: an `Optional` would put a `?`
    /// at every reader to say something none of them can act on.
    var trim: MediaTrim = .whole

    static let untouched = MediaEdits()

    var isUntouched: Bool { self == .untouched }

    /// What a cache key needs so a re-edit actually redraws.
    ///
    /// ⚠️ **A DESCRIPTION, NOT A HASH — AND THAT IS WHY THIS TYPE IS NOT
    /// `Hashable`.** `NewPostMediaCell` skips its whole redraw when the key is
    /// unchanged, so a collision is not a slow path: it is a thumbnail silently
    /// showing the previous crop while the editor shows the new one. `hashValue`
    /// may collide and is not stable across launches; spelling the fields cannot
    /// do either.
    /// ⚠️ **THE WHOLE CROP, NOT FIELDS PICKED OUT OF IT.** This used to spell
    /// `crop.rect` and `crop.angle`, which was complete on the day it was written
    /// and silently incomplete the day `isMirrored` was added — a picture flipped
    /// in the editor would have kept its old thumbnail on the next screen, with
    /// nothing to say so. Interpolating the value itself cannot fall behind it.
    /// ⚠️ **AND EVERY FIELD OF *THIS* TYPE HAS TO BE ADDED BY HAND.** The note
    /// above is about `MediaCrop` growing a field — interpolating `crop` whole
    /// covers that for free. It does **not** cover `MediaEdits` growing one:
    /// `trim` had to be written in here, and a future field will too. The
    /// failure is the same and just as quiet, one level up.
    var signature: String {
        "\(fit)/\(filter.rawValue)/\(crop)/\(trim)"
    }

    /// The picture as the author left it.
    ///
    /// ⚠️ **CUT FIRST, THEN DRESSED — AND THE ORDER IS STATED, NOT INCIDENTAL.**
    /// `MediaCrop`'s own note gives the reason: cropping first hands the filter
    /// fewer pixels, and for the `CIPhotoEffect` family the result is identical
    /// either way, so the cheaper order is free.
    ///
    /// ⚠️ **AND A FAILED RENDER RETURNS THE PICTURE, NEVER NOTHING.** Both
    /// renderers answer nil on an unreadable image or a degenerate rectangle.
    /// Dropping the photograph over a decoration is the one outcome that cannot
    /// be allowed, which is what each `??` here says.
    func applied(to image: UIImage) -> UIImage {
        let cut = MediaCropRenderer.apply(crop, to: image) ?? image
        return MediaFilterRenderer.apply(filter, to: cut) ?? cut
    }
}
