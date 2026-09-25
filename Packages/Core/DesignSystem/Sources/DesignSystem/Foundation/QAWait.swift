#if DEBUG
import Foundation

/// The DEBUG launch-argument hooks' one way to wait: for the STATE they need,
/// never for a guessed number of seconds, and never silently.
///
/// ⚠️ **WHY THIS EXISTS.** The QA hooks drove the app on fixed delays — "the
/// list has loaded by 2 s", "the flight has landed by 2.5 s" — and then
/// `guard … else { return }` when it had not. On a slow simulator, a cold run
/// or under `-mock-latency`, the hook did NOTHING and printed nothing, and a
/// run that exercised nothing read exactly like a run that passed. A hook
/// built on this either acts on the state it asked for or prints
/// `[qa] GAVE UP <label>` — the line to grep for before trusting a run.
@MainActor
public enum QAWait {
    /// Runs `action` as soon as `condition` holds, polling every `interval`;
    /// gives up after `timeout` with a `[qa] GAVE UP` line and never runs it.
    ///
    /// Checked once synchronously first, so a hook whose state is already
    /// there acts in the same turn it would have before.
    public static func until(
        _ label: String,
        timeout: TimeInterval = 20,
        interval: TimeInterval = 0.1,
        _ condition: @escaping @MainActor () -> Bool,
        then action: @escaping @MainActor () -> Void
    ) {
        attempt(label, since: Date(), timeout: timeout, interval: interval, condition, then: action)
    }

    private static func attempt(
        _ label: String, since start: Date, timeout: TimeInterval, interval: TimeInterval,
        _ condition: @escaping @MainActor () -> Bool,
        then action: @escaping @MainActor () -> Void
    ) {
        if condition() {
            action()
            return
        }
        let waited = Date().timeIntervalSince(start)
        guard waited < timeout else {
            fail(label, String(format: "still not ready after %.1fs", waited))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                attempt(label, since: start, timeout: timeout, interval: interval, condition, then: action)
            }
        }
    }

    /// A hook that could not do what it was asked. Always printed, so a run
    /// that skipped its subject says so.
    public static func fail(_ label: String, _ reason: String) {
        print("[qa] GAVE UP \(label): \(reason)")
    }
}
#endif
