import CoreGraphics
import Foundation

/// The arithmetic behind the timeline.
///
/// ⚠️ **PURE, AND DELIBERATELY SO — the same reason `StraightenDial` is.** A
/// `UIPanGestureRecognizer`'s translation cannot be set and a `UIScrollView`'s
/// content offset cannot be driven from a test without a window, so a decision
/// that lives inside a gesture handler or a scroll callback is a decision no
/// test can ask about. Every rule that could be wrong is here.
///
/// ⚠️ **AND EVERY FUNCTION SAYS WHICH CLOCK IT SPEAKS.** The trim arithmetic
/// this replaces could
/// take a bare `seconds` because source time and played time were the same
/// number. A speed ends that, and the two are mixed up silently: a handle placed
/// with played seconds over a filmstrip drawn in source seconds looks plausible
/// and cuts the wrong frame.
enum MediaTimelining {
    // MARK: - The scale

    /// How wide one SOURCE second is drawn.
    ///
    /// A judgement, not a measurement: at 60 a ten-second clip is 600pt, which
    /// scrolls on every phone this ships to and still shows enough of itself to
    /// aim with. It is the one number a zoom would later vary, which is why
    /// nothing below hard-codes it.
    ///
    /// ⚠️ **SOURCE, BECAUSE THE TRACK IS A PICTURE OF THE FILE.** The strip shows
    /// the WHOLE clip with the kept part bracketed — the discarded head and tail
    /// have to be on screen or there is nothing to drag a handle back across, and
    /// they exist in source time only. The ruler above it marks source time for
    /// the same reason. At 1x that is also played time, which is why C1 can have
    /// one pair of functions; the day a segment plays at 2x the two stop agreeing
    /// and the PLAYED pair arrives with it. Until then a played-time
    /// point-conversion would be a synonym nobody calls.
    static let pointsPerSecond: CGFloat = 60

    /// The shortest piece a cut may leave behind, in SOURCE seconds.
    ///
    /// ⚠️ A CEILING AS WELL AS A FLOOR — a clip already shorter than this cannot
    /// be cut at all, and `shortest(within:)` is what stops the rule inverting.
    static let shortestSourceSeconds: Double = 1

    static func shortest(withinSource duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(shortestSourceSeconds, duration)
    }

    static func x(atSourceSeconds seconds: Double, pointsPerSecond: CGFloat = pointsPerSecond) -> CGFloat {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return CGFloat(seconds) * pointsPerSecond
    }

