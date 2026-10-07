import Testing
@testable import MediaPlayback

/// #599: the tolerant assertions still fail when the property is broken —
/// shown on purpose-built samples, since the code under test is fine.
@MainActor
struct TimingToleranceTests {
    /// Frame leads: a healthy run with one stalled turn passes; a companion
    /// prepared in the same turn it is shown (every lead ~0) fails, and so
    /// does a run where a third of the frames come in late.
    @Test func leadsTolerateOneStallButNotAPresentWithoutLead() {
        let healthy = Array(repeating: 0.012, count: 30)
        #expect(TimingTolerance.mostlyAbove(healthy, 0.004))
        var oneStall = healthy
        oneStall[7] = 0.0003 // the CI reading on #587
        #expect(TimingTolerance.mostlyAbove(oneStall, 0.004), "one stalled turn is scheduling")
        let sameTurn = Array(repeating: 0.0002, count: 30)
        #expect(!TimingTolerance.mostlyAbove(sameTurn, 0.004), "prepared in the turn it shows: broken")
        var lateThird = healthy
        for index in stride(from: 0, to: 30, by: 3) { lateThird[index] = 0.001 }
        #expect(!TimingTolerance.mostlyAbove(lateThird, 0.004), "a third late is the code, not the runner")
        #expect(!TimingTolerance.mostlyAbove([], 0.004), "no samples prove nothing")
    }

    /// Loop samples: one reading 14 ms past the bound passes; a loop that
    /// overshoots by a whole frame on each of its wraps fails, and so does
    /// one wild sample past the hard limit.
    @Test func loopsTolerateOneLateReadingButNotARepeatedOvershoot() {
        let bound = 1.5 + 1.0 / 30 + 0.01
        let hard = 1.5 + 0.1
        var inside = stride(from: 0.5, through: 1.5, by: 0.01).map { $0 }
        #expect(TimingTolerance.withinBoundButOne(inside, bound, hardLimit: hard))
        inside.append(1.5475) // the CI reading on #587
        #expect(TimingTolerance.withinBoundButOne(inside, bound, hardLimit: hard), "one late reading")
        let overshootEachWrap = inside + [1.56, 1.57, 1.56]
        #expect(!TimingTolerance.withinBoundButOne(overshootEachWrap, bound, hardLimit: hard),
                "past the range on every wrap: broken")
        #expect(!TimingTolerance.withinBoundButOne([0.6, 1.0, 1.9], bound, hardLimit: hard), "a wild overshoot")
    }

    /// A look budget is spent by polls, not by time: a condition that never
    /// holds fails after its looks; one that holds stops at once.
    @Test func aLookBudgetCountsPolls() async throws {
        var polls = 0
        let never = try await TimingTolerance.settle(looks: 5, step: .milliseconds(1)) {
            polls += 1
            return false
        }
        #expect(!never)
        #expect(polls == 6, "five looks and the last word")
        let soon = try await TimingTolerance.firstAnswer(looks: 5, step: .milliseconds(1)) { 42 }
        #expect(soon == 42)
    }
}
