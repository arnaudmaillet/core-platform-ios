import Foundation

/// One clip of a take: a movie file and how long it runs.
struct CaptureClip: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
}

/// The clips the author has recorded towards ONE video, and the rules that
/// govern them: the three-minute budget, and the two-tap undo.
///
/// Pure values, so every rule is assertable without a camera — the screen
/// only asks this what to draw and what to allow.
///
/// ⚠️ **THE BUDGET IS THE TAKE'S, NOT A CLIP'S.** Three minutes is the length
/// of the one video the clips are stitched into, so a clip may only ever be
/// handed `remaining` to record — which is what the sources are given as their
/// hard stop, rather than the screen watching a clock and hoping to be on time.
struct CaptureTake: Equatable, Sendable {
    /// The longest video a take can become. Asked for in those words: three
    /// minutes, all clips together.
    static let limit: TimeInterval = 180

    /// ⚠️ **A HOLD SHORTER THAN THIS IS A SLIP, NOT A CLIP.** A long press
    /// recognises after a fraction of a second, and a finger lifted right after
    /// leaves a file of two or three frames — a segment too thin to see on the
    /// ring and too short to find in the editor. It is thrown away, file and all.
    static let shortest: TimeInterval = 0.3

    /// ⚠️ **"FULL" HAS A TOLERANCE.** A recording stopped by its own limit ends
    /// a frame or two either side of it; demanding exactly zero left would
    /// offer a 30ms "remaining" that no hold can use.
    static let fullTolerance: TimeInterval = 0.1

    private(set) var clips: [CaptureClip] = []

    /// Whether the next tap on the undo button deletes — see `undo()`.
    private(set) var isArmedToUndo = false

    var isEmpty: Bool { clips.isEmpty }

    var total: TimeInterval { clips.reduce(0) { $0 + $1.duration } }

    var remaining: TimeInterval { max(0, Self.limit - total) }

    var isFull: Bool { remaining <= Self.fullTolerance }

    /// Keeps a finished clip. Returns false — and keeps nothing — for a clip
    /// under `shortest`; the caller deletes its file.
    ///
    /// ⚠️ **A NEW CLIP DISARMS THE UNDO.** The armed segment was the last one;
    /// after a new clip it no longer is, and a second tap that then deleted the
    /// NEW clip would delete something the author never saw highlighted.
    @discardableResult
    mutating func append(_ clip: CaptureClip) -> Bool {
        isArmedToUndo = false
        guard clip.duration >= Self.shortest else { return false }
        clips.append(clip)
        return true
    }

    enum UndoStep: Equatable {
        /// Nothing to undo.
        case nothing
        /// The last clip is highlighted; the next tap deletes it.
        case armed
        /// The last clip is gone; its file is the caller's to delete.
        case deleted(CaptureClip)
    }

    /// The undo button's tap.
    ///
    /// ⚠️ **TWO TAPS, AND THE FIRST ONE ONLY POINTS.** A single destructive tap
    /// beside the shutter is too easy to land by accident — a thumb reaching for
    /// the shutter lands on it — and a lost clip cannot be recorded again. The
    /// first tap highlights the segment it would take; the second takes it.
    /// TikTok's convention, asked for by name.
    mutating func undo() -> UndoStep {
        guard let last = clips.last else {
            isArmedToUndo = false
            return .nothing
        }
        guard isArmedToUndo else {
            isArmedToUndo = true
            return .armed
        }
        isArmedToUndo = false
        clips.removeLast()
        return .deleted(last)
    }

    /// Anything else the author does puts the armed undo down.
    mutating func disarm() { isArmedToUndo = false }

    /// Drops every clip, handing them back so their files can go.
    mutating func discard() -> [CaptureClip] {
        let gone = clips
        clips = []
        isArmedToUndo = false
        return gone
    }

    /// Where each clip sits on the ring, as fractions of the budget.
    var segments: [ClosedRange<Double>] {
        var start = 0.0
        return clips.map { clip in
            let end = min(1, start + clip.duration / Self.limit)
            defer { start = end }
            return start...end
        }
    }
}
