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

    /// How wide one PLAYED second is drawn.
    ///
    /// A judgement, not a measurement: at 60 a ten-second clip is 600pt, which
    /// scrolls on every phone this ships to and still shows enough of itself to
    /// aim with. It is the one number a zoom varies, which is why nothing below
    /// hard-codes it.
    ///
    /// ⚠️ **PLAYED, AND THE ROUTE HERE WENT THROUGH BOTH ALTERNATIVES.** The
    /// track is a picture of the RESULT: the composition, laid out in the seconds
    /// a viewer will experience.
    ///
    /// - a piece at 2× is drawn HALF as wide as the film it covers, and one at
    ///   0.5× twice as wide — asked for in those words ("il faut le stretch");
    /// - the needle crosses the track at a CONSTANT points-per-second whatever
    ///   rates the pieces carry, and it never leaps: there is nothing between the
    ///   pieces to leap over. *"Le curseur ne devrait jamais faire de saut et
    ///   toujours se deplacer a la meme vitesse"*;
    /// - trimming a piece therefore RIPPLES — everything after it slides along —
    ///   and the discarded film is not drawn at all. It comes back by dragging
    ///   the edge out again.
    ///
    /// ⚠️ **THE OTHER TWO ARRANGEMENTS WERE BUILT AND MEASURED, AND BOTH FAIL ON
    /// SOMETHING THE AUTHOR CAN SEE.** The file at ONE scale cannot stretch a
    /// rate. The file at PER-PIECE scales — the whole clip on the track with the
    /// cut parts greyed — makes an edge drag free of any scrolling, and puts a
    /// hole in the middle of the track for the playhead to jump. Only the
    /// composition keeps the playhead honest, and what it costs is the head-trim
    /// gesture: a piece begins where the one before it ends, so dragging its
    /// START shortens it from the inside and the cap would stand still. The track
    /// pays that by scrolling under the finger, and the scroller's leading inset
    /// grows for the length of the gesture so that the first piece can do it too.
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

    static func x(atPlayedSeconds seconds: Double, pointsPerSecond: CGFloat = pointsPerSecond) -> CGFloat {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return CGFloat(seconds) * pointsPerSecond
    }

    static func playedSeconds(atX x: CGFloat, pointsPerSecond: CGFloat = pointsPerSecond) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double(max(x, 0) / pointsPerSecond)
    }

    /// A DISTANCE in points as a distance in played seconds — signed.
    ///
    /// ⚠️ **NOT `playedSeconds(atX:)`, AND THE DIFFERENCE IS INVISIBLE UNTIL A
    /// DRAG GOES LEFT.** That one answers "which moment is here", so it floors at
    /// zero: no result has a moment before its start. This one answers "how far
    /// did the finger travel", and a leftward drag is a negative number. Feeding
    /// a drag delta to the position converter turns every leftward sample into
    /// `max(-12, 0) == 0`, so a handle would open outwards and refuse to come
    /// back — a control that is half dead in a way that looks like a clamp.
    static func playedSeconds(ofPoints points: CGFloat, pointsPerSecond: CGFloat = pointsPerSecond) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return Double(points / pointsPerSecond)
    }

    /// The same distance as SOURCE seconds, for a piece playing at `speed`.
    ///
    /// ⚠️ **THE STRETCH, SEEN FROM THE FINGER.** A piece at 2× is drawn half as
    /// wide as the film it covers, so trimming one second out of it takes twice
    /// the drag. Converting a drag straight to source seconds — which is what the
    /// single-clock version did — would move a fast piece's edge twice as far as
    /// the finger went.
    static func sourceSeconds(
        ofPoints points: CGFloat, atSpeed rate: Double,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> Double {
        playedSeconds(ofPoints: points, pointsPerSecond: pointsPerSecond) * speed(of: rate)
    }

    // MARK: - The scrolling track

    /// How wide the strip has to be to hold the RESULT.
    static func contentWidth(
        of timeline: MediaTimeline, withinSource duration: Double,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> CGFloat {
        x(
            atPlayedSeconds: playedSeconds(of: timeline, withinSource: duration),
            pointsPerSecond: pointsPerSecond
        )
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

    /// How far into the RESULT the needle is, at a given scroll offset.
    ///
    /// Clamped into the result: a scroll view rubber-bands past both ends, and
    /// the time under the needle there is a moment the post will not have.
    static func playedSeconds(
        atContentOffset offset: CGFloat, trackWidth: CGFloat,
        pointsPerSecond: CGFloat = pointsPerSecond,
        of timeline: MediaTimeline, withinSource duration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let atNeedle = offset + centringInset(forTrackWidth: trackWidth)
        return min(
            max(playedSeconds(atX: atNeedle, pointsPerSecond: pointsPerSecond), 0),
            playedSeconds(of: timeline, withinSource: duration)
        )
    }

    /// The offset that brings a moment of the RESULT under the needle.
    static func contentOffset(
        forPlayedSeconds seconds: Double, trackWidth: CGFloat,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> CGFloat {
        x(atPlayedSeconds: seconds, pointsPerSecond: pointsPerSecond)
            - centringInset(forTrackWidth: trackWidth)
    }

    // MARK: - The composition, piece by piece

    /// Where one piece of the composition is drawn.
    struct Placement: Equatable, Sendable {
        let index: Int
        let piece: MediaSegment
        let from: CGFloat
        let to: CGFloat

        var width: CGFloat { max(to - from, 0) }
        func contains(_ x: CGFloat) -> Bool { x >= from && x <= to }
        var middle: CGFloat { (from + to) / 2 }
    }

    /// The kept pieces laid END TO END, in the order they will play.
    ///
    /// ⚠️ **NOTHING SITS BETWEEN THEM, AND FOR ONE ROUND THE DISCARDED FILM DID.**
    /// The track carried the whole file, holes and all, greyed — which made an
    /// edge drag free of any scrolling and cost the one thing that matters more:
    /// *"le curseur fait un saut sur la timeline alors qu'il ne devrait jamais en
    /// faire et toujours se deplacer a la meme vitesse"*. A hole is a stretch of
    /// track the playhead has to leap, and no arrangement of the drawing can hide
    /// that. So the track is the RESULT again, end to end: trimming a piece
    /// shortens it and everything after it slides along, which is the ripple every
    /// editor does and what was asked for in the same breath.
    ///
    /// ⚠️ **AND THE ORDER IS THE COMPOSITION'S, NOT THE FILE'S.** Pieces can be
    /// dragged past one another, so piece 1 may well start earlier in the file
    /// than piece 0. Nothing here may sort, and nothing may assume a piece's
    /// neighbour is adjacent in the source.
    static func placements(
        _ timeline: MediaTimeline, withinSource duration: Double,
        pointsPerSecond: CGFloat = pointsPerSecond
    ) -> [Placement] {
        var placed: [Placement] = []
        var played: Double = 0
        for (index, piece) in resolved(timeline, withinSource: duration).enumerated() {
            let from = x(atPlayedSeconds: played, pointsPerSecond: pointsPerSecond)
            played += piece.playedSeconds
            let to = x(atPlayedSeconds: played, pointsPerSecond: pointsPerSecond)
            placed.append(Placement(index: index, piece: piece, from: from, to: to))
        }
        return placed
    }

    /// Which piece a touch at `x` content points landed on, if any.
    static func piece(atPoints x: CGFloat, in placed: [Placement]) -> Int? {
        placed.first { $0.contains(x) }?.index
    }

    /// A moment of the RESULT, as the piece that is playing and where in the FILE
    /// it has got to.
    ///
    /// ⚠️ **THE PIECE IS PART OF THE ANSWER, NOT AN IMPLEMENTATION DETAIL.** Once
    /// pieces can be re-ordered, a moment of the file no longer says where in the
    /// result it is — the same second can appear twice, or in a piece that plays
    /// third. Everything downstream (the preview's seeks, the rate the player
    /// runs at, which piece an action targets) needs the piece, so it is carried
    /// rather than recovered.
    struct Moment: Equatable, Sendable {
        let piece: Int
        let sourceSeconds: Double
    }

    static func moment(
        atPlayedSeconds seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> Moment? {
        let pieces = resolved(timeline, withinSource: duration)
        guard let first = pieces.first else { return nil }
        guard seconds.isFinite, seconds > 0 else { return Moment(piece: 0, sourceSeconds: first.start) }
        var remaining = seconds
        for (index, piece) in pieces.enumerated() {
            let played = piece.playedSeconds
            if remaining > played {
                remaining -= played
                continue
            }
            return Moment(
                piece: index,
                sourceSeconds: min(piece.start + remaining * speed(of: piece), piece.end)
            )
        }
        let last = pieces.count - 1
        return Moment(piece: last, sourceSeconds: pieces[last].end)
    }

    /// And back: how far into the result a moment inside a known piece is.
    static func playedSeconds(
        ofPiece index: Int, atSourceSeconds seconds: Double,
        in timeline: MediaTimeline, withinSource duration: Double
    ) -> Double {
        let pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index) else { return 0 }
        var played: Double = 0
        for piece in pieces[..<index] { played += piece.playedSeconds }
        let piece = pieces[index]
        let into = min(max(seconds, piece.start), piece.end) - piece.start
        return played + into / speed(of: piece)
    }

    // MARK: - Splitting, and rates
    //
    // ⚠️ **THE BUTTONS THAT REACH THESE ARRIVED AFTER THEY DID, AND THAT ORDER
    // WAS THE POINT.** `IconActionBar` in the editor's toolbar now calls `split`
    // and `setRate` (charter F18). They were written first because the EXPORT had
    // to be able to honour a split before one could be offered: `PickedVideo`
    // carried a single range and the exporter a single `insertTimeRange`, so a
    // split would have published its first piece and dropped the rest —
    // silently, because what comes out is a perfectly good video. Arithmetic and
    // export first, button second, is what made the button safe to draw.

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
    /// ⚠️ **THE PIECE IS NAMED, NOT LOOKED UP BY TIME.** Pieces can be
    /// re-ordered, so a moment of the file no longer says which piece is under
    /// the needle — the same second can belong to two of them.
    static func split(
        _ timeline: MediaTimeline, atPiece index: Int, atSourceSeconds seconds: Double,
        withinSource duration: Double
    ) -> MediaTimeline {
        let pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index) else { return timeline }
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
        _ timeline: MediaTimeline, atPiece index: Int, atSourceSeconds seconds: Double,
        withinSource duration: Double
    ) -> Bool {
        let before = resolved(timeline, withinSource: duration).count
        let after = resolved(
            split(timeline, atPiece: index, atSourceSeconds: seconds, withinSource: duration),
            withinSource: duration
        ).count
        return after > before
    }

    /// The rates a person is offered. Anything between is arithmetic nobody asked
    /// for; these are the detents every reference ships.
    static let rates: [Double] = [0.25, 0.5, 1, 2, 4]

    /// How a rate is written.
    ///
    /// ⚠️ **ONE SPELLING, TWO PLACES THAT SHOW IT.** The chips offer a rate and
    /// the track stamps the piece that carries one; written twice, "0.5×" on the
    /// chip and "0.50×" on the stamp is the kind of disagreement nobody reports
    /// and everybody sees. The symbol is a multiplication sign, not the letter x
    /// — which is what every reference sets it in.
    static func rateLabel(_ rate: Double) -> String {
        guard rate.isFinite else { return "1×" }
        let whole = rate.rounded()
        if abs(rate - whole) < 0.001 { return "\(Int(whole))×" }
        return String(format: "%g×", (rate * 100).rounded() / 100)
    }

    /// Sets one piece's rate, leaving the others alone.
    static func setRate(
        _ rate: Double, atPiece index: Int, in timeline: MediaTimeline, withinSource duration: Double
    ) -> MediaTimeline {
        var pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index) else { return timeline }
        pieces[index].speed = rate
        return MediaTimeline(segments: pieces)
    }

    /// The same, for the piece under a moment — what the needle asks when the
    /// author has not taken hold of anything.
    static func setRate(
        _ rate: Double, at seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> MediaTimeline {
        let pieces = resolved(timeline, withinSource: duration)
        guard let index = pieceIndex(atSourceSeconds: seconds, within: pieces) else {
            return timeline
        }
        return setRate(rate, atPiece: index, in: timeline, withinSource: duration)
    }

    /// The rate one piece plays at.
    static func rate(atPiece index: Int, in timeline: MediaTimeline, withinSource duration: Double) -> Double {
        let pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index) else { return 1 }
        return pieces[index].speed
    }

    /// Where a moment of the FILE falls in the RESULT.
    ///
    /// ⚠️ **THE READOUT'S TWO HALVES ARE THE SAME CLOCK, AND FOR ONE BUILD THEY
    /// WERE NOT.** It read `stamp(secondsUnderNeedle) + " / " + stamp(played)` —
    /// the position in SOURCE seconds beside the length in PLAYED ones. At 1×
    /// they agree and the defect is invisible; at 2× a seven-second clip showed
    /// "0:04 / 0:04" with the needle half way through, and at 4× the left number
    /// can pass the right one. Measured on the device, which is where it was
    /// seen. `MediaSegment`'s own note says a function taking a bare `seconds` is
    /// a bug waiting to be written; this is the version where the CALLER mixed
    /// them.
    ///
    /// Moments outside what is kept collapse onto the nearest edge of it: a
    /// needle parked in the discarded head of a clip is at 0:00 of the result,
    /// because that is what a viewer will see.
    static func playedSeconds(
        atSourceSeconds seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> Double {
        guard seconds.isFinite else { return 0 }
        var played = 0.0
        for piece in resolved(timeline, withinSource: duration) {
            if seconds >= piece.end {
                played += piece.playedSeconds
                continue
            }
            if seconds > piece.start {
                played += (seconds - piece.start) / speed(of: piece)
            }
            break
        }
        return played
    }

    /// The rate the piece under `seconds` plays at — what a chosen chip shows.
    static func rate(
        at seconds: Double, in timeline: MediaTimeline, withinSource duration: Double
    ) -> Double {
        let pieces = resolved(timeline, withinSource: duration)
        guard let index = pieceIndex(atSourceSeconds: seconds, within: pieces) else { return 1 }
        return pieces[index].speed
    }

    // MARK: - Playing the composition

    // ⚠️ **THE PREVIEW PLAYS THE ARRANGEMENT AS ONE ITEM, AND THERE IS NOTHING
    // HERE ANY MORE.** This section used to hold `next(afterPiece:…)`: the
    // preview played the FILE, and at each piece's end it was SENT to the next
    // piece's start — a seek in the file on every boundary. After a re-order
    // every one of those seeks was a jump across the file, asynchronous and
    // decoded forward from a keyframe, and the author saw it as *"une mini pause
    // / glitch"* between the pieces. The canvas now plays the composition the
    // export builds (`VideoPlaybackController.load`), whose seconds ARE the
    // track's played seconds; a boundary is an edit inside one item, and the
    // only seek left is the loop back to the start.

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

    /// How far apart two tiles are in SOURCE seconds — what the generator's
    /// tolerance is derived from.
    ///
    /// ⚠️ **THE TIGHTEST SPACING IN THE WHOLE TIMELINE, NOT THE AVERAGE.** A tile
    /// is a fixed width of RESULT, so the film it covers depends on the rate of
    /// the piece it falls in: at 4× one tile is four times as much film as at 1×.
    /// The tolerance is derived from this (charter T5: strictly under half the
    /// spacing, or the strip repeats itself), and half of the AVERAGE spacing is
    /// wider than half of the smallest — so a slow piece next to a fast one would
    /// get a tolerance that lands two of its tiles on the same frame. The
    /// slowest piece sets it for everyone.
    static func tileSpacingSeconds(
        in timeline: MediaTimeline, withinSource duration: Double,
        tileWidth: CGFloat = tileWidth, pointsPerSecond: CGFloat = pointsPerSecond
    ) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        let played = Double(tileWidth / pointsPerSecond)
        let rates = resolved(timeline, withinSource: duration).map { speed(of: $0) }
        return played * (rates.min() ?? 1)
    }

    /// ONE SQUARE OF FILM.
    ///
    /// ⚠️ **THE SQUARES ARE A FIXED SHEET AND THE HANDLES ARE A WINDOW ON IT —
    /// THIS IS THE WHOLE MODEL, AND GETTING IT WRONG TWICE IS WHAT THE AUTHOR
    /// KEPT REPORTING.** Stated by them, finally, in one sentence: *"les frames
    /// ne bougent/se déplacent jamais, elles sont ancrées dans un
    /// container/section et c'est cette section qui bouge… quand on joue avec les
    /// pinces on révèle la suite de la piste, comme si le clip était en entier,
    /// seule la partie visible se trouve entre les pinces."*
    ///
    /// So the grid the squares sit on is cut on the **SOURCE**, not on the track:
    /// square `index` always covers source seconds `index × film ..< (index+1) ×
    /// film`, whatever the piece's in and out points happen to be. Opening a
    /// piece's end REVEALS the next squares of that sheet and moves nothing;
    /// closing it hides them again. Two earlier arrangements both failed here:
    /// one row of squares across the whole TRACK re-labelled every square after a
    /// cut, so the pictures changed in place and only the containers moved
    /// (*"c'est le container de la section qui se déplace"*); squares anchored to
    /// a piece's IN POINT kept their places and slid their film, which is the
    /// unfolding the author asked to be rid of.
    struct Square: Equatable, Sendable {
        /// ⚠️ **A PIECE AND AN INDEX ON THE SOURCE GRID, NOT A PLACE ON THE
        /// TRACK** — this is what lets one view keep one frame of film for the
        /// whole of an edit, and simply be moved.
        struct Place: Hashable, Sendable {
            let piece: Int
            let index: Int
        }

        let place: Place
        /// Where the square is DRAWN: the part of it the piece's window shows.
        let from: CGFloat
        let width: CGFloat
        /// Where the WHOLE square would be if the window hid none of it. The
        /// picture is laid at this size inside the drawn rectangle, so a square
        /// the window cuts in half is CROPPED rather than squeezed — and the film
        /// does not shift when the window opens.
        let filmFrom: CGFloat
        let filmWidth: CGFloat
        /// The second of film in the middle of the square — a point on the source
        /// grid, so the same frame is asked for once however many pieces show it.
        let seconds: Double

        var piece: Int { place.piece }
        var index: Int { place.index }
    }

    /// The squares of film to draw across `visible` content points.
    ///
    /// ⚠️ **NO SQUARE STRADDLES A SEAM**: a square belongs to one piece and is cut
    /// off at that piece's edge, so the last frame before a cut is the piece's
    /// real out-point rather than a blend of the two.
    ///
    /// ⚠️ **AND NOTHING IS SNAPPED OR ROUNDED ANY MORE.** An earlier version
    /// asked for the middle of whatever the square happened to cover and rounded
    /// it onto a grid, so that a drag would not ask for sixty new decodes a
    /// second. With the sheet cut on the source, a handle drag changes which
    /// squares are VISIBLE and never what any of them shows: the film a piece has
    /// already decoded is still the film it needs.
    static func squares(
        in timeline: MediaTimeline, withinSource duration: Double,
        visible: ClosedRange<CGFloat>,
        tileWidth: CGFloat = tileWidth, pointsPerSecond: CGFloat = pointsPerSecond
    ) -> [Square] {
        squares(
            along: spans(of: placements(
                timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
            )),
            withinSource: duration, visible: visible,
            tileWidth: tileWidth, pointsPerSecond: pointsPerSecond
        )
    }

    /// The squares of film to draw across `visible` content points, each cut off
    /// where its piece's film is DRAWN.
    ///
    /// ⚠️ **THE SHEET IS PLACED BY THE CLOCK AND CUT BY THE DRAWING.** Where a
    /// square's picture sits — `filmFrom` — comes from the piece's PLACEMENT, so
    /// carving daylight off a piece's end hides a point of film and moves none;
    /// how much of the square shows comes from the SPAN. A square that falls
    /// wholly in the daylight is not made at all, so it is never decoded.
    static func squares(
        along spans: [Span], withinSource duration: Double,
        visible: ClosedRange<CGFloat>,
        tileWidth: CGFloat = tileWidth, pointsPerSecond: CGFloat = pointsPerSecond
    ) -> [Square] {
        guard tileWidth > 0, pointsPerSecond > 0, visible.upperBound > visible.lowerBound
        else { return [] }
        var made: [Square] = []
        for span in spans {
            let at = span.placement
            let rate = speed(of: at.piece)
            let film = Double(tileWidth / pointsPerSecond) * rate
            guard at.width > 0, span.width > 0, rate > 0, film > 0 else { continue }
            // Where a second of the FILE is drawn inside this piece.
            let x = { (second: Double) -> CGFloat in
                at.from + CGFloat((second - at.piece.start) / rate) * pointsPerSecond
            }
            let first = Int((at.piece.start / film).rounded(.down))
            let last = Int((at.piece.end / film).rounded(.up))
            for index in first..<max(last, first + 1) {
                let opens = Double(index) * film
                let closes = opens + film
                let filmFrom = x(opens)
                let from = max(filmFrom, span.from)
                let to = min(x(closes), span.to)
                guard to > from, to > visible.lowerBound, from < visible.upperBound else { continue }
                made.append(
                    Square(
                        place: Square.Place(piece: at.index, index: index),
                        from: from, width: to - from,
                        filmFrom: filmFrom, filmWidth: tileWidth,
                        seconds: min(max(opens + film / 2, 0), duration)
                    )
                )
            }
        }
        return made
    }

    // MARK: - What is drawn between the pieces

    /// Where one piece's FILM is drawn, beside where its TIME is.
    ///
    /// ⚠️ **A SPAN NEVER FEEDS THE CLOCK.** `placement` is the piece on the
    /// composition's axis — what the needle, the ruler, a seek and a tap all
    /// read. `from`/`to` is only how much of that the film fills once daylight
    /// has been carved off its ends. Reading a span where a placement belongs
    /// would put a gap in time that the result does not have.
    struct Span: Equatable, Sendable {
        let placement: Placement
        let from: CGFloat
        let to: CGFloat
        /// The corner the piece's film is rounded to, already clamped to it.
        let radius: CGFloat

        var index: Int { placement.index }
        var width: CGFloat { max(to - from, 0) }
    }

    /// Where each piece's film is drawn: its placement, less half a daylight at
    /// every seam it shares — except on the piece that is HELD.
    ///
    /// ⚠️ **ASKED FOR IN THOSE WORDS**: *"plutôt séparer les segments avec un léger
    /// espace et arrondir les bords"*, in place of the white bar a cut used to
    /// draw. The daylight is CARVED OUT OF THE FILM, centred on the cut, and the
    /// clock keeps none of it: `placements` stays end to end, so the needle, the
    /// ruler and every seek are exactly what they were. The cost is a point of
    /// film hidden at each carved end.
    ///
    /// ⚠️ **THE HELD PIECE KEEPS ALL ITS FILM, AND HOLDING IT MOVES NOTHING
    /// ELSE.** Its caps stand on its cut, and the half-daylight its neighbours
    /// give up sits under them. Each half is worked out WITHOUT asking which
    /// piece is held, so taking a piece changes that piece's film and no other.
    ///
    /// ⚠️ **A HALF IS A WHOLE NUMBER OF PIXELS.** Floored per half at `scale`, so
    /// the daylight never lands on a half pixel and shimmer as the film scrolls;
    /// 1pt halves are whole at 1x, 2x and 3x alike. A piece too narrow to give
    /// up its daylight keeps `minimum` points of film and gives less.
    static func spans(
        of placed: [Placement], gap: CGFloat = 0, holding held: Int? = nil,
        corner: CGFloat = 0, height: CGFloat = .infinity, scale: CGFloat = 0,
        keepingAtLeast minimum: CGFloat = 1
    ) -> [Span] {
        let count = placed.count
        guard count > 0 else { return [] }
        let wanted = gap.isFinite && gap > 0 ? gap / 2 : 0
        let keep = minimum.isFinite ? max(minimum, 0) : 0
        func ends(_ index: Int) -> Int { (index > 0 ? 1 : 0) + (index < count - 1 ? 1 : 0) }
        func room(_ index: Int) -> CGFloat {
            let shared = ends(index)
            guard shared > 0 else { return .infinity }
            return max(placed[index].width - keep, 0) / CGFloat(shared)
        }
        func pixelFloor(_ value: CGFloat) -> CGFloat {
            guard scale > 0, scale.isFinite else { return value }
            return (value * scale + 1e-6).rounded(.down) / scale
        }
        let halves: [CGFloat] = (0..<max(count - 1, 0)).map { seam in
            pixelFloor(max(0, min(wanted, room(seam), room(seam + 1))))
        }
        return placed.enumerated().map { index, at in
            let carvesLeading = index > 0 && index != held
            let carvesTrailing = index < count - 1 && index != held
            let from = at.from + (carvesLeading ? halves[index - 1] : 0)
            let to = max(at.to - (carvesTrailing ? halves[index] : 0), from)
            return Span(
                placement: at, from: from, to: to,
                radius: endRadius(width: to - from, height: height, preferred: corner)
            )
        }
    }

    /// The corner a piece's ends can take.
    ///
    /// ⚠️ **CLAMPED HERE BECAUSE CORE ANIMATION DOES NOT.** Measured on the
    /// simulator: a radius past half the width draws a spike rather than a pill,
    /// and exactly half draws clean, `.continuous` included. A piece zoomed out
    /// to a sliver is a capsule, never a thorn.
    static func endRadius(width: CGFloat, height: CGFloat, preferred: CGFloat) -> CGFloat {
        guard width.isFinite, height.isFinite || height == .infinity, preferred.isFinite
        else { return 0 }
        return max(0, min(preferred, width / 2, height / 2))
    }

    /// The part of one piece's film that is laid out right now: a rounded,
    /// clipping window the piece's squares sit in.
    struct FilmWindow: Equatable, Sendable {
        let piece: Int
        let from: CGFloat
        let to: CGFloat
        let radius: CGFloat
        /// Whether the window's leading edge IS the piece's drawn start — only
        /// then is there a corner to draw there.
        let roundsLeading: Bool
        let roundsTrailing: Bool

        var width: CGFloat { max(to - from, 0) }
    }

    /// One window per piece that has squares: the HULL of those squares.
    ///
    /// ⚠️ **CHARTER T6: A WINDOW IS AS WIDE AS WHAT IS LAID OUT, NEVER AS THE
    /// PIECE.** A four-minute piece is 14400pt, and a rounded clipping layer
    /// that wide is 43200px at 3x — far past the 16384 Metal asserts at. The
    /// squares already stop at the visible band plus its margin, so their hull
    /// is bounded by the track, whatever the clip's length or the zoom. And
    /// because the window is MADE of its squares, no square can exist without a
    /// window to stand in.
    static func windows(of squares: [Square], along spans: [Span]) -> [FilmWindow] {
        var bounds: [Int: (from: CGFloat, to: CGFloat)] = [:]
        for square in squares {
            let known = bounds[square.piece]
            bounds[square.piece] = (
                min(known?.from ?? square.from, square.from),
                max(known?.to ?? square.from + square.width, square.from + square.width)
            )
        }
        return spans.compactMap { span in
            guard let hull = bounds[span.index] else { return nil }
            let leading = hull.from <= span.from + 0.001
            let trailing = hull.to >= span.to - 0.001
            let radius = leading || trailing
                ? min(span.radius, max(hull.to - hull.from, 0) / 2) : 0
            return FilmWindow(
                piece: span.index, from: hull.from, to: hull.to, radius: radius,
                roundsLeading: leading, roundsTrailing: trailing
            )
        }
    }

    /// The two caps around the held piece.
    struct Caps: Equatable, Sendable {
        let start: ClosedRange<CGFloat>
        let end: ClosedRange<CGFloat>

        var centres: (start: CGFloat, end: CGFloat) {
            (
                start.lowerBound + (start.upperBound - start.lowerBound) / 2,
                end.lowerBound + (end.upperBound - end.lowerBound) / 2
            )
        }

        /// Whether a touch at `x` is on the selection — its caps included.
        func claims(_ x: CGFloat) -> Bool {
            x >= start.lowerBound && x <= end.upperBound
        }
    }

    /// ⚠️ **ONE SOURCE FOR WHERE THE CAPS ARE DRAWN, WHERE A FINGER TAKES THEM,
    /// AND WHICH TOUCHES THE SELECTION KEEPS.** Three inline copies of this
    /// arithmetic used to exist; a cap moved in one and not the others is a
    /// handle whose reach is beside it.
    static func caps(around span: Span, grab: CGFloat) -> Caps {
        Caps(
            start: (span.from - grab)...span.from,
            end: span.to...(span.to + grab)
        )
    }

    /// How far a `.continuous` corner runs along each edge, per point of radius.
    /// Measured: at r = 8 the top row reaches full coverage about 11pt in, and
    /// 1.528665 × 8 is 12.2 — a safe upper bound, and any excess is hidden by
    /// the film that stands in front of it.
    static let cornerReach: CGFloat = 1.528665

    /// The four white plates that turn the frame's inner corners into curves:
    /// top leading, top trailing, bottom leading, bottom trailing.
    ///
    /// ⚠️ **THEY STAND BEHIND THE FILM, SO THE CURVE IS THE FILM'S OWN.** The
    /// held piece's window is rounded at its ends; a white plate behind each
    /// corner shows through exactly where the film has been rounded away, and
    /// nowhere else. No path has to be matched to Core Animation's continuous
    /// curve, and a clamped radius — even zero — still closes the frame. The
    /// plates tuck under the cap by `tuck` and reach up under the rail, so their
    /// own edges are never seen.
    static func fillets(
        around span: Span, top: CGFloat, bottom: CGFloat, rail: CGFloat, tuck: CGFloat,
        reach: CGFloat = cornerReach
    ) -> [CGRect] {
        guard span.radius > 0, span.width > 0, bottom > top else { return [] }
        let extent = reach * span.radius + 1
        let wide = min(extent, span.width)
        let tall = min(extent, (bottom - top) / 2)
        let width = wide + tuck
        let height = tall + rail
        return [
            CGRect(x: span.from - tuck, y: top - rail, width: width, height: height),
            CGRect(x: span.to - wide, y: top - rail, width: width, height: height),
            CGRect(x: span.from - tuck, y: bottom - tall, width: width, height: height),
            CGRect(x: span.to - wide, y: bottom - tall, width: width, height: height),
        ]
    }

    /// How far either side of the middle of the track the strip is laid, so a
    /// scroll does not arrive at an empty edge. ⚠️ **CHARTER T2 AND T3 LIVE
    /// HERE**: what bounds the decoding is this margin, not the length of the
    /// clip — a four-minute clip is asked for exactly as many squares as a
    /// ten-second one.
    static let filmMargin: CGFloat = 4 * tileWidth

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

    /// The same rule, for a seek asked in PLAYED seconds — the preview's own
    /// clock — over a piece running at `speed`.
    ///
    /// ⚠️ **T7 IS ABOUT FILM, AND A PLAYED SECOND OF A FAST PIECE IS SEVERAL
    /// SECONDS OF IT.** A quarter-second of slack on a 4× piece is a whole second
    /// of film, which lands the picture on keyframes and makes the scrub jump —
    /// the very thing the ceiling exists to prevent. So the distance is measured
    /// in film, the rule applied there, and the answer brought back to the
    /// item's clock.
    static func seekTolerance(movedPlayedSeconds moved: Double, atSpeed rate: Double) -> Double {
        // Clamped where rates enter, so never zero and never infinite.
        let speed = speed(of: rate)
        return seekTolerance(movedSeconds: moved * speed) / speed
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
        /// Where the author left the needle, in seconds of the preview ITEM —
        /// the played seconds of the arrangement it is running. Nil means the
        /// player owns the time and the track simply follows.
        ///
        /// ⚠️ **IT WAS SOURCE SECONDS, AND AFTER A RE-ORDER THAT WAS AMBIGUOUS:**
        /// the same second of film can stand in two pieces, while a played second
        /// names exactly one moment of the result.
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
        acrossPlayedSeconds duration: Double,
        minimumSpacing: CGFloat = 64,
        maximumTicks: Int = 64
    ) -> Double {
        let fits: (Double) -> Bool = { step in
            CGFloat(step) * pointsPerSecond >= minimumSpacing
                && (!duration.isFinite || duration / step <= Double(maximumTicks))
        }
        return rulerSteps.first(where: fits) ?? rulerSteps[rulerSteps.count - 1]
    }

    /// The moments to mark, from zero to the end of the RESULT and no further.
    ///
    /// ⚠️ **IT USED TO OVERSHOOT BY ONE, AND THE AXIS CHANGE MADE THAT A LIE.**
    /// The extra mark existed because the last one can sit most of a step short
    /// of the end, leaving the tail looking unmeasured — and it was drawn inside
    /// the trailing inset, where there was room. A mark is now placed at the film
    /// that plays AT that moment, and past the end of the result there is no such
    /// film: every overshoot mark clamps onto the last piece's end and piles up
    /// on the one before it. Seen on the device as "0:06" and "0:08" printed on
    /// top of each other. What fills the tail instead is the discarded film,
    /// greyed — which says "not part of this" more plainly than a timecode could.
    static func rulerSeconds(upToPlayedSeconds duration: Double, step: Double) -> [Double] {
        guard duration.isFinite, duration > 0, step.isFinite, step > 0 else { return [] }
        var marks: [Double] = []
        var at: Double = 0
        while at <= duration {
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
            //
            // ⚠️ **BUT ONLY WHEN IT IS ACTUALLY CROSSED — THE UNCONDITIONAL
            // VERSION GREW A CLIP NOBODY HAD TOUCHED.** This read
            // `min(max(start, 0), end - floor)` for every piece, so one that
            // arrived SHORTER than a second had its start pulled earlier to make
            // it one: [3.5…4.0] against a ten-second file came back as
            // [3.0…4.0] — half a second of film the author had cut away handed
            // back to them, in a piece they had not touched, with a total that
            // disagreed with the edit they left. The floor is a refusal, enforced
            // where a piece is MADE (`moved`, `canSplit`); reading one back is
            // not the place to rewrite it. A CROSSED range is different: it is
            // corrupt rather than short, and the repair is the documented one —
            // the start yields, the end holds.
            let asked = max(segment.start, 0)
            let start = asked < end ? asked : max(end - floor, 0)
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
    static func speed(of segment: MediaSegment) -> Double { speed(of: segment.speed) }

    /// The same clamp on a bare rate — the drag converter needs it before there
    /// is a segment to ask.
    static func speed(of rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 1 }
        return min(max(rate, slowest), fastest)
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

    // MARK: - Carrying a piece to a new place

    /// The same pieces, one of them moved.
    ///
    /// ⚠️ **THE ORDER IS THE COMPOSITION'S, AND NOTHING ELSE MAY SORT.** A
    /// re-ordered timeline can have piece 1 starting earlier in the file than
    /// piece 0; `resolved` keeps what it is given, `placements` lays them out in
    /// that order, and the exporter inserts them in it.
    static func reordered(
        _ timeline: MediaTimeline, move from: Int, to: Int, withinSource duration: Double
    ) -> MediaTimeline {
        var pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(from), pieces.indices.contains(to), from != to else {
            return timeline
        }
        let carried = pieces.remove(at: from)
        pieces.insert(carried, at: to)
        return MediaTimeline(segments: pieces)
    }

    /// Where the pieces sit while one of them is in the author's hand: THE SHOT
    /// LIST — every piece the same width, the whole composition across `width`
    /// points, whatever each one will run for.
    ///
    /// ⚠️ **ASKED FOR, AND THE REASON IT IS ASKED FOR IS THE REAL ONE**: *"reduire
    /// au grab tout les segments a des largeurs egales pour pouvoir plus
    /// facilement inserer sans avoir a parcourir toute la timeline"*. On the
    /// track a piece is drawn at the length it will play for, so a ten-second
    /// piece is 600pt and the place a carried piece has to reach is off screen —
    /// and the track cannot scroll while it is being carried, because the film
    /// and the finger would move at once. Every editor that solves this solves it
    /// the same way: a second arrangement where duration stops deciding width.
    /// NCH's VideoPad says it plainly — *"the width of each clip is the same,
    /// regardless of its duration"* (storyboard mode) against *"proportional to
    /// its duration"* (timeline mode); Premiere Elements' Sceneline, iMovie's
    /// shot list, Instagram's Re-Order Mode and InShot's rearranging mode are the
    /// same idea, and Resolve's Cut page keeps one on screen permanently.
    ///
    /// ⚠️ **AND IT MAKES THE DROP RULE RIGHT BY CONSTRUCTION.** The carried piece
    /// is the one under the finger, so "which piece is the finger over" IS "which
    /// piece has the carried one's centre crossed" — the centre-crossing rule
    /// every drag-and-drop guide insists on, because triggering on the EDGES
    /// makes the neighbours oscillate while a finger hovers on a boundary.
    ///
    /// ⚠️ **AND NO NARROWER THAN `minimum`, WHICH MAKES THE LIST WIDER THAN THE
    /// TRACK WHEN THERE ARE MANY PIECES.** Shared out evenly, twelve pieces left
    /// chips twenty points wide — a sliver of picture nobody can tell apart from
    /// its neighbour, and a target no finger can aim at. Asked for in those
    /// words: *"avoir une largeur minimale pour les segments compressés … la
    /// largeur totale peut donc dépasser la largeur de l'écran"*; the list
    /// scrolls instead, which is what iMovie's and InShot's re-order rows do.
    static func shots(
        _ timeline: MediaTimeline, withinSource duration: Double, across width: CGFloat,
        startingAt leading: CGFloat = 0, atLeast minimum: CGFloat = 0
    ) -> [Placement] {
        let pieces = resolved(timeline, withinSource: duration)
        guard !pieces.isEmpty, width.isFinite, width > 0, leading.isFinite else { return [] }
        let each = max(width / CGFloat(pieces.count), minimum.isFinite ? minimum : 0)
        return pieces.enumerated().map { index, piece in
            Placement(
                index: index, piece: piece,
                from: leading + CGFloat(index) * each, to: leading + CGFloat(index + 1) * each
            )
        }
    }

    /// Where a shot list opens: the chip being lifted under the finger that lifted
    /// it, as far as the list's two ends allow.
    ///
    /// ⚠️ **THE PIECE STAYS UNDER THE FINGER.** A list wider than the track has to
    /// open SOMEWHERE, and opened at its start the piece the author has just
    /// picked up could be a screen away from their finger — the one thing a
    /// lift must never do. A list that fits opens at zero, as before.
    static func shotListOffset(
        centring shot: Placement?, underTrackX x: CGFloat,
        listWidth: CGFloat, trackWidth: CGFloat
    ) -> CGFloat {
        let most = max(listWidth - trackWidth, 0)
        guard let shot, x.isFinite, most > 0 else { return 0 }
        return min(max((shot.from + shot.to) / 2 - x, 0), most)
    }

    /// How fast the shot list scrolls by itself while a carried chip is held near
    /// one of the track's ends — points a second, negative towards the start,
    /// zero anywhere else.
    ///
    /// ⚠️ **ASKED FOR: A CHIP HELD AT THE EDGE OF THE SCREEN SLIDES THE LIST**
    /// (*"avoir en grab un segment compressé et le bouger vers les extrémités des
    /// bords de l'écran fait slider la scrollview"*). The finger cannot scroll
    /// the list and carry a piece at once, so the edge does it for them — the
    /// rule every drag-to-reorder list on the platform follows.
    ///
    /// ⚠️ **SQUARED, SO THE EDGE OF THE ZONE IS A CRAWL.** A finger that strays a
    /// few points into it should nudge the list, not send it; a finger pressed
    /// against the bezel wants the far end. Past the edge — a finger can be
    /// reported outside the view — the speed holds at its fastest.
    static func edgeScrollSpeed(
        atTrackX x: CGFloat, trackWidth width: CGFloat, zone: CGFloat, fastest: CGFloat
    ) -> CGFloat {
        guard x.isFinite, width > 0, zone > 0, fastest > 0 else { return 0 }
        let zone = min(zone, width / 2)
        if x < zone {
            let depth = min((zone - x) / zone, 1)
            return -fastest * depth * depth
        }
        if x > width - zone {
            let depth = min((x - (width - zone)) / zone, 1)
            return fastest * depth * depth
        }
        return 0
    }

    /// One time mark above the shot list: where it is drawn, and the second of
    /// the RESULT it names.
    struct ShotMark: Equatable, Sendable {
        let x: CGFloat
        let seconds: Double
    }

    /// The time marks above the shot list: the moment of the RESULT at which each
    /// piece begins, over the edge of the chip that stands for it, and the end of
    /// the result over the last chip's far edge.
    ///
    /// ⚠️ **THE RULER HAS TO TELL THE TRUTH ABOUT THE LIST, NOT ABOUT THE TRACK
    /// IT REPLACED.** Asked for in those words: *"mettre à jour les crans /
    /// indications de temps juste au-dessus pour que ça corresponde bien —
    /// attention lorsqu'on réorganise, il faut bien mettre à jour cette barre de
    /// temps"*. The chips are all the same width whatever they run for, so a
    /// ruler of evenly spaced seconds would lie about every one of them; the only
    /// honest marks are the SEAMS, labelled with where each piece starts in the
    /// order as it stands — which is also what changes when a piece is carried
    /// past another.
    ///
    /// ⚠️ **AND A MARK IS DROPPED RATHER THAN DRAWN ON TOP OF ANOTHER.** With many
    /// pieces the chips get narrower than a timecode; the first and last marks
    /// always stay, and the ones between are kept only where there is room.
    static func shotMarks(_ shots: [Placement], minimumSpacing: CGFloat) -> [ShotMark] {
        guard let last = shots.last else { return [] }
        var all: [ShotMark] = []
        var played: Double = 0
        for shot in shots {
            all.append(ShotMark(x: shot.from, seconds: played))
            played += shot.piece.playedSeconds
        }
        let end = ShotMark(x: last.to, seconds: played)
        var kept: [ShotMark] = []
        for mark in all {
            let clearOfThePrevious = kept.last.map { mark.x - $0.x >= minimumSpacing } ?? true
            let clearOfTheEnd = end.x - mark.x >= minimumSpacing || kept.isEmpty
            if clearOfThePrevious && clearOfTheEnd { kept.append(mark) }
        }
        return kept + [end]
    }

    /// Where a piece being carried would land if it were dropped at `x`.
    ///
    /// ⚠️ **THE PLACE THE FINGER IS OVER, MEASURED ON THE RE-FLOWED TRACK.** The
    /// pieces move as soon as they are crossed, so after each swap the carried
    /// piece occupies the span the finger is in — which is what stops a drag
    /// oscillating between two positions at the boundary.
    static func dropIndex(forPoints x: CGFloat, in placed: [Placement], moving from: Int) -> Int {
        guard !placed.isEmpty else { return from }
        if let over = piece(atPoints: x, in: placed) { return over }
        // Past either end of the whole track: the ends are where a carry that
        // has run out of track belongs.
        return x < (placed.first?.from ?? 0) ? 0 : placed.count - 1
    }

    // MARK: - The handles

    /// Which end of a piece a touch took hold of.
    enum Edge: Equatable, Sendable {
        case start
        case end
    }

    /// Moves ONE piece's start or end by a number of SOURCE seconds.
    ///
    /// ⚠️ **ANY PIECE, AND IT USED TO BE THE OUTER PAIR ONLY.** A timeline of *n*
    /// pieces has *2n* edges, and every one of them is something the author can
    /// take hold of — asked for in those words ("il faut pouvoir redimensionner
    /// les segments"). The note that stood here said an interior boundary was
    /// shared by two pieces and that moving it must shorten one and lengthen its
    /// neighbour; that is the RIPPLE model, and it is not what a split of one
    /// source wants. Each piece owns its two edges: pulling one in leaves a GAP
    /// in the file that the result simply skips, which is a real edit (cutting
    /// the middle out of a clip) and exports exactly as it reads — `VideoExporter`
    /// inserts each piece separately.
    ///
    /// ⚠️ **THE ONLY LIMITS ARE THE FILE AND THE FLOOR — THE NEIGHBOUR IS NOT
    /// ONE, AND MAKING IT ONE WAS THE DEFECT.** A cut does not divide the film
    /// between the two halves: each half is an independent CLIP with its own in
    /// and out points into the whole source, and the material beyond them is
    /// still there — every editor calls it the clip's handles. So dragging a
    /// piece's END out again reveals the film past the cut and PUSHES the pieces
    /// after it along the track; dragging a piece's START back reveals the film
    /// before it. Clamping each edge to the facing edge of the piece next door
    /// meant a cut clip could never be re-opened: reported as *"si on etire sur
    /// la pince de droite, le clip doit pousser le segment suivant et reveler le
    /// reste de la video"*.
    ///
    /// ⚠️ **AND THE TWO HALVES MAY THEREFORE COVER THE SAME FILM.** That is not a
    /// contradiction to guard against — it is what an editor does when the same
    /// moment is wanted twice. The pieces are a PLAYLIST, not a partition, and
    /// `placements` lays them out in the order they play rather than by where
    /// they sit in the file.
    static func moved(
        _ timeline: MediaTimeline, piece index: Int, edge: Edge,
        bySourceSeconds delta: Double, withinSource duration: Double
    ) -> MediaTimeline {
        var pieces = resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index), delta.isFinite else { return timeline }
        let floor = shortest(withinSource: duration)
        let piece = pieces[index]
        switch edge {
        case .start:
            let limit = max(piece.end - floor, 0)
            pieces[index].start = min(max(piece.start + delta, 0), limit)
        case .end:
            let limit = min(piece.start + floor, duration)
            pieces[index].end = max(min(piece.end + delta, duration), limit)
        }
        return MediaTimeline(segments: pieces)
    }

    /// The outer pair, for the spoken adjustment — which has no notion of which
    /// piece is selected and means "the end of the whole thing".
    static func moved(
        _ timeline: MediaTimeline, edge: Edge, bySourceSeconds delta: Double,
        withinSource duration: Double
    ) -> MediaTimeline {
        let pieces = resolved(timeline, withinSource: duration)
        guard !pieces.isEmpty else { return timeline }
        return moved(
            timeline, piece: edge == .start ? 0 : pieces.count - 1, edge: edge,
            bySourceSeconds: delta, withinSource: duration
        )
    }

    /// Which edge a touch at `x` takes, if either. `x` is in the track's own
    /// content coordinates, and so are both ends.
    ///
    /// ⚠️ **THE NEARER ONE WINS A TIE, AND THE TIE IS REAL.** Cut to the
    /// minimum, a piece's two handles are a few points apart and one touch is
    /// within reach of both. Answering `.start` by default would make the end
    /// handle unreachable exactly when the author wants to widen the piece again.
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
