import CoreImage
import MediaPlayback
import UIKit

/// One look a picture can be shown in.
///
/// ⚠️ **THE VALUE LIVES IN MEDIAPLAYBACK NOW (`LookPreset`), AND THIS NAME
/// STAYS.** A video's look is drawn by that package's compositor, which may not
/// import a feature; the photo path and the video path read one type, and every
/// screen here keeps saying `MediaFilter`. What the row SPELLS is a screen's
/// business and stays below.
///
/// ⚠️ **APPLE'S OWN LOOKS, NOT LUTs — FOR NOW.** See `LookPreset`: swapping in
/// LUTs later touches `FrameLookRenderer` and nothing here.
typealias MediaFilter = LookPreset

extension LookPreset {
    /// What the row spells under each thumbnail.
    var name: String {
        switch self {
        case .original: "Original"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .mono: "Mono"
        case .noir: "Noir"
        case .process: "Process"
        case .tonal: "Tonal"
        case .transfer: "Transfer"
        }
    }
}

/// Puts a `MediaFilter` through a picture.
///
/// ⚠️ **THE LOOK IS `FrameLookRenderer`'S, AND THE RENDER IS THE SHARED
/// CONTEXT'S.** This used to hold its own `CIFilter` table and its own context;
/// both moved to MediaPlayback so a video's look is the very graph a
/// photograph's is. What stays here is the `UIImage` wrapping.
///
/// ⚠️ **THE CALLER FETCHES ONE SOURCE IMAGE AND ASKS FOR MANY LOOKS.** The
/// library seam caches nothing — `PhotosMediaLibrary.thumbnail` runs a full
/// `PHImageManager` request with iCloud access allowed on every call — so
/// rendering a row of nine by asking it nine times would be nine round trips for
/// one photograph. Ask once, filter locally.
enum MediaFilterRenderer {
    /// Nil only when the source cannot be read as a `CIImage`; `.original`
    /// always returns the source itself.
    static func apply(_ filter: MediaFilter, to image: UIImage) -> UIImage? {
        guard filter != .original else { return image }
        guard let source = CIImage(image: image) else { return nil }

        let output = FrameLookRenderer.apply(FrameLook(preset: filter), to: source, time: 0)
        guard let rendered = EditingRenderContext.shared.createCGImage(output, from: output.extent)
        else { return nil }

        // ⚠️ THE SOURCE'S SCALE AND ORIENTATION ARE CARRIED OVER, NOT DEFAULTED.
        // `UIImage(cgImage:)` alone lands at scale 1 and `.up`, which on a Retina
        // thumbnail doubles its apparent size and rotates anything the camera
        // recorded sideways.
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
