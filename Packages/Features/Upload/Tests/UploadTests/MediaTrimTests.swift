import Foundation
import Testing
@testable import Upload

/// **EVERY RULE A TRIM HANDLE COULD GET WRONG, ASKED WITHOUT A GESTURE.**
///
/// A `UIPanGestureRecognizer`'s translation cannot be set, so anything decided
/// inside a drag handler is a decision no test can reach. `StraightenDial` was
/// split for exactly this reason and says so; this follows it.
struct MediaTrimTests {
    private let duration = 10.0

    // MARK: - Resolving

    @Test func anUntouchedTrimIsTheWholeClip() {
        let range = MediaTrimming.resolved(.whole, within: duration)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == duration)
    }

    /// ⚠️ **A STORED TRIM CAN OUTLIVE THE CLIP IT WAS MADE FOR** — a draft, a
    /// re-pick, a library that answers a different file. "4s to 9s" against a
    /// two-second clip has to mean something rather than hand an exporter a
    /// range that is not in the asset.
    @Test func aTrimFromALongerClipIsBroughtInside() {
        let range = MediaTrimming.resolved(MediaTrim(start: 4, end: 9), within: 2)

        #expect(range.upperBound <= 2, "the end is past the clip: \(range)")
        #expect(range.lowerBound >= 0)
        #expect(range.lowerBound <= range.upperBound, "and it never inverts: \(range)")
    }

    /// ⚠️ **THE START YIELDS; THE END HOLDS — AND ASKING ONLY FOR A VALID RANGE
    /// CANNOT TELL THE TWO APART.** This first asserted "not inverted, at least
    /// the floor wide", which a wrong implementation satisfies just as well:
    /// letting the START win turns (8, 3) into 8...9, and letting the END win
    /// turns it into 2...3. Both are non-inverted and both are a second long.
    /// Proven by breaking the clamp and watching this pass.
    ///
    /// The end is the one the author last put somewhere; a start dragged through
    /// it should push itself back, not drag the end along.
    @Test func aStartPushedPastTheEndYieldsAndTheEndHolds() {
        let range = MediaTrimming.resolved(MediaTrim(start: 8, end: 3), within: duration)

        #expect(range.lowerBound < range.upperBound, "got \(range)")
        #expect(range.upperBound <= 3.001, "the end moved instead of the start: \(range)")
        #expect(range.upperBound - range.lowerBound >= MediaTrimming.shortestSeconds - 0.001)
    }

    /// ⚠️ **THE FLOOR IS A CEILING TOO.** A clip already shorter than the
    /// minimum cannot be trimmed, and the rule has to bend rather than invert.
    @Test func aClipShorterThanTheFloorSurvivesIt() {
        let range = MediaTrimming.resolved(MediaTrim(start: 0.2, end: 0.4), within: 0.5)

        #expect(range.lowerBound >= 0)
        #expect(range.upperBound <= 0.5, "got \(range)")
        #expect(range.lowerBound <= range.upperBound)
    }

    // MARK: - Whether it cuts anything

    /// ⚠️ **THE ASSERTION THAT IS NOT `!isWhole`.** A trim of 0 to exactly the
    /// duration is a different VALUE from `.whole` and the same INSTRUCTION.
    /// Both must take the publish path's passthrough route: attaching a time
    /// range that happens to cover everything still makes the exporter
    /// re-encode the clip for nothing.
    @Test func aTrimCoveringTheWholeClipCutsNothing() {
        #expect(MediaTrimming.cuts(.whole, within: duration) == false)
        #expect(
            MediaTrimming.cuts(MediaTrim(start: 0, end: duration), within: duration) == false,
            "an explicit 0-to-duration is the same instruction as .whole"
        )
    }

    /// The witness for the line above: a real trim does cut, so "cuts nothing"
    /// is about the value and not about the function always saying no.
    @Test func aRealTrimCuts() {
        #expect(MediaTrimming.cuts(MediaTrim(start: 2, end: 8), within: duration))
        #expect(MediaTrimming.cuts(MediaTrim(start: 2, end: nil), within: duration))
        #expect(MediaTrimming.cuts(MediaTrim(start: 0, end: 8), within: duration))
    }

    // MARK: - Dragging

    @Test func theStartStopsAtTheBeginningOfTheClip() {
        let moved = MediaTrimming.moved(
            MediaTrim(start: 1, end: 8), handle: .start, bySeconds: -50, within: duration
        )
        #expect(MediaTrimming.resolved(moved, within: duration).lowerBound == 0)
    }

    @Test func theEndStopsAtTheEndOfTheClip() {
        let moved = MediaTrimming.moved(
            MediaTrim(start: 1, end: 8), handle: .end, bySeconds: 50, within: duration
        )
        #expect(MediaTrimming.resolved(moved, within: duration).upperBound == duration)
    }

    /// The handles may not cross, and may not close to nothing.
    @Test func theHandlesKeepTheShortestClipBetweenThem() {
        let squeezed = MediaTrimming.moved(
            MediaTrim(start: 2, end: 8), handle: .start, bySeconds: 50, within: duration
        )
        let range = MediaTrimming.resolved(squeezed, within: duration)
        #expect(range.upperBound - range.lowerBound >= MediaTrimming.shortestSeconds - 0.001,
                "got \(range)")

        let other = MediaTrimming.moved(
            MediaTrim(start: 2, end: 8), handle: .end, bySeconds: -50, within: duration
        )
        let otherRange = MediaTrimming.resolved(other, within: duration)
        #expect(otherRange.upperBound - otherRange.lowerBound >= MediaTrimming.shortestSeconds - 0.001,
                "got \(otherRange)")
    }

    /// ⚠️ **THE PROPERTY THE INCREMENTAL DESIGN EXISTS FOR.** Drag the end past
    /// the finish of the clip, then drag back the same distance: it must come
    /// back. Measured from touch-down it would not — the overshoot would have to
    /// be undone first, and the handle would feel stuck for exactly as long as
    /// it was pushed.
    @Test func aHandleDraggedPastTheEndComesStraightBack() {
        var trim = MediaTrim(start: 1, end: 6)
        trim = MediaTrimming.moved(trim, handle: .end, bySeconds: 20, within: duration)
        #expect(MediaTrimming.resolved(trim, within: duration).upperBound == duration,
                "guard: it went to the end")

        trim = MediaTrimming.moved(trim, handle: .end, bySeconds: -2, within: duration)

        #expect(abs(MediaTrimming.resolved(trim, within: duration).upperBound - 8) < 0.001,
                "got \(MediaTrimming.resolved(trim, within: duration))")
    }

    /// Two small steps equal one big one — what "incremental" means, asserted
    /// rather than assumed.
    @Test func twoStepsMakeTheSameMoveAsOne() {
        let once = MediaTrimming.moved(
            MediaTrim(start: 1, end: 8), handle: .start, bySeconds: 2, within: duration
        )
        var twice = MediaTrimming.moved(
            MediaTrim(start: 1, end: 8), handle: .start, bySeconds: 1, within: duration
        )
        twice = MediaTrimming.moved(twice, handle: .start, bySeconds: 1, within: duration)

        #expect(abs(MediaTrimming.resolved(once, within: duration).lowerBound
                    - MediaTrimming.resolved(twice, within: duration).lowerBound) < 0.001)
    }

    // MARK: - Taking hold

    /// ⚠️ **THE NEARER HANDLE WINS, AND THE TIE IS REAL.** Trimmed to the
    /// minimum, the two handles are a few points apart and one touch is within
    /// reach of both. Answering `.start` by default would make the end handle
    /// unreachable exactly when the author wants to widen the selection again.
    @Test func theNearerHandleTakesTheTouch() {
        #expect(MediaTrimming.handle(at: 12, startX: 10, endX: 40) == .start)
        #expect(MediaTrimming.handle(at: 38, startX: 10, endX: 40) == .end)
        #expect(MediaTrimming.handle(at: 26, startX: 20, endX: 30) == .end,
                "a touch nearer the end takes the end even when both are in reach")
    }

    @Test func aTouchBeyondReachTakesNeither() {
        #expect(MediaTrimming.handle(at: 300, startX: 10, endX: 40) == nil)
    }

    // MARK: - The cache key

    /// ⚠️ **THE TRAP `MediaEdits.signature` HAS ALREADY FALLEN INTO ONCE.** The
    /// key is what `NewPostMediaCell` uses to decide whether to redraw at all,
    /// so a decision missing from it is a thumbnail silently showing the
    /// previous edit while the editor shows the new one — no error, no clue.
    ///
    /// The existing note explains that interpolating `crop` WHOLE covers a new
    /// `MediaCrop` field for free. It does not cover a new `MediaEdits` field,
    /// which is what `trim` is. `isMirrored` went stale exactly this way.
    @Test func changingOnlyTheTrimChangesTheCacheKey() {
        var edited = MediaEdits.untouched
        edited.trim = MediaTrim(start: 1, end: 4)

        #expect(edited.signature != MediaEdits.untouched.signature)
    }

    /// The witness: two edits differing in nothing share a key, so the line
    /// above is about `trim` and not about the key being different every time
    /// it is asked for.
    @Test func twoIdenticalEditsShareTheirKey() {
        #expect(MediaEdits.untouched.signature == MediaEdits().signature)
    }

    /// A trim makes an edit worth carrying. `change(_:_:)` stores nothing when
    /// an edit is untouched, so a trim that did not move this needle would be
    /// dropped on its way to the next screen.
    @Test func aTrimMakesAnEditWorthKeeping() {
        var edited = MediaEdits.untouched
        edited.trim = MediaTrim(start: 1, end: 4)

        #expect(edited.isUntouched == false)
    }

    // MARK: - Points and seconds

    @Test func aMomentAndItsPlaceAgree() {
        let x = MediaTrimming.x(forSeconds: 2.5, width: 200, duration: duration)
        #expect(abs(x - 50) < 0.001)

        let back = MediaTrimming.seconds(forWidth: x, width: 200, duration: duration)
        #expect(abs(back - 2.5) < 0.001)
    }

    /// ⚠️ A ZERO WIDTH IS NOT A CRASH. The strip is asked where a handle goes
    /// before it has been laid out — every band tenant is built before its first
    /// `layoutSubviews`.
    @Test func anUnlaidStripAnswersZeroRatherThanNaN() {
        #expect(MediaTrimming.x(forSeconds: 2, width: 0, duration: duration) == 0)
        #expect(MediaTrimming.seconds(forWidth: 10, width: 0, duration: duration) == 0)
        #expect(MediaTrimming.seconds(forWidth: 10, width: 100, duration: 0) == 0)
        #expect(MediaTrimming.resolved(.whole, within: 0) == 0...0)
    }
}
