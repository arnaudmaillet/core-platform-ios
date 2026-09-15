import Testing
import UIKit
@testable import Upload

/// The straightening dial: its arithmetic first, then the control around it.
struct StraightenDialTests {
    // MARK: - The rule, without a finger

    @Test func draggingTheRulerRightTurnsThePictureBack() {
        let right = StraightenDial.advanced(0, by: 60)
        let left = StraightenDial.advanced(0, by: -60)

        #expect(right < 0, "the tick under the finger travels with it: got \(right)")
        #expect(left > 0, "and the other way: got \(left)")
        #expect(abs(right) == abs(left), "symmetric: \(right) vs \(left)")
    }

    /// ⚠️ **SPELLED IN POINTS, NOT IN UNITS OF THE CONSTANT.** Every other line in
    /// this suite says `pointsPerDegree * n`, which stays true if the constant
    /// changes to 60 and the dial becomes unusable. One assertion has to hold the
    /// actual number, or the feel of the control is pinned nowhere.
    @Test func sixPointsOfTravelIsOneDegree() {
        #expect(StraightenDial.pointsPerDegree == 6, "the whole feel of the dial is this number")
        #expect(StraightenDial.advanced(0, by: -6) == 1)
        #expect(StraightenDial.advanced(10, by: -30) == 15)
        #expect(StraightenDial.span == 45, "and a straightening tool stops at a quarter of a turn")
    }

    @Test func theDialStopsAtFortyFiveEitherWay() {
        #expect(StraightenDial.advanced(44, by: -600) == 45)
        #expect(StraightenDial.advanced(-44, by: 600) == -45)
    }

    /// ⚠️ **THE HALF THAT MAKES A CLAMP USABLE.** A value computed from the
    /// touch-down point goes numb after the clamp: shove 600pt past the end and
    /// the dial ignores the first 600pt of the way back. Advancing from where the
    /// value actually is answers immediately.
    @Test func comingBackFromTheEndAnswersAtOnce() {
        let pinned = StraightenDial.advanced(40, by: -600)
        #expect(pinned == 45, "guard: it must really be pinned at the end")

        let easedBack = StraightenDial.advanced(pinned, by: StraightenDial.pointsPerDegree)

        #expect(easedBack == 44, "one degree back on the first six points: got \(easedBack)")
    }

    /// ⚠️ `MediaCrop.isUntouched` IS AN EXACT `==`: a dial resting at a fifth of
    /// a degree is a picture the renderer turns, resamples and grows, for
    /// something nobody can see.
    @Test func nearlyLevelIsLevel() {
        #expect(StraightenDial.settled(0.3) == 0)
        #expect(StraightenDial.settled(-0.49) == 0)
        #expect(StraightenDial.settled(0.8) == 0.8, "and a real angle is left alone")
    }

    @Test func theDetentsAreEveryFiveDegrees() {
        #expect(StraightenDial.detentIndex(for: 0) == 0)
        #expect(StraightenDial.detentIndex(for: 4.9) == 1)
        #expect(StraightenDial.detentIndex(for: -12) == -2)
    }

    // MARK: - The control

    @MainActor
    private func dial() -> StraightenDialView {
        let dial = StraightenDialView()
        dial.frame = CGRect(x: 0, y: 0, width: 300, height: StraightenDialView.height)
        dial.layoutIfNeeded()
        return dial
    }

    @MainActor
    @Test func turningTheDialSaysSoAndSpellsIt() {
        let dial = dial()
        var announced: [CGFloat] = []
        dial.onTurn = { announced.append($0) }

        dial.debugDrag(by: -StraightenDial.pointsPerDegree * 8)

        #expect(dial.angle == 8, "got \(dial.angle)")
        #expect(announced == [8], "announced once, with the value: \(announced)")
        #expect(dial.debugReading == "8°", "got \(dial.debugReading ?? "nil")")
    }

    @MainActor
    @Test func aDialLeftWhereItWasSaysNothing() {
        let dial = dial()
        var announced: [CGFloat] = []
        dial.onTurn = { announced.append($0) }

        dial.debugDrag(by: 0)

        #expect(announced.isEmpty, "no movement, no word: \(announced)")
    }

    @MainActor
    @Test func lettingGoNearLevelSettlesToExactlyLevel() {
        let dial = dial()
        var settled: [CGFloat] = []
        dial.onSettle = { settled.append($0) }

        dial.debugDrag(by: -StraightenDial.pointsPerDegree * 0.3)
        #expect(dial.angle != 0, "guard: the drag must really have moved it")

        dial.debugEndDrag()

        #expect(dial.angle == 0, "got \(dial.angle)")
        #expect(settled == [0], "and the host is told the settled value: \(settled)")
    }

    @MainActor
    @Test func tappingTheReadingPutsThePictureBackLevel() {
        let dial = dial()
        dial.debugDrag(by: -StraightenDial.pointsPerDegree * 20)
        #expect(dial.angle == 20, "guard: turned first")
        var settled: [CGFloat] = []
        dial.onSettle = { settled.append($0) }

        dial.debugTapReadout()

        #expect(dial.angle == 0)
        #expect(settled == [0], "got \(settled)")
    }

    @MainActor
    @Test func statingAnAngleDoesNotAnnounceIt() {
        let dial = dial()
        var announced: [CGFloat] = []
        dial.onTurn = { announced.append($0) }
        dial.onSettle = { announced.append($0) }

        dial.setAngle(-12)

        #expect(dial.angle == -12, "the value is taken: \(dial.angle)")
        #expect(dial.debugReading == "-12°")
        #expect(announced.isEmpty, "but adopting a stored value is not a choice: \(announced)")
    }
}
