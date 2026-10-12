import Foundation
import Synchronization

/// What the coordinator reads from the device. Injected, so tests pick the
/// physical memory and the free disk space without touching the real ones.
public struct CacheDevice: Sendable {
    public var physicalMemory: @Sendable () -> UInt64
    public var availableDiskCapacity: @Sendable () -> Int64?

    public init(physicalMemory: @escaping @Sendable () -> UInt64, availableDiskCapacity: @escaping @Sendable () -> Int64?) {
        self.physicalMemory = physicalMemory
        self.availableDiskCapacity = availableDiskCapacity
    }

    public static let current = CacheDevice(
        physicalMemory: { ProcessInfo.processInfo.physicalMemory },
        availableDiskCapacity: {
            let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    )
}

/// The coordinator's one entry point per release signal.
public enum TrimReason: Sendable, Equatable {
    /// Speculative entries and half of `recent` (per class, see `CachePriorityClass`).
    case memoryWarning
    /// Only leased entries stay (persistent namespaces keep `retained`).
    case memoryCritical
    /// Memory down to retained + leased; disk indexes flushed, expired entries
    /// swept, free disk measured again.
    case background
    /// Disk budgets recomputed for this pressure (`.normal` restores them).
    case lowDisk(DiskPressure)
    /// Logout, account or profile switch: viewer-scoped and signed namespaces
    /// wiped, memory and disk; public media kept.
    case viewerChanged
    /// Settings → Storage → Clear: one category, or everything (`nil`), memory
    /// and disk together, persistent namespaces included.
    case clear(CacheCategory?)

    /// The memory signal behind this trim; nil for a disk, session or Settings
    /// trim. What a holder of memory outside any `ManagedCache` (idle players,
    /// frame generators) reacts to, through `observeMemoryPressure`.
    public var memoryPressure: MemoryPressure? {
        switch self {
        case .memoryWarning: .warning
        case .memoryCritical: .critical
        case .background: .background
        case .lowDisk, .viewerChanged, .clear: nil
        }
    }
}

/// What every managed cache holds, for Settings → Storage (#899) and the
/// `-cache-audit` instrument (#900).
public struct CacheUsageReport: Sendable {
    public struct Line: Sendable, Equatable {
        public let namespace: CacheNamespace
        public let medium: CacheMedium
        public let usage: CacheUsage
        /// Hits, misses, evictions per reason and speculative fates since
        /// the cache was created.
        public let statistics: CacheStatistics
    }

    public let lines: [Line]

    public func usage(of name: String, medium: CacheMedium) -> CacheUsage? {
        lines.first { $0.namespace.name == name && $0.medium == medium }?.usage
    }

    /// Bytes of one category, on one medium or both.
    public func bytes(in category: CacheCategory, medium: CacheMedium? = nil) -> Int {
        lines
            .filter { $0.namespace.category == category && (medium == nil || $0.medium == medium) }
            .reduce(0) { $0 + $1.usage.bytes }
    }

    public func totalBytes(medium: CacheMedium? = nil) -> Int {
        lines.filter { medium == nil || $0.medium == medium }.reduce(0) { $0 + $1.usage.bytes }
    }

    /// Speculative fates summed over every namespace (or one category): the
    /// app's waste ratio is `speculative().wasteRatio`.
    public func speculative(in category: CacheCategory? = nil) -> CacheSpeculativeStatistics {
        lines
            .filter { category == nil || $0.namespace.category == category }
            .reduce(CacheSpeculativeStatistics()) { $0 + $1.statistics.speculative }
    }