    static func sourceSeconds(atX x: CGFloat, pointsPerSecond: CGFloat = pointsPerSecond) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double(max(x, 0) / pointsPerSecond)
    }

    /// A DISTANCE in points as a distance in seconds — signed.
    ///
    /// ⚠️ **NOT `sourceSeconds(atX:)`, AND THE DIFFERENCE IS INVISIBLE UNTIL A
    /// DRAG GOES LEFT.** That one answers "which moment is here", so it floors at
    /// zero: no clip has a moment before its start. This one answers "how far did
    /// the finger travel", and a leftward drag is a negative number. Feeding a
    /// drag delta to the position converter turns every leftward sample into
    /// `max(-12, 0) == 0`, so a handle would open outwards and refuse to come
    /// back — a control that is half dead in a way that looks like a clamp.
    static func sourceSeconds(ofPoints points: CGFloat, pointsPerSecond: CGFloat = pointsPerSecond) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double(points / pointsPerSecond)
    }

    // MARK: - The scrolling track

    /// How wide the strip has to be to hold the whole clip.
    static func contentWidth(
        ofSourceSeconds duration: Double, pointsPerSecond: CGFloat = pointsPerSecond
    ) -> CGFloat {
        x(atSourceSeconds: duration, pointsPerSecond: pointsPerSecond)
    }

    /// The padding at each end of the strip.
    ///
    /// ⚠️ **HALF THE TRACK, BECAUSE THE PLAYHEAD IS NAILED TO THE CENTRE.** The
    /// strip moves and the line does not — which is the whole gesture: you push
    /// the film past a fixed needle. Without this inset the first frame could
    /// never reach the needle (the content starts at the left edge) and neither
    /// could the last, so the first and last seconds of every clip would be
    /// unreachable. Half a track of emptiness at each end is what makes the two
    /// ends of the film addressable at all, and it is why the scroller's resting
    /// offset is NEGATIVE rather than zero.
    static func centringInset(forTrackWidth width: CGFloat) -> CGFloat {
        max(width, 0) / 2
    }

    /// Which moment of the file is under the needle, at a given scroll offset.
    ///
    /// Clamped into the clip: a scroll view rubber-bands past both ends, and the
    /// time under the needle there is a moment the file does not have.
    static func sourceSeconds(
        atContentOffset offset: CGFloat, trackWidth: CGFloat,
        pointsPerSecond: CGFloat = pointsPerSecond, withinSource duration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let atNeedle = offset + centringInset(forTrackWidth: trackWidth)
        let seconds = sourceSeconds(atX: atNeedle, pointsPerSecond: pointsPerSecond)
        return min(max(seconds, 0), duration)
    }

    /// The offset that brings `seconds` under the needle — the inverse of the
    /// above, for following playback and for opening on a stored cut.
    static func contentOffset(
        forSourceSeconds seconds: Double, trackWidth: CGFloat,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> CGFloat {
        x(atSourceSeconds: seconds, pointsPerSecond: pointsPerSecond)
            - centringInset(forTrackWidth: trackWidth)
    }

    // MARK: - Splitting, and rates
    //
    // ⚠️ **NOTHING ON SCREEN REACHES THESE YET, AND THAT IS DELIBERATE RATHER
    // THAN FORGOTTEN.** The control that offers them is the second selector
    // (charter F18). They are here first because the EXPORT had to be able to
    // honour a split before one could be offered: `PickedVideo` carried a single
    // range and the exporter a single `insertTimeRange`, so a split would have
    // published its first piece and dropped the rest — silently, because what
    // comes out is a perfectly good video. Arithmetic and export first, button
    // second, is the order that makes the button safe to draw.

    /// Which piece a moment falls in, if any.
    ///
    /// ⚠️ **BY TIME, NOT BY AN IDENTIFIER — AND `MediaSegment` STILL HAS NONE.**
    /// The model says identity arrives when a list can be re-ordered; split and
    /// speed both act on "the piece under the needle", which is a question about
    /// time. Adding an id now would be a field nothing reads, which is the dead
    /// code this repository has already removed twice.
    static func pieceIndex(
        atSourceSeconds seconds: Double, within pieces: [MediaSegment]
    ) -> Int? {
        guard seconds.isFinite else { return nil }
        return pieces.firstIndex { seconds >= $0.start && seconds < $0.end }
            ?? (pieces.isEmpty ? nil : (seconds >= (pieces.last?.end ?? 0) ? pieces.count - 1 : nil))
    }

    /// Cuts the piece under `seconds` in two.
    ///
    /// ⚠️ **REFUSED WHEN EITHER HALF WOULD BE UNDER THE FLOOR, AND REFUSING IS
    /// THE WHOLE RULE.** A split that leaves a tenth of a second behind makes a
    /// piece whose handles cannot move and whose export is a single frame — the
    /// same "control that reaches nothing" a too-short clip already says out loud.
    /// Returning the timeline unchanged is what lets the caller say so.
    static func split(
        _ timeline: MediaTimeline, atSourceSeconds seconds: Double, withinSource duration: Double
    ) -> MediaTimeline {
        let pieces = resolved(timeline, withinSource: duration)
        guard let index = pieceIndex(atSourceSeconds: seconds, within: pieces) else {
            return timeline
        }
        let piece = pieces[index]
        let floor = shortest(withinSource: duration)
        guard seconds - piece.start >= floor, piece.end - seconds >= floor else { return timeline }

        var cut = pieces
        cut[index] = MediaSegment(start: piece.start, end: seconds, speed: piece.speed)
        cut.insert(
            MediaSegment(start: seconds, end: piece.end, speed: piece.speed), at: index + 1
        )
        return MediaTimeline(segments: cut)
    }

    /// Whether a split at this moment would do anything — what a button asks
    /// before offering itself.
    ///
    /// ⚠️ **COUNTED, NOT COMPARED.** This first asked whether `split` had returned
    /// something different from the timeline it was given — and `.whole` is a
    /// DIFFERENT VALUE from the one piece it resolves to, so an untouched clip
    /// always looked splittable, including a tenth of a second from its end. The
    /// question is whether there is one more piece afterwards.
    static func canSplit(
        _ timeline: MediaTimeline, atSourceSeconds seconds: Double, withinSource duration: Double
    ) -> Bool {
        let before = resolved(timeline, withinSource: duration).count
        let after = resolved(
            split(timeline, atSourceSeconds: seconds, withinSource: duration),
            withinSource: duration
        ).count
        return after > before
    }

    /// The rates a person is offered. Anything between is arithmetic nobody asked
    /// for; these are the detents every reference ships.
    static let rates: [Double] = [0.25, 0.5, 1, 2, 4]

    /// Sets the rate of the piece under `seconds`, leaving the others alone.
    static func setRate(
        _ rate: Double, at seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> MediaTimeline {
        var pieces = resolved(timeline, withinSource: duration)
        guard let index = pieceIndex(atSourceSeconds: seconds, within: pieces) else {
            return timeline
        }
        let piece = pieces[index]
        pieces[index] = MediaSegment(start: piece.start, end: piece.end, speed: rate)
        return MediaTimeline(segments: pieces)
    }

    /// The rate the piece under `seconds` plays at — what a chosen chip shows.
    static func rate(
        at seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> Double {
        let pieces = resolved(timeline, withinSource: duration)
        guard let index = pieceIndex(atSourceSeconds: seconds, within: pieces) else { return 1 }
        return pieces[index].speed
    }

    // MARK: - Playback stays inside the cut

    /// Where playback should jump back to, if it has run outside what is kept.
    ///
    /// ⚠️ **A CUT IS A PROMISE ABOUT WHAT THE POST WILL BE, AND PREVIEW HAS TO
    /// KEEP IT.** A clip that plays on past the end handle is showing the author
    /// footage they have just decided to throw away, and showing it as though it
    /// were part of the result. The same is true at the head: a trimmed opening
    /// that still plays first means the preview and the export disagree about
    /// where the post begins.
    ///
    /// ⚠️ **AND THE SLACK IS WHAT STOPS IT THRASHING.** Turning back at exactly
    /// the end handle races the player, which may report a time a frame past it
    /// and be sent back again and again; turning back a little early is
    /// invisible and settles. Coming back to the start, the playhead is inside
    /// by construction, so the return trip cannot re-trigger.
    ///
    /// Nil is the ordinary answer — the playhead is inside the cut and nothing
    /// needs to happen.
    static func loopback(
        playheadSeconds playhead: Double, within pieces: [MediaSegment], slack: Double = 0.06
    ) -> Double? {
        guard playhead.isFinite,
              let start = pieces.first?.start, let end = pieces.last?.end,
              end > start
        else { return nil }
        if playhead >= end - slack { return start }
        if playhead < start - slack { return start }
        return nil
    }

    // MARK: - Following smoothly

    /// The biggest move the film may make in one beat without being eased.
    ///
    /// ⚠️ **PLAYBACK IS A STEP; EVERYTHING ELSE IS A JUMP.** Following a clip at
    /// sixty points a second on a sixty-hertz display moves the film ONE POINT a
    /// beat, and a dropped frame makes it two or three — easing that would put a
    /// quarter-second animation on top of motion that is already smooth, and the
    /// film would swim. What is not smooth is a DISCONTINUITY: letting go of a
    /// handle after the player has been seeked somewhere else, or the playhead
    /// turning back at the end of the cut. Those move tens of points at once, and
    /// they are what reads as brusque.
    ///
    /// Twelve points is comfortably above any beat of playback — a run of eight
    /// consecutive dropped frames — and far below the smallest jump worth easing.
    static let stepWithoutEasing: CGFloat = 12

    /// Whether a move of the film this far should be eased rather than taken at
    /// once.
    static func easesFollow(byPoints distance: CGFloat) -> Bool {
        guard distance.isFinite else { return false }
        return abs(distance) > stepWithoutEasing
    }

    // MARK: - Zoom

    /// ⚠️ **THE RANGE A PINCH MAY REACH, AND BOTH ENDS ARE REASONED.** Below
    /// `closest` a tile covers so little film that two neighbours are the same
    /// frame and the strip stops being informative; above `widest` a
    /// four-minute clip is 4800pt — one screenful for every twelve seconds — and
    /// the handles cannot be aimed, which is the static-strip failure this whole
    /// design exists to avoid, arrived at by zooming out.
    static let widestPointsPerSecond: CGFloat = 12
    static let closestPointsPerSecond: CGFloat = 320

    /// The scale a pinch arrives at, kept inside the range.
    static func zoomed(_ pointsPerSecond: CGFloat, by scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0, pointsPerSecond.isFinite, pointsPerSecond > 0 else {
            return pointsPerSecond
        }
        return min(max(pointsPerSecond * scale, widestPointsPerSecond), closestPointsPerSecond)
    }

    // MARK: - The film, tile by tile

    /// One square of film.
    ///
    /// ⚠️ **A CONSTANT WIDTH, WHICH IS WHAT MAKES THE STRIP SCALE.** The first
    /// version fitted a FIXED NUMBER of thumbnails across the whole clip, so a
    /// 52-second clip got 32 cells of 97pt — stretched crops of a square picture —
    /// and a four-minute clip would have got 32 cells of 450pt, which is not a
    /// filmstrip at all. At a constant tile the sampling is the same everywhere
    /// and the COUNT grows with the clip, which is only affordable because the
    /// tiles off screen are never decoded.
    static let tileWidth: CGFloat = 54

    /// How many tiles a clip is worth.
    static func tileCount(acrossContentWidth width: CGFloat, tileWidth: CGFloat = tileWidth) -> Int {
        guard width > 0, tileWidth > 0 else { return 0 }
        return Int((width / tileWidth).rounded(.up))
    }

    /// How far apart two tiles are in SOURCE seconds — what the generator's
    /// tolerance is derived from.
    static func tileSpacingSeconds(
        tileWidth: CGFloat = tileWidth, pointsPerSecond: CGFloat = pointsPerSecond
    ) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double(tileWidth / pointsPerSecond)
    }

    /// The moment a tile should show: the MIDDLE of the stretch it covers.
    ///
    /// ⚠️ **THE MIDDLE, NOT THE EDGE.** Asking at a tile's leading edge lands the
    /// first tile on exactly zero, which is the opening fade so much real film
    /// starts with — the same reason `VideoExporter.posterImage` stopped sampling
    /// there — and the last tile on the instant the clip ends, where there is
    /// frequently no frame at all.
    static func sourceSeconds(
        ofTile index: Int, tileWidth: CGFloat = tileWidth,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double((CGFloat(index) + 0.5) * tileWidth / pointsPerSecond)
    }

    /// Which tiles are on screen, widened by a margin so a scroll does not
    /// arrive at an empty edge.
    ///
    /// ⚠️ **THIS IS THE WHOLE OF CHARTER T2.** A 54pt tile across a 393pt track
    /// is eight on screen; with the margin, sixteen. That number does not change
    /// when the clip gets longer, which is what makes a four-minute clip cost the
    /// same at rest as a ten-second one. Measured elsewhere: a thumbnail at this
    /// size is 198 KB, so six hundred of them — an eager ten-minute strip — is
    /// 116 MB for a band 74pt tall.
    static func visibleTiles(
        contentOffset: CGFloat, trackWidth: CGFloat, tileWidth: CGFloat = tileWidth,
        count: Int, margin: Int = 4
    ) -> Range<Int> {
        guard count > 0, tileWidth > 0, trackWidth > 0 else { return 0..<0 }
        let first = Int((contentOffset / tileWidth).rounded(.down)) - margin
        let last = Int(((contentOffset + trackWidth) / tileWidth).rounded(.up)) + margin
        let low = min(max(first, 0), count)
        let high = min(max(last, low), count)
        return low..<high
    }

    /// How far either side of the asked-for moment a scrub's seek may land —
    /// charter T7.
    ///
    /// ⚠️ **AS TOLERANT AS THE SCRUB IS FAST, AND A CONSTANT IS WRONG AT BOTH
    /// ENDS.** An exact seek decodes forward from the nearest keyframe; asked
    /// exactly, sixty times a second, the picture falls behind the finger and
    /// then catches up in lurches. Asked loosely while the finger creeps, the
    /// picture does not move at all and the track feels dead. The distance this
    /// sample moved IS the speed — a fling moves seconds per frame and gets cheap
    /// keyframes, a crawl moves milliseconds and gets the exact frame it is
    /// asking for. Read off `VideoTimelineView`, which arrives at the same rule.
    /// ⚠️ **THE CEILING CAME DOWN FROM A SECOND, AND A SECOND WAS PART OF THE
    /// JUMPING.** A tolerant seek lands on the nearest sync sample, so on a clip
    /// with a two-second GOP a tolerance of one second moves the picture in
    /// keyframe steps — which is exactly the "the video jumps instead of
    /// progressing" that a fast scroll was reported to show. The looseness was
    /// bought to keep up with a finger; the chase in
    /// `VideoPlaybackController.seek` is what actually keeps up, by never having
    /// more than one seek in flight, and it makes a tight tolerance affordable.
    /// A quarter second is `VideoPlaybackController`'s own long-standing default
    /// and the most a scrub should ever land away from where it was asked.
    static func seekTolerance(
        movedSeconds moved: Double, tightest: Double = 0.02, loosest: Double = 0.25
    ) -> Double {
        guard moved.isFinite else { return loosest }
        return min(max(abs(moved), tightest), loosest)
    }

    // MARK: - Who owns the time

    /// What the track is waiting for before it lets the player move it again.
    ///
    /// ⚠️ **TWO CLOCKS CANNOT BOTH BE RIGHT, AND THE HANDOVER IS WHERE THEY SWAP.**
    /// While a finger is down the TRACK owns the time and the player follows it;
    /// while the clip runs the PLAYER owns it and the track follows. The moment
    /// the finger lifts is the only place both want it, and a seek is neither
    /// instant nor exact — `VideoPlaybackController.seek` is deliberately
    /// tolerant by a quarter second. Letting the track follow immediately means
    /// the first tick reads a player that has not moved yet and drags the film
    /// back to where the scrub started, which looks exactly like the scrub being
    /// ignored.
    struct Handover: Equatable, Sendable {
        /// Where the author left the needle, in SOURCE seconds. Nil means the
        /// player owns the time and the track simply follows.
        var target: Double?
        /// How many times we have looked and not seen the player arrive.
        var ticksWaited: Int = 0

        static let settled = Handover(target: nil)
    }

    /// How close the player has to get before the track believes it arrived.
    ///
    /// Wider than the seek's own quarter-second tolerance, because the player is
    /// running again by the time it is asked and has moved on a little.
    static let handoverTolerance: Double = 0.4

    /// How long the track will wait before following anyway.
    ///
    /// ⚠️ **A HANDOVER THAT NEVER COMPLETES WOULD FREEZE THE TRACK FOREVER.** The
    /// player can legitimately never reach the target — a scrub past the end, a
    /// clip that looped, a seek the item refused — and the failure mode of
    /// waiting for it is a timeline that stops following playback altogether,
    /// with nothing on screen to say why. Half a second at 60Hz.
    static let handoverTicks = 30

    /// Whether the track may take its position from the player yet.
    ///
    /// Returns the decision and the state to carry into the next tick.
    static func handover(
        _ state: Handover, playerSeconds: Double, tolerance: Double = handoverTolerance
    ) -> (follow: Bool, next: Handover) {
        guard let target = state.target else { return (true, .settled) }
        guard playerSeconds.isFinite else {
            return (false, Handover(target: target, ticksWaited: state.ticksWaited + 1))
        }
        if abs(playerSeconds - target) <= tolerance { return (true, .settled) }
        let waited = state.ticksWaited + 1
        if waited >= handoverTicks { return (true, .settled) }
        return (false, Handover(target: target, ticksWaited: waited))
    }

    // MARK: - The ruler

    /// The gaps a ruler is allowed to label with, in seconds.
    ///
    /// Only numbers a person reads as a round amount of time: 3 and 20 are
    /// arithmetically fine and "0:03, 0:06, 0:09" is not how anyone thinks about
    /// a clip.
    static let rulerSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// How far apart to label the ruler.
    ///
    /// ⚠️ **TWO RULES, AND THE SECOND ONE IS NOT ABOUT READABILITY.** The first
    /// is spacing: at 60pt per second a label every second is 60pt apart and the
    /// timecodes touch. The second is COUNT — every tick is a view, and a
    /// forty-minute clip at a two-second step is twelve hundred of them for a
    /// strip 74pt tall. Capping the count makes the ruler coarser on a long clip,
    /// which is right; capping the ticks after the fact would silently stop the
    /// ruler partway along a clip that kept scrolling, which is a lie.
    ///
    /// Falls back to the widest gap offered rather than to nothing: a ruler with
    /// too few marks is still a ruler.
    static func rulerStep(
        pointsPerSecond: CGFloat = pointsPerSecond,
        acrossSourceSeconds duration: Double,
        minimumSpacing: CGFloat = 64,
        maximumTicks: Int = 64
    ) -> Double {
        let fits: (Double) -> Bool = { step in
            CGFloat(step) * pointsPerSecond >= minimumSpacing
                && (!duration.isFinite || duration / step <= Double(maximumTicks))
        }
        return rulerSteps.first(where: fits) ?? rulerSteps[rulerSteps.count - 1]
    }

    /// The moments to mark, from zero, at most one past the end of the clip.
    ///
    /// ⚠️ **ONE PAST THE END, DELIBERATELY.** The last mark before the end can sit
    /// most of a step short of it, and a ruler that simply stops there leaves the
    /// tail of the clip looking unmeasured. The overshoot is drawn inside the
    /// trailing inset, where there is room for it.
    static func rulerSeconds(upToSourceSeconds duration: Double, step: Double) -> [Double] {
        guard duration.isFinite, duration > 0, step.isFinite, step > 0 else { return [] }
        var marks: [Double] = []
        var at: Double = 0
        while at <= duration + step {
            marks.append(at)
            at += step
            // The count is bounded by `rulerStep` above; this is the backstop for
            // a caller that passed its own step, not the working limit.
            if marks.count >= 512 { break }
        }
        return marks
    }

    // MARK: - Resolving

    /// The timeline as concrete pieces, every one inside the file and in order.
    ///
    /// ⚠️ **EVERY READER GOES THROUGH THIS.** A stored timeline can outlive the
    /// clip it was made for — a draft, a re-pick, a library answering a different
    /// file — so "keep 4s to 9s" against a two-second clip has to mean something
    /// rather than hand an exporter a range that is not in the asset. The trim
    /// slice learned this the expensive way, when a strip laid out against a
    /// declared duration cut a file of a different length.
    ///
    /// An empty timeline resolves to the whole clip as one piece at 1×, so
    /// callers that want pieces need not special-case it. Callers that must tell
    /// a passthrough from a re-encode ask `cuts(_:withinSource:)`, which is a
    /// different question.
    static func resolved(_ timeline: MediaTimeline, withinSource duration: Double) -> [MediaSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        guard !timeline.segments.isEmpty else {
            return [MediaSegment(start: 0, end: duration)]
        }
        let floor = shortest(withinSource: duration)
        var kept: [MediaSegment] = []
        for segment in timeline.segments {
            // ⚠️ **A PIECE ENTIRELY OUTSIDE THE FILE IS DROPPED, NOT DRAGGED IN.**
            // Clamping it would place it on the last second — and a stale
            // timeline of several such pieces would export that same second over
            // and over, which looks deliberate and is nonsense. A piece that
            // OVERLAPS the file is still clamped: that part of it is real.
            guard segment.start < duration, segment.end > 0 else { continue }
            let end = min(max(segment.end, 0), duration)
            // The start yields to the end, never the other way around — an
            // inverted range is the one shape an exporter cannot be handed.
            let start = min(max(segment.start, 0), max(end - floor, 0))
            guard end > start else { continue }
            kept.append(
                MediaSegment(start: start, end: end, speed: speed(of: segment))
            )
        }
        // A timeline whose every piece fell away is not an empty timeline — it
        // is a broken one, and the honest answer is the clip itself.
        return kept.isEmpty ? [MediaSegment(start: 0, end: duration)] : kept
    }

    /// ⚠️ **A SPEED OF ZERO IS A CLIP THAT NEVER ENDS.** `playedSeconds` divides
    /// by it, and an exporter handed an infinite target duration does not fail
    /// politely. Clamped where the value enters, not where it is used.
    static func speed(of segment: MediaSegment) -> Double {
        guard segment.speed.isFinite, segment.speed > 0 else { return 1 }
        return min(max(segment.speed, slowest), fastest)
    }

    /// The range AVFoundation's pitch algorithms actually cover
    /// (`AVAudioProcessingSettings` documents 1/32 to 32 for every one of them).
    /// Far wider than anything a person would choose; this is a guard, not a UI.
    static let slowest: Double = 1 / 32
    static let fastest: Double = 32

    /// How long the finished clip will run, in PLAYED seconds.
    static func playedSeconds(of timeline: MediaTimeline, withinSource duration: Double) -> Double {
        resolved(timeline, withinSource: duration).reduce(0) { $0 + $1.playedSeconds }
    }

    /// Whether this timeline asks for anything other than the clip as shot.
    ///
    /// ⚠️ **NOT `!timeline.isWhole`.** One segment spanning the file at 1× is a
    /// different VALUE from `.whole` and the same INSTRUCTION, and only the
    /// passthrough route copies the bytes —
    /// `AVAssetExportPresetPassthrough` ignores any composition it is given, so
    /// the two paths are genuinely different work.
    static func cuts(_ timeline: MediaTimeline, withinSource duration: Double) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        let pieces = resolved(timeline, withinSource: duration)
        guard pieces.count == 1, let only = pieces.first else { return true }
        return only.start > 0.001
            || only.end < duration - 0.001
            || abs(only.speed - 1) > 0.001
    }

    // MARK: - The outer handles

    /// Which end of the whole timeline a touch took hold of.
    ///
    /// ⚠️ **TWO, BECAUSE C1 HAS ONE PIECE.** A split timeline has *n+1*
    /// boundaries and an interior one is shared by two pieces — moving it must
    /// shorten one and lengthen its neighbour, which is a different rule and
    /// arrives with the split. This is the outer pair only, and says so.
    enum Edge: Equatable, Sendable {
        case start
        case end
    }

    /// Moves the timeline's first start or last end by a number of SOURCE
    /// seconds, keeping the piece inside the file and no shorter than the floor.
    ///
    /// ⚠️ **INCREMENTAL, LIKE THE DIAL — NOT MEASURED FROM TOUCH-DOWN.** The
    /// view zeroes the recogniser's translation every sample and hands over the
    /// delta, so a drag that runs into an end and comes back does not first have
    /// to undo the distance it overshot by. Measured-from-origin dragging is what
    /// makes a control feel stuck at its limits.
    static func moved(
        _ timeline: MediaTimeline, edge: Edge, bySourceSeconds delta: Double,
        withinSource duration: Double
    ) -> MediaTimeline {
        guard duration.isFinite, duration > 0 else { return timeline }
        var pieces = resolved(timeline, withinSource: duration)
        let floor = shortest(withinSource: duration)
        switch edge {
        case .start:
            guard var first = pieces.first else { return timeline }
            let limit = max(first.end - floor, 0)
            first.start = min(max(first.start + delta, 0), limit)
            pieces[0] = first
        case .end:
            guard var last = pieces.last else { return timeline }
            let limit = min(last.start + floor, duration)
            last.end = max(min(last.end + delta, duration), limit)
            pieces[pieces.count - 1] = last
        }
        return MediaTimeline(segments: pieces)
    }

    /// Which edge a touch at `x` takes, if either. `x` is in the track's own
    /// coordinates, so both ends are PLAYED positions.
    ///
    /// ⚠️ **THE NEARER ONE WINS A TIE, AND THE TIE IS REAL.** Cut to the
    /// minimum, the two handles are a few points apart and one touch is within
    /// reach of both. Answering `.start` by default would make the end handle
    /// unreachable exactly when the author wants to widen the selection again.
    static func edge(
        at x: CGFloat, startX: CGFloat, endX: CGFloat, reach: CGFloat = 44
    ) -> Edge? {
        let toStart = abs(x - startX)
        let toEnd = abs(x - endX)
        guard min(toStart, toEnd) <= reach else { return nil }
        return toStart <= toEnd ? .start : .end
    }

    // MARK: - Reading a timecode

    /// "0:07", "1:04", "12:30" — a stamp, not a sentence.
    ///
    /// ⚠️ **WRITTEN HERE BECAUSE NOTHING REACHABLE DOES IT.** `MediaPickerGridCell`
    /// has a private copy and `SnapScrubPreviewView` has a better one, but that
    /// lives in `Feed` and a feature package may never import another. A
    /// `DateComponentsFormatter`'s shortest style is still "12 min".
    /// ⚠️ **THE ONE FUNCTION HERE THAT DOES NOT NAME A CLOCK, AND IT IS NOT AN
    /// OVERSIGHT.** It formats a number of seconds and interprets nothing — the
    /// ruler hands it source time and the duration readout hands it played time,
    /// and neither reading is wrong. Naming a clock here would force one of the
    /// two callers to lie.
    static func stamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, total % 60) }
        return String(format: "%d:%02d:%02d", hours, minutes, total % 60)
    }
}
