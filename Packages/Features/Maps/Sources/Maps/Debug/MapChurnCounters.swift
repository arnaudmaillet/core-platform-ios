#if DEBUG
import Foundation

/// Counts what a region change actually DOES to the annotation set.
///
/// The pan/zoom cost survived every elimination: it is not the animation (the
/// still arm measures marginally worse), and it is not the clustering
/// arithmetic (rebuilding at `-O` moved nothing, though the same loop is 160x
/// faster in isolation). What is left is MapKit's own region work — which
/// nothing here can reach — and population churn, which nothing here could
/// MEASURE. That is what this closes.
///
/// The split that matters is `bound` vs `skipped`. A `configure` call that hits
/// its idempotence guard costs nothing, so counting configure calls would say
/// "hundreds of rebinds per settle" about a path that mostly returns on its
/// first line — the same lie `sheets=N` told when it counted assignment instead
/// of motion.
@MainActor
enum MapChurnCounters {
    /// `reconcileClusters()` entries.
    static var reconciles = 0
    /// Annotations handed to `addAnnotations` — a real view realization each.
    static var added = 0
    /// Annotations that left `displayed` and were handed to the pop-out.
    static var departed = 0
    /// `viewFor` calls, i.e. MapKit asking for a view (dequeue + configure).
    static var viewFor = 0
    /// `configure` calls that passed the idempotence guard and did real work.
    static var bound = 0
    /// `configure` calls that returned at the guard — free.
    static var skipped = 0

    /// Total main-thread microseconds spent inside `reconcileClusters()`.
    ///
    /// The count of reconciles says how often the main thread is interrupted;
    /// only the DURATION says whether that interruption is a dropped frame. A
    /// reconcile is synchronous on the main thread, so every millisecond here
    /// is a millisecond CoreAnimation is not committing.
    static var reconcileMicros = 0
    /// The single worst reconcile in the interval, in microseconds.
    static var reconcileWorstMicros = 0

    static func recordReconcile(micros: Int) {
        reconcileMicros += micros
        reconcileWorstMicros = max(reconcileWorstMicros, micros)
    }

    /// Deltas since the previous read, then rearms. The HUD samples ~1/s, so a
    /// reading is "per second", and the sweep fires a region change every 1.4s.
    static func drain() -> (reconciles: Int, added: Int, departed: Int, viewFor: Int, bound: Int, skipped: Int) {
        defer {
            reconciles = 0; added = 0; departed = 0; viewFor = 0; bound = 0; skipped = 0
            reconcileMicros = 0; reconcileWorstMicros = 0
        }
        return (reconciles, added, departed, viewFor, bound, skipped)
    }
}
#endif