    /// Every category with its bytes (memory and disk), zero included.
    public var bytesByCategory: [CacheCategory: Int] {
        Dictionary(uniqueKeysWithValues: CacheCategory.allCases.map { ($0, bytes(in: $0)) })
    }
}

/// The one owner of every cache budget in the app.
///
/// Every memory and disk namespace registers here. The coordinator turns each
/// namespace's budget rule into bytes from the device (physical memory, free
/// disk, the user's Settings limit), and reacts to every release signal:
/// memory warning and critical pressure, background, low disk, Low Power,
/// thermal state, the network path, and the viewer changing. It also owns the
/// global allowance of speculative fills (`fillSlots`) that every list's
/// prefetcher shares, sized from the current `PrefetchPolicy`.
///
/// Signals arrive through injected `CacheSignalSource`s (`SystemCacheSignals`
/// in the app); every entry point can also be called directly. Thread-safe
/// behind a `Mutex`; caches are always called OUTSIDE the coordinator's lock.
///
/// ⚠️ **No disk work on the main thread (#898).** UIKit posts the lifecycle
/// signals there, and the composition root registers caches there. Whatever a
/// call asks of a DISK cache (budgets that evict files, the background sweep
/// and index flush, the free-space measure) then runs on the coordinator's
/// own utility queue, in order; memory caches are trimmed in place, at once.
/// Called off the main thread (Settings, a test), everything runs in place,
/// so the caller sees it done when the call returns. One exception, by
/// design: a wipe (`.viewerChanged`, `.clear`) reaches every cache in place,
/// since nothing may be served to the next viewer; `DiskStore.removeAll`
/// then does one folder rename there and deletes on its janitor queue, and
/// the LocalStore deletes on its writer's queue.
public final class CacheCoordinator: Sendable {
    /// The share of each namespace's budget that unleased speculative entries
    /// may use, so prefetching never crowds out what was seen (#970's
    /// proposal: video 100 MB and images 60 MB under Automatic).
    public static let speculativeShare = 0.20

    /// The global allowance of speculative fills. Pass it to every `CacheFills`.
    public let fillSlots: CacheFillSlots

    /// The lookahead's counters (prefetch arrivals, next-video first range,
    /// time to first frame, bytes per priority and network), reported by the
    /// image pipeline, the video cache and the feed lookahead (#900).
    public let prefetchCounters = CachePrefetchCounters()

    private struct State {
        var caches: [any ManagedCache] = []
        var limit: CacheStorageLimit
        var pressure: DiskPressure
        var conditions: CacheConditions
        var sources: [any CacheSignalSource] = []
        var observers: [UInt64: @Sendable (CacheConditions, PrefetchPolicy) -> Void] = [:]
        var trimObservers: [UInt64: @Sendable (TrimReason) -> Void] = [:]
        var nextObserverID: UInt64 = 0
    }

    private let device: CacheDevice
    private let state: Mutex<State>
    /// Serialises budget applications so a stale computation never lands last.
    /// Taken before `state`, never inside it.
    private let budgetGate = Mutex(())
    /// Where disk work asked for on the main thread runs (see the type's note).
    private let diskQueue = DispatchQueue(label: "CacheKit.CacheCoordinator.disk", qos: .utility)

    /// Measures free disk at once, off the main thread; made on it (the app's
    /// composition root), the coordinator starts at `.normal` and measures on
    /// its queue, which shrinks the disk budgets moments later if it must.
    public init(device: CacheDevice = .current, storageLimit: CacheStorageLimit = .automatic, conditions: CacheConditions = CacheConditions()) {
        self.device = device
        let onMain = Thread.isMainThread
        let pressure = onMain ? DiskPressure.normal : DiskPressure(availableCapacity: device.availableDiskCapacity())
        state = Mutex(State(limit: storageLimit, pressure: pressure, conditions: conditions))
        fillSlots = CacheFillSlots(limit: PrefetchPolicy(conditions: conditions).maxConcurrentSpeculativeFills)
        if onMain {
            diskQueue.async { [weak self] in self?.refreshDiskSpace() }
        }
    }

    // MARK: - Registry

    /// Registers `cache` and applies its budget at once. A cache with the same
    /// name and medium replaces the previous one.
    public func register(_ cache: any ManagedCache) {
        let inBackground = state.withLock { state -> Bool in
            state.caches.removeAll { $0.namespace.name == cache.namespace.name && $0.medium == cache.medium }
            state.caches.append(cache)
            return state.conditions.isInBackground
        }
        if inBackground, Self.isHeldInBackground(cache) { cache.setAdmissionsPaused(true) }
        applyBudgets(reason: .budget)
    }

