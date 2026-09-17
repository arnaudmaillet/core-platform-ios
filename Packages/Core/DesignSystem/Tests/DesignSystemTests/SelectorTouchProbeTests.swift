import Testing
import UIKit
@testable import DesignSystem

/// One probe, several watched strips.
///
/// ⚠️ **THE TALLY IS THE SUBJECT, AND THE GESTURE IS NOT TESTABLE.**
/// `UIGestureRecognizer.state` is read-only and no test can put a finger on one
/// bar and lift it from another, so the recogniser's three-line mapping from
/// `state` to up-or-down is checked on a device. What is entered here is the
/// exact function the recogniser enters — the counting, which is where the
/// defect was.
@MainActor
struct SelectorTouchProbeTests {
    @Test func oneStripAnnouncesTheTouchAndTheLift() {
        var told: [Bool] = []
        let probe = SelectorTouchProbe { told.append($0) }
        let strip = UIView()

        probe.debugTouch(strip, isDown: true)
        probe.debugTouch(strip, isDown: false)

        #expect(told == [true, false])
    }

    /// ⚠️ **THE DEFECT: A LIFT FROM ONE STRIP WHILE A FINGER IS ON THE OTHER.**
    /// The host suspends the stack's back-swipe for the length of a touch, so a
    /// premature `false` puts a screen-wide pop gesture back underneath a live
    /// drag. With a bare flag this reported `[true, false]` and the drag went on.
    @Test func aLiftFromOneStripIsSilentWhileTheOtherIsStillHeld() {
        var told: [Bool] = []
        let probe = SelectorTouchProbe { told.append($0) }
        let actions = UIView()
        let modes = UIView()

        probe.debugTouch(actions, isDown: true)
        probe.debugTouch(modes, isDown: true)
        probe.debugTouch(actions, isDown: false)

        #expect(told == [true], "the second strip is still held: \(told)")
    }

    @Test func theLastLiftIsTheOneThatAnnounces() {
        var told: [Bool] = []
        let probe = SelectorTouchProbe { told.append($0) }
        let actions = UIView()
        let modes = UIView()

        probe.debugTouch(actions, isDown: true)
        probe.debugTouch(modes, isDown: true)
        probe.debugTouch(actions, isDown: false)
        probe.debugTouch(modes, isDown: false)

        #expect(told == [true, false])
    }

    /// A recogniser reports `.changed` on every sample of a press that travels,
    /// and each one arrives here as another "down".
    @Test func aTouchThatTravelsDoesNotAnnounceAgain() {
        var told: [Bool] = []
        let probe = SelectorTouchProbe { told.append($0) }
        let strip = UIView()

        probe.debugTouch(strip, isDown: true)
        probe.debugTouch(strip, isDown: true)
        probe.debugTouch(strip, isDown: true)

        #expect(told == [true])
    }
}
