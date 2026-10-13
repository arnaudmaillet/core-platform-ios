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
        // ⚠️ Typed locals and single interpolations throughout: one array
        // literal of `+` chains timed out Xcode 26's type checker on CI.
        let expensive: String = conditions.isNetworkExpensive ? "(expensive)" : ""
        let constrained: String = conditions.isNetworkConstrained ? "(constrained)" : ""
        let lessCellular: String = conditions.usesLessCellularData ? "(lessCellularData)" : ""
        let policy: String = name(of: PrefetchPolicy(conditions: conditions).level)
        let memory: String = megabytes(report.totalBytes(medium: .memory))
        let disk: String = megabytes(report.totalBytes(medium: .disk))
        let wasteRatio: String = percent(speculative.wasteRatio)
        let wasted: String = megabytes(speculative.wastedBytes)
        let spent: String = megabytes(speculative.usedBytes + speculative.wastedBytes)
        let device: String = deviceFlags(conditions)
        let header: [String] = [
            "t=\(String(format: "%.1f", uptime))",
            "trigger=\(trigger)",
            "limit=\(name(of: limit))",
            "diskPressure=\(name(of: pressure))",
            "policy=\(policy)",
            "network=\(conditions.network.rawValue)\(expensive)\(constrained)\(lessCellular)",
            "device=\(device)",
            "memory=\(memory)",
            "disk=\(disk)",
            "waste=\(wasteRatio)(\(wasted) of \(spent))"
        ]
        let headerText: String = header.joined(separator: " ")
        var lines: [String] = ["\(prefix) \(headerText)"]
        let ordered = report.lines.sorted {
            ($0.medium.rawValue, $0.namespace.name) < ($1.medium.rawValue, $1.namespace.name)
        }
        for line in ordered {
            let text: String = namespaceLine(line)
            lines.append("\(prefix)   \(text)")
        }
        let prefetchText: String = prefetchLine(prefetch)
        lines.append("\(prefix)   \(prefetchText)")
        return lines
    }

    static func namespaceLine(_ line: CacheUsageReport.Line) -> String {
        let usage = line.usage
        let statistics = line.statistics
        let budget: String
        if usage.byteLimit == .max {
            budget = "unlimited"
        } else {
            let share: Double? = usage.byteLimit > 0 ? Double(usage.bytes) / Double(usage.byteLimit) : nil
            let limitText: String = megabytes(usage.byteLimit)
            let shareText: String = percent(share)
            budget = "\(limitText)(\(shareText))"
        }
        let tiers: [String] = CacheTier.allCases.map { tier -> String in
            let bytes: String = megabytes(usage.bytesByTier[tier, default: 0])
            return "\(tier.rawValue):\(bytes)"
        }
        let removals: [String] = CacheEvictionReason.allCases.compactMap { reason -> String? in
            let count = statistics.removals[reason, default: 0]
            guard count > 0 else { return nil }
            let bytes: String = megabytes(statistics.removedBytes[reason, default: 0])
            return "\(reason.rawValue):\(count)/\(bytes)"
        }
        let removedText: String = removals.isEmpty ? "none" : removals.joined(separator: ",")
        let tiersText: String = tiers.joined(separator: ",")
        let fates = statistics.speculative
        let storedBytes: String = megabytes(fates.storedBytes)
        let usedBytes: String = megabytes(fates.usedBytes)
        let wastedBytes: String = megabytes(fates.wastedBytes)
        let discardedBytes: String = megabytes(fates.discardedBytes)
        let speculativeText: String = "stored:\(fates.stored)/\(storedBytes),used:\(fates.used)/\(usedBytes),wasted:\(fates.wasted)/\(wastedBytes),discarded:\(fates.discarded)/\(discardedBytes)"
        let usedText: String = megabytes(usage.bytes)
        let pinnedText: String = megabytes(usage.pinnedBytes)
        let classText: String = name(of: line.namespace.priorityClass)
        let hitRateText: String = percent(statistics.hitRate)
        let wasteText: String = percent(fates.wasteRatio)
        var fields: [String] = [
            "ns=\(line.namespace.name)",
            "medium=\(line.medium.rawValue)",
            "class=\(classText)",
            "scope=\(line.namespace.scope.rawValue)",
            "bytes=\(usedText)/\(budget)",
            "entries=\(usage.count)",
            "pinned=\(pinnedText)",
            "tiers=\(tiersText)",
            "hits=\(statistics.hits)",
            "misses=\(statistics.misses)",
            "hitRate=\(hitRateText)",
            "removed=\(removedText)",
            "speculative=\(speculativeText)",
            "waste=\(wasteText)"
        ]
        // What the disk index costs (#1079): a memory cache has none.
        if line.medium == .disk {
            fields.append("indexWrites=\(statistics.indexWrites)(delayed:\(statistics.delayedIndexWrites))")
        }
        return fields.joined(separator: " ")
    }

    static func prefetchLine(_ snapshot: CachePrefetchCounters.Snapshot) -> String {
        var fields: [String] = ["prefetch"]
        for category in CacheCategory.allCases {
            guard let arrivals = snapshot.arrivals[category], arrivals.total > 0 else { continue }
            let hitRate: String = percent(arrivals.hitRate)
            fields.append("\(category.rawValue)=ready:\(arrivals.ready),inFlight:\(arrivals.inFlight),missed:\(arrivals.missed),hitRate:\(hitRate)")
        }
        let starts: Int = snapshot.nextVideoFirstRangeHits + snapshot.nextVideoFirstRangeMisses
        let firstRangeRate: String = percent(snapshot.nextVideoFirstRangeHitRate)
        fields.append("nextVideoFirstRange=\(snapshot.nextVideoFirstRangeHits)/\(starts)(\(firstRangeRate))")
        let frames = snapshot.firstFrame
        let p50: String = milliseconds(frames.percentile(0.5))
        let p90: String = milliseconds(frames.percentile(0.9))
        let longest: Double? = frames.count > 0 ? frames.maximum : nil
        let maximum: String = milliseconds(longest)
        fields.append("timeToFirstFrame=n:\(frames.count),p50:\(p50),p90:\(p90),max:\(maximum)")
        let priorities: [String] = CacheFillPriority.allCases.reversed().map { priority -> String in
            let bytes: Int = snapshot.otherBytes[priority, default: 0] + snapshot.cellularBytes[priority, default: 0]
            let size: String = megabytes(bytes)
            return "\(name(of: priority)):\(size)"
        }
        let fetched: String = priorities.joined(separator: ",")
        fields.append("fetched=\(fetched)")
        let cellular: String = megabytes(snapshot.speculativeCellularBytes)
        fields.append("p2Cellular=\(cellular)")
        return fields.joined(separator: " ")
    }

    /// What else the policy follows (#898): `background`, `lowPower`, and
    /// the thermal state when it is not nominal; `-` for none.
    static func deviceFlags(_ conditions: CacheConditions) -> String {
        var flags: [String] = []
        if conditions.isInBackground { flags.append("background") }
        if conditions.isLowPowerModeEnabled { flags.append("lowPower") }
        let thermal: String? = switch conditions.thermalState {
        case .nominal: nil
        case .fair: "thermal:fair"
        case .serious: "thermal:serious"
        case .critical: "thermal:critical"
        @unknown default: "thermal:unknown"
        }
        if let thermal { flags.append(thermal) }
        return flags.isEmpty ? "-" : flags.joined(separator: ",")
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
