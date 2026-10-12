import Foundation
import Synchronization

/// The lookahead's own counters (#900, #970), which no cache can see by
/// itself: whether what the viewer reached was already there, whether the
/// next full-screen video started from its preloaded first range, how long a
/// video took to its first frame, and what speculative work cost on cellular.
///
/// The consumers report: the image pipeline (#894), the video cache (#895)
/// and the feed lookahead (#970). The `CacheCoordinator` owns one
/// (`prefetchCounters`) and the `-cache-audit` instrument logs it. The waste
/// ratio is not here: every cache counts it itself
/// (`CacheStatistics.speculative`).
///
/// Kept in Release, like `CacheStatistics`: each report is one addition under
/// a lock, and the call sites live in production code.
public final class CachePrefetchCounters: Sendable {
    /// What an item found when it reached the screen.
    public enum Arrival: String, Sendable, CaseIterable {
        /// Already in a cache: a prefetch (or an earlier visit) paid off.
        case ready
        /// A prefetch was in flight: joined, so part of the wait was saved.
        case inFlight
        /// Nothing: fetched from scratch.
        case missed
    }

    /// Arrivals of one kind of content.
    public struct Arrivals: Sendable, Equatable {
        public var ready = 0
        public var inFlight = 0
        public var missed = 0

        public init() {}

        public var total: Int { ready + inFlight + missed }

        /// Items found ready over every item that arrived, `nil` before any.
        public var hitRate: Double? {
            total > 0 ? Double(ready) / Double(total) : nil
        }
    }

    /// Times to first frame, in seconds: count, maximum and the recent
    /// window's percentiles.
    public struct FirstFrameTimes: Sendable, Equatable {
        public var count = 0
        public var maximum: Double = 0
        /// The last `CachePrefetchCounters.firstFrameWindow` samples, oldest first.
        public var recent: [Double] = []

        public init() {}

        /// The `fraction` percentile (0...1) of the recent window, `nil` if empty.
        public func percentile(_ fraction: Double) -> Double? {
            guard !recent.isEmpty else { return nil }
            let sorted = recent.sorted()
            let rank = Int((Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
            return sorted[rank]
        }
    }

    public struct Snapshot: Sendable, Equatable {
        /// Per category: images, videos.
        public var arrivals: [CacheCategory: Arrivals] = [:]
        /// The next full-screen video started on its preloaded first range.
        public var nextVideoFirstRangeHits = 0
        public var nextVideoFirstRangeMisses = 0
        public var firstFrame = FirstFrameTimes()
        /// Bytes fetched over the network per fill priority, on cellular (or
        /// any expensive path) and elsewhere.
        public var cellularBytes: [CacheFillPriority: Int] = [:]
        public var otherBytes: [CacheFillPriority: Int] = [:]

        public init() {}

        /// Next-video starts that found their first range, `nil` before any.
        public var nextVideoFirstRangeHitRate: Double? {
            let total = nextVideoFirstRangeHits + nextVideoFirstRangeMisses
            return total > 0 ? Double(nextVideoFirstRangeHits) / Double(total) : nil
        }

        /// P2 (speculative) bytes fetched on cellular: what Low Data users
        /// and "use less cellular data" (#899) care about.
        public var speculativeCellularBytes: Int { cellularBytes[.speculative, default: 0] }
    }

    /// How many recent first-frame times the percentiles cover.
    public static let firstFrameWindow = 256

    private let state = Mutex(Snapshot())

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    /// An item of `category` reached the screen and found `arrival`. Report
    /// it once per item per arrival (a cell configured, a page settled), not
    /// once per lookup.
    public func recordArrival(_ category: CacheCategory, _ arrival: Arrival) {
        state.withLock { snapshot in
            var arrivals = snapshot.arrivals[category, default: Arrivals()]
            switch arrival {
            case .ready: arrivals.ready += 1
            case .inFlight: arrivals.inFlight += 1
            case .missed: arrivals.missed += 1
            }
            snapshot.arrivals[category] = arrivals
        }
    }

    /// The next full-screen video started playing: `hit` when its first range
    /// was already on disk or in memory (#895).
    public func recordNextVideoStart(firstRangeHit hit: Bool) {
        state.withLock { snapshot in
            if hit {
                snapshot.nextVideoFirstRangeHits += 1
            } else {
                snapshot.nextVideoFirstRangeMisses += 1
            }
        }
    }

    /// A video showed its first frame `seconds` after it was asked to play.
    public func recordTimeToFirstFrame(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        state.withLock { snapshot in
            snapshot.firstFrame.count += 1
            snapshot.firstFrame.maximum = max(snapshot.firstFrame.maximum, seconds)
            snapshot.firstFrame.recent.append(seconds)
            if snapshot.firstFrame.recent.count > Self.firstFrameWindow {
                snapshot.firstFrame.recent.removeFirst(snapshot.firstFrame.recent.count - Self.firstFrameWindow)
            }
        }
    }

    /// A fill at `priority` fetched `bytes` over the network. `cellular`: the
    /// path was cellular or expensive at the time; the coordinator's
    /// `recordTransfer(bytes:priority:)` reads it from its conditions.
    public func recordTransfer(bytes: Int, priority: CacheFillPriority, cellular: Bool) {
        guard bytes > 0 else { return }
        state.withLock { snapshot in
            if cellular {
                snapshot.cellularBytes[priority, default: 0] += bytes
            } else {
                snapshot.otherBytes[priority, default: 0] += bytes
            }
        }
    }

    public func reset() {
        state.withLock { $0 = Snapshot() }
    }
}
