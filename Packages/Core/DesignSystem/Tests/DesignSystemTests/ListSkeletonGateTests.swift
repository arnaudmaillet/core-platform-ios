import Testing
@testable import DesignSystem

/// A list section's loading on the kit's timing (#1770).
@MainActor
struct ListSkeletonGateTests {
    @Test func nothingThenBonesThenTakingLonger() {
        let time = ManualLoadingClock()
        let gate = ListSkeletonGate(clock: time.clock)
        var changes = 0
        gate.onChange = { changes += 1 }
        #expect(gate.loading() == .nothing)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(changes == 1)
        #expect(gate.loading() == .bones)
        time.advance(LoadingTiming.takingLonger)
        #expect(gate.loading() == .takingLonger)
        #expect(changes >= 2)

        // Try Again: the wait starts over.
        gate.retry()
        #expect(gate.loading() == .nothing)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(gate.loading() == .bones)
    }

    @Test func anAnswerAfterTheBonesWaitsOutTheirMinimum() {
        let time = ManualLoadingClock()
        let gate = ListSkeletonGate(clock: time.clock)
        _ = gate.loading()
        time.advance(LoadingTiming.skeletonDelay)
        var applied = 0
        gate.landed { applied += 1 }
        #expect(applied == 0, "the answer cut the bones short")
        gate.landed { applied += 10 }
        time.advance(LoadingTiming.minimum)
        #expect(applied == 10, "the newest answer lands, once")
    }

    @Test func aQuickAnswerLandsAtOnce() {
        let time = ManualLoadingClock()
        let gate = ListSkeletonGate(clock: time.clock)
        _ = gate.loading()
        var applied = false
        gate.landed { applied = true }
        #expect(applied)
        time.advance(1)
        #expect(gate.loading() == .nothing, "a new load waits its delay again")
    }
}
