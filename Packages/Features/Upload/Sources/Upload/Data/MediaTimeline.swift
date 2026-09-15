import Foundation

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

    init(start: Double, end: Double, speed: Double = 1) {
        self.start = start
        self.end = end
        self.speed = speed
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
