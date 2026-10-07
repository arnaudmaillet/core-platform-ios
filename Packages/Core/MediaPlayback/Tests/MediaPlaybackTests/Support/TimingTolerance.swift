import Foundation

/// Real-time assertions that a hosted CI runner cannot fail by scheduling
/// alone (#599), while a real regression still does.
///
/// ⚠️ **WHY.** These suites measure time itself — a frame's lead over its
/// display, a loop's furthest sample, frames produced while a clip plays —
/// with margins of a few milliseconds. A runner that deschedules the test
/// process (or the decoder) for a few ms, or for seconds, broke them in
/// rotation on PRs that never touched the code: VideoFrameCompanionTests'
/// shortest lead at 0.3 ms, a loop sampled 14 ms past its bound, a reader's
/// wall-clock budget burnt while the process was not running (a 3 s sample
/// that took 77 s). Every suite here is already `.serialized` and
/// `.exclusiveMediaWork`; the starvation is the machine's.
///
/// Two remedies, as EmoteKit (#556) and Profile (#528) did for theirs:
/// - **look budgets** instead of wall-clock deadlines: a budget counts the
///   test's own polls, so time the process spends descheduled costs nothing;
/// - **robust statistics** instead of the worst sample: one late sample is
///   scheduling; a property broken by the code breaks most of them.
enum TimingTolerance {
    /// Polls `condition` up to `looks` times, sleeping `step` between looks.
    /// Returns whether it held. A descheduled process spends no looks.
    /// Runs in the CALLER's isolation (`#isolation`): the suites here are main-
    /// actor and nonisolated alike, and their conditions read non-Sendable state.
    static func settle(
        looks: Int, step: Duration = .milliseconds(5),
        isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
    ) async throws -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try await Task.sleep(for: step)
        }
        return condition()
    }

    /// Polls `answer` up to `looks` times; the first non-nil answer.
    static func firstAnswer<T>(
        looks: Int, step: Duration = .milliseconds(5),
        isolation: isolated (any Actor)? = #isolation, _ answer: () -> T?
    ) async throws -> T? {
        for _ in 0..<looks {
            if let value = answer() { return value }
            try await Task.sleep(for: step)
        }
        return answer()
    }

    /// Whether `samples` clear `bound` as a property of the code, not of one
    /// lucky or unlucky turn: the median does, and at most `missFraction` of
    /// them (rounded up, at least one) fall at or below it.
    ///
    /// A companion prepared in the same turn it is shown leads by ~0 on
    /// EVERY frame: the median fails. A runner that stalls the main thread
    /// once folds one prepare into its present: one miss, tolerated.
    static func mostlyAbove(_ samples: [Double], _ bound: Double, missFraction: Double = 0.1) -> Bool {
        guard !samples.isEmpty else { return false }
        let sorted = samples.sorted()
        guard sorted[sorted.count / 2] > bound else { return false }
        let misses = sorted.filter { $0 <= bound }.count
        let allowed = max(1, Int((Double(samples.count) * missFraction).rounded(.up)))
        return misses <= allowed
    }

    /// Whether `samples` stay within `bound` but for at most one late reading,
    /// which itself stays under `hardLimit`.
    ///
    /// A loop that overshoots its range on every wrap puts several samples
    /// past the bound (one per wrap at least): it fails. One sample read late
    /// by a starved sampler, a few ms past: tolerated. A wild overshoot past
    /// `hardLimit` fails even once.
    static func withinBoundButOne(_ samples: [Double], _ bound: Double, hardLimit: Double) -> Bool {
        let over = samples.filter { $0 > bound }
        return over.count <= 1 && over.allSatisfy { $0 <= hardLimit }
    }
}
