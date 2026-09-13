import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// One look a picture can be shown in.
///
/// ⚠️ **APPLE'S OWN LOOKS, NOT LUTs — FOR NOW.** The intended end state is
/// `CIColorCube` fed by `.cube` files, which is how filter packs are really
/// built. That needs colour assets nobody has authored yet, so this first cut
/// uses the `CIPhotoEffect` family: eight looks, shipped with the system, no
/// assets to carry. The row and the per-item state below do not care which of
/// the two is behind a case, so swapping in LUTs later touches `ciFilter` and
/// nothing else.
///
/// The eight names were read out of this SDK's `CIFilterBuiltins.h` rather than
/// recalled, and the typed spelling is the one `ProfileQRCode` already uses —
/// `CIFilter(name:)` turns a typo into a crash at run time.
enum MediaFilter: String, CaseIterable, Sendable {
    case original
    case chrome
    case fade
    case instant
    case mono
    case noir
    case process
    case tonal
    case transfer

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

    /// Nil for `.original`, which is the absence of a filter rather than a
    /// filter that does nothing — the renderer returns the source untouched and
    /// pays no GPU cost at all.
    fileprivate var ciFilter: CIFilter? {
        switch self {
        case .original: nil
        case .chrome: CIFilter.photoEffectChrome()
        case .fade: CIFilter.photoEffectFade()
        case .instant: CIFilter.photoEffectInstant()
        case .mono: CIFilter.photoEffectMono()
        case .noir: CIFilter.photoEffectNoir()
        case .process: CIFilter.photoEffectProcess()
        case .tonal: CIFilter.photoEffectTonal()
        case .transfer: CIFilter.photoEffectTransfer()
        }
    }
}

/// Puts a `MediaFilter` through a picture.
///
/// ⚠️ **ONE CONTEXT, CREATED ONCE, AS `VideoStillCapture` ALREADY ARGUES.** A
/// `CIContext` allocates its own GPU resources, and building one per call is the
/// documented way to make a cheap render expensive. It is thread-safe by
/// contract, so one static serves every caller.
///
/// ⚠️ **THE CALLER FETCHES ONE SOURCE IMAGE AND ASKS FOR MANY LOOKS.** The
/// library seam caches nothing — `PhotosMediaLibrary.thumbnail` runs a full
/// `PHImageManager` request with iCloud access allowed on every call — so
/// rendering a row of nine by asking it nine times would be nine round trips for
/// one photograph. Ask once, filter locally.
enum MediaFilterRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Nil only when the source cannot be read as a `CIImage`; `.original`
    /// always returns the source itself.
    static func apply(_ filter: MediaFilter, to image: UIImage) -> UIImage? {
        guard let ciFilter = filter.ciFilter else { return image }
        guard let source = CIImage(image: image) else { return nil }

        ciFilter.setValue(source, forKey: kCIInputImageKey)
        guard let output = ciFilter.outputImage,
              let rendered = context.createCGImage(output, from: output.extent)
        else { return nil }

        // ⚠️ THE SOURCE'S SCALE AND ORIENTATION ARE CARRIED OVER, NOT DEFAULTED.
        // `UIImage(cgImage:)` alone lands at scale 1 and `.up`, which on a Retina
        // thumbnail doubles its apparent size and rotates anything the camera
        // recorded sideways.
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
