#if DEBUG
import Foundation
import Synchronization

/// `-cache-audit` (#900): what every cache namespace holds and does, so the
/// budgets, tiers and lookahead windows can be tuned on measurements instead
/// of guesses.
///
/// Every `interval` (10 s by default, `-cache-audit-interval <seconds>`) and
/// after each trim the coordinator applies, it writes one block of lines:
///
/// - a header: the trigger, the Settings limit, the disk pressure, the
///   prefetch policy and network, memory and disk totals, and the app's waste
///   ratio;
/// - one line per namespace and medium: bytes against the budget, entries,
///   pinned and per-tier bytes, hits, misses, entries and bytes removed per
///   reason, and what became of its speculative entries;
/// - the lookahead's counters (`CachePrefetchCounters`).
///
/// Lines go to stdout and to `cache-audit.log` in the app's Documents (read
/// it with `xcrun simctl get_app_container <udid> cn.wynn.core-platform-ios
/// data`), which a new run starts afresh. The format is in
/// `dev/CACHE_AUDIT.md`.
///
/// DEBUG only: the counters it reads exist in Release, the instrument does not.
public final class CacheAudit: Sendable {
    public static let argument = "-cache-audit"
    public static let intervalArgument = "-cache-audit-interval"
    public static let defaultInterval: TimeInterval = 10
    public static let logFileName = "cache-audit.log"
    /// Every line starts with it, so a console capture greps them out.
    public static let prefix = "[cache-audit]"

