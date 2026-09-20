import Testing

/// The lock behind `ExclusiveMediaWork`: however many suites ask at once,
/// one runs.
struct ExclusiveMediaWorkTests {
    /// Counts how many bodies are inside at once.
    private actor Inside {
        private(set) var now = 0
        private(set) var most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 }
    }

    @Test func fourSuitesAskingAtOnceRunOneAtATime() async throws {
        let lock = MediaWorkLock()
        let inside = Inside()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await lock.run {
                        await inside.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await inside.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let most = await inside.most
        let left = await inside.now
        #expect(most == 1, "\(most) ran at once")
        #expect(left == 0)
    }

    /// A suite that fails lets the next one in.
    @Test func aFailureReleasesTheLock() async throws {
        struct Failed: Error {}
        let lock = MediaWorkLock()
        await #expect(throws: Failed.self) {
            try await lock.run { throw Failed() }
        }
        // ⚠️ DETACHED AND WATCHED, NOT AWAITED: a lock that stayed held would
        // leave this waiting forever, and a hang is not a red test.
        let after = Inside()
        _ = Task { try await lock.run { await after.enter() } }
        for _ in 0..<200 where await after.most == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ran = await after.most
        #expect(ran == 1, "the lock stayed held after a failure")
    }
}
