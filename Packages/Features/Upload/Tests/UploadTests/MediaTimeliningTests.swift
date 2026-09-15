import Foundation
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
        let x = MediaTimelining.x(atSourceSeconds: 2.5, pointsPerSecond: 60)
        #expect(x == 150)
        #expect(abs(MediaTimelining.sourceSeconds(atX: x, pointsPerSecond: 60) - 2.5) < 0.001)
    }

    /// ⚠️ A ZERO SCALE IS NOT A CRASH. Every band tenant is asked where things go
    /// before its first layout.
    @Test func anUnlaidTrackAnswersZeroRatherThanNaN() {
        #expect(MediaTimelining.sourceSeconds(atX: 10, pointsPerSecond: 0) == 0)
        #expect(MediaTimelining.x(atSourceSeconds: .nan) == 0)
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

        let atRest = MediaTimelining.contentOffset(forSourceSeconds: 0, trackWidth: width)

        #expect(atRest == -200, "the clip would open half a screen past its start")
        #expect(
            MediaTimelining.sourceSeconds(
                atContentOffset: atRest, trackWidth: width, withinSource: 10
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

        let offset = MediaTimelining.contentOffset(forSourceSeconds: 3.5, trackWidth: width)
        let back = MediaTimelining.sourceSeconds(
            atContentOffset: offset, trackWidth: width, withinSource: duration
        )

        #expect(abs(back - 3.5) < 0.001)
    }

    /// A scroll view rubber-bands past both ends; the needle then stands over a
    /// moment the file does not have, and a seek there is a seek to nowhere.
    @Test func aRubberBandedScrollStaysInsideTheClip() {
        let width: CGFloat = 400

        #expect(
            MediaTimelining.sourceSeconds(
                atContentOffset: -900, trackWidth: width, withinSource: duration
            ) == 0
        )
        #expect(
            MediaTimelining.sourceSeconds(
                atContentOffset: 5000, trackWidth: width, withinSource: duration
            ) == duration
        )
    }

    /// ⚠️ **A POSITION FLOORS AT ZERO AND A DISTANCE DOES NOT.** Using the
    /// position converter for a drag delta turns every leftward sample into
    /// zero — the handle opens outwards and will not come back, which reads as a
    /// clamp rather than as the dead control it is.
    @Test func aLeftwardDragIsANegativeNumberOfSeconds() {
        #expect(MediaTimelining.sourceSeconds(ofPoints: -120, pointsPerSecond: 60) == -2)
        #expect(MediaTimelining.sourceSeconds(ofPoints: 120, pointsPerSecond: 60) == 2)
        #expect(MediaTimelining.sourceSeconds(atX: -120, pointsPerSecond: 60) == 0,
                "the position converter still floors, which is why it is not this one")
    }

    @Test func theStripIsAsWideAsTheClipIsLong() {
        #expect(MediaTimelining.contentWidth(ofSourceSeconds: 10, pointsPerSecond: 60) == 600)
        #expect(MediaTimelining.contentWidth(ofSourceSeconds: 0, pointsPerSecond: 60) == 0)
    }

    // MARK: - Splitting, and rates

    @Test func splittingMakesTwoPiecesOutOfOne() throws {
        let split = MediaTimelining.split(.whole, atSourceSeconds: 4, withinSource: duration)

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
        let tooEarly = MediaTimelining.split(.whole, atSourceSeconds: 0.4, withinSource: duration)
        let tooLate = MediaTimelining.split(.whole, atSourceSeconds: 9.7, withinSource: duration)

        #expect(MediaTimelining.resolved(tooEarly, withinSource: duration).count == 1)
        #expect(MediaTimelining.resolved(tooLate, withinSource: duration).count == 1)
        #expect(MediaTimelining.canSplit(.whole, atSourceSeconds: 0.4, withinSource: duration) == false)
        #expect(MediaTimelining.canSplit(.whole, atSourceSeconds: 4, withinSource: duration),
                "witness: a split in the middle is offered")
    }

    /// Splitting the SECOND piece must not disturb the first — the commonest way
    /// to get an insert wrong is to put it at the wrong index.
    @Test func splittingOnePieceLeavesTheOthersAlone() throws {
        let once = MediaTimelining.split(.whole, atSourceSeconds: 3, withinSource: duration)

        let twice = MediaTimelining.split(once, atSourceSeconds: 7, withinSource: duration)

        let pieces = MediaTimelining.resolved(twice, withinSource: duration)
        #expect(pieces.count == 3, "got \(pieces)")
        #expect(pieces.map(\.start) == [0, 3, 7])
        #expect(pieces.map(\.end) == [3, 7, duration])
    }

    @Test func splittingKeepsTheRateOfThePieceItCuts() throws {
        let sped = MediaTimeline(segments: [MediaSegment(start: 0, end: duration, speed: 2)])

        let split = MediaTimelining.split(sped, atSourceSeconds: 5, withinSource: duration)

        let pieces = MediaTimelining.resolved(split, withinSource: duration)
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.speed == 2 }, "the halves lost the rate: \(pieces)")
    }

    // MARK: - Rates

    @Test func aRateAppliesToThePieceUnderTheNeedleAndNoOther() throws {
        let split = MediaTimelining.split(.whole, atSourceSeconds: 4, withinSource: duration)

        let sped = MediaTimelining.setRate(2, at: 6, in: split, withinSource: duration)

        let pieces = MediaTimelining.resolved(sped, withinSource: duration)
        #expect(pieces.count == 2, "got \(pieces)")
        #expect(pieces.first?.speed == 1, "the first piece was sped up too")
        #expect(pieces.last?.speed == 2, "the second piece kept its rate")
    }

    @Test func theRateUnderTheNeedleIsWhatIsRead() {
        let split = MediaTimelining.split(.whole, atSourceSeconds: 4, withinSource: duration)
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

    // MARK: - Playback stays inside the cut

    /// ⚠️ **A CUT IS A PROMISE ABOUT WHAT THE POST WILL BE.** A preview that
    /// plays on past the end handle shows the author footage they have just
    /// decided to throw away, as though it were part of the result.
    @Test func playbackTurnsBackWhenItReachesTheEndOfTheCut() {
        let kept = [MediaSegment(start: 2, end: 6)]

        #expect(MediaTimelining.loopback(playheadSeconds: 6, within: kept) == 2)
        #expect(MediaTimelining.loopback(playheadSeconds: 5.99, within: kept) == 2,
                "the slack has to turn back a little early or it races the player")
    }

    /// And at the head too: a trimmed opening that still plays first means the
    /// preview and the export disagree about where the post begins.
    @Test func playbackJumpsForwardWhenItIsBeforeTheCut() {
        let kept = [MediaSegment(start: 4, end: 9)]

        #expect(MediaTimelining.loopback(playheadSeconds: 0, within: kept) == 4)
        #expect(MediaTimelining.loopback(playheadSeconds: 3.5, within: kept) == 4)
    }

    /// ⚠️ **AND IT MUST SETTLE, NOT THRASH.** Coming back to the start, the
    /// playhead is inside the cut by construction; if the return trip could
    /// re-trigger, the clip would be seeked on every beat and never play at all.
    @Test func theTurnBackDoesNotTriggerItself() {
        let kept = [MediaSegment(start: 2, end: 6)]
        let back = try? #require(MediaTimelining.loopback(playheadSeconds: 6, within: kept))

        #expect(MediaTimelining.loopback(playheadSeconds: back ?? 0, within: kept) == nil,
                "arriving at the start asks to go to the start again")
        #expect(MediaTimelining.loopback(playheadSeconds: 4, within: kept) == nil,
                "the middle of the cut is not a reason to seek")
    }

    @Test func thereIsNothingToTurnBackFromWithoutACut() {
        #expect(MediaTimelining.loopback(playheadSeconds: 3, within: []) == nil)
        #expect(MediaTimelining.loopback(
            playheadSeconds: .nan, within: [MediaSegment(start: 0, end: 5)]
        ) == nil)
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
    @Test func anImpossiblePinchChangesNothing() {
        #expect(MediaTimelining.zoomed(60, by: 0) == 60)
        #expect(MediaTimelining.zoomed(60, by: .nan) == 60)
        #expect(MediaTimelining.zoomed(60, by: -2) == 60)
        #expect(MediaTimelining.zoomed(0, by: 2) == 0)
    }

    /// The whole point of zooming in: the same second of film is drawn wider, so
    /// a handle can be aimed at a moment a coarse strip cannot express.
    @Test func zoomingInDrawsASecondWider() {
        let coarse = MediaTimelining.x(atSourceSeconds: 1, pointsPerSecond: 60)
        let close = MediaTimelining.x(atSourceSeconds: 1, pointsPerSecond: 240)

        #expect(close == coarse * 4)
        // And the ruler coarsens or refines with it rather than staying put.
        #expect(MediaTimelining.rulerStep(pointsPerSecond: 240, acrossSourceSeconds: 20)
                < MediaTimelining.rulerStep(pointsPerSecond: 20, acrossSourceSeconds: 20))
    }

    // MARK: - The film, tile by tile (charter T2, T3)

    @Test func aClipIsWorthOneTilePerTileWidthOfFilm() {
        let tenSeconds = MediaTimelining.contentWidth(ofSourceSeconds: 10)   // 600pt

        #expect(MediaTimelining.tileCount(acrossContentWidth: tenSeconds, tileWidth: 54) == 12)
        #expect(MediaTimelining.tileCount(acrossContentWidth: 0) == 0)
    }

    /// ⚠️ **CHARTER T2, AND THE REASON THE WHOLE TILE SYSTEM EXISTS.** The number
    /// of tiles worth decoding must not grow with the clip. The predecessor fitted
    /// a fixed count across the WHOLE clip, so every second of film cost a
    /// thumbnail however far off screen it was — 600 of them on a ten-minute clip,
    /// which is 116 MB of decoded pixels for a band 74pt tall.
    @Test func aLongClipHasNoMoreTilesOnScreenThanAShortOne() {
        let width: CGFloat = 393
        let short = MediaTimelining.tileCount(
            acrossContentWidth: MediaTimelining.contentWidth(ofSourceSeconds: 10)
        )
        let long = MediaTimelining.tileCount(
            acrossContentWidth: MediaTimelining.contentWidth(ofSourceSeconds: 240)
        )
        #expect(long > short * 10, "guard: the long clip really is much longer")

        let onScreenShort = MediaTimelining.visibleTiles(
            contentOffset: 0, trackWidth: width, count: short
        )
        let onScreenLong = MediaTimelining.visibleTiles(
            contentOffset: 0, trackWidth: width, count: long
        )

        #expect(onScreenLong.count <= onScreenShort.count + 1,
                "\(onScreenLong.count) tiles for four minutes against \(onScreenShort.count) for ten seconds")
        #expect(onScreenLong.count <= 48, "charter T3: \(onScreenLong.count) tiles alive at once")
    }

    @Test func theWindowFollowsTheScrollAndKeepsAMargin() {
        let count = MediaTimelining.tileCount(
            acrossContentWidth: MediaTimelining.contentWidth(ofSourceSeconds: 240)
        )

        let atRest = MediaTimelining.visibleTiles(contentOffset: 0, trackWidth: 393, count: count)
        let scrolled = MediaTimelining.visibleTiles(
            contentOffset: 3000, trackWidth: 393, count: count
        )

        #expect(atRest.lowerBound == 0, "the margin ran off the front of the film")
        #expect(scrolled.lowerBound > atRest.upperBound, "the window did not follow the scroll")
        #expect(scrolled.upperBound <= count, "the margin ran off the end of the film")
    }

    /// ⚠️ **THE MIDDLE OF THE TILE, NOT ITS EDGE.** A tile asking at its leading
    /// edge puts the first one on exactly zero — the opening fade most real film
    /// starts with — and the last on the instant the clip ends, where there is
    /// frequently no frame at all.
    @Test func aTileShowsTheMiddleOfWhatItCovers() {
        #expect(MediaTimelining.sourceSeconds(ofTile: 0, tileWidth: 60, pointsPerSecond: 60) == 0.5)
        #expect(MediaTimelining.sourceSeconds(ofTile: 3, tileWidth: 60, pointsPerSecond: 60) == 3.5)
    }

    /// The spacing the generator's tolerance is derived from — charter T5.
    @Test func theSpacingIsOneTileOfFilm() {
        #expect(abs(MediaTimelining.tileSpacingSeconds(tileWidth: 60, pointsPerSecond: 60) - 1) < 0.001)
        #expect(MediaTimelining.tileSpacingSeconds(pointsPerSecond: 0) == 0)
    }

    @Test func anUnlaidTrackHasNoTiles() {
        #expect(MediaTimelining.visibleTiles(
            contentOffset: 0, trackWidth: 0, count: 10
        ).isEmpty)
        #expect(MediaTimelining.visibleTiles(
            contentOffset: 0, trackWidth: 393, count: 0
        ).isEmpty)
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
            pointsPerSecond: 60, acrossSourceSeconds: 20, minimumSpacing: 64
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
            pointsPerSecond: 60, acrossSourceSeconds: 2400,
            minimumSpacing: 64, maximumTicks: 64
        )

        #expect(spacingWouldAllow >= 2400 / 64, "got \(spacingWouldAllow): \(2400 / spacingWouldAllow) ticks")
        #expect(spacingWouldAllow > 2, "spacing alone would have said 2")
    }

    /// A ruler with too few marks is still a ruler; a ruler with none is a bug
    /// that looks like a design.
    @Test func aClipLongerThanEveryOfferedStepStillGetsARuler() {
        let step = MediaTimelining.rulerStep(
            pointsPerSecond: 60, acrossSourceSeconds: 100_000, maximumTicks: 8
        )

        #expect(step == MediaTimelining.rulerSteps.last)
    }

    @Test func theMarksRunFromZeroPastTheEnd() {
        let marks = MediaTimelining.rulerSeconds(upToSourceSeconds: 10, step: 4)

        #expect(marks == [0, 4, 8, 12], "the tail of the clip would look unmeasured")
    }

    @Test func anUnmeasurableClipIsNotMarked() {
        #expect(MediaTimelining.rulerSeconds(upToSourceSeconds: 0, step: 1).isEmpty)
        #expect(MediaTimelining.rulerSeconds(upToSourceSeconds: 10, step: 0).isEmpty)
        #expect(MediaTimelining.rulerSeconds(upToSourceSeconds: .infinity, step: 1).isEmpty)
    }
}