    private let coordinator: CacheCoordinator
    private let interval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let sink: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "CacheKit.CacheAudit", qos: .utility)

    private struct Running {
        var timer: (any DispatchSourceTimer)?
        var trims: CacheObservation?
    }

    private let running = Mutex(Running())

    /// - Parameter sink: receives each block of lines, on the audit's own queue.
    public init(
        coordinator: CacheCoordinator,
        interval: TimeInterval = CacheAudit.defaultInterval,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sink: @escaping @Sendable ([String]) -> Void
    ) {
        self.coordinator = coordinator
        self.interval = max(1, interval)
        self.uptime = uptime
        self.sink = sink
    }

    deinit { stop() }

    /// Starts the audit when `arguments` hold `-cache-audit`, logging to
    /// stdout and to `cache-audit.log` in Documents. Keep the returned audit:
    /// it stops when deallocated.
    public static func startIfRequested(
        _ coordinator: CacheCoordinator,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> CacheAudit? {
        guard arguments.contains(argument) else { return nil }
        var interval = defaultInterval
        if let position = arguments.firstIndex(of: intervalArgument), position + 1 < arguments.count,
           let seconds = TimeInterval(arguments[position + 1]), seconds > 0 {
            interval = seconds
        }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appending(path: logFileName)
        if let file { try? Data().write(to: file) }
        let audit = CacheAudit(coordinator: coordinator, interval: interval) { lines in
            let text = lines.joined(separator: "\n") + "\n"
            print(text, terminator: "")
            guard let file, let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
        audit.start()
        return audit
    }

    /// Logs every `interval` and after each trim, from now on.
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.emit(trigger: "interval") }
        let trims = coordinator.observeTrims { [weak self] reason in
            self?.queue.async { [weak self] in self?.emit(trigger: "trim:" + Self.name(of: reason)) }
        }
        let previous = running.withLock { running -> Running in
            let taken = running
            running = Running(timer: timer, trims: trims)
            return taken
        }
        previous.timer?.cancel()
        previous.trims?.cancel()
        timer.resume()
        queue.async { [weak self] in self?.emit(trigger: "start") }
    }

    public func stop() {
        let previous = running.withLock { running -> Running in
            let taken = running
            running = Running()
            return taken
        }
        previous.timer?.cancel()
        previous.trims?.cancel()
    }

    /// Logs a block now, on the caller's thread.
    public func emit(trigger: String) {
        sink(Self.lines(
            trigger: trigger,
            uptime: uptime(),
            report: coordinator.usage(),
            prefetch: coordinator.prefetchCounters.snapshot,
            limit: coordinator.storageLimit,
            pressure: coordinator.diskPressure,
            conditions: coordinator.conditions
        ))
    }

    // MARK: - Format

    /// One block of the log. Pure, so the format is tested.
    public static func lines(
        trigger: String,
        uptime: TimeInterval,
        report: CacheUsageReport,
        prefetch: CachePrefetchCounters.Snapshot,
        limit: CacheStorageLimit,
        pressure: DiskPressure,
        conditions: CacheConditions
    ) -> [String] {
        let speculative = report.speculative()
        var header = [
            "t=" + String(format: "%.1f", uptime),
            "trigger=" + trigger,
            "limit=" + name(of: limit),
            "diskPressure=" + name(of: pressure),
            "policy=" + name(of: PrefetchPolicy(conditions: conditions).level),
            "network=" + conditions.network.rawValue + (conditions.isNetworkExpensive ? "(expensive)" : "")
                + (conditions.isNetworkConstrained ? "(constrained)" : "")
                + (conditions.usesLessCellularData ? "(lessCellularData)" : ""),
            "memory=" + megabytes(report.totalBytes(medium: .memory)),
            "disk=" + megabytes(report.totalBytes(medium: .disk))
        ]
        header.append("waste=" + percent(speculative.wasteRatio)
            + "(\(megabytes(speculative.wastedBytes)) of \(megabytes(speculative.usedBytes + speculative.wastedBytes)))")
        var lines = ["\(prefix) " + header.joined(separator: " ")]
        let ordered = report.lines.sorted {
            ($0.medium.rawValue, $0.namespace.name) < ($1.medium.rawValue, $1.namespace.name)
        }
        for line in ordered {
            lines.append("\(prefix)   " + namespaceLine(line))
        }
        lines.append("\(prefix)   " + prefetchLine(prefetch))
        return lines
    }

    static func namespaceLine(_ line: CacheUsageReport.Line) -> String {
        let usage = line.usage
        let statistics = line.statistics
        let budget = usage.byteLimit == .max
            ? "unlimited"
            : megabytes(usage.byteLimit) + "(" + percent(usage.byteLimit > 0 ? Double(usage.bytes) / Double(usage.byteLimit) : nil) + ")"
        let tiers = CacheTier.allCases.map { "\($0.rawValue):" + megabytes(usage.bytesByTier[$0, default: 0]) }
        let removed = CacheEvictionReason.allCases.compactMap { reason -> String? in
            let count = statistics.removals[reason, default: 0]
            guard count > 0 else { return nil }
            return "\(reason.rawValue):\(count)/" + megabytes(statistics.removedBytes[reason, default: 0])
        }
        let fates = statistics.speculative
        return [
            "ns=" + line.namespace.name,
            "medium=" + line.medium.rawValue,
            "class=" + name(of: line.namespace.priorityClass),
            "scope=" + line.namespace.scope.rawValue,
            "bytes=" + megabytes(usage.bytes) + "/" + budget,
            "entries=\(usage.count)",
            "pinned=" + megabytes(usage.pinnedBytes),
            "tiers=" + tiers.joined(separator: ","),
            "hits=\(statistics.hits)",
            "misses=\(statistics.misses)",
            "hitRate=" + percent(statistics.hitRate),
            "removed=" + (removed.isEmpty ? "none" : removed.joined(separator: ",")),
            "speculative=stored:\(fates.stored)/\(megabytes(fates.storedBytes))"
                + ",used:\(fates.used)/\(megabytes(fates.usedBytes))"
                + ",wasted:\(fates.wasted)/\(megabytes(fates.wastedBytes))"
                + ",discarded:\(fates.discarded)/\(megabytes(fates.discardedBytes))",
            "waste=" + percent(fates.wasteRatio)
        ].joined(separator: " ")
    }

    static func prefetchLine(_ snapshot: CachePrefetchCounters.Snapshot) -> String {
        var fields = ["prefetch"]
        for category in CacheCategory.allCases {
            guard let arrivals = snapshot.arrivals[category], arrivals.total > 0 else { continue }
            fields.append("\(category.rawValue)=ready:\(arrivals.ready),inFlight:\(arrivals.inFlight),missed:\(arrivals.missed)"
                + ",hitRate:" + percent(arrivals.hitRate))
        }
        let starts = snapshot.nextVideoFirstRangeHits + snapshot.nextVideoFirstRangeMisses
        fields.append("nextVideoFirstRange=\(snapshot.nextVideoFirstRangeHits)/\(starts)(" + percent(snapshot.nextVideoFirstRangeHitRate) + ")")
        let frames = snapshot.firstFrame
        fields.append("timeToFirstFrame=n:\(frames.count),p50:" + milliseconds(frames.percentile(0.5))
            + ",p90:" + milliseconds(frames.percentile(0.9)) + ",max:" + milliseconds(frames.count > 0 ? frames.maximum : nil))
        let priorities = CacheFillPriority.allCases.reversed().map { priority -> String in
            "\(name(of: priority)):" + megabytes(snapshot.otherBytes[priority, default: 0] + snapshot.cellularBytes[priority, default: 0])
        }
        fields.append("fetched=" + priorities.joined(separator: ","))
        fields.append("p2Cellular=" + megabytes(snapshot.speculativeCellularBytes))
        return fields.joined(separator: " ")
    }

    // MARK: - Names

    public static func name(of reason: TrimReason) -> String {
        switch reason {
        case .memoryWarning: "memoryWarning"
        case .memoryCritical: "memoryCritical"
        case .background: "background"
        case .lowDisk(let pressure): "lowDisk(\(name(of: pressure)))"
        case .viewerChanged: "viewerChanged"
        case .clear(let category): "clear(\(category?.rawValue ?? "all"))"
        }
    }

    static func name(of limit: CacheStorageLimit) -> String {
        switch limit {
        case .automatic: "automatic"
        case .total(let bytes): megabytes(bytes)
        }
    }

    static func name(of pressure: DiskPressure) -> String {
        switch pressure {
        case .normal: "normal"
        case .low: "low"
        case .critical: "critical"
        }
    }

    static func name(of level: PrefetchPolicy.Level) -> String {
        switch level {
        case .off: "off"
        case .reduced: "reduced"
        case .cellular: "cellular"
        case .full: "full"
        }
    }

    static func name(of priorityClass: CachePriorityClass) -> String {
        switch priorityClass {
        case .expendable: "expendable"
        case .standard: "standard"
        case .preferred: "preferred"
        case .persistent: "persistent"
        }
    }

    static func name(of priority: CacheFillPriority) -> String {
        switch priority {
        case .visible: "P0"
        case .next: "P1"
        case .speculative: "P2"
        }
    }

    /// Decimal megabytes, one decimal: the unit Settings and the system show.
    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / Double(CacheBytes.megabyte))
    }

    static func percent(_ ratio: Double?) -> String {
        guard let ratio else { return "-" }
        return String(format: "%.0f%%", ratio * 100)
    }

    static func milliseconds(_ seconds: Double?) -> String {
        guard let seconds else { return "-" }
        return String(format: "%.0fms", seconds * 1000)
    }
}
#endif
