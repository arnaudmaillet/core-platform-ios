import Foundation
import MediaPlayback
import Testing
@testable import Upload

/// **EVERY RULE THE TIMELINE COULD GET WRONG, ASKED WITHOUT A GESTURE OR A
/// SCROLL VIEW.**
///
/// ⚠️ **AND ASKED OF THE FUNCTION UNDER TEST, NEVER THROUGH A WRAPPER THAT
/// REPEATS ITS JOB.** The trim slice put every `moved` assertion through
/// `resolved`, which clamps too — so both clamps inside `moved` could be deleted
/// and all five tests stayed green. Measured at the time: `moved` returned
/// `start: -49`, a kept range of minus forty-four seconds, all tidied away
/// before the assertion saw it. `moved` here returns an already-resolved
/// timeline, so its own output is what is read.
struct MediaTimeliningTests {
    private let duration = 10.0

    // MARK: - Resolving

    @Test func anUntouchedTimelineIsTheWholeClipAsOnePiece() throws {
        let pieces = MediaTimelining.resolved(.whole, withinSource: duration)

        #expect(pieces.count == 1)
        let only = try #require(pieces.first)
        #expect(only.start == 0)
        #expect(only.end == duration)
        #expect(only.speed == 1)
    }

    /// A stored timeline can outlive the clip it was made for — a draft, a
    /// re-pick, a library answering a different file. The trim slice learned
    /// this when a strip laid out against a declared duration cut a file of a
    /// different length.
    @Test func aPieceOverlappingTheClipIsBroughtInside() throws {
        let stale = MediaTimeline(segments: [MediaSegment(start: 1, end: 9)])

        let pieces = MediaTimelining.resolved(stale, withinSource: 2)

        let only = try #require(pieces.first)
        #expect(only.start == 1, "the part that IS in the file is kept: \(only)")
        #expect(only.end == 2, "and the part that is not is cut off: \(only)")
    }

