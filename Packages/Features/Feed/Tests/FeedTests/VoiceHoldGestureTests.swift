import CoreGraphics
import Testing
@testable import Feed

/// The hold's thresholds (#2102): 200 ms, 100 pt to cancel, 55 % on
/// release, 20 + 80 pt to lock, no lock past 30 % of the way to cancel.
struct VoiceHoldGestureTests {
    typealias Gesture = VoiceHoldGesture

    @Test func aQuickLiftIsATapAndRecordsNothing() {
        #expect(Gesture.release(heldFor: 0.15, leading: 0) == .tap)
        #expect(Gesture.release(heldFor: 0.25, leading: 0) == .send)
    }

    @Test func aHundredPointsTowardTheLeadingEdgeCancels() {
        #expect(Gesture.outcome(leading: 99, up: 0) == .holding(cancel: 0.99, lock: 0))
        #expect(Gesture.outcome(leading: 100, up: 0) == .cancelled)
    }

    @Test func releasedPastFiftyFivePercentCancelsToo() {
        #expect(Gesture.release(heldFor: 2, leading: 54) == .send)
        #expect(Gesture.release(heldFor: 2, leading: 55) == .cancel)
    }

    @Test func theLockWaitsTwentyPointsThenFillsOverEighty() {
        #expect(Gesture.outcome(leading: 0, up: 20) == .holding(cancel: 0, lock: 0))
        #expect(Gesture.outcome(leading: 0, up: 60) == .holding(cancel: 0, lock: 0.5))
        #expect(Gesture.outcome(leading: 0, up: 100) == .locked)
    }

    @Test func noLockPastThirtyPercentOfTheWayToCancel() {
        #expect(Gesture.outcome(leading: 31, up: 120) == .holding(cancel: 0.31, lock: 0))
        #expect(Gesture.outcome(leading: 29, up: 120) == .locked)
    }
}
