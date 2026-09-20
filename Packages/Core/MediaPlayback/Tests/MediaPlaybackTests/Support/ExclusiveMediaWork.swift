import Testing

/// Runs a suite while no other suite carrying this trait runs.
///
/// ⚠️ **THE SUITES THAT FAILED WERE NEVER WRONG — THEY WERE STARVED.** Swift
/// Testing runs suites side by side in one process. The exports and the
/// composed reads (`VideoExporterTests`, the transition suites,
/// `SoundtrackCompositionTests`) fill a CI runner's few cores and its decoder
/// for minutes at a time, and the suites that measure REAL TIME beside them
/// miss their deadlines: `ComposedFrameReaderTests` read no frame at all in its
/// ten-second budget, `RehearsalLoopTests` played past its range,
/// `CompositorFinishTests` showed a stale frame. Each passed alone, every time.
/// Longer timeouts only move the line; keeping the two kinds apart removes the
/// cause. Suites without the trait still run in parallel with everything.
///
/// ⚠️ **A SUITE TRAIT, NOT RECURSIVE — THE LOCK IS TAKEN ONCE, AROUND THE
/// WHOLE SUITE.** It is not re-entrant: a suite nested inside another that
/// carries the trait must not carry it too, or it waits for itself.
struct ExclusiveMediaWork: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await MediaWorkLock.shared.run(function)
    }
}

extension Trait where Self == ExclusiveMediaWork {
    /// See `ExclusiveMediaWork`.
    static var exclusiveMediaWork: Self { Self() }
}

/// A first-come, first-served async lock.
actor MediaWorkLock {
    static let shared = MediaWorkLock()

    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    /// How many runs have held it at once, at most — for the trait's own test.
    private(set) var mostAtOnce = 0
    private var holding = 0
    #endif

    func run(_ body: @Sendable () async throws -> Void) async throws {
        await acquire()
        do {
            try await body()
        } catch {
            release()
            throw error
        }
        release()
    }

    private func acquire() async {
        if isHeld {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isHeld = true
        }
        #if DEBUG
        holding += 1
        mostAtOnce = max(mostAtOnce, holding)
        #endif
    }

    private func release() {
        #if DEBUG
        holding -= 1
        #endif
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
