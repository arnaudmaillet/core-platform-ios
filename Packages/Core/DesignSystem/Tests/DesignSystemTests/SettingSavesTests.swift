import Testing
@testable import DesignSystem

/// Settings saved while the viewer goes on (#1775): a change shows at once,
/// saves in turn, and goes back on failure before the screen says why.
@MainActor
struct SettingSavesTests {
    /// A gate a save waits at until the test opens it.
    @MainActor private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var arrivals = 0

        func wait() async {
            arrivals += 1
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private struct Refused: Error {}

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test func aChangeShowsAtOnceAndLeavesOnceSaved() async {
        let saves = SettingSaves<String, Bool>()
        var redraws = 0
        saves.onChange = { redraws += 1 }
        let gate = Gate()

        let asked = saves.save(true, for: "ghost", { _ in await gate.wait() }, failed: { _ in })
        #expect(asked)
        #expect(saves.value(for: "ghost") == true)
        #expect(saves.isSaving("ghost"))
        #expect(!saves.isIdle)
        #expect(redraws == 1)

        await until { gate.arrivals == 1 }
        gate.open()
        await saves.debugSettle()
        #expect(saves.value(for: "ghost") == nil)
        #expect(saves.isIdle)
        #expect(redraws == 2)
    }

    /// One after another: the second starts once the first is done, so it
    /// starts from the record the first left.
    @Test func savesRunInTurn() async {
        let saves = SettingSaves<String, Bool>()
        let gate = Gate()
        var order: [String] = []

        saves.save(true, for: "a", { _ in order.append("a starts"); await gate.wait(); order.append("a ends") }, failed: { _ in })
        saves.save(false, for: "b", { _ in order.append("b starts") }, failed: { _ in })
        #expect(saves.isSaving("a") && saves.isSaving("b"), "the second row did not show its change")

        await until { gate.arrivals == 1 }
        #expect(order == ["a starts"])
        gate.open()
        await saves.debugSettle()
        #expect(order == ["a starts", "a ends", "b starts"])
    }

    /// The row on its way waits: the same key again sends nothing.
    @Test func theSameSettingAgainWaits() async {
        let saves = SettingSaves<String, Bool>()
        let gate = Gate()
        var sent = 0
        saves.save(true, for: "a", { _ in sent += 1; await gate.wait() }, failed: { _ in })
        let again = saves.save(false, for: "a", { _ in sent += 1 }, failed: { _ in })
        #expect(!again)
        #expect(saves.value(for: "a") == true)

        await until { gate.arrivals == 1 }
        gate.open()
        await saves.debugSettle()
        #expect(sent == 1)
    }

    /// A failure lets the change go first — the row is back to the record
    /// when the screen says why.
    @Test func aFailureLetsTheChangeGoBeforeItIsTold() async {
        let saves = SettingSaves<String, Bool>()
        var savingWhenTold: Bool?
        saves.save(true, for: "a", { _ in throw Refused() }, failed: { [saves] error in
            #expect(error is Refused)
            savingWhenTold = saves.isSaving("a")
        })
        await saves.debugSettle()
        #expect(savingWhenTold == false)
        #expect(saves.isIdle)
    }
}
