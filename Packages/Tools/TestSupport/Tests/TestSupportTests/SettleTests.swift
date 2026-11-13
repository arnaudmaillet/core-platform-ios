import Testing
import TestSupport

@MainActor
struct SettleTests {
    /// It returns as soon as the condition holds, having let queued work on
    /// the caller's actor land.
    @Test func itWaitsForWorkOnTheCallersActor() async {
        var done = false
        Task { @MainActor in done = true }
        #expect(await settle { done })
    }

    /// A condition that never holds spends the budget and says so.
    @Test func aConditionThatNeverHoldsReportsFalse() async {
        var looks = 0
        let held = await settle(looks: 5) {
            looks += 1
            return false
        }
        #expect(!held)
        #expect(looks == 6, "every look checks, and once more at the end")
    }

    /// An async condition is awaited.
    @Test func anAsyncConditionIsAwaited() async {
        actor Box { var value = 0; func bump() { value += 1 }; func read() -> Int { value } }
        let box = Box()
        Task { await box.bump() }
        #expect(await settle(until: { await box.read() == 1 }))
    }
}
