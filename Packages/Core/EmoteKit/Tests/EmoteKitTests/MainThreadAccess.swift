import Testing

/// Keeps every other suite of this target off the main thread while a suite
/// MEASURES the main thread.
///
/// ⚠️ **`MainThreadBusyMeter` CANNOT TELL WHOSE TURN IT IS TIMING.** Swift
/// Testing runs suites side by side in one process, and most suites here are
/// `@MainActor`. While `EmoteBakeCostTests` timed a cold bake, `EmoteEngineTests`
/// (two to three minutes of bakes on a CI runner), the poster, label and strip
/// suites were running their own turns on the same main thread, and the meter
/// booked every one of them to the bake: 0.9 to 12.6 s "busy" against a bound
/// of ~0.7-1.1 s. That was 11 of the 12 red EmoteKit lanes in the 100 CI runs
/// up to 2026-10-01, the bake itself unchanged — even a green run timed a
/// 500 ms idle sleep at 5.3 s of wall clock. Subtracting an idle sample taken
/// beforehand cannot help: the neighbours' load is not steady.
///
/// So every suite here SHARES the main thread (`.sharesMainThread`) and runs
/// beside the others exactly as before, and a suite that measures it takes it
/// EXCLUSIVELY (`.measuresMainThread`) and runs alone. A measurer waiting for
/// its turn holds back new sharers, so it cannot starve.
///
/// ⚠️ **A NEW SUITE IN THIS TARGET MUST CARRY `.sharesMainThread`** — one
/// without it can run in the middle of a measurement. Like `.serialized`, it is
/// a suite trait taken once around the whole suite; it is not re-entrant, so a
/// nested suite must not carry it again.
struct MainThreadAccess: SuiteTrait, TestScoping {
    let exclusive: Bool

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await MainThreadLock.shared.run(exclusive: exclusive, function)
    }
}

extension Trait where Self == MainThreadAccess {
    /// Runs beside every other sharing suite. See `MainThreadAccess`.
    static var sharesMainThread: Self { Self(exclusive: false) }
    /// Runs alone. See `MainThreadAccess`.
    static var measuresMainThread: Self { Self(exclusive: true) }
}

/// A readers-writer async lock that prefers the writer.
actor MainThreadLock {
    static let shared = MainThreadLock()

    private var sharers = 0
    private var measuring = false
    private var waitingToShare: [CheckedContinuation<Void, Never>] = []
    private var waitingToMeasure: [CheckedContinuation<Void, Never>] = []

    func run(exclusive: Bool, _ body: @Sendable () async throws -> Void) async throws {
        if exclusive { await acquireExclusive() } else { await acquireShared() }
        defer {
            if exclusive { releaseExclusive() } else { releaseShared() }
        }
        try await body()
    }

    // A waiter is resumed with the lock ALREADY counted for it, so nothing can
    // slip in between its resumption and its first step.

    private func acquireShared() async {
        if measuring || !waitingToMeasure.isEmpty {
            await withCheckedContinuation { waitingToShare.append($0) }
        } else {
            sharers += 1
        }
    }

    private func releaseShared() {
        sharers -= 1
        if sharers == 0, !waitingToMeasure.isEmpty {
            measuring = true
            waitingToMeasure.removeFirst().resume()
        }
    }

    private func acquireExclusive() async {
        if measuring || sharers > 0 {
            await withCheckedContinuation { waitingToMeasure.append($0) }
        } else {
            measuring = true
        }
    }

    private func releaseExclusive() {
        if !waitingToMeasure.isEmpty {
            waitingToMeasure.removeFirst().resume()
            return
        }
        measuring = false
        sharers += waitingToShare.count
        let resumed = waitingToShare
        waitingToShare.removeAll()
        resumed.forEach { $0.resume() }
    }
}
