import CoreGraphics
import Foundation

/// The part of a clip that will be published.
///
/// ⚠️ **SECONDS, NOT FRACTIONS — AND THE HOUSE RULE POINTS THE OTHER WAY.**
/// `MediaCrop.rect` is deliberately normalised because the editor chooses it
/// against a canvas-sized render while `post()` bakes it against a 1080x1080 one,
/// and only a fraction means the same thing in both. A trim has no such problem:
/// a clip is the same length whatever size it is drawn at, and a second is a
/// second on both sides. Expressing it as a fraction would add a division by a
/// duration that has to be loaded asynchronously, at every reader, for nothing.
///
/// `end` is optional rather than `.infinity` so "to the end of the clip" is
/// sayable **without knowing the duration** — which matters because the strip is
/// built before `AVURLAsset.load(.duration)` has answered.
struct MediaTrim: Equatable, Sendable {
    /// Seconds from the clip's start.
    var start: Double
    /// Seconds from the clip's start, or nil for "as far as it goes".
    var end: Double?

    static let whole = MediaTrim(start: 0, end: nil)

    var isWhole: Bool { self == .whole }
}

/// The arithmetic behind the trim handles.
///
/// ⚠️ **PURE, AND DELIBERATELY SO — the same reason `StraightenDial` is.** A
/// `UIPanGestureRecognizer`'s translation cannot be set, so a decision that
/// lives inside the gesture handler is a decision no test can ask about. Every
/// rule that could be wrong is here; the view below only feeds it touches.
///
/// ⚠️ **AND `MediaCropGeometry.grip(at:box:reach:)` IS NOT REUSABLE FOR THIS,
/// THOUGH IT LOOKS LIKE IT SHOULD BE.** Its gate is
/// `box.insetBy(dx: -reach, dy: -reach).contains(point)` and it then tests
/// `point.y` against the box's top and bottom edges. A trim strip is about 56pt
/// tall and the reach is a finger's 44, so every touch anywhere on it would come
/// back gripping top AND bottom. The `Grip` OptionSet is not 2-D-bound; that
/// function is.
enum MediaTrimming {
    /// Which end a touch took hold of.
    enum Handle: Equatable, Sendable {
        case start
        case end
    }

    /// The shortest clip a trim may leave behind.
    ///
    /// A judgement, not a measurement: one second is about the least that reads
    /// as a clip rather than a stutter. ⚠️ It is a CEILING as well as a floor —
    /// a clip already shorter than this cannot be trimmed at all, and
    /// `shortest(within:)` is what stops the rule from inverting and producing
    /// an empty or negative range on one.
    static let shortestSeconds: Double = 1

    /// How far from a handle's ink a touch may land and still take it.
    /// A finger, not the drawing — the same 44 the crop surface uses.
    static let reach: CGFloat = 44

    /// The floor that actually applies to a clip of this length.
    static func shortest(within duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(shortestSeconds, duration)
    }

    /// The trim as a concrete pair of seconds, with `nil` resolved and both ends
    /// brought inside the clip.
    ///
    /// ⚠️ **EVERY READER GOES THROUGH THIS.** A stored trim can outlive the clip
    /// it was made for — a draft, a re-pick, a library that answers a different
    /// file — so "start 4s, end 9s" against a two-second clip has to mean
    /// something rather than crash an exporter.
    static func resolved(_ trim: MediaTrim, within duration: Double) -> ClosedRange<Double> {
        guard duration.isFinite, duration > 0 else { return 0...0 }
        let floor = shortest(within: duration)
        let end = min(trim.end ?? duration, duration)
        // The start yields to the end, not the other way around: a start pushed
        // past the end would otherwise silently invert the range.
        let start = min(max(trim.start, 0), max(end - floor, 0))
        return start...max(end, start + floor)
    }

    /// Whether this trim actually asks for less than the whole clip.
    ///
    /// ⚠️ **NOT `!trim.isWhole`.** A trim of 0 to exactly the duration is a
    /// different VALUE from `.whole` and the same INSTRUCTION, and the publish
    /// path must take the passthrough route for both — attaching a time range
    /// that happens to cover everything still makes the exporter re-encode.
    static func cuts(_ trim: MediaTrim, within duration: Double) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        let range = resolved(trim, within: duration)
        return range.lowerBound > 0.001 || range.upperBound < duration - 0.001
    }

    /// Moves one handle by a number of seconds, keeping both inside the clip and
    /// at least `shortest` apart.
    ///
    /// ⚠️ **INCREMENTAL, LIKE THE DIAL — NOT MEASURED FROM TOUCH-DOWN.** The
    /// view zeroes the recogniser's translation every sample and hands over the
    /// delta, so a drag that runs into an end and comes back does not first have
    /// to undo the distance it overshot by. Measured-from-origin dragging is what
    /// makes a control feel stuck at its limits.
    static func moved(
        _ trim: MediaTrim, handle: Handle, bySeconds delta: Double, within duration: Double
    ) -> MediaTrim {
        guard duration.isFinite, duration > 0 else { return trim }
        let range = resolved(trim, within: duration)
        let floor = shortest(within: duration)
        switch handle {
        case .start:
            let wanted = range.lowerBound + delta
            let limit = max(range.upperBound - floor, 0)
            return MediaTrim(start: min(max(wanted, 0), limit), end: range.upperBound)
        case .end:
            let wanted = range.upperBound + delta
            let limit = min(range.lowerBound + floor, duration)
            return MediaTrim(start: range.lowerBound, end: max(min(wanted, duration), limit))
        }
    }

    /// Which handle a touch at `x` takes, if either.
    ///
    /// ⚠️ **THE NEARER ONE WINS A TIE, AND THE TIE IS REAL.** On a trimmed-to-
    /// minimum clip the two handles are a few points apart and both are within
    /// reach of the same touch. Answering `.start` by default would make the end
    /// handle unreachable exactly when the author most wants to widen the
    /// selection again.
    static func handle(
        at x: CGFloat, startX: CGFloat, endX: CGFloat, reach: CGFloat = reach
    ) -> Handle? {
        let toStart = abs(x - startX)
        let toEnd = abs(x - endX)
        guard min(toStart, toEnd) <= reach else { return nil }
        return toStart <= toEnd ? .start : .end
    }

    /// Where a moment in the clip sits along a strip of `width`.
    static func x(forSeconds seconds: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration.isFinite, duration > 0, width > 0 else { return 0 }
        let fraction = min(max(seconds / duration, 0), 1)
        return width * CGFloat(fraction)
    }

    /// How many seconds a distance along a strip of `width` is worth.
    static func seconds(forWidth distance: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, width > 0 else { return 0 }
        return Double(distance / width) * duration
    }
}
