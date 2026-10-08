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

    /// Whether playhead `samples` stay inside a looping `range` — one frame of
    /// slack past its end — but for at most one late reading, which may be as
    /// late as one whole period of the loop.
    ///
    /// ⚠️ **THE LATE READING'S LIMIT IS THE LOOP'S OWN PERIOD, NOT A FEW
    /// MILLISECONDS** (#599). A starved runner can hold the wrap, or the
    /// sampler, for hundreds of ms: CI read 1.875 s in a 0.5…1.5 s loop, past a
    /// fixed 1.6 s hard limit, with every other sample inside. What a broken
    /// loop does is different and still fails:
    /// - it overshoots on EVERY wrap — several readings past the end;
    /// - it never wraps — every reading after the end is past it;
    /// - it runs on into the item — a reading more than a period past the end.
    static func withinLoopButOne(_ samples: [Double], loop range: ClosedRange<Double>, frame: Double) -> Bool {
        withinBoundButOne(
            samples, range.upperBound + frame + 0.01,
            hardLimit: range.upperBound + (range.upperBound - range.lowerBound)
        )
    }

    /// How much film a looping item played between two playhead readings.
    ///
    /// ⚠️ **A SMALL STEP BACK IS NOT A WRAP** (#599). A composed reader that
    /// fell behind restarts, and the playhead it reports can step back a few
    /// hundredths; reading every step back as a whole loop added a period of
    /// "film" in one look, and the frames read ahead BEFORE the change counted
    /// as played after it (CI: two red frames at 0.033 s and 0.067 s in
    /// `aLiveLookReachesThePlayingFrames`). Only a step back of more than half
    /// the period is the end wrapping to the start; a smaller one adds nothing.
    static func filmAdvanced(from last: Double, to head: Double, period: Double) -> Double {
        if head >= last { return head - last }
        return last - head > period / 2 ? head + period - last : 0
    }

    /// Whether a looping item's `reading` is where playing on from `start`
    /// puts it after some time inside `elapsed`, within `slack`, modulo
    /// `period`.
    ///
    /// ⚠️ **A STARVED SLEEP CAN WRAP THE LOOP** (#599): a "300 ms" sleep that
    /// ran ~2.4 s put a 3 s clip resumed at 2.25 s back at 1.68 s, and
    /// `fraction > 0.6` read that as the scrub being undone. Measured instead
    /// against the wall clock the test actually spent: a clip dragged back to
    /// where a scrub STARTED is still off by the scrub's length, at any
    /// elapsed time short of a whole period.
    static func isOnLoop(
        _ reading: Double, start: Double, elapsed: ClosedRange<Double>, period: Double, slack: Double
    ) -> Bool {
        let low = max(0, elapsed.lowerBound - slack)
        let high = elapsed.upperBound + slack
        // Any elapsed time of a whole period or more puts it anywhere.
        guard high - low < period else { return true }
        var advance = (reading - start).truncatingRemainder(dividingBy: period)
        if advance < 0 { advance += period }
        var candidate = advance
        while candidate <= high {
            if candidate >= low { return true }
            candidate += period
        }
        return false
    }
}
