import Foundation

/// One of Apple's own looks a picture can wear.
///
/// ⚠️ **MOVED HERE FROM UPLOAD, WHERE IT WAS `MediaFilter`, AND UPLOAD STILL
/// SAYS `MediaFilter`** (a typealias). The compositor that draws a video's look
/// lives in this package, and this package may not depend on a feature — so the
/// value moved to where both the photo path and the video path can read it. The
/// words a row spells under each look stay in Upload: naming is a screen's job.
///
/// ⚠️ **APPLE'S OWN LOOKS, NOT LUTs — FOR NOW.** The intended end state is
/// `CIColorCube` fed by `.cube` files; nobody has authored those yet, so these
/// are the `CIPhotoEffect` family, shipped with the system. `FrameLookRenderer`
/// is the one place that knows which filter is behind a case.
public enum LookPreset: String, CaseIterable, Sendable {
    case original
    case chrome
    case fade
    case instant
    case mono
    case noir
    case process
    case tonal
    case transfer
}

/// The dials an author turns on a picture.
///
/// ⚠️ **EVERY WRITE IS NORMALISED, WHICHEVER PATH IT TAKES.** A slider dragged
/// back to the middle rarely lands on exactly zero, and a value of 0.0003 is not
/// "untouched" to `==` — the editor would keep an entry for a picture nobody
/// changed, and "absent means untouched" (`MediaEdits`) would stop being true.
/// So each field clamps into its key's range and snaps anything within
/// `snap` of zero to zero, on the subscript AND on a direct assignment
/// (`didSet`). An initial value is not normalised: every default is zero.
///
/// ⚠️ **ONE FIELD PER KEY, SAME NAME, SAME ORDER.** `Key` is how screens loop
/// over the dials, and `FrameLookNeutralityTests` holds the two lists together
/// through `Mirror`: a field with no key could never be reset, and a key with no
/// field would write nowhere.
public struct LookAdjustments: Equatable, Sendable {
    /// Two-sided dials run -1...1 and rest at 0.
    public var brightness: Double = 0 { didSet { brightness = Key.brightness.normalised(brightness) } }
    public var contrast: Double = 0 { didSet { contrast = Key.contrast.normalised(contrast) } }
    public var saturation: Double = 0 { didSet { saturation = Key.saturation.normalised(saturation) } }
    public var warmth: Double = 0 { didSet { warmth = Key.warmth.normalised(warmth) } }
    public var highlights: Double = 0 { didSet { highlights = Key.highlights.normalised(highlights) } }
    public var shadows: Double = 0 { didSet { shadows = Key.shadows.normalised(shadows) } }
    /// One-sided dials run 0...1 and rest at 0.
    public var sharpness: Double = 0 { didSet { sharpness = Key.sharpness.normalised(sharpness) } }
    public var vignette: Double = 0 { didSet { vignette = Key.vignette.normalised(vignette) } }
    public var grain: Double = 0 { didSet { grain = Key.grain.normalised(grain) } }

    /// How close to zero a value has to be to count as zero.
    public static let snap = 0.005

    public static let neutral = LookAdjustments()

    public var isNeutral: Bool { self == .neutral }

    public init() {}

    /// One dial.
    public enum Key: String, CaseIterable, Sendable {
        case brightness, contrast, saturation, warmth, highlights, shadows, sharpness, vignette, grain

        /// Where the dial can go. Zero is inside every range and is always the
        /// resting value.
        public var range: ClosedRange<Double> {
            switch self {
            case .brightness, .contrast, .saturation, .warmth, .highlights, .shadows: -1...1
            case .sharpness, .vignette, .grain: 0...1
            }
        }

        /// `value` clamped into the range, with a near-zero snapped to zero and
        /// NaN — which no comparison can clamp — treated as zero.
        public func normalised(_ value: Double) -> Double {
            guard !value.isNaN else { return 0 }
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            return abs(clamped) < LookAdjustments.snap ? 0 : clamped
        }
    }

    /// Reads or writes one dial by key. Writing normalises, as every write does.
    public subscript(key: Key) -> Double {
        get {
            switch key {
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .warmth: warmth
            case .highlights: highlights
            case .shadows: shadows
            case .sharpness: sharpness
            case .vignette: vignette
            case .grain: grain
            }
        }
        set {
            switch key {
            case .brightness: brightness = newValue
            case .contrast: contrast = newValue
            case .saturation: saturation = newValue
            case .warmth: warmth = newValue
            case .highlights: highlights = newValue
            case .shadows: shadows = newValue
            case .sharpness: sharpness = newValue
            case .vignette: vignette = newValue
            case .grain: grain = newValue
            }
        }
    }
}

/// A stylised treatment laid over the whole picture. One at a time.
public enum LookEffectKind: String, CaseIterable, Sendable {
    case blur, pixellate, rgbSplit, vhs, posterize, comic, bloom, zoomBlur, crystallize, halftone, thermal, xray
}

/// An effect and how strongly it is mixed with the picture beneath it.
public struct LookEffect: Equatable, Sendable {
    public var kind: LookEffectKind
    /// 0...1, clamped on every write. Zero is not stored: see `normalised`.
    public var intensity: Double {
        didSet { intensity = Self.clamped(intensity) }
    }

    public init(kind: LookEffectKind, intensity: Double) {
        self.kind = kind
        self.intensity = Self.clamped(intensity)
    }

    /// ⚠️ **AN EFFECT AT ZERO IS NO EFFECT, AND IT IS SPELLED `nil`.** Two
    /// spellings of "nothing" would make `FrameLook.isNeutral` answer false for
    /// a picture that looks untouched. Every field that stores an effect passes
    /// it through here.
    public static func normalised(_ effect: LookEffect?) -> LookEffect? {
        guard let effect, effect.intensity >= LookAdjustments.snap else { return nil }
        return effect
    }

    private static func clamped(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

/// Everything that colours a picture: a preset, the dials, and one effect.
///
/// ⚠️ **THE ORDER THE RENDERER APPLIES THEM IS ITS OWN, NOT THIS TYPE'S** —
/// adjustments, then the preset, then the effect, then sharpness, vignette and
/// grain (`FrameLookRenderer`). This is only the list.
public struct FrameLook: Equatable, Sendable {
    public var preset: LookPreset
    public var adjustments: LookAdjustments
    /// Nil is no effect; an effect written at zero intensity becomes nil.
    public var effect: LookEffect? {
        didSet { effect = LookEffect.normalised(effect) }
    }

    public init(
        preset: LookPreset = .original, adjustments: LookAdjustments = .neutral,
        effect: LookEffect? = nil
    ) {
        self.preset = preset
        self.adjustments = adjustments
        self.effect = LookEffect.normalised(effect)
    }

    public static let neutral = FrameLook()

    /// ⚠️ **`==` AGAINST THE NEUTRAL VALUE, NOT A LIST OF FIELDS.** A list
    /// falls behind the day a field is added; the comparison cannot.
    public var isNeutral: Bool { self == .neutral }
}
