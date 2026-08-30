import Foundation

#if DEBUG
/// Live-instance census for the hero machinery — one balanced counter per
/// transition object, incremented at `init` and decremented at `deinit`.
///
/// ⚠️ Why counting, not weak references: the objects this watches (animators,
/// interruptors, flight cards) are supposed to be GONE a beat after every
/// settle, and "gone" is only observable as an absence. A weak ref can prove
/// one instance died; a counter proves NO instance survived — across a soak of
/// hundreds of flights, which is where the leak that motivates this actually
/// shows. The in-app hero audit publishes these counts at every transition
/// settle, and the UI suites assert they read zero.
///
/// Lock-protected and nonisolated on purpose: `deinit` runs wherever the last
/// release happens and cannot hop to the main actor.
public enum ZoomDebugCensus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    public static func increment(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    public static func decrement(_ key: String) {
        lock.lock()
        counts[key, default: 0] -= 1
        lock.unlock()
    }

    public static func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }

    /// Every key with a non-zero count — the audit's "who is still alive"
    /// line. Empty is the healthy answer at rest.
    public static func liveEntries() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts.filter { $0.value != 0 }
    }

    /// Census keys, shared so the audit and the counted types cannot drift.
    public enum Key {
        public static let controller = "zoom.controller"
        public static let animator = "zoom.animator"
        public static let interruptor = "zoom.interruptor"
        public static let grabDriver = "zoom.grabDriver"
        public static let liveMediaRetry = "zoom.liveMediaRetry"
        public static let flightCard = "zoom.flightCard"
        public static let pinCard = "zoom.pinCard"
    }
}
#endif