    /// ⚠️ **A PIECE ENTIRELY OUTSIDE THE FILE IS DROPPED, NOT DRAGGED IN.**
    /// Clamping it would put it on the last second; several such pieces would
    /// export that same second over and over, which looks deliberate and is
    /// nonsense. Found by this test failing on the first implementation, which
    /// clamped everything.
    @Test func aPieceEntirelyPastTheClipIsDropped() throws {
        let stale = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 1),
            MediaSegment(start: 40, end: 50)
        ])

        let pieces = MediaTimelining.resolved(stale, withinSource: 2)

        #expect(pieces.count == 1, "got \(pieces)")
        #expect(try #require(pieces.first).end == 1)
    }

    /// ⚠️ **THE START YIELDS; THE END HOLDS.** Asking only for a valid range
    /// cannot tell the two apart — letting the START win turns (8, 3) into
    /// 8...9, letting the END win turns it into 2...3, and both are valid and a
    /// second long. The trim slice shipped that weaker assertion first.
    @Test func aStartPushedPastTheEndYieldsAndTheEndHolds() throws {
        let crossed = MediaTimeline(segments: [MediaSegment(start: 8, end: 3)])

        let only = try #require(MediaTimelining.resolved(crossed, withinSource: duration).first)

        #expect(only.end <= 3.001, "the end moved instead of the start: \(only)")
        #expect(only.start < only.end)
    }

    /// ⚠️ **READING A TIMELINE BACK MAY NOT REWRITE IT.** The floor is a refusal,
    /// enforced where a piece is made; applying it again on the way back pulled
    /// the START of anything shorter than a second EARLIER to make it one — half
    /// a second of film the author had cut away, handed back inside a piece they
    /// had not touched, with a total that disagreed with the edit they left.
    @Test func aPieceShorterThanTheFloorComesBackAsItWasLeft() throws {
        let short = MediaTimeline(segments: [
            MediaSegment(start: 3.5, end: 4),
            MediaSegment(start: 4, end: 10)
        ])

        let pieces = MediaTimelining.resolved(short, withinSource: duration)

        #expect(pieces.count == 2, "got \(pieces)")
        #expect(abs(try #require(pieces.first).start - 3.5) < 0.001,
                "a piece nobody touched grew: \(pieces)")
        #expect(abs(MediaTimelining.playedSeconds(of: short, withinSource: duration) - 6.5) < 0.001,
                "the result does not run for what the pieces say")
    }

    /// ⚠️ **A TIMELINE WHOSE EVERY PIECE FELL AWAY IS BROKEN, NOT EMPTY.**
    /// Returning `[]` would export nothing at all, and an empty file is the one
    /// outcome that loses the author's video outright.
    @Test func aTimelineOfImpossiblePiecesFallsBackToTheClip() throws {
        let impossible = MediaTimeline(segments: [
            MediaSegment(start: 50, end: 40),
            MediaSegment(start: 99, end: 98)
        ])

        let pieces = MediaTimelining.resolved(impossible, withinSource: duration)

        #expect(pieces.count == 1)
        #expect(try #require(pieces.first).end == duration)
    }

    /// ⚠️ **THE FLOOR IS A CEILING TOO.** A clip already shorter than the
    /// minimum cannot be cut at all, and the rule has to bend rather than invert.
    @Test func aClipShorterThanTheFloorSurvivesIt() throws {
        let pieces = MediaTimelining.resolved(
            MediaTimeline(segments: [MediaSegment(start: 0.2, end: 0.4)]), withinSource: 0.5
        )

        let only = try #require(pieces.first)
        #expect(only.start >= 0)
        #expect(only.end <= 0.5, "got \(only)")
        // ⚠️ **SOMETHING MUST BE KEPT.** The predecessor asserted `start <= end`,
        // which `0...0` satisfies — an implementation collapsing every short clip
        // to nothing would have passed both short-clip tests, and the export
        // would produce an empty file.
        #expect(only.end > only.start, "nothing survives: \(only)")
    }

    // MARK: - The two clocks

    /// The whole reason the clocks are named: at twice the speed, the same
    /// stretch of file takes half as long to watch.
    @Test func aFasterPieceCoversTheSameFileInLessTime() {
        let piece = MediaSegment(start: 0, end: 4, speed: 2)

        #expect(piece.sourceSeconds == 4)
        #expect(piece.playedSeconds == 2)
    }

    @Test func aSlowerPieceTakesLonger() {
        let piece = MediaSegment(start: 0, end: 4, speed: 0.5)

        #expect(piece.sourceSeconds == 4)
        #expect(piece.playedSeconds == 8)
    }

    @Test func theTimelineAddsUpItsPiecesInPlayedTime() {
        let timeline = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, speed: 2),     // 2 played
            MediaSegment(start: 6, end: 8, speed: 0.5)    // 4 played
        ])

        #expect(MediaTimelining.playedSeconds(of: timeline, withinSource: duration) == 6)
    }

    /// ⚠️ **AND A MOMENT OF THE FILE HAS A PLACE IN THE RESULT, WHICH IS NOT THE
    /// SAME NUMBER.** The readout asks this: "where is the playhead" has to be
    /// answered in the seconds a viewer will experience, or it cannot be set
    /// beside "how long the result runs". For one build it was not, and a
    /// seven-second clip at 2× read "0:04 / 0:04" with the needle half way along.
    @Test func aMomentOfTheFileHasAPlaceInTheResult() {
        let timeline = MediaTimeline(segments: [MediaSegment(start: 0, end: 10, speed: 2)])

        #expect(MediaTimelining.playedSeconds(
            atSourceSeconds: 4, in: timeline, withinSource: duration
        ) == 2)
    }

    /// And the conversion changes at every boundary, which is what makes it
    /// arithmetic rather than a division.
    @Test func eachPieceContributesItsOwnRateToThePosition() {
        let timeline = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, speed: 1),     // 4 played
            MediaSegment(start: 4, end: 10, speed: 2)     // 3 played
        ])

        // Seven seconds in: all of the first piece, then half of the three
        // seconds of the second that have gone by.
        #expect(MediaTimelining.playedSeconds(
            atSourceSeconds: 7, in: timeline, withinSource: duration
        ) == 5.5)
    }

    @Test func aMomentInTheDiscardedHeadIsTheStartOfTheResult() {
        let timeline = MediaTimeline(segments: [MediaSegment(start: 4, end: 10, speed: 1)])

        #expect(MediaTimelining.playedSeconds(
            atSourceSeconds: 2, in: timeline, withinSource: duration
        ) == 0)
    }

    @Test func aMomentPastTheCutIsTheWholeResult() {
        let timeline = MediaTimeline(segments: [MediaSegment(start: 0, end: 6, speed: 2)])

        #expect(MediaTimelining.playedSeconds(
            atSourceSeconds: 9, in: timeline, withinSource: duration
        ) == 3)
    }

    /// ⚠️ **A SPEED OF ZERO IS A CLIP THAT NEVER ENDS.** `playedSeconds` divides
    /// by it, and an exporter handed an infinite target duration does not fail
    /// politely.
    @Test func animpossibleSpeedBecomesOne() {
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: 0)) == 1)
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: -3)) == 1)
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: .infinity)) == 1)
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: .nan)) == 1)
    }

    @Test func aWildSpeedIsBroughtIntoTheRangeTheAlgorithmsCover() {
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: 1000))
                == MediaTimelining.fastest)
        #expect(MediaTimelining.speed(of: MediaSegment(start: 0, end: 1, speed: 0.0001))
                == MediaTimelining.slowest)
    }

    // MARK: - Whether it cuts anything

    /// ⚠️ **THE ASSERTION THAT IS NOT `!isWhole`.** One segment spanning the file
    /// at 1× is a different VALUE from `.whole` and the same INSTRUCTION. Only
    /// the passthrough route copies the bytes, and
    /// `AVAssetExportPresetPassthrough` ignores any composition given to it, so
    /// the two are genuinely different work.
    @Test func aTimelineCoveringTheWholeClipAtOneSpeedCutsNothing() {
        #expect(MediaTimelining.cuts(.whole, withinSource: duration) == false)
        #expect(
            MediaTimelining.cuts(
                MediaTimeline(segments: [MediaSegment(start: 0, end: duration)]),
                withinSource: duration
            ) == false,
            "an explicit full span at 1x is the same instruction as .whole"
        )
    }

    /// ⚠️ **AND A SPEED ALONE IS A CUT.** This is the case a trim-shaped test
    /// would miss entirely: the same frames, from end to end, are still a
    /// different video once they play at a different rate.
    @Test func aSpeedAloneCountsAsACut() {
        let sped = MediaTimeline(segments: [MediaSegment(start: 0, end: duration, speed: 2)])

        #expect(MediaTimelining.cuts(sped, withinSource: duration))
    }

    @Test func aRealCutCuts() {
        #expect(MediaTimelining.cuts(
            MediaTimeline(segments: [MediaSegment(start: 2, end: 8)]), withinSource: duration
        ))
        #expect(MediaTimelining.cuts(
            MediaTimeline(segments: [
                MediaSegment(start: 0, end: 4), MediaSegment(start: 6, end: duration)
            ]),
            withinSource: duration
        ), "two pieces are never the clip as shot")
    }

    // MARK: - Dragging an edge

    @Test func theStartStopsAtTheBeginningOfTheClip() throws {
        let moved = MediaTimelining.moved(
            MediaTimeline(segments: [MediaSegment(start: 1, end: 8)]),
            edge: .start, bySourceSeconds: -50, withinSource: duration
        )

        #expect(try #require(moved.segments.first).start == 0)
    }

    @Test func theEndStopsAtTheEndOfTheClip() throws {
        let moved = MediaTimelining.moved(
            MediaTimeline(segments: [MediaSegment(start: 1, end: 8)]),
            edge: .end, bySourceSeconds: 50, withinSource: duration
        )

        #expect(try #require(moved.segments.last).end == duration)
    }

    @Test func theEdgesKeepTheShortestPieceBetweenThem() throws {
        let squeezed = MediaTimelining.moved(
            MediaTimeline(segments: [MediaSegment(start: 2, end: 8)]),
            edge: .start, bySourceSeconds: 50, withinSource: duration
        )
        let piece = try #require(squeezed.segments.first)

        #expect(piece.sourceSeconds >= MediaTimelining.shortestSourceSeconds - 0.001,
                "got \(piece)")
    }

    /// ⚠️ **THE PROPERTY THE INCREMENTAL DESIGN EXISTS FOR.** Drag past the end,
    /// then back the same distance: it must come back. Measured from touch-down
    /// it would not — the overshoot would have to be undone first, and the
    /// handle would feel stuck for exactly as long as it was pushed.
    @Test func anEdgeDraggedPastTheEndComesStraightBack() throws {
        var timeline = MediaTimeline(segments: [MediaSegment(start: 1, end: 6)])
        timeline = MediaTimelining.moved(
            timeline, edge: .end, bySourceSeconds: 20, withinSource: duration
        )
        #expect(try #require(timeline.segments.last).end == duration, "guard: it went to the end")

        timeline = MediaTimelining.moved(
            timeline, edge: .end, bySourceSeconds: -2, withinSource: duration
        )

        #expect(abs(try #require(timeline.segments.last).end - 8) < 0.001,
                "got \(timeline.segments)")
    }

    /// Dragging an edge must not silently reset a speed the author chose.
    @Test func movingAnEdgeKeepsTheSpeed() throws {
        let moved = MediaTimelining.moved(
            MediaTimeline(segments: [MediaSegment(start: 1, end: 8, speed: 2)]),
            edge: .start, bySourceSeconds: 1, withinSource: duration
        )

        #expect(try #require(moved.segments.first).speed == 2)
    }

    /// Two small steps equal one big one — what "incremental" means, asserted
    /// rather than assumed.
    @Test func twoStepsMakeTheSameMoveAsOne() throws {
        let start = MediaTimeline(segments: [MediaSegment(start: 1, end: 8)])

        let once = MediaTimelining.moved(
            start, edge: .start, bySourceSeconds: 2, withinSource: duration
        )
        var twice = MediaTimelining.moved(
            start, edge: .start, bySourceSeconds: 1, withinSource: duration
        )
        twice = MediaTimelining.moved(twice, edge: .start, bySourceSeconds: 1, withinSource: duration)

        #expect(abs(try #require(once.segments.first).start
                    - #require(twice.segments.first).start) < 0.001)
        #expect(abs(try #require(once.segments.first).start - 3) < 0.001,
                "and it landed where it should: \(once)")
    }

    @Test func theNearerEdgeTakesTheTouch() {
        #expect(MediaTimelining.edge(at: 12, startX: 10, endX: 400) == .start)
        #expect(MediaTimelining.edge(at: 390, startX: 10, endX: 400) == .end)
        #expect(MediaTimelining.edge(at: 26, startX: 20, endX: 30) == .end,
                "a touch nearer the end takes it even when both are in reach")
        #expect(MediaTimelining.edge(at: 900, startX: 10, endX: 400) == nil)
    }

    // MARK: - Points and played seconds

    @Test func aMomentAndItsPlaceAgree() {
        let x = MediaTimelining.x(atPlayedSeconds: 2.5, pointsPerSecond: 60)
        #expect(x == 150)
        #expect(abs(MediaTimelining.playedSeconds(atX: x, pointsPerSecond: 60) - 2.5) < 0.001)
    }

    /// ⚠️ A ZERO SCALE IS NOT A CRASH. Every band tenant is asked where things go
    /// before its first layout.
    @Test func anUnlaidTrackAnswersZeroRatherThanNaN() {
        #expect(MediaTimelining.playedSeconds(atX: 10, pointsPerSecond: 0) == 0)
        #expect(MediaTimelining.x(atPlayedSeconds: .nan) == 0)
        #expect(MediaTimelining.resolved(.whole, withinSource: 0).isEmpty)
    }

    // MARK: - The stamp

    @Test func theStampReadsAsATimecode() {
        #expect(MediaTimelining.stamp(0) == "0:00")
        #expect(MediaTimelining.stamp(7) == "0:07")
        #expect(MediaTimelining.stamp(64) == "1:04")
        #expect(MediaTimelining.stamp(750) == "12:30")
        #expect(MediaTimelining.stamp(3661) == "1:01:01")
    }

    @Test func theStampSurvivesNonsense() {
        #expect(MediaTimelining.stamp(-5) == "0:00")
        #expect(MediaTimelining.stamp(.nan) == "0:00")
        #expect(MediaTimelining.stamp(.infinity) == "0:00")
    }

    // MARK: - The cache key

    /// ⚠️ **THE TRAP `MediaEdits.signature` HAS ALREADY FALLEN INTO ONCE.** The
    /// key is what `NewPostMediaCell` uses to decide whether to redraw at all, so
    /// a decision missing from it is a thumbnail silently showing the previous
    /// edit while the editor shows the new one — no error, no clue.
    ///
    /// Interpolating `crop` WHOLE covers a new `MediaCrop` field for free. It
    /// does not cover a new `MediaEdits` field, which is what `timeline` is —
    /// `isMirrored` went stale exactly this way, and `trim` had to be written in
    /// by hand before it, and now `timeline` has.
    @Test func changingOnlyTheTimelineChangesTheCacheKey() {
        var edited = MediaEdits.untouched
        edited.timeline = MediaTimeline(segments: [MediaSegment(start: 1, end: 4)])

        #expect(edited.signature != MediaEdits.untouched.signature)
    }

    /// The witness: two edits differing in nothing share a key, so the line above
    /// is about `timeline` and not about the key being different every time it is
    /// asked for.
    @Test func twoIdenticalEditsShareTheirKey() {
        #expect(MediaEdits.untouched.signature == MediaEdits().signature)
    }

    /// ⚠️ **AND A SPEED ALONE MUST MOVE THE KEY TOO.** Same frames, same
    /// rectangle — a signature spelling only the segments' ends would be blind to
    /// it, and this is the field the split-and-speed slices will lean on.
    @Test func changingOnlyASpeedChangesTheCacheKey() {
        var slow = MediaEdits.untouched
        slow.timeline = MediaTimeline(segments: [MediaSegment(start: 0, end: 4, speed: 0.5)])
        var fast = MediaEdits.untouched
        fast.timeline = MediaTimeline(segments: [MediaSegment(start: 0, end: 4, speed: 2)])

        #expect(slow.signature != fast.signature)
    }

    /// A cut makes an edit worth carrying. `change(_:_:)` stores nothing when an
    /// edit is untouched, so a cut that did not move this needle would be dropped
    /// on its way to the next screen.
    @Test func aCutMakesAnEditWorthKeeping() {
        var edited = MediaEdits.untouched
        edited.timeline = MediaTimeline(segments: [MediaSegment(start: 1, end: 4)])

        #expect(edited.isUntouched == false)
    }

    // MARK: - The scrolling track

    /// ⚠️ **THE RESTING OFFSET IS NEGATIVE, AND THAT IS THE WHOLE DESIGN.** A
    /// track that started at offset zero would put the clip's first frame at the
    /// left EDGE while the needle stands at the centre — so the opening second
    /// could never be played from, and neither could the closing one. Half a
    /// track of padding at each end is what makes both ends addressable.
    @Test func theStartOfTheClipSitsUnderTheNeedleAtRest() {
        let width: CGFloat = 400

        let atRest = MediaTimelining.contentOffset(
            forPlayedSeconds: 0, trackWidth: width
        )

        #expect(atRest == -200, "the clip would open half a screen past its start")
        #expect(
            MediaTimelining.playedSeconds(
                atContentOffset: atRest, trackWidth: width, of: .whole, withinSource: 10
            ) == 0
        )
    }

    /// ⚠️ **A ROUND TRIP CANNOT SEE A WRONG INSET, AND THIS ONE DID NOT.**
    /// Measured: with `centringInset` returning zero, this test stayed green —
    /// the inset is added going one way and subtracted coming back, so any value
    /// at all round-trips. It proves the two directions agree with each other and
    /// nothing about whether either is right. The test above it is what holds the
    /// inset down, by asserting an absolute number.
    @Test func scrollingAndSeekingAreInverses() {
        let width: CGFloat = 393

        let offset = MediaTimelining.contentOffset(
            forPlayedSeconds: 3.5, trackWidth: width
        )
        let back = MediaTimelining.playedSeconds(
            atContentOffset: offset, trackWidth: width, of: .whole, withinSource: duration
        )

        #expect(abs(back - 3.5) < 0.001)
    }

    /// A scroll view rubber-bands past both ends; the needle then stands over a
    /// moment the file does not have, and a seek there is a seek to nowhere.
    @Test func aRubberBandedScrollStaysInsideTheClip() {
        let width: CGFloat = 400

        #expect(
            MediaTimelining.playedSeconds(
                atContentOffset: -900, trackWidth: width, of: .whole, withinSource: duration
            ) == 0
        )
        #expect(
            MediaTimelining.playedSeconds(
                atContentOffset: 5000, trackWidth: width, of: .whole, withinSource: duration
            ) == duration
        )
    }

    /// ⚠️ **A POSITION FLOORS AT ZERO AND A DISTANCE DOES NOT.** Using the
    /// position converter for a drag delta turns every leftward sample into
    /// zero — the handle opens outwards and will not come back, which reads as a
    /// clamp rather than as the dead control it is.
    @Test func aLeftwardDragIsANegativeNumberOfSeconds() {
        #expect(MediaTimelining.playedSeconds(ofPoints: -120, pointsPerSecond: 60) == -2)
        #expect(MediaTimelining.playedSeconds(ofPoints: 120, pointsPerSecond: 60) == 2)
        #expect(MediaTimelining.playedSeconds(atX: -120, pointsPerSecond: 60) == 0,
                "the position converter still floors, which is why it is not this one")
    }

    /// ⚠️ **AND THE SAME DRAG IS WORTH MORE FILM IN A FAST PIECE.** A piece at 2×
    /// is drawn half as wide as the film it covers, so one point of finger is two
    /// frames rather than one. Converting a drag straight to source seconds moves
    /// a fast piece's edge twice as far as the finger went — invisible at 1×,
    /// which is the only rate that existed when the converter was written.
    @Test func aDragIsWorthTheFilmTheStretchPutsUnderIt() {
        #expect(MediaTimelining.sourceSeconds(ofPoints: 120, atSpeed: 1, pointsPerSecond: 60) == 2)
        #expect(MediaTimelining.sourceSeconds(ofPoints: 120, atSpeed: 2, pointsPerSecond: 60) == 4)
        #expect(MediaTimelining.sourceSeconds(ofPoints: 120, atSpeed: 0.5, pointsPerSecond: 60) == 1)
        #expect(MediaTimelining.sourceSeconds(ofPoints: 120, atSpeed: 0, pointsPerSecond: 60) == 2,
                "a nonsense rate is one, not a division by zero")
    }

    @Test func theStripIsAsWideAsTheResultIsLong() {
        #expect(MediaTimelining.contentWidth(of: .whole, withinSource: 10, pointsPerSecond: 60) == 600)
        #expect(MediaTimelining.contentWidth(of: .whole, withinSource: 0, pointsPerSecond: 60) == 0)
    }

    /// ⚠️ **THE STRETCH, WHICH IS THE WHOLE AXIS CHANGE.** The same film at twice
    /// the speed takes half the room, and at half the speed twice — so the needle
    /// crosses the track at a constant points-per-second whatever rates the pieces
    /// carry. Asked for in those words: the timeline must always advance at the
    /// same rate.
    @Test func aPieceIsDrawnAtTheLengthItWillRunFor() {
        let fast = MediaTimeline(segments: [MediaSegment(start: 0, end: 10, speed: 2)])
        let slow = MediaTimeline(segments: [MediaSegment(start: 0, end: 10, speed: 0.5)])

        #expect(MediaTimelining.contentWidth(of: fast, withinSource: duration, pointsPerSecond: 60) == 300)
        #expect(MediaTimelining.contentWidth(of: slow, withinSource: duration, pointsPerSecond: 60) == 1200)
    }

    // MARK: - Splitting, and rates

    @Test func splittingMakesTwoPiecesOutOfOne() throws {
        let split = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        let pieces = MediaTimelining.resolved(split, withinSource: duration)
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(pieces.first?.start == 0)
        #expect(pieces.first?.end == 4)
        #expect(pieces.last?.start == 4)
        #expect(pieces.last?.end == duration)
        // ⚠️ AND THE TWO HALVES TOGETHER ARE STILL THE WHOLE CLIP. A split that
        // lost a frame at the seam would be invisible on screen and audible in
        // the export.
        #expect(MediaTimelining.playedSeconds(of: split, withinSource: duration) == duration)
    }

    /// ⚠️ **A SPLIT THAT LEAVES A SLIVER IS A PIECE WHOSE HANDLES CANNOT MOVE.**
    /// Refusing is what lets the screen say so, rather than making a segment that
    /// exports to a single frame.
    @Test func aSplitTooCloseToAnEndIsRefused() {
        let tooEarly = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 0.4, withinSource: duration)
        let tooLate = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 9.7, withinSource: duration)

        #expect(MediaTimelining.resolved(tooEarly, withinSource: duration).count == 1)
        #expect(MediaTimelining.resolved(tooLate, withinSource: duration).count == 1)
        #expect(MediaTimelining.canSplit(.whole, atPiece: 0, atSourceSeconds: 0.4, withinSource: duration) == false)
        #expect(MediaTimelining.canSplit(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration),
                "witness: a split in the middle is offered")
    }

    /// Splitting the SECOND piece must not disturb the first — the commonest way
    /// to get an insert wrong is to put it at the wrong index.
    @Test func splittingOnePieceLeavesTheOthersAlone() throws {
        let once = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 3, withinSource: duration)

        let twice = MediaTimelining.split(once, atPiece: 1, atSourceSeconds: 7, withinSource: duration)

        let pieces = MediaTimelining.resolved(twice, withinSource: duration)
        #expect(pieces.count == 3, "got \(pieces)")
        #expect(pieces.map(\.start) == [0, 3, 7])
        #expect(pieces.map(\.end) == [3, 7, duration])
    }

    @Test func splittingKeepsTheRateOfThePieceItCuts() throws {
        let sped = MediaTimeline(segments: [MediaSegment(start: 0, end: duration, speed: 2)])

        let split = MediaTimelining.split(sped, atPiece: 0, atSourceSeconds: 5, withinSource: duration)

        let pieces = MediaTimelining.resolved(split, withinSource: duration)
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.speed == 2 }, "the halves lost the rate: \(pieces)")
    }

    // MARK: - Rates

    @Test func aRateAppliesToThePieceUnderTheNeedleAndNoOther() throws {
        let split = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        let sped = MediaTimelining.setRate(2, at: 6, in: split, withinSource: duration)

        let pieces = MediaTimelining.resolved(sped, withinSource: duration)
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(pieces.first?.speed == 1, "the first piece was sped up too")
        #expect(pieces.last?.speed == 2, "the second piece kept its rate")
    }

    @Test func theRateUnderTheNeedleIsWhatIsRead() {
        let split = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)
        let sped = MediaTimelining.setRate(4, at: 1, in: split, withinSource: duration)

        #expect(MediaTimelining.rate(at: 1, in: sped, withinSource: duration) == 4)
        #expect(MediaTimelining.rate(at: 6, in: sped, withinSource: duration) == 1)
    }

    /// ⚠️ **AND A RATE CHANGES HOW LONG THE RESULT RUNS.** Asserting the stored
    /// value alone would pass on an implementation that recorded the number and
    /// exported the clip unchanged.
    @Test func aRateShortensWhatThePostWillRun() {
        let sped = MediaTimelining.setRate(2, at: 5, in: .whole, withinSource: duration)

        #expect(MediaTimelining.playedSeconds(of: sped, withinSource: duration) == duration / 2)
    }

    @Test func theOfferedRatesIncludeAsShot() {
        #expect(MediaTimelining.rates.contains(1), "there is no way back to as-shot")
        #expect(MediaTimelining.rates == MediaTimelining.rates.sorted())
    }

    // MARK: - A cut leaves both halves their handles

    /// ⚠️ **A CUT IS NOT A PARTITION OF THE FILM.** Each half is an independent
    /// clip with its own in and out points into the WHOLE source — what every
    /// editor calls its handles — so pulling a piece's end back out reveals the
    /// film past the cut. Reported as *"si on etire sur la pince de droite, le
    /// clip doit pousser le segment suivant et reveler le reste de la video"*;
    /// the edge was clamped to the next piece's start, so a cut clip could never
    /// be re-opened.
    @Test func apieceCanBeStretchedBackOverTheFilmTheCutTookAway() throws {
        let cut = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        let stretched = MediaTimelining.moved(
            cut, piece: 0, edge: .end, bySourceSeconds: 3, withinSource: duration
        )

        let pieces = MediaTimelining.resolved(stretched, withinSource: duration)
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(abs(pieces[0].end - 7) < 0.001,
                "the first piece stopped at the cut instead of reaching into the film beyond it")
        #expect(abs(pieces[1].start - 4) < 0.001,
                "the second piece's own film moved when only the first was dragged")
    }

    /// And the same at the other end: a piece's start reaches back over the film
    /// the piece before it is showing.
    @Test func apieceCanBeStretchedBackBeforeTheCut() throws {
        let cut = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        let stretched = MediaTimelining.moved(
            cut, piece: 1, edge: .start, bySourceSeconds: -3, withinSource: duration
        )

        let pieces = MediaTimelining.resolved(stretched, withinSource: duration)
        #expect(abs(pieces[1].start - 1) < 0.001, "got \(pieces)")
        #expect(abs(pieces[0].end - 4) < 0.001, "the first piece was shortened to make room")
    }

    /// ⚠️ **AND THE TWO HALVES MAY THEN COVER THE SAME FILM.** That is not a
    /// state to guard against: the pieces are a playlist, not a partition, and
    /// showing the same moment twice is something an editor does on purpose.
    @Test func twoPiecesMayShowTheSameFilm() throws {
        let cut = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)
        let stretched = MediaTimelining.moved(
            cut, piece: 0, edge: .end, bySourceSeconds: 3, withinSource: duration
        )

        let pieces = MediaTimelining.resolved(stretched, withinSource: duration)

        #expect(pieces[0].end > pieces[1].start, "guard: they really do overlap: \(pieces)")
        // And the result is as long as the two of them together — seven seconds
        // then six — because the track is a playlist: the shared film plays
        // twice rather than being shared out between them.
        #expect(abs(MediaTimelining.playedSeconds(of: stretched, withinSource: duration) - 13) < 0.001,
                "got \(MediaTimelining.playedSeconds(of: stretched, withinSource: duration))")
    }

    /// What DOES stop an edge: the file's own bounds and the one-second floor.
    @Test func anEdgeStopsAtTheFilmAndAtTheFloor() throws {
        let cut = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        let past = MediaTimelining.moved(
            cut, piece: 1, edge: .end, bySourceSeconds: 50, withinSource: duration
        )
        #expect(MediaTimelining.resolved(past, withinSource: duration)[1].end == duration,
                "an edge ran off the end of the file")

        let crushed = MediaTimelining.moved(
            cut, piece: 0, edge: .end, bySourceSeconds: -50, withinSource: duration
        )
        let floor = MediaTimelining.resolved(crushed, withinSource: duration)[0]
        #expect(abs(floor.end - floor.start - MediaTimelining.shortestSourceSeconds) < 0.001,
                "the piece was crushed past the floor: \(floor)")
    }

    // MARK: - Carrying a piece to a new place

    @Test func aPieceCanBeCarriedPastItsNeighbour() {
        let three = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2),
            MediaSegment(start: 3, end: 5),
            MediaSegment(start: 6, end: 8)
        ])

        let moved = MediaTimelining.reordered(three, move: 0, to: 2, withinSource: duration)

        #expect(MediaTimelining.resolved(moved, withinSource: duration).map(\.start) == [3, 6, 0],
                "got \(moved)")
    }

    /// ⚠️ **THE ORDER IS THE COMPOSITION'S, AND NOTHING MAY SORT IT BACK.** A
    /// carried piece can start later in the file than the one after it; every
    /// reader from `resolved` to the exporter has to keep what it is given.
    @Test func aCarriedPieceKeepsItsPlaceThroughResolving() {
        let swapped = MediaTimeline(segments: [
            MediaSegment(start: 6, end: 9),
            MediaSegment(start: 0, end: 3)
        ])

        #expect(MediaTimelining.resolved(swapped, withinSource: duration).map(\.start) == [6, 0])
    }

    @Test func carryingAPieceNowhereChangesNothing() {
        let two = MediaTimelining.split(.whole, atPiece: 0, atSourceSeconds: 4, withinSource: duration)

        #expect(MediaTimelining.reordered(two, move: 1, to: 1, withinSource: duration) == two)
        #expect(MediaTimelining.reordered(two, move: 0, to: 9, withinSource: duration) == two)
        #expect(MediaTimelining.reordered(two, move: -1, to: 0, withinSource: duration) == two)
    }

    /// Where a carried piece would land: the place the finger is over, measured
    /// on the track as it has already re-flowed.
    @Test func aCarriedPieceLandsWhereTheFingerIs() {
        let three = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2),      // drawn 0–120
            MediaSegment(start: 3, end: 5),      // drawn 120–240
            MediaSegment(start: 6, end: 8)       // drawn 240–360
        ])
        let placed = MediaTimelining.placements(three, withinSource: duration)

        #expect(MediaTimelining.dropIndex(forPoints: 300, in: placed, moving: 0) == 2)
        #expect(MediaTimelining.dropIndex(forPoints: 60, in: placed, moving: 2) == 0)
        // Past either end, a carry that has run out of track belongs to the end
        // it ran out at.
        #expect(MediaTimelining.dropIndex(forPoints: -400, in: placed, moving: 2) == 0)
        #expect(MediaTimelining.dropIndex(forPoints: 9000, in: placed, moving: 0) == 2)
    }

    // MARK: - The shot list

    /// ⚠️ **DURATION STOPS DECIDING WIDTH, AND THAT IS THE WHOLE POINT.** On the
    /// track a piece is drawn at the length it will run for, so a short piece
    /// beside a long one is a few points wide and the long one's far end is off
    /// screen. While one is being carried every piece is the same width and the
    /// whole composition is on the track at once.
    @Test func theShotListGivesEveryPieceTheSameWidth() {
        let three = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 1),      // one second
            MediaSegment(start: 2, end: 8),      // six
            MediaSegment(start: 8, end: 9)       // one
        ])

        let shots = MediaTimelining.shots(three, withinSource: duration, across: 300)

        #expect(shots.map(\.width) == [100, 100, 100], "got \(shots.map(\.width))")
        #expect(shots.map(\.from) == [0, 100, 200])
        #expect(shots.last?.to == 300, "the list does not fill the track: \(shots)")
    }

    /// The list is the composition's order, not the film's — a carried piece can
    /// start later in the file than the one drawn after it.
    @Test func theShotListIsInPlayOrder() {
        let swapped = MediaTimeline(segments: [
            MediaSegment(start: 6, end: 9),
            MediaSegment(start: 0, end: 3)
        ])

        let shots = MediaTimelining.shots(swapped, withinSource: duration, across: 200)

        #expect(shots.map(\.piece.start) == [6, 0], "got \(shots.map(\.piece.start))")
        #expect(shots.map(\.index) == [0, 1])
    }

    /// ⚠️ **A FLOOR UNDER EVERY CHIP, AND THE LIST RUNS PAST THE TRACK FOR IT.**
    /// Twelve pieces shared out over 358 points are thirty points each — a sliver
    /// nobody can aim at. Asked for: a minimum width, and a list that scrolls.
    @Test func aShotListIsNeverNarrowerThanItsFloor() {
        let twelve = MediaTimeline(segments: (0..<12).map {
            MediaSegment(start: Double($0), end: Double($0 + 1))
        })

        let shots = MediaTimelining.shots(
            twelve, withinSource: 12, across: 358, startingAt: 16, atLeast: 64
        )

        #expect(shots.map(\.width) == Array(repeating: 64, count: 12), "got \(shots.map(\.width))")
        #expect(shots.first?.from == 16)
        // ⚠️ NAMED, NOT WRITTEN INLINE: inside `#expect` the sum is not inferred
        // as a `CGFloat`, and 784 was reported as not equal to 784.
        let end: CGFloat = 16 + 12 * 64
        #expect(shots.last?.to == end, "the list stops at \(shots.last?.to ?? 0)")
    }

    /// The witness: a floor that is not reached changes nothing — two pieces
    /// still share the track between them.
    @Test func aFloorThatIsNotReachedLeavesTheListAlone() {
        let two = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 3), MediaSegment(start: 3, end: 9)
        ])

        let shots = MediaTimelining.shots(
            two, withinSource: duration, across: 358, startingAt: 16, atLeast: 64
        )

        #expect(shots.map(\.width) == [179, 179], "got \(shots.map(\.width))")
        let end: CGFloat = 16 + 358
        #expect(shots.last?.to == end)
    }

    /// ⚠️ **THE PIECE THAT WAS LIFTED OPENS UNDER THE FINGER THAT LIFTED IT**, as
    /// far as the list's ends allow — and a list that fits does not move at all.
    @Test func aLongListOpensWithTheLiftedChipUnderTheFinger() {
        let chip = MediaTimelining.Placement(
            index: 9, piece: MediaSegment(start: 9, end: 10), from: 592, to: 656
        )

        #expect(MediaTimelining.shotListOffset(
            centring: chip, underTrackX: 265, listWidth: 784, trackWidth: 390
        ) == 359)
        // Past either end, it stops at the end.
        #expect(MediaTimelining.shotListOffset(
            centring: chip, underTrackX: 10, listWidth: 784, trackWidth: 390
        ) == 394)
        #expect(MediaTimelining.shotListOffset(
            centring: chip, underTrackX: 1000, listWidth: 784, trackWidth: 390
        ) == 0)
        // A list that fits, or no chip at all, stays where it is.
        #expect(MediaTimelining.shotListOffset(
            centring: chip, underTrackX: 265, listWidth: 390, trackWidth: 390
        ) == 0)
        #expect(MediaTimelining.shotListOffset(
            centring: nil, underTrackX: 265, listWidth: 784, trackWidth: 390
        ) == 0)
    }

    /// ⚠️ **THE LIST SCROLLS BY ITSELF ONLY NEAR AN END, TOWARDS THAT END, AND
    /// FASTER THE CLOSER THE FINGER GETS.**
    @Test func theListScrollsByItselfOnlyNearAnEnd() {
        func speed(_ x: CGFloat) -> CGFloat {
            MediaTimelining.edgeScrollSpeed(atTrackX: x, trackWidth: 390, zone: 56, fastest: 600)
        }

        #expect(speed(195) == 0, "the middle of the track moved the list")
        #expect(speed(57) == 0 && speed(333) == 0, "the zone is wider than it says")
        #expect(speed(40) < 0 && speed(350) > 0, "the list runs the wrong way")
        #expect(abs(speed(20)) > abs(speed(40)), "deeper into the zone is not faster")
        #expect(speed(390 - 20) > speed(390 - 40), "deeper into the zone is not faster")
        #expect(abs(speed(28) + 150) < 0.01, "half way in is not a quarter speed: \(speed(28))")
        #expect(abs(speed(390 - 28) - 150) < 0.01,
                "half way in is not a quarter speed: \(speed(390 - 28))")
        #expect(speed(0) == -600 && speed(390) == 600)
        // A finger reported past the edge holds the fastest speed.
        #expect(speed(-30) == -600 && speed(430) == 600)
        // A zone wider than half the track does not run both ways at once.
        #expect(MediaTimelining.edgeScrollSpeed(
            atTrackX: 50, trackWidth: 100, zone: 80, fastest: 600
        ) == 0)
    }

    // MARK: - Daylight between the pieces

    private func laid(_ widths: [CGFloat]) -> [MediaTimelining.Placement] {
        var x: CGFloat = 0
        return widths.enumerated().map { index, width in
            defer { x += width }
            return MediaTimelining.Placement(
                index: index, piece: MediaSegment(start: Double(index), end: Double(index + 1)),
                from: x, to: x + width
            )
        }
    }

    private func laid(
        _ widths: [CGFloat], carrying kinds: [VideoTransitionKind?]
    ) -> [MediaTimelining.Placement] {
        laid(widths).enumerated().map { index, placed in
            var piece = placed.piece
            piece.transitionOut = kinds.indices.contains(index) ? kinds[index] : nil
            return MediaTimelining.Placement(index: index, piece: piece, from: placed.from, to: placed.to)
        }
    }

    private func caps(of placed: [MediaTimelining.Placement], holding held: Int) -> MediaTimelining.Caps {
        let span = MediaTimelining.spans(of: placed, gap: 2, holding: held, scale: 3)[held]
        return MediaTimelining.caps(around: span, grab: 12)
    }

    /// ⚠️ **A CAP CARRIES A `+` ONLY WHERE IT STANDS ON A CUT, AND READS THE
    /// PIECE BEFORE THAT CUT** — a transition belongs to its outgoing piece.
    @Test func capMarksStandOnlyOnInteriorCutsAndReadThePieceBefore() {
        let placed = laid([180, 180, 180], carrying: [.dipToBlack, .zoom, nil])
        func marks(_ held: Int) -> [String] {
            MediaTimelining.capMarks(placed, holding: held, caps: caps(of: placed, holding: held))
                .map { "\($0.edge) \($0.index) \($0.kind?.rawValue ?? "none")" }
        }
        #expect(marks(0) == ["end 0 dipToBlack"])
        #expect(marks(1) == ["start 0 dipToBlack", "end 1 zoom"])
        #expect(marks(2) == ["start 1 zoom"])
        let single = laid([180])
        #expect(MediaTimelining.capMarks(single, holding: 0, caps: caps(of: single, holding: 0)).isEmpty)
        #expect(MediaTimelining.capMarks(placed, holding: 3, caps: caps(of: placed, holding: 1)).isEmpty)
    }

    /// ⚠️ **A FINGER WIDE, FROM THE CAP'S OUTER EDGE INWARDS, AND NO FURTHER
    /// THAN THE MIDDLE OF THE HELD FILM.**
    @Test func aCapsPlusReachesAFingerInwardsAndStopsAtTheMiddle() {
        let wide = laid([180, 180, 180])
        let marks = MediaTimelining.capMarks(wide, holding: 1, caps: caps(of: wide, holding: 1), reach: 44)
        #expect(marks.map(\.reach) == [168...212, 328...372], "got \(marks.map(\.reach))")

        let narrow = laid([100, 20, 100])
        let tight = MediaTimelining.capMarks(narrow, holding: 1, caps: caps(of: narrow, holding: 1), reach: 44)
        #expect(tight.map(\.reach) == [88...110, 110...132], "got \(tight.map(\.reach))")
    }

    /// ⚠️ **THE DAYLIGHT IS CARVED FROM THE FILM AND NEVER FROM THE CLOCK.** Asked
    /// for as *"séparer les segments avec un léger espace"*: two points between
    /// neighbours, centred on the cut, and the outer ends of the result untouched.
    @Test func daylightIsCarvedFromTheFilmAndNeverFromTheClock() {
        let placed = laid([180, 180, 180])
        let spans = MediaTimelining.spans(of: placed, gap: 2, scale: 3)

        #expect(spans.count == 3)
        #expect(spans[0].from == 0 && spans[2].to == 540, "an outer end was carved: \(spans)")
        for seam in 0..<2 {
            let gap = spans[seam + 1].from - spans[seam].to
            #expect(abs(gap - 2) < 0.0001, "seam \(seam) has \(gap)pt of daylight")
            #expect(abs((spans[seam].to + spans[seam + 1].from) / 2 - placed[seam].to) < 0.0001,
                    "seam \(seam)'s daylight is not centred on its cut")
        }
        for (span, at) in zip(spans, placed) {
            #expect(span.from >= at.from && span.to <= at.to, "a span leaves its placement: \(span)")
            #expect(span.placement == at, "the clock was rewritten: \(span.placement)")
        }
    }

    /// ⚠️ **THE HELD PIECE KEEPS ALL ITS FILM, AND ITS NEIGHBOURS KEEP WHAT THEY
    /// HAD.** Its caps stand on its cut; holding it must move nothing else.
    @Test func theHeldPieceKeepsAllItsFilmAndItsNeighboursKeepTheirs() {
        let placed = laid([180, 180, 180])
        let free = MediaTimelining.spans(of: placed, gap: 2, scale: 3)
        let held = MediaTimelining.spans(of: placed, gap: 2, holding: 1, scale: 3)

        #expect(held[1].from == 180 && held[1].to == 360, "the held piece was carved: \(held[1])")
        #expect(held[0] == free[0] && held[2] == free[2],
                "holding the middle moved a neighbour: \(free) → \(held)")
        #expect(held[0].to == 179 && held[2].from == 361)
    }

    /// A piece too narrow for its daylight keeps a hair of film, and gives up
    /// what it cannot spare — never a negative width.
    @Test func aPieceTooNarrowForItsDaylightKeepsAHairOfFilm() {
        let three = MediaTimelining.spans(of: laid([100, 3, 100]), gap: 2)
        #expect(abs(three[1].width - 1) < 0.0001, "got \(three[1])")

        let sliver = MediaTimelining.spans(of: laid([100, 1.5, 100]), gap: 2)
        #expect(abs(sliver[1].width - 1) < 0.0001, "got \(sliver[1])")
        #expect(abs((sliver[0].to + sliver[1].from) / 2 - 100) < 0.0001, "not centred: \(sliver)")
        #expect(abs((sliver[1].to + sliver[2].from) / 2 - 101.5) < 0.0001, "not centred: \(sliver)")

        let floored = MediaTimelining.spans(of: laid([100, 1.5, 100]), gap: 2, scale: 3)
        #expect(floored[0].to == 100 && floored[1].from == 100, "a quarter point was not floored: \(floored)")
        for span in three + sliver + floored {
            #expect(span.width >= 0, "a negative width: \(span)")
        }
    }

    /// ⚠️ **EACH HALF IS A WHOLE NUMBER OF PIXELS**, so the daylight never sits
    /// on a half pixel and shimmers as the film scrolls.
    @Test func eachHalfOfTheDaylightIsAWholeNumberOfPixels() {
        let clamped = MediaTimelining.spans(of: laid([100, 2.1, 100]), gap: 2, scale: 3)
        let half = clamped[1].from - 100
        #expect(abs(half - 1.0 / 3) < 0.0001, "got \(half)")
        for scale in [CGFloat(2), 3] {
            let spans = MediaTimelining.spans(of: laid([180, 180, 180]), gap: 2, scale: scale)
            #expect(spans[0].to == 179 && spans[1].from == 181, "at \(scale)x: \(spans)")
            // A half that floors differently at each scale.
            let narrow = MediaTimelining.spans(of: laid([100, 2.1, 100]), gap: 2, scale: scale)
            let floored = narrow[1].from - 100
            #expect(abs(floored - (0.55 * scale).rounded(.down) / scale) < 0.0001,
                    "at \(scale)x the half is \(floored)")
        }
        for (span, at) in zip(clamped, laid([100, 2.1, 100])) {
            for edge in [(span.from - at.from) * 3, (at.to - span.to) * 3] {
                #expect(abs(edge - edge.rounded()) < 0.0001, "an edge off the pixel grid: \(span)")
            }
        }
    }

    /// ⚠️ **A CORNER NEVER OUTGROWS ITS PIECE.** Core Animation does not clamp: a
    /// radius past half the width draws a spike.
    @Test func aPiecesCornersNeverOutgrowIt() {
        let radius = { (width: CGFloat) in
            MediaTimelining.endRadius(width: width, height: 54, preferred: 8)
        }
        #expect(radius(100) == 8 && radius(16) == 8 && radius(12) == 6)
        #expect(radius(1) == 0.5 && radius(0) == 0 && radius(.nan) == 0)
        #expect(MediaTimelining.endRadius(width: 100, height: 10, preferred: 8) == 5)
        for span in MediaTimelining.spans(of: laid([100, 3, 12, 1]), gap: 2, corner: 8, height: 54) {
            #expect(span.radius <= span.width / 2 + 0.0001, "a spike: \(span)")
        }
    }

    /// ⚠️ **THE SQUARES STOP AT THE DAYLIGHT, AND THE SHEET DOES NOT MOVE.** A
    /// square's picture is placed by the clock; carving only hides a point of it.
    @Test func theSquaresStopAtTheDaylightAndTheSheetStaysPut() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4.15), MediaSegment(start: 4.15, end: 10)
        ])
        let placed = MediaTimelining.placements(cut, withinSource: duration, pointsPerSecond: 61)
        let whole = MediaTimelining.squares(
            along: MediaTimelining.spans(of: placed), withinSource: duration,
            visible: -1000...2000, pointsPerSecond: 61
        )
        let carved = MediaTimelining.squares(
            along: MediaTimelining.spans(of: placed, gap: 2), withinSource: duration,
            visible: -1000...2000, pointsPerSecond: 61
        )
        let sheet = Dictionary(uniqueKeysWithValues: whole.map { ($0.place, $0.filmFrom) })
        for square in carved {
            #expect(sheet[square.place] == square.filmFrom, "a square moved on the sheet: \(square)")
            let seam = placed[0].to
            #expect(!(square.from < seam + 1 && square.from + square.width > seam - 1),
                    "a square is drawn in the daylight: \(square)")
        }

        // A 1s piece at 4× at 12pt/s is 3pt: a square of its that lies wholly
        // inside the carved half is not made at all.
        let fast = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 5), MediaSegment(start: 5, end: 6, speed: 4),
            MediaSegment(start: 6, end: 10)
        ])
        let slow = MediaTimelining.placements(fast, withinSource: duration, pointsPerSecond: 12)
        let spans = MediaTimelining.spans(of: slow, gap: 2)
        let made = MediaTimelining.squares(
            along: spans, withinSource: duration, visible: -1000...2000, pointsPerSecond: 12
        )
        for square in made where square.piece == 1 {
            #expect(square.from >= spans[1].from - 0.0001
                    && square.from + square.width <= spans[1].to + 0.0001,
                    "a square outside its drawn film: \(square) in \(spans[1])")
        }
    }

    /// The squares as they were cut before any daylight existed — an independent
    /// copy of that loop, kept as the oracle.
    private func squaresAsTheyWere(
        _ timeline: MediaTimeline, visible: ClosedRange<CGFloat>, pointsPerSecond: CGFloat
    ) -> [MediaTimelining.Square] {
        let tile = MediaTimelining.tileWidth
        var made: [MediaTimelining.Square] = []
        for at in MediaTimelining.placements(timeline, withinSource: duration, pointsPerSecond: pointsPerSecond) {
            let rate = at.piece.speed
            let film = Double(tile / pointsPerSecond) * rate
            let x = { (second: Double) in at.from + CGFloat((second - at.piece.start) / rate) * pointsPerSecond }
            let first = Int((at.piece.start / film).rounded(.down))
            let last = Int((at.piece.end / film).rounded(.up))
            for index in first..<max(last, first + 1) {
                let opens = Double(index) * film
                let filmFrom = x(opens)
                let from = max(filmFrom, at.from)
                let to = min(x(opens + film), at.to)
                guard to > from, to > visible.lowerBound, from < visible.upperBound else { continue }
                made.append(MediaTimelining.Square(
                    place: .init(piece: at.index, index: index), from: from, width: to - from,
                    filmFrom: filmFrom, filmWidth: tile,
                    seconds: min(max(opens + film / 2, 0), duration)
                ))
            }
        }
        return made
    }

    /// ⚠️ **WITH NO DAYLIGHT, THE SQUARES ARE EXACTLY WHAT THEY WERE** — the shot
    /// list and every older test read this wrapper.
    @Test func withNoGapTheSquaresAreExactlyTodays() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4.15), MediaSegment(start: 4.15, end: 10, speed: 2)
        ])
        let now = MediaTimelining.squares(
            in: cut, withinSource: duration, visible: -500...900, pointsPerSecond: 61
        )
        let then = squaresAsTheyWere(cut, visible: -500...900, pointsPerSecond: 61)
        #expect(!now.isEmpty)
        #expect(now == then, "the gap-free squares changed")
    }

    /// ⚠️ **A WINDOW IS THE HULL OF ITS SQUARES — CHARTER T6 — AND ROUNDS ONLY
    /// THE ENDS IT SHOWS.**
    @Test func aWindowIsTheHullOfItsSquaresAndRoundsOnlyTheEndsItHolds() {
        let long = MediaTimelining.spans(
            of: MediaTimelining.placements(.whole, withinSource: 240, pointsPerSecond: 60),
            corner: 8, height: 54
        )
        let middle = MediaTimelining.windows(
            of: MediaTimelining.squares(
                along: long, withinSource: 240, visible: 7000...7822, pointsPerSecond: 60
            ),
            along: long
        )
        #expect(middle.count == 1)
        #expect(middle.first.map { !$0.roundsLeading && !$0.roundsTrailing && $0.radius == 0 } == true,
                "the middle of a long piece is rounded: \(middle)")
        #expect((middle.first?.width ?? .infinity) <= 822 + 108, "the window follows the piece: \(middle)")

        let start = MediaTimelining.windows(
            of: MediaTimelining.squares(
                along: long, withinSource: 240, visible: -411...411, pointsPerSecond: 60
            ),
            along: long
        )
        #expect(start.first.map { $0.roundsLeading && !$0.roundsTrailing && $0.radius == 8 } == true,
                "got \(start)")

        let three = MediaTimelining.spans(of: laid([180, 180, 180]), gap: 2, corner: 8, height: 54)
        var squares: [MediaTimelining.Square] = []
        for span in three {
            // A hand-laid sheet: squares every 54pt from each placement's start.
            for x in stride(from: span.placement.from, to: span.placement.to, by: CGFloat(54)) {
                let from = max(x, span.from)
                let to = min(x + 54, span.to)
                guard to > from, from < 432 else { continue }
                squares.append(MediaTimelining.Square(
                    place: .init(piece: span.index, index: Int(x)), from: from, width: to - from,
                    filmFrom: x, filmWidth: 54, seconds: 0
                ))
            }
        }
        let open = MediaTimelining.windows(of: squares, along: three)
        let froms: [CGFloat] = open.map { $0.from }
        let tos: [CGFloat] = open.map { $0.to }
        #expect(froms == [0, 181, 361], "got \(open)")
        // The band stops laying squares at 432, so the last window ends on the
        // square that crosses it — not on its piece's end.
        #expect(tos == [179, 359, 468], "got \(open)")
        #expect(open.map { $0.roundsLeading } == [true, true, true])
        #expect(open.map { $0.roundsTrailing } == [true, true, false])
    }

    /// The caps stand on the held film, and that is also the band a tap keeps.
    @Test func theCapsStandOnTheHeldFilm() {
        let held = MediaTimelining.spans(of: laid([180, 180, 180]), gap: 2, holding: 1)[1]
        let caps = MediaTimelining.caps(around: held, grab: 12)

        let start: ClosedRange<CGFloat> = 168...180
        let end: ClosedRange<CGFloat> = 360...372
        #expect(caps.start == start && caps.end == end, "got \(caps)")
        #expect(caps.centres.start == 174 && caps.centres.end == 366)
        #expect(caps.claims(168) && caps.claims(372))
        #expect(!caps.claims(167.9) && !caps.claims(372.1))
    }

    /// ⚠️ **A PLATE COVERS THE WHOLE CORNER THE FILM GIVES UP**, tucked under the
    /// cap and the rail.
    @Test func aFilletCoversTheCornerTheFilmGivesUp() throws {
        let held = MediaTimelining.spans(
            of: laid([180, 180, 180]), gap: 2, holding: 1, corner: 8, height: 54
        )[1]
        let plates = MediaTimelining.fillets(around: held, top: 19.5, bottom: 73.5, rail: 1.5, tuck: 2)
        try #require(plates.count == 4)
        let reach = MediaTimelining.cornerReach * 8 + 1
        #expect(abs(plates[0].minX - 178) < 0.001 && abs(plates[0].minY - 18) < 0.001)
        #expect(abs(plates[0].width - (reach + 2)) < 0.001 && abs(plates[0].height - (reach + 1.5)) < 0.001)
        #expect(abs(plates[1].minX - (360 - reach)) < 0.001 && abs(plates[1].maxX - 362) < 0.001)
        #expect(abs(plates[2].maxY - 75) < 0.001 && abs(plates[3].maxY - 75) < 0.001)

        let thin = MediaTimelining.spans(
            of: laid([100, 3, 100]), gap: 2, holding: 1, corner: 8, height: 54
        )[1]
        let narrow = MediaTimelining.fillets(around: thin, top: 19.5, bottom: 73.5, rail: 1.5, tuck: 2)
        #expect(abs((narrow.first?.width ?? 0) - (3 + 2)) < 0.001, "got \(narrow)")

        let square = MediaTimelining.spans(of: laid([180]), corner: 0, height: 54)[0]
        #expect(MediaTimelining.fillets(around: square, top: 19.5, bottom: 73.5, rail: 1.5, tuck: 2).isEmpty)
    }

    /// A track with no width yet — which is every track before its first layout
    /// — has nowhere to lay a list out.
    @Test func aShotListNeedsATrackToStandOn() {
        #expect(MediaTimelining.shots(.whole, withinSource: duration, across: 0).isEmpty)
        #expect(MediaTimelining.shots(.whole, withinSource: 0, across: 300).isEmpty)
    }

    /// The list may be inset from the track's edges, to leave room for the
    /// timecodes centred on its ends.
    @Test func theShotListCanStandInsideTheTrack() {
        let two = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2),
            MediaSegment(start: 2, end: 8)
        ])

        let shots = MediaTimelining.shots(two, withinSource: duration, across: 200, startingAt: 16)

        #expect(shots.map(\.from) == [16, 116])
        #expect(shots.last?.to == 216)
    }

    /// ⚠️ **THE MARKS OVER THE LIST ARE ITS SEAMS, LABELLED WITH WHERE EACH PIECE
    /// BEGINS IN THE RESULT.** Evenly spaced seconds over chips of one width would
    /// lie about every chip; the seams are the only honest marks.
    @Test func theShotListIsMarkedAtItsSeams() {
        let two = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2),
            MediaSegment(start: 2, end: 8)
        ])
        let shots = MediaTimelining.shots(two, withinSource: duration, across: 200, startingAt: 16)

        let marks = MediaTimelining.shotMarks(shots, minimumSpacing: 30)

        #expect(marks == [
            MediaTimelining.ShotMark(x: 16, seconds: 0),
            MediaTimelining.ShotMark(x: 116, seconds: 2),
            MediaTimelining.ShotMark(x: 216, seconds: 8)
        ], "got \(marks)")
    }

    /// ⚠️ **AND THE MARKS FOLLOW THE ORDER, WHICH IS THE WHOLE POINT DURING A
    /// CARRY.** The same two pieces the other way round meet six seconds in.
    @Test func theShotMarksFollowTheOrder() {
        let swapped = MediaTimeline(segments: [
            MediaSegment(start: 2, end: 8),
            MediaSegment(start: 0, end: 2)
        ])
        let shots = MediaTimelining.shots(swapped, withinSource: duration, across: 200)

        #expect(MediaTimelining.shotMarks(shots, minimumSpacing: 30).map(\.seconds) == [0, 6, 8])
    }

    /// ⚠️ **A MARK THAT WOULD SIT ON ANOTHER IS LEFT OUT — NEVER THE ENDS.** Ten
    /// pieces across a hundred points leave ten points a chip, and a timecode is
    /// twenty wide.
    @Test func crowdedSeamsKeepTheirEndsAndDropWhatDoesNotFit() {
        let ten = MediaTimeline(segments: (0..<10).map {
            MediaSegment(start: Double($0), end: Double($0) + 1)
        })
        let shots = MediaTimelining.shots(ten, withinSource: 20, across: 100)

        let marks = MediaTimelining.shotMarks(shots, minimumSpacing: 30)

        #expect(marks.first?.seconds == 0, "the start of the result was dropped")
        #expect(marks.last?.seconds == 10, "the end of the result was dropped")
        for (one, next) in zip(marks, marks.dropFirst()) {
            #expect(next.x - one.x >= 30 - 0.001, "\(one) and \(next) sit on each other")
        }
    }

    /// ⚠️ **AND THE DROP RULE WORKS ON IT UNCHANGED** — which is what makes the
    /// carried piece's CENTRE the thing that decides, since the carried chip is
    /// the one under the finger.
    @Test func aCarriedPieceLandsWhereTheFingerIsOnTheShotList() {
        let three = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 1),
            MediaSegment(start: 2, end: 8),
            MediaSegment(start: 8, end: 9)
        ])
        let shots = MediaTimelining.shots(three, withinSource: duration, across: 300)

        #expect(MediaTimelining.dropIndex(forPoints: 250, in: shots, moving: 0) == 2)
        #expect(MediaTimelining.dropIndex(forPoints: 50, in: shots, moving: 2) == 0)
    }

    // MARK: - What the preview and the export are both built from

    /// ⚠️ **AN UNCUT CLIP IS NO PIECES AT ALL** — the file as shot, which the
    /// preview plays without a composition and the export copies without one.
    @Test func anUncutClipHasNoPiecesToBuild() {
        #expect(MediaTimelining.exportSegments(.whole, withinSource: duration).isEmpty)
        #expect(MediaTimelining.exportSegments(
            MediaTimeline(segments: [MediaSegment(start: 0, end: duration)]), withinSource: duration
        ).isEmpty, "one piece at 1x spanning the file is the file as shot")
    }

    /// ⚠️ **AND A RE-ORDERED ONE KEEPS ITS ORDER.** The preview plays the pieces
    /// in the order the author arranged; sorting them back would play the camera's.
    @Test func aReorderedTimelineIsBuiltInItsOwnOrder() {
        let swapped = MediaTimeline(segments: [
            MediaSegment(start: 6, end: 9, speed: 2),
            MediaSegment(start: 0, end: 3)
        ])

        let pieces = MediaTimelining.exportSegments(swapped, withinSource: duration)

        #expect(pieces.map(\.start) == [6, 0], "got \(pieces)")
        #expect(pieces.map(\.speed) == [2, 1])
    }

    /// ⚠️ **A SPLIT PLAYS THE SAME FILM, AND MUST NOT COST A NEW ITEM.** Two
    /// touching halves at one rate are the piece they were cut from; rebuilding
    /// the preview for them would be a visible hitch for no difference.
    @Test func aSplitPlaysTheSameFilm() {
        let whole = MediaTimeline(segments: [MediaSegment(start: 2, end: 8)])
        let split = MediaTimelining.split(whole, atPiece: 0, atSourceSeconds: 5, withinSource: duration)
        #expect(split != whole, "guard: the split did something")

        #expect(MediaTimelining.playsTheSame(whole, split, withinSource: duration))
    }

    /// And the untouched clip is the one piece a rate chip leaves behind when it
    /// is set back to 1.
    @Test func anUntouchedClipPlaysTheSameAsOnePieceAtRateOne() {
        let asShot = MediaTimeline(segments: [MediaSegment(start: 0, end: duration, speed: 1)])

        #expect(MediaTimelining.playsTheSame(.whole, asShot, withinSource: duration))
    }

    /// ⚠️ **BUT A RE-ORDER, A RATE OR A TRIM IS A DIFFERENT FILM.** Each of these
    /// is what the preview must rebuild for.
    @Test func anOrderARateOrATrimIsADifferentFilm() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let swapped = MediaTimeline(segments: [
            MediaSegment(start: 4, end: 10),
            MediaSegment(start: 0, end: 4)
        ])
        let faster = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, speed: 2),
            MediaSegment(start: 4, end: 10)
        ])
        let trimmed = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 3),
            MediaSegment(start: 4, end: 10)
        ])

        #expect(!MediaTimelining.playsTheSame(cut, swapped, withinSource: duration))
        #expect(!MediaTimelining.playsTheSame(cut, faster, withinSource: duration))
        #expect(!MediaTimelining.playsTheSame(cut, trimmed, withinSource: duration))
    }

    /// ⚠️ **A SEEK ASKED IN PLAYED SECONDS IS AS TIGHT, IN FILM, AS T7 ALLOWS.**
    /// A quarter second of slack on a 4× piece is a second of film — keyframe
    /// steps, the jumping the ceiling exists to stop.
    @Test func aSeekOverAFastPieceIsNoLooserInFilm() {
        let played = MediaTimelining.seekTolerance(movedPlayedSeconds: 10, atSpeed: 4)

        #expect(abs(played * 4 - 0.25) < 0.0001, "\(played)s of item is \(played * 4)s of film")
        #expect(MediaTimelining.seekTolerance(movedPlayedSeconds: 0.1, atSpeed: 1)
                == MediaTimelining.seekTolerance(movedSeconds: 0.1),
                "at 1x the two clocks are the same one")
        #expect(MediaTimelining.seekTolerance(movedPlayedSeconds: 0.1, atSpeed: 0).isFinite,
                "a rate of zero reached the division")
    }

    // MARK: - Following smoothly

    /// ⚠️ **PLAYBACK IS A STEP; A SCRUB IS A JUMP.** At sixty points a second on
    /// a sixty-hertz display the film moves ONE POINT a beat — easing that would
    /// lay a quarter-second animation over motion that is already smooth, and the
    /// film would swim. Easing is for the discontinuities: letting go of a handle
    /// after the player was seeked elsewhere, and the playhead turning back at
    /// the end of the cut.
    @Test func aBeatOfPlaybackIsNotEasedAndAJumpIs() {
        #expect(MediaTimelining.easesFollow(byPoints: 1) == false)
        #expect(MediaTimelining.easesFollow(byPoints: 4) == false,
                "a run of dropped frames is still playback")
        #expect(MediaTimelining.easesFollow(byPoints: 60), "a second of film is a jump")
        #expect(MediaTimelining.easesFollow(byPoints: -60), "and so is one backwards")
    }

    @Test func anUnreadableDistanceIsNotEased() {
        #expect(MediaTimelining.easesFollow(byPoints: .nan) == false)
    }

    /// ⚠️ **AN EASE BEHIND A RUNNING CLIP LANDS WHERE THE CLIP WILL BE.** Aimed
    /// at where the clip WAS, a quarter-second ease ended 13–15pt behind it —
    /// past `stepWithoutEasing` — so the next beat eased again, for as long as
    /// the clip played: the film moved in jumps (measured under
    /// `-timeline-probe`, an ease of 15.1pt every quarter second after a wrap).
    @Test func anEaseBehindARunningClipLandsAhead() {
        let ease = MediaTimelining.followEase(from: 0, to: 100, lead: 13.2)
        #expect(ease.landing == 113.2)
        // The beat after it is a step again.
        #expect(MediaTimelining.easesFollow(byPoints: (113.2 + 1) - ease.landing) == false)
    }

    /// ⚠️ **AND IT ARRIVES MOVING AS FAST AS THE CLIP.** The slope a cubic
    /// timing curve ends on is `(1 − y₂)/(1 − x₂)`; times the distance it
    /// travels, that is how far the film would go in one more ease's time —
    /// which must be the lead, or the film stops dead and starts again.
    @Test func anEaseBehindARunningClipEndsAtItsSpeed() {
        let ease = MediaTimelining.followEase(from: 0, to: 100, lead: 13.2)
        let slope = (1 - ease.controlPoint.y) / (1 - ease.controlPoint.x)
        #expect(abs(slope * (ease.landing - 0) - 13.2) < 0.001, "the curve ends at slope \(slope)")
    }

    @Test func aStoppedClipIsEasedToRest() {
        let ease = MediaTimelining.followEase(from: 40, to: 400, lead: 0)
        #expect(ease.landing == 400)
        #expect(ease.controlPoint.y == 1, "a stopped clip's ease ends moving")
    }

    /// A jump BACK behind a running clip — the wrap at the end of a loop — ends
    /// at rest where the clip will be: the curve cannot end moving forwards
    /// while it travels backwards without leaving the unit square.
    @Test func aJumpBackEndsAtRestAhead() {
        let ease = MediaTimelining.followEase(from: 600, to: 0, lead: 13.2)
        #expect(ease.landing == 13.2)
        #expect(ease.controlPoint.y == 1)
    }

    /// A film just ahead of a running clip travels only the little the clip
    /// has not yet covered, and would need a slope far past the square;
    /// capped, the curve stays inside it and never overshoots.
    @Test func aShortHopNeverOvershoots() {
        let ease = MediaTimelining.followEase(from: 12.5, to: 0, lead: 13.2)
        #expect(ease.landing - 12.5 > 0.5, "guard: the hop is not the short forward one")
        #expect((0...1).contains(ease.controlPoint.y), "the curve leaves the unit square: \(ease.controlPoint)")
        #expect(MediaTimelining.followEase(from: 0, to: 100, lead: .nan).landing == 100)
        #expect(MediaTimelining.followEase(from: 0, to: 100, lead: -5).landing == 100)
    }

    // MARK: - Zoom (charter F15)

    @Test func aPinchMovesTheScaleAndStaysInsideTheRange() {
        let start = MediaTimelining.pointsPerSecond

        #expect(MediaTimelining.zoomed(start, by: 2) == start * 2)
        #expect(MediaTimelining.zoomed(start, by: 100) == MediaTimelining.closestPointsPerSecond)
        #expect(MediaTimelining.zoomed(start, by: 0.001) == MediaTimelining.widestPointsPerSecond)
    }

    /// ⚠️ **A SCALE OF NOTHING LEAVES THE TRACK WHERE IT IS.** A pinch that has
    /// not begun reports a scale of 1, and a recogniser that is cancelled can
    /// report nonsense; either answering zero would collapse the film to no width
    /// at all, which is a division by zero everywhere downstream.
    /// ⚠️ **THE ZOOM CEILING KEEPS THE STRIP OUT OF THE GENERATOR'S CLIFF.**
    /// `VideoFilmstrip.tolerance` is derived from the tile spacing, and below
    /// roughly one frame interval the window stops containing a frame at all —
    /// measured on a 30fps clip: spacing 0.050 returns 3 frames of 3, spacing
    /// 0.033 returns ONE. A 54pt tile at the closest zoom is 0.169s apart, five
    /// times clear of it. Raising the ceiling past about 1000 points a second
    /// would empty the strip silently, so it turns this red first.
    @Test func theClosestZoomStaysClearOfTheGeneratorsFloor() {
        let tightest = MediaTimelining.tileSpacingSeconds(
            in: .whole, withinSource: duration,
            pointsPerSecond: MediaTimelining.closestPointsPerSecond
        )

        #expect(tightest >= 0.05,
                "at \(tightest)s between tiles the generator returns nothing for most of them")
    }

    @Test func anImpossiblePinchChangesNothing() {
        #expect(MediaTimelining.zoomed(60, by: 0) == 60)
        #expect(MediaTimelining.zoomed(60, by: .nan) == 60)
        #expect(MediaTimelining.zoomed(60, by: -2) == 60)
        #expect(MediaTimelining.zoomed(0, by: 2) == 0)
    }

    /// The whole point of zooming in: the same second of film is drawn wider, so
    /// a handle can be aimed at a moment a coarse strip cannot express.
    @Test func zoomingInDrawsASecondWider() {
        let coarse = MediaTimelining.x(atPlayedSeconds: 1, pointsPerSecond: 60)
        let close = MediaTimelining.x(atPlayedSeconds: 1, pointsPerSecond: 240)

        #expect(close == coarse * 4)
        // And the ruler coarsens or refines with it rather than staying put.
        #expect(MediaTimelining.rulerStep(pointsPerSecond: 240, acrossPlayedSeconds: 20)
                < MediaTimelining.rulerStep(pointsPerSecond: 20, acrossPlayedSeconds: 20))
    }

    // MARK: - The film, square by square (charter T2, T3)

    /// The squares of a stretch of track, at a scale where the numbers are easy.
    private func squares(
        _ timeline: MediaTimeline, across visible: ClosedRange<CGFloat>,
        tileWidth: CGFloat = 60, pointsPerSecond: CGFloat = 60, withinSource: Double = 10
    ) -> [MediaTimelining.Square] {
        MediaTimelining.squares(
            in: timeline, withinSource: withinSource, visible: visible,
            tileWidth: tileWidth, pointsPerSecond: pointsPerSecond
        )
    }

    /// The film drawn at a point of the track.
    private func film(at x: CGFloat, in timeline: MediaTimeline, tileWidth: CGFloat = 60) -> Double? {
        squares(timeline, across: 0...2000, tileWidth: tileWidth)
            .first { x >= $0.from && x < $0.from + $0.width }?.seconds
    }

    @Test func aPieceIsWorthOneSquarePerTileWidthOfFilm() throws {
        let whole = squares(.whole, across: 0...600, tileWidth: 54)

        #expect(whole.count == 12, "got \(whole.count)")
        // ⚠️ AND THE LAST ONE IS CUT TO THE FILM'S OWN END: 600 is eleven whole
        // squares and six points, and six points of overhang past the closing cap
        // reads as a rendering fault.
        let last = try #require(whole.last)
        #expect(abs(last.width - 6) < 0.01, "the last square overhangs: \(last)")
    }

    /// ⚠️ **CHARTER T2, AND THE REASON THE WHOLE SYSTEM EXISTS.** The number of
    /// squares worth decoding must not grow with the clip. The predecessor fitted
    /// a fixed count across the WHOLE clip, so every second of film cost a
    /// thumbnail however far off screen it was — 600 of them on a ten-minute clip,
    /// which is 116 MB of decoded pixels for a band 74pt tall.
    @Test func aLongClipHasNoMoreSquaresOnScreenThanAShortOne() {
        let window: ClosedRange<CGFloat> = -MediaTimelining.filmMargin...(
            393 + MediaTimelining.filmMargin
        )

        let short = squares(.whole, across: window, tileWidth: 54, withinSource: 10)
        let long = squares(.whole, across: window, tileWidth: 54, withinSource: 240)

        #expect(MediaTimelining.contentWidth(of: .whole, withinSource: 240)
                > MediaTimelining.contentWidth(of: .whole, withinSource: 10) * 10,
                "guard: the long clip really is much longer")
        #expect(long.count <= short.count + 1,
                "\(long.count) squares for four minutes against \(short.count) for ten seconds")
        #expect(long.count <= 48, "charter T3: \(long.count) squares alive at once")
    }

    @Test func theWindowFollowsTheScrollAndKeepsAMargin() throws {
        let atRest = squares(
            .whole, across: -MediaTimelining.filmMargin...(393 + MediaTimelining.filmMargin),
            tileWidth: 54, withinSource: 240
        )
        let scrolled = squares(
            .whole,
            across: (3000 - MediaTimelining.filmMargin)...(3000 + 393 + MediaTimelining.filmMargin),
            tileWidth: 54, withinSource: 240
        )

        let first = try #require(atRest.first)
        let lastAtRest = try #require(atRest.last)
        let firstScrolled = try #require(scrolled.first)
        #expect(first.from == 0, "the margin ran off the front of the film")
        #expect(firstScrolled.from > lastAtRest.from, "the window did not follow the scroll")
        #expect(firstScrolled.from >= 3000 - MediaTimelining.filmMargin - 54,
                "the window reached further back than its margin")
    }

    /// ⚠️ **A SQUARE BELONGS TO ITS PIECE, AND THAT IS WHAT MAKES THE FILM TRAVEL
    /// WITH THE CLIP.** Laid across the track instead, the squares stand still
    /// while the pieces move: cropping one re-labels every square after the cut
    /// and only the containers move, which is what was reported — *"c'est le
    /// container de la section qui se déplace"*.
    @Test func everySquareIsWhollyInsideItsOwnPiece() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, speed: 1),     // drawn 0–120
            MediaSegment(start: 6, end: 10, speed: 1)     // drawn 120–360
        ])
        let placed = MediaTimelining.placements(cut, withinSource: duration, pointsPerSecond: 60)

        for square in squares(cut, across: 0...360) {
            let mine = placed[square.piece]
            #expect(square.from >= mine.from - 0.01 && square.from + square.width <= mine.to + 0.01,
                    "\(square) sticks out of \(mine)")
            // ⚠️ THE FRAME MAY BE CENTRED JUST OUTSIDE, AND THAT IS THE CROP: a
            // square the window cuts in half keeps its own frame and is trimmed,
            // which is what makes the sheet read as fixed. Half a square is the
            // whole of the licence.
            #expect(square.seconds >= mine.piece.start - 0.46
                    && square.seconds <= mine.piece.end + 0.46,
                    "\(square) shows film from well outside its piece")
        }
    }

    /// And the squares of a piece move with it, by exactly what it moved.
    @Test func aPiecesSquaresTravelWithIt() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let cropped = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 3),               // one second taken off the first
            MediaSegment(start: 4, end: 10)
        ])

        let before = squares(cut, across: 0...600).filter { $0.piece == 1 }
        let after = squares(cropped, across: 0...600).filter { $0.piece == 1 }

        #expect(before.count > 2 && after.count >= before.count, "guard: got \(before.count)")
        for (was, now) in zip(before, after) {
            #expect(abs(now.seconds - was.seconds) < 0.001,
                    "the second piece's film changed: \(was.seconds) -> \(now.seconds)")
            #expect(abs(now.from - (was.from - 60)) < 0.01,
                    "its film did not travel with it: \(was.from) -> \(now.from)")
        }
    }

    /// ⚠️ **THE MIDDLE OF THE TILE, NOT ITS EDGE.** A tile asking at its leading
    /// edge puts the first one on exactly zero — the opening fade most real film
    /// starts with — and the last on the instant the clip ends, where there is
    /// frequently no frame at all.
    @Test func aSquareShowsTheMiddleOfWhatItCovers() {
        #expect(film(at: 30, in: .whole) == 0.5)
        #expect(film(at: 210, in: .whole) == 3.5)
    }

    /// ⚠️ **AND A TILE IN A FAST PIECE COVERS MORE FILM THAN ONE IN A SLOW ONE.**
    /// A tile is a fixed width of RESULT; the film under it is that width times
    /// the rate. Asked the old way — a straight division by the scale — every
    /// tile of a 2× piece would show the frame from half way back, and the strip
    /// would disagree with the picture the needle is standing on.
    @Test func aSquareInAFastPieceReachesFurtherIntoTheFilm() {
        let fast = MediaTimeline(segments: [MediaSegment(start: 0, end: 10, speed: 2)])

        // The first square covers the first second of RESULT, which is the first
        // two seconds of film; its middle is one second in.
        #expect(film(at: 30, in: fast) == 1)
        #expect(film(at: 150, in: fast) == 5)
    }

    /// ⚠️ **AND A TILE OVER A HOLE SHOWS THE FILM THAT IS THERE.** The whole file
    /// ⚠️ **A TILE PAST A CUT READS FROM THE PIECE THAT IS THERE, NOT FROM THE
    /// FILE.** The pieces are laid end to end: the film a trim removed is not on
    /// the track at all, so the tile after the seam shows the next piece's
    /// opening frames rather than the ones the cut threw away.
    @Test func aSquarePastACutReadsFromThePieceThatFollowsIt() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, speed: 1),     // drawn 0–120
            MediaSegment(start: 6, end: 10, speed: 1)     // drawn 120–360
        ])

        // 60–120pt is the last square of the first piece.
        #expect(film(at: 90, in: cut) == 1.5)
        // 120–180 is the first square of the second, which begins at the file's 6s.
        #expect(film(at: 150, in: cut) == 6.5)
    }

    /// The spacing the generator's tolerance is derived from — charter T5.
    @Test func theSpacingIsOneTileOfFilm() {
        #expect(abs(MediaTimelining.tileSpacingSeconds(
            in: .whole, withinSource: duration, tileWidth: 60, pointsPerSecond: 60
        ) - 1) < 0.001)
        #expect(MediaTimelining.tileSpacingSeconds(
            in: .whole, withinSource: duration, pointsPerSecond: 0
        ) == 0)
    }

    /// ⚠️ **THE SLOWEST PIECE SETS THE TOLERANCE FOR EVERYONE — CHARTER T5.**
    /// The rule is "strictly under half the spacing, or the strip repeats
    /// itself", and the spacing is not one number any more: a tile of a 4× piece
    /// covers four times the film a 1× tile does. Deriving from the average, or
    /// from the fastest, gives the slow piece a window wide enough to land two of
    /// its tiles on the same frame.
    @Test func theTightestSpacingInTheTimelineIsWhatCounts() {
        let mixed = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4, speed: 4),
            MediaSegment(start: 4, end: 10, speed: 0.5)
        ])

        #expect(abs(MediaTimelining.tileSpacingSeconds(
            in: mixed, withinSource: duration, tileWidth: 60, pointsPerSecond: 60
        ) - 0.5) < 0.001)
    }

    @Test func anUnlaidTrackHasNoSquares() {
        #expect(squares(.whole, across: 0...393, tileWidth: 0).isEmpty)
        #expect(squares(.whole, across: 0...393, withinSource: 0).isEmpty)
        #expect(squares(.whole, across: 0...0).isEmpty)
    }

    // MARK: - Which film a square of the strip stands for

    /// ⚠️ **OPENING A PIECE REVEALS THE NEXT SQUARES OF ITS SHEET AND MOVES NOT
    /// ONE OF THEM.** The author's own words for what a handle does: *"on révèle
    /// la suite de la piste, comme si le clip était en entier, seule la partie
    /// visible se trouve entre les pinces"*. Two earlier arrangements failed it —
    /// squares laid across the TRACK changed their film in place the moment
    /// anything was cut, and squares anchored to a piece's IN POINT slid their
    /// film as the piece grew.
    @Test func continuingAPieceRevealsMoreOfItsSheetAndMovesNothing() throws {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let continued = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 5),      // the first piece carried on a second
            MediaSegment(start: 4, end: 10)
        ])

        let before = squares(cut, across: 0...600, tileWidth: 54).filter { $0.piece == 0 }
        let after = squares(continued, across: 0...600, tileWidth: 54).filter { $0.piece == 0 }

        #expect(after.count == before.count + 1,
                "no film was revealed: \(before.count) squares then \(after.count)")
        for (was, now) in zip(before, after) {
            #expect(now.seconds == was.seconds,
                    "a square that was already there changed its film: \(was) -> \(now)")
            #expect(now.from == was.from && now.filmFrom == was.filmFrom,
                    "a square that was already there moved: \(was) -> \(now)")
        }
        let opened = try #require(after.last)
        let was = try #require(before.last)
        #expect(opened.seconds > was.seconds, "the square that was revealed shows no new film")
    }

    /// ⚠️ **AND TRIMMING A HEAD CHANGES WHAT NO SQUARE SHOWS.** The window closes
    /// from the left: the squares it passes are hidden, the ones that remain keep
    /// their own film and travel with the piece. Anchored to the piece's IN POINT
    /// instead, every square of it would take on new film as the handle moved —
    /// the sheet sliding under the window, which is what the author reported as
    /// *"cet effet des frames qui se déplient"*.
    @Test func trimmingAHeadHidesSquaresAndChangesWhatNoneOfThemShows() throws {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let cropped = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 5, end: 10)      // a second taken off the second's head
        ])

        let before = squares(cut, across: 0...600, tileWidth: 54).filter { $0.piece == 1 }
        let after = squares(cropped, across: 0...600, tileWidth: 54).filter { $0.piece == 1 }

        #expect(after.count < before.count, "nothing was hidden: \(after.count)")
        for now in after {
            let was = before.first { $0.index == now.index }
            #expect(now.seconds == was?.seconds,
                    "a square that is still shown took on new film: \(now)")
        }
        // And the piece carries them: every one is a second of film further left,
        // because the piece itself is.
        for now in after where now.width > 53 {
            let was = try #require(before.first { $0.index == now.index })
            #expect(abs(now.filmFrom - (was.filmFrom - 60)) < 0.01,
                    "\(now) did not travel with its piece")
        }
    }

    /// And the same in the other direction: cropping HIDES squares and moves none
    /// of the ones that remain.
    @Test func croppingAPieceHidesSquaresAndMovesNoneOfTheRest() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let cropped = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 3),
            MediaSegment(start: 4, end: 10)
        ])

        let before = squares(cut, across: 0...600, tileWidth: 54).filter { $0.piece == 0 }
        let after = squares(cropped, across: 0...600, tileWidth: 54).filter { $0.piece == 0 }

        #expect(after.count < before.count, "nothing was hidden: \(after.count)")
        for now in after {
            let was = before.first { $0.index == now.index }
            #expect(now.seconds == was?.seconds, "a square kept on changed its film: \(now)")
            #expect(now.from == was?.from, "a square kept on moved: \(now)")
        }
    }

    /// ⚠️ **AND A DRAG ASKS FOR NOTHING NEW AT ALL.** A finger moving an edge
    /// reports sixty times a second; squares that re-mapped as it went would make
    /// each of those samples sixteen fresh decodes. Cut on the SOURCE, the sheet
    /// does not move under a handle: every frame the strip has is still a frame
    /// it needs.
    @Test func aTilesFilmStandsStillWhileAnEdgeInchesAlong() {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4, end: 10)
        ])
        let nudged = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4.05),   // three points of finger
            MediaSegment(start: 4, end: 10)
        ])

        #expect(film(at: 250, in: cut, tileWidth: 54) == film(at: 250, in: nudged, tileWidth: 54))
    }

    /// ⚠️ **AND A SQUARE THE WINDOW CUTS IN HALF IS CROPPED, NOT MOVED.** Its
    /// frame is the frame of that stretch of film — which is why it may be
    /// centred a little outside the piece — and the part of it the window shows
    /// is drawn where it has always been. Anything else makes the sheet slide as
    /// a handle moves, which is the whole of the complaint.
    @Test func aSquareTheWindowCutsInHalfKeepsItsOwnFrame() throws {
        let cut = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 4),
            MediaSegment(start: 4.15, end: 10)
        ])

        let first = try #require(
            squares(cut, across: 0...600, tileWidth: 54).first { $0.piece == 1 }
        )

        #expect(first.from >= 240 - 0.01, "it is drawn outside its own piece: \(first)")
        #expect(first.width < 54, "guard: the window really does cut this one: \(first)")
        #expect(first.filmFrom < first.from,
                "its picture was pulled into the visible part instead of being cropped")
        #expect(abs(first.seconds - (Double(first.index) * 0.9 + 0.45)) < 0.001,
                "it is not showing its own stretch of the sheet: \(first)")
    }

    // MARK: - Seeking while scrubbing (charter T7)

    /// ⚠️ **A CONSTANT TOLERANCE IS WRONG AT BOTH ENDS.** Exact seeks sixty times
    /// a second leave the picture lurching behind the finger; loose ones leave a
    /// slow drag showing no change at all. The distance a sample moved is the
    /// speed.
    @Test func aFastScrubAsksLooselyAndASlowOneAsksExactly() {
        let flung = MediaTimelining.seekTolerance(movedSeconds: 0.9)
        let crept = MediaTimelining.seekTolerance(movedSeconds: 0.004)

        #expect(flung > crept * 10, "the tolerance barely moves: \(crept) to \(flung)")
        #expect(crept <= 0.02, "a crawl is paying for keyframes it cannot see")
    }

    @Test func theToleranceIsBoundedAtBothEnds() {
        #expect(MediaTimelining.seekTolerance(movedSeconds: 60) == 0.25,
                "a tolerance this loose lands on keyframes, which reads as jumping")
        #expect(MediaTimelining.seekTolerance(movedSeconds: 0) == 0.02)
        #expect(MediaTimelining.seekTolerance(movedSeconds: -0.2) == 0.2,
                "a backwards scrub is just as fast as a forwards one")
        #expect(MediaTimelining.seekTolerance(movedSeconds: -5) == 0.25,
                "and it meets the same ceiling going backwards")
        #expect(MediaTimelining.seekTolerance(movedSeconds: .nan) == 0.25)
    }

    // MARK: - Who owns the time

    /// ⚠️ **THE BUG THIS EXISTS FOR.** Reported from the device: "if I move
    /// forward in the timeline, the video goes back to its starting point
    /// instead of carrying on from the cursor." One cause was a stale pause
    /// anchor in `VideoPlaybackController` (fixed there, with its own test); the
    /// other is here — the track resumed following one tick after the finger
    /// lifted, read a player that had not finished seeking, and copied the OLD
    /// position back over the new one.
    @Test func theTrackDoesNotFollowAPlayerThatHasNotArrivedYet() {
        let waiting = MediaTimelining.Handover(target: 8)

        let (follow, next) = MediaTimelining.handover(waiting, playerSeconds: 0.4)

        #expect(follow == false, "the track just copied the pre-scrub position back")
        #expect(next.target == 8, "and it has forgotten what it was waiting for")
        #expect(next.ticksWaited == 1)
    }

    @Test func theTrackFollowsAgainOnceThePlayerArrives() {
        let waiting = MediaTimelining.Handover(target: 8, ticksWaited: 4)

        let (follow, next) = MediaTimelining.handover(waiting, playerSeconds: 8.2)

        #expect(follow)
        #expect(next == .settled, "still waiting for a target it already reached: \(next)")
    }

    /// ⚠️ **AND IT GIVES UP RATHER THAN WAITING FOREVER.** The player can
    /// legitimately never arrive — a scrub past the end, a clip that looped, a
    /// seek the item refused — and a track that waits for it stops following
    /// playback altogether with nothing on screen to say why.
    @Test func theTrackStopsWaitingForAPlayerThatNeverArrives() {
        var state = MediaTimelining.Handover(target: 8)
        var follows = 0

        for _ in 0..<MediaTimelining.handoverTicks * 2 {
            let (follow, next) = MediaTimelining.handover(state, playerSeconds: 0)
            if follow { follows += 1 }
            state = next
        }

        #expect(follows > 0, "the track never followed again")
        #expect(state == .settled)
    }

    @Test func aSettledHandoverAlwaysFollows() {
        let (follow, next) = MediaTimelining.handover(.settled, playerSeconds: 3)

        #expect(follow)
        #expect(next == .settled)
    }

    /// A player with no readable time is not an arrival — it is a player that
    /// has not answered. Counting it as one would hand the time back on the
    /// strength of a NaN.
    @Test func anUnreadablePlayerTimeIsNotAnArrival() {
        let (follow, next) = MediaTimelining.handover(
            MediaTimelining.Handover(target: 8), playerSeconds: .nan
        )

        #expect(follow == false)
        #expect(next.ticksWaited == 1)
    }

    // MARK: - The ruler

    /// ⚠️ **THE FIRST RULE IS SPACING.** At 60pt a second, labelling every second
    /// puts "0:01" 60pt from "0:02" and the timecodes touch.
    @Test func theRulerSkipsSecondsRatherThanLetTimecodesTouch() {
        let step = MediaTimelining.rulerStep(
            pointsPerSecond: 60, acrossPlayedSeconds: 20, minimumSpacing: 64
        )

        #expect(step == 2, "a 1s step would be 60pt apart, under the 64pt minimum")
        #expect(CGFloat(step) * 60 >= 64)
    }

    /// ⚠️ **AND THE SECOND RULE IS COUNT, WHICH SPACING ALONE NEVER REACHES.**
    /// Every mark is a view. A forty-minute clip at the spacing-only answer of
    /// two seconds is twelve hundred views for a strip 74pt tall — and spacing
    /// says two seconds is fine, because at 60pt a second it is.
    @Test func aLongClipIsMarkedCoarselyRatherThanWithAThousandTicks() {
        let spacingWouldAllow = MediaTimelining.rulerStep(
            pointsPerSecond: 60, acrossPlayedSeconds: 2400,
            minimumSpacing: 64, maximumTicks: 64
        )

        #expect(spacingWouldAllow >= 2400 / 64, "got \(spacingWouldAllow): \(2400 / spacingWouldAllow) ticks")
        #expect(spacingWouldAllow > 2, "spacing alone would have said 2")
    }

    /// A ruler with too few marks is still a ruler; a ruler with none is a bug
    /// that looks like a design.
    @Test func aClipLongerThanEveryOfferedStepStillGetsARuler() {
        let step = MediaTimelining.rulerStep(
            pointsPerSecond: 60, acrossPlayedSeconds: 100_000, maximumTicks: 8
        )

        #expect(step == MediaTimelining.rulerSteps.last)
    }

    /// ⚠️ **AND NOT ONE STEP FURTHER — IT USED TO.** A mark is placed at the film
    /// that plays at that moment, and past the end of the result there is none:
    /// an overshoot clamps onto the last piece's end and prints on top of the
    /// mark before it. Seen on the device as "0:06" and "0:08" overlapping.
    @Test func theMarksRunFromZeroToTheEndOfTheResult() {
        #expect(MediaTimelining.rulerSeconds(upToPlayedSeconds: 10, step: 4) == [0, 4, 8])
        #expect(MediaTimelining.rulerSeconds(upToPlayedSeconds: 12, step: 4) == [0, 4, 8, 12],
                "a mark that lands exactly on the end is a mark, not an overshoot")
    }

    @Test func anUnmeasurableClipIsNotMarked() {
        #expect(MediaTimelining.rulerSeconds(upToPlayedSeconds: 0, step: 1).isEmpty)
        #expect(MediaTimelining.rulerSeconds(upToPlayedSeconds: 10, step: 0).isEmpty)
        #expect(MediaTimelining.rulerSeconds(upToPlayedSeconds: .infinity, step: 1).isEmpty)
    }
}
