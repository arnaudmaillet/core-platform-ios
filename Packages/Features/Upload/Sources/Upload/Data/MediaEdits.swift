import CoreImage
import MediaPlayback
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
/// ⚠️ **EVERYTHING BUT THE FIT REACHES THE SERVER'S PIXELS.** The crop, the
/// look (preset, adjustments, effect) and the overlays are baked into an
/// uploaded photograph by `applied(to:artwork:includingOverlays:)`; a video
/// carries them, with its timeline and its song, in `exportPlan(...)`. The fit
/// is a `UIView.ContentMode` — how a picture is laid in a frame it does not fill
/// — and is honoured by screens, not by the encoder.
///
/// ⚠️ **ABSENT MUST KEEP MEANING "UNTOUCHED".** The editor hands on only the
/// entries it actually wrote, and `MediaEditorTests` pins that a screen nobody
/// edited carries nothing — so no read path may use `edits[id, default:]`, which
/// would quietly fill the dictionary with no-ops on every page that scrolled by.
/// Every default below is neutral, and the fields that could hold a near-neutral
/// value normalise it on every write (`LookAdjustments`, `effect`).
struct MediaEdits: Equatable, Sendable {
    /// Whether the picture fills its frame or is shown whole. Absent means
    /// `.fill`, which is where the canvas starts.
    var fit: ContentFit = .fill

    /// The look's preset. Absent means `.original`, the picture undressed.
    var filter: MediaFilter = .original

    /// The dials. Absent means every one at rest.
    var adjustments: LookAdjustments = .neutral

    /// The stylised effect, if any. One written at zero intensity is stored as
    /// nil — see `LookEffect.normalised`.
    ///
    /// ⚠️ **NORMALISED ON A WRITE, NOT IN THE MEMBERWISE INITIALISER** — `didSet`
    /// does not run there. The editor writes through `change(_:_:)`, which is a
    /// write; `look` normalises again on the way out either way.
    var effect: LookEffect? = nil {
        didSet { effect = LookEffect.normalised(effect) }
    }

    /// What the author kept of the picture, and how far they straightened it.
    var crop: MediaCrop = .untouched

    /// What the author made of a CLIP: the pieces they kept, in order.
    /// Meaningless on a photograph, and left `.whole` there rather than made
    /// optional: an `Optional` would put a `?` at every reader to say something
    /// none of them can act on.
    var timeline: MediaTimeline = .whole

    /// Text, emoji and stickers laid over the finished picture, bottom first.
    var overlays: [FrameOverlay] = []

    /// The song under a CLIP. Always nil on a photograph: an image attachment
    /// cannot carry sound, and the editor says so instead of storing one.
    var soundtrack: VideoSoundtrack? = nil

    static let untouched = MediaEdits()

    var isUntouched: Bool { self == .untouched }

    /// Everything that colours the picture, as the renderers read it.
    var look: FrameLook { FrameLook(preset: filter, adjustments: adjustments, effect: effect) }

    /// What is done to the picture after its film is cut, in the order both
    /// renderers apply it.
    ///
    /// ⚠️ **`includingOverlays: false` IS THE EDITOR'S.** Its canvas draws
    /// overlays as views over the page so they can move under a finger; baking
    /// them into the page too would show every overlay twice, and the copy in
    /// the pixels would not move.
    /// ⚠️ **`includingCrop: false` IS FOR THE CROP SURFACE ITSELF.** While the
    /// author is aiming the box, the clip behind it must be the WHOLE film — a
    /// compositor that has already cut it would leave them cropping a crop, and
    /// every box they drew would bite twice.
    func finish(includingOverlays: Bool, includingCrop: Bool = true) -> FrameFinish {
        FrameFinish(
            crop: includingCrop ? crop : .untouched,
            look: look,
            overlays: includingOverlays ? overlays : []
        )
    }

