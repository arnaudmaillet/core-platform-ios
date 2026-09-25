import Testing
import UIKit
@testable import DesignSystem

/// The QA hooks' wait acts on the state it was given, or says it gave up.
@MainActor
struct QAWaitTests {
    @Test func actsInTheSameTurnWhenTheStateIsAlreadyThere() {
        var ran = false
        QAWait.until("now", { true }) { ran = true }
        #expect(ran)
    }

    @Test func actsOnceTheStateArrives() async throws {
        var ready = false, ran = 0
        QAWait.until("later", interval: 0.02, { ready }) { ran += 1 }
        #expect(ran == 0)
        ready = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(ran == 1, "acted \(ran) times")
    }

    @Test func neverActsAfterGivingUp() async throws {
        var ready = false, ran = false
        QAWait.until("never", timeout: 0.05, interval: 0.02, { ready }) { ran = true }
        try await Task.sleep(for: .milliseconds(150))
        ready = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran, "a hook that gave up still acted")
    }
}
