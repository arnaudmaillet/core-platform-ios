import Testing
import UIKit
@testable import Upload

/// The band's arrival curve, as values — `MapAnnotationPop`'s reason applies
/// here too: a timing that can only be checked by watching it is a timing
/// nobody checks.
struct BandPopTests {
    @Test func theStaggerRisesOneStepPerElement() {
        #expect(BandPop.stagger(for: 0) == 0)
        #expect(abs(BandPop.stagger(for: 1) - BandPop.staggerStep) < 0.0001)
        #expect(abs(BandPop.stagger(for: 3) - 3 * BandPop.staggerStep) < 0.0001)
    }

    /// ⚠️ **AND IT STOPS RISING.** Unbounded, the twelfth effect pill would
    /// arrive nearly half a second after the first — long enough for the author
    /// to have reached for it and found nothing there.
    @Test func theStaggerIsCappedSoALongRowDoesNotBecomeAQueue() {
        #expect(BandPop.stagger(for: 100) == BandPop.staggerCap)
        #expect(BandPop.staggerCap < BandPop.duration * 1.5,
                "the tail outlasts the curve by more than half again")
        let capped = Int((BandPop.staggerCap / BandPop.staggerStep).rounded())
        #expect(capped == BandPop.audibleElements, "the cap and the sound's count disagree")
    }

    /// A negative index is a caller's bug, not a negative delay.
    @Test func anIndexBeforeTheFirstIsTheFirst() {
        #expect(BandPop.stagger(for: -3) == 0)
    }

    @Test func settledIsTheLastElementsDelayPlusItsOwnCurve() {
        #expect(abs(BandPop.settled(after: 1) - BandPop.duration) < 0.0001)
        #expect(abs(BandPop.settled(after: 3) - (2 * BandPop.staggerStep + BandPop.duration)) < 0.0001)
        #expect(abs(BandPop.settled(after: 0) - BandPop.duration) < 0.0001, "nothing still takes one curve")
    }

    /// ⚠️ **THE WHOLE THING HAS TO BE OVER BEFORE A SECOND TAP IS LIKELY.** A
    /// row that is still arriving when the author has already chosen the next
    /// category reads as lag, whatever it is doing.
    @Test func aFullRowIsSettledInUnderTwoThirdsOfASecond() {
        #expect(BandPop.settled(after: 12) < 0.6, "got \(BandPop.settled(after: 12))")
    }

    @Test func theCollapsedScaleIsATravelTheEyeSeesAndTheCaptionSurvives() {
        #expect(BandPop.collapsedScale < 0.9, "too little travel to read as arriving")
        #expect(BandPop.collapsedScale > 0.6, "a card this small reads as a different, smaller control")
        #expect(BandPop.collapsedTransform.a == BandPop.collapsedScale)
        #expect(BandPop.collapsedTransform.d == BandPop.collapsedScale, "scaled on one axis only")
    }
}

/// The ruler's sweep: out from the needle, and everything whole at the end.
struct RulerRevealTests {
    private let width: CGFloat = 200

    @Test func nothingIsDrawnBeforeTheSweepStarts() {
        for x in stride(from: CGFloat(0), through: width, by: 25) {
            #expect(BandPop.landed(x, reveal: 0, width: width) == 0, "at \(x)")
        }
    }

    @Test func everythingIsWholeOnceItHasFinished() {
        for x in stride(from: CGFloat(0), through: width, by: 25) {
            #expect(BandPop.landed(x, reveal: 1, width: width) == 1, "at \(x)")
        }
    }

    /// ⚠️ **THE NEEDLE FIRST.** It is where the author is reading; a sweep
    /// arriving from one end would pass the needle rather than come out of it.
    @Test func theTicksUnderTheNeedleAreAheadOfTheOnesAtTheEnds() {
        let middle = BandPop.landed(width / 2, reveal: 0.5, width: width)
        let end = BandPop.landed(width, reveal: 0.5, width: width)

        #expect(middle > end, "middle \(middle), end \(end)")
        #expect(end >= 0, "a tick cannot be drawn backwards: \(end)")
    }

    /// ⚠️ **AND THE ENDS ARE MOVING BEFORE THE MIDDLE IS DONE**, or the sweep
    /// takes twice the curve it is given.
    /// ⚠️ **AND THE WINDOW WHERE BOTH ARE MOVING IS WHAT MAKES IT A SWEEP.**
    /// Measured: the middle is whole at a reveal of 0.55 and the ends start at
    /// 0.45, so there is a stretch where the strip is growing at both. Without
    /// it the ends would only begin once the middle had finished, and the sweep
    /// would need twice the curve it is given.
    @Test func thereIsAMomentWhenTheMiddleAndTheEndsAreBothTravelling() {
        let middle = BandPop.landed(width / 2, reveal: 0.5, width: width)
        let end = BandPop.landed(width, reveal: 0.5, width: width)

        #expect(middle > 0 && middle < 1, "the middle is not travelling: \(middle)")
        #expect(end > 0 && end < 1, "the ends are not travelling: \(end)")
    }

    /// A strip with no width answers rather than dividing by zero.
    @Test func aStripWithNoWidthIsNotADivisionByZero() {
        let landed = BandPop.landed(0, reveal: 0.5, width: 0)
        #expect(landed >= 0 && landed <= 1, "got \(landed)")
    }

    @Test func theSweepIsSymmetricAboutTheNeedle() {
        let left = BandPop.landed(width * 0.25, reveal: 0.7, width: width)
        let right = BandPop.landed(width * 0.75, reveal: 0.7, width: width)
        #expect(abs(left - right) < 0.0001, "left \(left), right \(right)")
    }
}