    public func unregister(_ cache: any ManagedCache) {
        state.withLock { state in
            state.caches.removeAll { $0 === cache }
        }
        applyBudgets(reason: .budget)
    }

    public var registeredCaches: [any ManagedCache] { state.withLock { $0.caches } }

    // MARK: - Budgets

    public var storageLimit: CacheStorageLimit { state.withLock { $0.limit } }

    /// The Settings → Storage choice (#899). Shrinking evicts at once.
    public func setStorageLimit(_ limit: CacheStorageLimit) {
        state.withLock { $0.limit = limit }
        applyBudgets(reason: .budget)
    }

    public var diskPressure: DiskPressure { state.withLock { $0.pressure } }

    public var diskPoolBudgets: DiskPoolBudgets {
        state.withLock { DiskPoolBudgets(limit: $0.limit, pressure: $0.pressure) }
    }

    /// The limits the coordinator gives `cache` now (what it applied on
    /// registration and after the last change).
    public func limits(for cache: any ManagedCache) -> CacheLimits? {
        let snapshot = state.withLock { $0 }
        return computeLimits(snapshot).first { $0.cache === cache }?.limits
    }

    /// Measures free disk space and, if the pressure level changed, applies
    /// the new disk budgets. The initializer measures once; every trip to the
    /// background and back measures again, off the main thread (the measure
    /// itself can take a while: the system counts purgeable space).
    @discardableResult
    public func refreshDiskSpace() -> DiskPressure {
        let measured = DiskPressure(availableCapacity: device.availableDiskCapacity())
        if measured != diskPressure {
            trim(.lowDisk(measured))
        }
        return measured
    }

    // MARK: - Conditions

    public var conditions: CacheConditions { state.withLock { $0.conditions } }

    public var prefetchPolicy: PrefetchPolicy { PrefetchPolicy(conditions: conditions) }

    public func updateConditions(_ change: (inout CacheConditions) -> Void) {
        let update = state.withLock { state -> (CacheConditions, PrefetchPolicy, [@Sendable (CacheConditions, PrefetchPolicy) -> Void]) in
            change(&state.conditions)
            return (state.conditions, PrefetchPolicy(conditions: state.conditions), Array(state.observers.values))
        }
        let (conditions, policy, observers) = update
        fillSlots.setLimit(policy.maxConcurrentSpeculativeFills)
        for observer in observers { observer(conditions, policy) }
    }

