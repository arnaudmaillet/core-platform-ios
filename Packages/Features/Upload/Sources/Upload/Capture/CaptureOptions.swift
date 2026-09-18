import CoreGraphics
import Foundation

/// The shape a capture is FRAMED in.
///
/// ⚠️ **A CROP HANDED TO THE EDITOR, NEVER PIXELS CUT AT CAPTURE.** The file
/// keeps the whole frame the sensor gave; the ratio travels as the editor's own
/// `MediaEdits.crop` (`crop(forUpright:)`), so the author can still widen it
/// there and nothing is rendered twice. The live preview shows it as a window
/// over the full frame — the same centred rectangle this crop keeps.
enum CaptureRatio: String, CaseIterable, Sendable {
    /// 9:16, the feed's own shape and where the camera opens.
    case tall
    /// 3:4, the classic photograph.
    case classic
    /// 1:1.
    case square

    /// Width over height.
    var aspect: CGFloat {
        switch self {
        case .tall: 9.0 / 16.0
        case .classic: 3.0 / 4.0
        case .square: 1
        }
    }

    var label: String {
        switch self {
        case .tall: "9:16"
        case .classic: "3:4"
        case .square: "1:1"
        }
    }

    var spoken: String {
        switch self {
        case .tall: "Nine by sixteen"
        case .classic: "Three by four"
        case .square: "Square"
        }
    }

    /// The centred crop that keeps this shape of a picture whose UPRIGHT size is
    /// `size` — fractions of the picture, as `MediaCrop.rect` states them.
    ///
    /// ⚠️ **UNTOUCHED WHEN THE PICTURE ALREADY HAS THE SHAPE**, within half a
    /// percent: an entry that keeps 99.8% of a picture is an edit that says
    /// nothing, and `MediaEdits`' rule is that absent means untouched. A 9:16
    /// clip framed 9:16 hands the editor nothing at all.
    ///
    /// ⚠️ **THE UPRIGHT SIZE, NOT THE BUFFER'S.** A phone records portrait video
    /// as a landscape buffer with a quarter turn in its track transform, and a
    /// photograph carries an orientation flag; the editor aims crops at the
    /// picture as drawn (`MediaCropRenderer.upturned`), and at zero degrees the
    /// turned bounding box IS the upright picture. `CapturedMediaLibrary`
    /// measures that size from the file itself.
    func crop(forUpright size: CGSize) -> MediaCrop {
        guard size.width > 0, size.height > 0 else { return .untouched }
        let source = size.width / size.height
        guard abs(source - aspect) / aspect > 0.005 else { return .untouched }
        if source > aspect {
            // Wider than wanted: keep the full height, cut the sides.
            let width = aspect / source
            return MediaCrop(rect: CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1))
        } else {
            let height = source / aspect
            return MediaCrop(rect: CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height))
        }
    }

    /// The largest rectangle of this shape centred in `bounds` — the preview's
    /// window.
    func window(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }
}

/// What the flash does. Photos fire it; a recording holds the torch on for
/// `.on` (and for `.auto`, which a recording cannot meter frame by frame, as
/// off — see `CaptureFlashMode.lightsTorch`).
enum CaptureFlashMode: String, CaseIterable, Sendable {
    case off
    case auto
    case on

    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .on: "On"
        }
    }

    var symbolName: String {
        switch self {
        case .off: "bolt.slash"
        case .auto: "bolt.badge.automatic"
        case .on: "bolt"
        }
    }

    /// ⚠️ **AUTO DOES NOT LIGHT THE TORCH.** A torch that switched itself on
    /// and off with the light mid-clip would flicker through the video; the
    /// system Camera app offers the torch as on or off for the same reason.
    var lightsTorch: Bool { self == .on }
}

/// The countdown before the shutter acts.
enum CaptureTimer: Int, CaseIterable, Sendable {
    case off = 0
    case three = 3
    case ten = 10

    var label: String {
        switch self {
        case .off: "Off"
        case .three: "3s"
        case .ten: "10s"
        }
    }

    var symbolName: String {
        switch self {
        case .off: "timer"
        case .three: "3.circle"
        case .ten: "10.circle"
        }
    }
}

/// The icons in the camera's bottom selector, in the order they stand.
///
/// ⚠️ **APPENDED, NEVER INSERTED** — the raw value is the selector's index and
/// the tests address the options by it, the editor's `TrackAction` rule.
enum CaptureOption: Int, CaseIterable, Sendable {
    case flash
    case timer
    case ratio
    case filters
    case grid

    var title: String {
        switch self {
        case .flash: "Flash"
        case .timer: "Timer"
        case .ratio: "Aspect ratio"
        case .filters: "Filters"
        case .grid: "Grid"
        }
    }

    /// ⚠️ **GRID OPENS NOTHING.** It is a toggle: a band holding one switch
    /// would be a band for its own sake. Choosing it flips the grid and puts
    /// the selector back to neutral.
    var opensBand: Bool { self != .grid }
}

/// Everything the author chose on the camera that travels with a capture.
struct CaptureSettings: Equatable, Sendable {
    var flash: CaptureFlashMode = .off
    var timer: CaptureTimer = .off
    var ratio: CaptureRatio = .tall
    var filter: MediaFilter = .original
    var showsGrid = false
}
