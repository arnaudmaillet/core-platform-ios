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

    /// A loop's late reading may be up to a period late — the CI reading on
    /// #649 was 1.875 s in a 0.5…1.5 s loop — while a loop that overshoots on
    /// every wrap, never wraps, or runs on past a period still fails.
    @Test func aLoopToleratesOneReadingUpToAPeriodLate() {
        let loop = 0.5...1.5
        let frame = 1.0 / 30
        let wraps = (0..<3).flatMap { _ in stride(from: 0.5, through: 1.5, by: 0.01).map { $0 } }
        #expect(TimingTolerance.withinLoopButOne(wraps, loop: loop, frame: frame))
        #expect(TimingTolerance.withinLoopButOne(wraps + [1.875] + wraps, loop: loop, frame: frame),
                "one starved reading, the loop wrapping after it")
        #expect(!TimingTolerance.withinLoopButOne(wraps + [1.56] + wraps + [1.57] + wraps + [1.56], loop: loop, frame: frame),
                "past the end on every wrap: broken")
        #expect(!TimingTolerance.withinLoopButOne(wraps + [1.6, 1.7, 1.8, 1.9], loop: loop, frame: frame),
                "it never wrapped: broken")
        #expect(!TimingTolerance.withinLoopButOne(wraps + [2.6], loop: loop, frame: frame),
                "more than a period past the end: it ran on into the item")
    }

    /// A look budget is spent by polls, not by time: a condition that never
    /// holds fails after its looks; one that holds stops at once.
    /// A restart's small step back adds no film; the end wrapping to the
    /// start adds the rest of the loop.
    @Test func aSmallStepBackIsNotAWrap() {
        #expect(abs(TimingTolerance.filmAdvanced(from: 1.0, to: 1.2, period: 4) - 0.2) < 1e-9)
        #expect(TimingTolerance.filmAdvanced(from: 1.2, to: 1.17, period: 4) == 0, "a restart counted as a loop")
        let wrapped = TimingTolerance.filmAdvanced(from: 3.9, to: 0.1, period: 4)
        #expect(abs(wrapped - 0.2) < 1e-9, "the end wrapping to the start: \(wrapped)")
    }

    /// The scrub case: resumed at 2.25 s on a 3 s loop. Played on, it is
    /// where the elapsed time says, wrapped or not; dragged back to where the
    /// scrub started (0.1 s), it is not — unless a whole period went by.
    @Test func aLoopReadingIsJudgedAgainstTheElapsedTime() {
        // 0.3 s later: 2.55 s.
        #expect(TimingTolerance.isOnLoop(2.55, start: 2.25, elapsed: 0.3...0.35, period: 3, slack: 0.2))
        // A starved 2.4 s: wrapped to 1.65 s, and still right.
        #expect(TimingTolerance.isOnLoop(1.65, start: 2.25, elapsed: 2.38...2.42, period: 3, slack: 0.2))
        // Dragged back to the scrub's start and played 0.3 s: 0.4 s. Wrong.
        #expect(!TimingTolerance.isOnLoop(0.4, start: 2.25, elapsed: 0.3...0.35, period: 3, slack: 0.2))
        // ...and still wrong after a starved 2.4 s (0.1 + 2.4 = 2.5 s).
        #expect(!TimingTolerance.isOnLoop(2.5, start: 2.25, elapsed: 2.38...2.42, period: 3, slack: 0.2))
    }

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
