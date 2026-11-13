import Testing

/// Runs a suite while no other suite carrying this trait runs.
///
/// ⚠️ **`ToastClock.current` AND `ToastView.pendingUndo` ARE PROCESS-WIDE.**
/// Swift Testing runs suites side by side in one process, and `.serialized`
/// only orders a suite's own tests. A toast takes `ToastClock.current` when
/// its countdown starts. So a toast made by `ToastFullMessageTests` could start
/// on another suite's manual clock, which that suite then advanced: the toast
/// left, its tap was ignored, and `aCutToastsTapOpensTheSheetNotTheAction`
/// found "no sheet". That happened on develop's backstop (run 43431833823)
/// and in local full runs, never with the suite alone.
///
/// ⚠️ **A NEW SUITE THAT SETS `ToastClock.current` OR UNDOES A TOAST CARRIES
/// `.ownsToastClock`.** Suites without it still run in parallel with
/// everything.
///
/// A suite trait, taken once around the whole suite and not re-entrant: a
/// suite nested inside another one that carries it must not carry it too.
struct ToastClockAccess: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ToastClockLock.shared.run(function)
    }
}

extension Trait where Self == ToastClockAccess {
    /// See `ToastClockAccess`.
    static var ownsToastClock: Self { Self() }
}

/// A first-come, first-served async lock.
actor ToastClockLock {
    static let shared = ToastClockLock()

    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

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
    }

    private func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
