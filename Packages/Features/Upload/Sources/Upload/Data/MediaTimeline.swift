import Foundation
import MediaPlayback

/// One piece of the source clip, in the order it will play.
///
/// ⚠️ **TWO CLOCKS, AND EVERY NAME HERE SAYS WHICH.** The trim this replaces
/// could speak of
/// "seconds" because there was only one kind: the source ran at the speed it was
/// shot at, so a second of source was a second of output. A speed ends that. Two
/// seconds of source at 2× occupy **one second of output**, and from here on:
///
/// - the **filmstrip** and the trim handles work in SOURCE seconds — they are
///   pictures of the file, and the file does not change speed;
/// - the **ruler**, the **playhead** and the **exported duration** work in
///   PLAYED seconds — what a viewer will experience;
/// - and ⚠️ `AVMutableComposition.scaleTimeRange(_:toDuration:)` takes its range
///   in PLAYED time, so scaling one segment moves every later segment's offset.
///
/// A function here that took a bare `seconds` would be a bug waiting to be
/// written. None does.
struct MediaSegment: Equatable, Sendable {
    /// Where this piece begins in the SOURCE file.
    var start: Double
    /// Where it ends in the SOURCE file.
    var end: Double
    /// 1 is as shot. 2 plays it twice as fast, so it lasts half as long.
    var speed: Double
    /// The transition at the cut AFTER this piece, if any.
    ///
    /// ⚠️ **IT BELONGS TO THE PIECE BEFORE THE CUT.** So it travels with that
    /// piece when the pieces are re-ordered, the right half keeps it when the
    /// piece is split (the cut it names is still after that half), and it is
    /// gone when its piece becomes the last one — there is no cut after the end
    /// of the film. `nil` is a plain cut.
    ///
    /// ⚠️ **TAKING IT AWAY TAKES ITS LENGTH WITH IT** — see `transitionSeconds`.
    var transitionOut: VideoTransitionKind? {
        didSet { if transitionOut == nil { transitionSeconds = nil } }
    }
    /// How long that transition runs, in PLAYED seconds, as the author asked —
    /// what is drawn is clamped to what the two pieces can give
    /// (`VideoExporter.transitionHalf`). Nil is the standard half second.
    ///
    /// ⚠️ **NIL FOR THE STANDARD, AND NIL ON A PLAIN CUT — WRITES ARE TURNED INTO
    /// IT, IN THE INITIALISER TOO.** A length stored where no transition is, or
    /// 0.5 spelled next to nil, would be two spellings of the same film and break
    /// every equality that compares timelines — the rule `filter` and
    /// `transitionOut` already follow. So the first edit made before a duration
    /// existed is the same value today.
    var transitionSeconds: Double? {
        didSet {
            let kept = Self.stored(transitionSeconds, for: transitionOut)
            if kept != transitionSeconds { transitionSeconds = kept }
        }
    }

    /// What `transitionSeconds` keeps of `seconds` on a cut carrying `kind`.
    private static func stored(_ seconds: Double?, for kind: VideoTransitionKind?) -> Double? {
        guard kind != nil, let seconds, seconds.isFinite,
              abs(seconds - VideoTransitionKind.standardSeconds) >= 0.0005
        else { return nil }
        return seconds
    }
    /// The look this piece alone wears, under the whole media's.
    ///
    /// ⚠️ **IT BELONGS TO THE PIECE, SO IT TRAVELS WITH IT** — re-ordered with
    /// it, kept by both halves of a split (`split` copies the piece), kept by a
    /// rate change and a move.
    ///
    /// ⚠️ **NIL IS NO FILTER, AND `.original` IS NEVER STORED** — a write of
    /// `.original` becomes nil, in the initialiser too. Two spellings of "none"
    /// would break every equality that compares timelines, the same rule
    /// `transitionOut` follows.
    var filter: MediaFilter? {
        didSet { if filter == .original { filter = nil } }
    }

    init(
        start: Double, end: Double, speed: Double = 1, transitionOut: VideoTransitionKind? = nil,
        transitionSeconds: Double? = nil, filter: MediaFilter? = nil
    ) {
        self.start = start
        self.end = end
        self.speed = speed
        self.transitionOut = transitionOut
        // ⚠️ An initialiser runs no `didSet`: the same rule, said here too.
        self.transitionSeconds = Self.stored(transitionSeconds, for: transitionOut)
        self.filter = filter == .original ? nil : filter
    }

    /// How much of the FILE this piece covers.
    var sourceSeconds: Double { max(end - start, 0) }

    /// How long it will RUN once played at its speed.
    var playedSeconds: Double {
        guard speed > 0, speed.isFinite else { return sourceSeconds }
        return sourceSeconds / speed
    }
}

/// What the author has made of a clip: the pieces they kept, in order.
///
/// ⚠️ **EMPTY IS THE WHOLE CLIP, AND IT IS NOT THE SAME AS ONE SEGMENT COVERING
/// EVERYTHING.** The distinction `cuts(_:withinSource:)` draws, and it is
/// sharper here than it was for a trim: an empty timeline exports by
/// passthrough, and `AVAssetExportPresetPassthrough` **ignores `videoComposition`
/// and `audioMix` outright**. One segment at 1× spanning the file is a full
/// re-encode that produces the same pictures. Every untouched video would pay
/// for a feature it is not using.
///
/// ⚠️ **NO PER-SEGMENT IDENTITY YET, DELIBERATELY.** A list that can be split and
/// re-ordered needs stable ids; a list that only ever holds one does not, and an
/// unused field is dead code — the rule this repository has already applied to a
/// composition slot and to a `stopPreview()` that could not be reached. Identity
/// arrives with the split.
struct MediaTimeline: Equatable, Sendable {
    var segments: [MediaSegment]

    init(segments: [MediaSegment] = []) {
        self.segments = segments
    }

    static let whole = MediaTimeline()

    var isWhole: Bool { segments.isEmpty }
}