    /// What a cache key needs so a re-edit actually redraws.
    ///
    /// ⚠️ **A DESCRIPTION, NOT A HASH — AND THAT IS WHY THIS TYPE IS NOT
    /// `Hashable`.** `NewPostMediaCell` skips its whole redraw when the key is
    /// unchanged, so a collision is not a slow path: it is a thumbnail silently
    /// showing the previous crop while the editor shows the new one. `hashValue`
    /// may collide and is not stable across launches; spelling the fields cannot
    /// do either.
    /// ⚠️ **EACH FIELD WHOLE, NOT PIECES PICKED OUT OF IT.** This used to spell
    /// `crop.rect` and `crop.angle`, which was complete on the day it was written
    /// and silently incomplete the day `isMirrored` was added — a picture flipped
    /// in the editor would have kept its old thumbnail on the next screen, with
    /// nothing to say so. Interpolating the value itself cannot fall behind it.
    /// ⚠️ **AND EVERY FIELD OF *THIS* TYPE HAS TO BE ADDED BY HAND, IN
    /// DECLARATION ORDER.** Interpolating `crop` whole covers `MediaCrop` growing
    /// a field; nothing covers `MediaEdits` growing one — `trim` had to be
    /// written in here, then `timeline`, then four more at once.
    /// `MediaEditsSignatureTests` is what turns a forgotten field into a red
    /// test: it reads this type's fields with `Mirror` and changes each one.
    var signature: String {
        [
            "\(fit)",
            filter.rawValue,
            "\(adjustments)",
            effect.map { "\($0)" } ?? "-",
            "\(crop)",
            "\(timeline)",
            "\(overlays)",
            soundtrack.map { "\($0)" } ?? "-"
        ].joined(separator: "/")
    }

    /// The picture as the author left it: cut, then dressed, then written on —
    /// as ONE Core Image graph and ONE render.
    ///
    /// ⚠️ **CUT FIRST, THEN DRESSED — AND THE ORDER IS STATED, NOT INCIDENTAL.**
    /// Cropping first hands the look fewer pixels, and overlays are placed in
    /// fractions of the CUT picture (`OverlayPlacement`), so they come last.
    ///
    /// ⚠️ **TURNED UPRIGHT ONLY WHEN THE GEOMETRY IS TOUCHED.** A cut or an
    /// overlay is aimed at the picture as drawn, and `CIImage(image:)` reads the
    /// raw buffer (`MediaCropRenderer.upturned`); a look alone leaves the
    /// geometry alone and carries the orientation flag through untouched, as
    /// `MediaFilterRenderer` always has.
    ///
    /// ⚠️ **AND A FAILED RENDER RETURNS THE PICTURE, NEVER NOTHING.** A cut
    /// under a pixel is skipped and the look is still applied; an unreadable
    /// picture or a failed render hands the source back. Dropping the
    /// photograph over a decoration is the one outcome that cannot be allowed.
    ///
    /// `nonisolated` by construction: everything it touches is a value, a
    /// `Sendable` image, or a renderer that makes its filters per call.
    func applied(
        to image: UIImage, artwork: (any OverlayArtwork)?, includingOverlays: Bool = true
    ) -> UIImage {
        let finish = self.finish(includingOverlays: includingOverlays)
        guard !finish.isNone else { return image }
        let turns = !finish.crop.isUntouched || !finish.overlays.isEmpty
        let base = turns ? MediaCropRenderer.upturned(image) : image
        guard let source = CIImage(image: base) else { return image }

        let cut = finish.crop.applied(to: source) ?? source
        let dressed = FrameLookRenderer.apply(finish.look, to: cut, time: 0)
        let written = OverlayRasterizer.composite(finish.overlays, over: dressed, time: 0, artwork: artwork)
        guard written !== source else { return image }

        let extent = written.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite,
              let rendered = EditingRenderContext.shared.createCGImage(written, from: extent)
        else { return image }
        return UIImage(cgImage: rendered, scale: base.scale, orientation: base.imageOrientation)
    }
}