    /// Calls `handler` with the conditions and policy after every change, so
    /// a lookahead re-plans its windows (#970). Keep the returned token; the
    /// observation ends when it is cancelled or deallocated.
    public func observeConditions(_ handler: @escaping @Sendable (CacheConditions, PrefetchPolicy) -> Void) -> CacheObservation {
        let id = state.withLock { state -> UInt64 in
            state.nextObserverID += 1
            state.observers[state.nextObserverID] = handler
            return state.nextObserverID
        }
        return CacheObservation { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
    }

    /// Calls `handler` after every `trim(_:)` (each signal's trim, a low-disk
    /// change, a viewer change, a Settings clear), with its reason, on the
    /// thread that applied it. The
    /// `-cache-audit` instrument logs a report on each. Keep the returned
    /// token; the observation ends when it is cancelled or deallocated.
    public func observeTrims(_ handler: @escaping @Sendable (TrimReason) -> Void) -> CacheObservation {
        let id = state.withLock { state -> UInt64 in
            state.nextObserverID += 1
            state.trimObservers[state.nextObserverID] = handler
            return state.nextObserverID
        }
        return CacheObservation { [weak self] in
            self?.state.withLock { _ = $0.trimObservers.removeValue(forKey: id) }
        }
    }

    /// Counts `bytes` a fill at `priority` fetched over the network, as
    /// cellular when the current path is cellular or expensive.
    public func recordTransfer(bytes: Int, priority: CacheFillPriority) {
        let current = self.conditions
        let cellular = current.network == .cellular || current.isNetworkExpensive
        prefetchCounters.recordTransfer(bytes: bytes, priority: priority, cellular: cellular)
    }

    /// Whether a playing video is under-buffered. While it is, no new P2 fill
    /// starts anywhere in the app (the Media3 / BytePlus rule): a prefetch
    /// never competes with the video being watched. The video cache (#895)
    /// reports it.
    public func setPlaybackUnderBuffered(_ underBuffered: Bool) {
        fillSlots.setPaused(underBuffered)
    }

    /// Calls `handler` after every memory trim (a warning, the background,
    /// critical pressure), on the thread that applied it: for memory held
    /// outside any `ManagedCache` (idle players, frame generators), which
    /// releases itself at the depth the pressure calls for. Keep the returned
    /// token; the observation ends when it is cancelled or deallocated.
    public func observeMemoryPressure(_ handler: @escaping @Sendable (MemoryPressure) -> Void) -> CacheObservation {
        observeTrims { reason in
            if let pressure = reason.memoryPressure { handler(pressure) }
        }
    }

    // MARK: - Signals

    /// Releases memory or disk for `reason`. Caches are visited lowest
    /// priority class first. Disk work asked for on the main thread runs on
    /// the coordinator's queue (see the type's note).
    public func trim(_ reason: TrimReason) {
        switch reason {
        case .memoryWarning:
            trimMemory(.warning)
        case .memoryCritical:
            trimMemory(.critical)
        case .background:
            trimMemory(.background)
            offMainThread { [weak self] in
                guard let self else { return }
                for cache in caches(.disk) {
                    cache.trim(.expired, reason: .background)
                    cache.flush()
                }
                refreshDiskSpace()
            }
        case .lowDisk(let pressure):
            state.withLock { $0.pressure = pressure }
            applyBudgets(reason: .lowDisk)
        case .viewerChanged:
            for cache in registeredCaches where cache.namespace.isWipedOnViewerChange {
                cache.removeAll(reason: .viewerChanged)
            }
        case .clear(let category):
            for cache in registeredCaches where category == nil || cache.namespace.category == category {
                cache.removeAll(reason: .clear)
            }
        }
        let observers = state.withLock { Array($0.trimObservers.values) }
        for observer in observers { observer(reason) }
    }

    /// Persists every disk index (off the main thread).
    public func flush() {
        offMainThread { [weak self] in
            guard let self else { return }
            for cache in caches(.disk) { cache.flush() }
        }
    }

    /// Waits until the disk work queued from the main thread so far has run.
    /// Tests, and the audit; the app never needs to.
    public func waitForDiskWork() {
        diskQueue.sync {}
    }

    public func usage() -> CacheUsageReport {
        CacheUsageReport(lines: registeredCaches.map { cache in
            CacheUsageReport.Line(namespace: cache.namespace, medium: cache.medium, usage: cache.usage, statistics: cache.statistics)
        })
    }

    /// Starts listening to `sources` (in the app: `SystemCacheSignals` plus a
    /// `NotificationCacheSignals` for session changes). Replaces any previous
    /// sources.
    public func startObserving(_ sources: [any CacheSignalSource]) {
        stopObserving()
        state.withLock { $0.sources = sources }
        for source in sources {
            source.start { [weak self] signal in self?.handle(signal) }
        }
    }

    public func stopObserving() {
        let previous = state.withLock { state -> [any CacheSignalSource] in
            let taken = state.sources
            state.sources = []
            return taken
        }
        for source in previous { source.stop() }
    }

    /// What each signal does.
    public func handle(_ signal: CacheSignal) {
        switch signal {
        case .memoryWarning:
            trim(.memoryWarning)
        case .memoryCritical:
            trim(.memoryCritical)
        case .didEnterBackground:
            // First: a fill that lands after the trim keeps nothing in memory
            // and no prefetch starts.
            updateConditions { $0.isInBackground = true }
            holdBackgroundCut(true)
            trim(.background)
        case .willEnterForeground:
            updateConditions { $0.isInBackground = false }
            holdBackgroundCut(false)
            offMainThread { [weak self] in self?.refreshDiskSpace() }
        case .lowPowerMode(let enabled):
            updateConditions { $0.isLowPowerModeEnabled = enabled }
        case .thermalState(let thermal):
            updateConditions { $0.thermalState = thermal }
        case .network(let interface, let constrained, let expensive):
            updateConditions {
                $0.network = interface
                $0.isNetworkConstrained = constrained
                $0.isNetworkExpensive = expensive
            }
        case .viewerChanged:
            trim(.viewerChanged)
        }
    }

    // MARK: - Internals

    private func caches(_ medium: CacheMedium) -> [any ManagedCache] {
        registeredCaches
            .filter { $0.medium == medium }
            .sorted { $0.namespace.priorityClass < $1.namespace.priorityClass }
    }

    /// The memory namespaces the background cuts to `retained` (the
    /// expendable and standard classes: feed media) admit nothing new below
    /// it until the foreground (#898): the trim's release holds, whatever a
    /// list still lays out or a fill delivers in the meantime. Avatars and UI
    /// assets, which the background cuts less deep, keep filling.
    private func holdBackgroundCut(_ held: Bool) {
        for cache in caches(.memory) where !held || Self.isHeldInBackground(cache) {
            cache.setAdmissionsPaused(held)
        }
    }

    private static func isHeldInBackground(_ cache: any ManagedCache) -> Bool {
        cache.medium == .memory && cache.namespace.priorityClass.depth(for: .background) >= .belowRetained
    }

    private func trimMemory(_ pressure: MemoryPressure) {
        let reason: CacheEvictionReason = switch pressure {
        case .warning: .memoryWarning
        case .background: .background
        case .critical: .memoryCritical
        }
        for cache in caches(.memory) {
            cache.trim(cache.namespace.priorityClass.depth(for: pressure), reason: reason)
        }
    }

    /// Memory limits in place; disk limits (which may delete files) off the
    /// main thread.
    private func applyBudgets(reason: CacheEvictionReason) {
        applyBudgets(reason: reason, medium: .memory)
        offMainThread { [weak self] in self?.applyBudgets(reason: reason, medium: .disk) }
    }

    private func applyBudgets(reason: CacheEvictionReason, medium: CacheMedium) {
        budgetGate.withLock { _ in
            let snapshot = state.withLock { $0 }
            for assignment in computeLimits(snapshot) where assignment.cache.medium == medium {
                assignment.cache.setLimits(assignment.limits, reason: reason)
            }
        }
    }

    /// Runs `work` in place off the main thread, or on `diskQueue` from it.
    private func offMainThread(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            diskQueue.async(execute: work)
        } else {
            work()
        }
    }

    private func computeLimits(_ snapshot: State) -> [(cache: any ManagedCache, limits: CacheLimits)] {
        let physicalMemory = device.physicalMemory()
        let pools = DiskPoolBudgets(limit: snapshot.limit, pressure: snapshot.pressure)
        var diskBytes: [ObjectIdentifier: Int] = [:]
        for pool in DiskPool.allCases {
            var members: [(cache: any ManagedCache, budget: DiskBudget)] = []
            for cache in snapshot.caches {
                if case .disk(let budget) = cache.budget, budget.pool == pool {
                    members.append((cache, budget))
                }
            }
            let shares = DiskBudget.split(pools[pool], among: members.map(\.budget))
            for (member, bytes) in zip(members, shares) {
                diskBytes[ObjectIdentifier(member.cache)] = bytes
            }
        }
        return snapshot.caches.map { cache in
            let bytes: Int
            switch cache.budget {
            case .memory(let rule):
                bytes = rule.bytes(physicalMemory: physicalMemory)
            case .disk:
                bytes = diskBytes[ObjectIdentifier(cache)] ?? 0
            }
            return (cache, CacheLimits(bytes: bytes, speculativeShare: Self.speculativeShare))
        }
    }
}
