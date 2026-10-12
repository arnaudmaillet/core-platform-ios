import Foundation
import Synchronization

/// A disk cache namespace: one file per entry under
/// `Caches/<namespace>/v<version>/`, an index of size, last access, tier and
/// expiry, and the same tiers, leases and LRU order as `MemoryCache`.
///
/// - **Versioned:** at start-up every folder of the namespace other than
///   `v<version>` is deleted, so a new format is never misread. Bump the
///   version when the bytes a key maps to change meaning.
/// - **Atomic writes:** bytes are written to `v<N>/incoming/` under a fresh
///   name, then renamed into `v<N>/objects/`. A reader never sees half a file,
///   and a crash leaves only debris that the next start-up removes.
/// - **The index is a cache of the truth, not the truth:** it is flushed every
///   `flushThreshold` changes and when the app goes to the background. At
///   start-up it is reconciled with the files: an entry whose file is missing
///   or has the wrong size is dropped, a file no entry names is deleted, and an
///   unreadable index starts the namespace empty. A crash costs cached bytes,
///   never correctness.
/// - **Excluded from backup**, and under `Caches/`, so iOS may purge it.
///
/// A lease pins a FILE: a player reading it by path keeps it until the lease
/// ends, even if the entry is replaced or wiped meanwhile (the file is then
/// deleted on release).
///
/// Open ONE store per namespace per process: start-up cleans the folder, so a
/// second instance would delete the first one's staged writes.
///
/// - **A wipe returns at once** (`removeAll`, #898): the index is emptied and
///   the `objects` folder is renamed to a `trash-<uuid>` folder under the
///   lock, so nothing is served afterwards, and the files are deleted on a
///   utility queue. A logout or a profile switch posts on the main thread;
///   the wipe never does disk I/O there beyond a few renames. Trash a crash
///   left behind is deleted at the next start-up, off the caller's thread too.
///
/// Thread-safe behind a `Mutex` (see `MemoryCache` for why not an actor).
/// File reads and writes run outside the lock; only renames (a write's commit
/// into `objects`, a wipe's swap of the folder) and the index bookkeeping run
/// under it, so a wipe and a commit never interleave.
public final class DiskStore: ManagedCache {
    public let namespace: CacheNamespace
    public let diskBudget: DiskBudget
    public let version: Int
    public var budget: CacheBudget { .disk(diskBudget) }
    /// `Caches/<namespace>/v<version>/`.
    public let directory: URL

    private let objects: URL
    private let incoming: URL
    private let indexURL: URL
    private let clock: any CacheClock
    private let speculativeLifetime: TimeInterval
    private let idleLifetime: TimeInterval?
    private let flushThreshold: Int
    private let state: Mutex<State>
    /// Serialises index writes so an older snapshot never lands after a newer
    /// one. Always taken BEFORE `state`, never inside it.
    private let flushGate = Mutex(())

    /// Deletes wiped files and start-up trash, off every caller's thread.
    static let janitor = DispatchQueue(label: "CacheKit.DiskStore.janitor", qos: .utility)

    /// The prefix of a wiped `objects` folder waiting for the janitor.
    static let trashPrefix = "trash-"

    public enum StoreError: Error, Equatable {
        /// The name must be a plain folder name: letters, digits, `.`, `-`, `_`.
        case invalidNamespaceName(String)
    }

    /// Opens (or creates) the namespace's folder and reconciles its index.
    ///
    /// - Parameters:
    ///   - root: the folder namespaces live in; the app's `Caches` by default.
    ///     Tests pass a temporary folder.
    ///   - idleLifetime: when set, an entry nobody used for that long expires,
    ///     whatever its tier (UI assets: 30 days, #971).
    ///   - flushThreshold: index changes between automatic flushes.
    public init(
        namespace: CacheNamespace,
        version: Int = 1,
        budget: DiskBudget,
        root: URL? = nil,
        limits: CacheLimits = .unlimited,
        clock: any CacheClock = SystemCacheClock(),
        speculativeLifetime: TimeInterval = CacheTier.speculativeLifetime,
        idleLifetime: TimeInterval? = nil,
        flushThreshold: Int = 32
    ) throws {
        guard Self.isValidName(namespace.name) else { throw StoreError.invalidNamespaceName(namespace.name) }
        let fileManager = FileManager.default
        let base = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var namespaceFolder = base.appending(path: namespace.name, directoryHint: .isDirectory)
        let versionName = "v\(version)"
        let directory = namespaceFolder.appending(path: versionName, directoryHint: .isDirectory)
        let objects = directory.appending(path: "objects", directoryHint: .isDirectory)
        let incoming = directory.appending(path: "incoming", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: namespaceFolder, withIntermediateDirectories: true)
        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        try namespaceFolder.setResourceValues(exclusion)
        // Another version's folder (or any stray file) is never misread: it goes.
        for item in (try? fileManager.contentsOfDirectory(atPath: namespaceFolder.path)) ?? [] where item != versionName {
            try? fileManager.removeItem(at: namespaceFolder.appending(path: item))
        }
        try? fileManager.removeItem(at: incoming)
        // A wipe's trash the janitor never reached (the app was killed first):
        // not one of ours any more, deleted in the background.
        let leftovers = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(Self.trashPrefix) }
            .map { directory.appending(path: $0, directoryHint: .isDirectory) }
        if !leftovers.isEmpty {
            Self.janitor.async {
                for folder in leftovers { try? FileManager.default.removeItem(at: folder) }
            }
        }
        try fileManager.createDirectory(at: objects, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)

        self.namespace = namespace
        self.diskBudget = budget
        self.version = version
        self.directory = directory
        self.objects = objects
        self.incoming = incoming
        self.indexURL = directory.appending(path: "index.json")
        self.clock = clock
        self.speculativeLifetime = speculativeLifetime
        self.idleLifetime = idleLifetime
        self.flushThreshold = max(1, flushThreshold)

        let recovered = Self.recover(indexURL: indexURL, objects: objects, now: clock.now, idle: idleLifetime)
        state = Mutex(State(limits: limits, records: recovered.records, nextOrder: recovered.nextOrder))
        state.withLock { $0.dirty = recovered.changed }
        flush()
    }

    // MARK: - Reading

    /// The bytes for `key`, as a USE (LRU move, speculative promoted to
    /// `recent`). `nil` if absent, expired, or the file vanished.
    public func data(for key: String) -> Data? {
        guard let resolved = resolve(key) else { return nil }
        do {
            return try Data(contentsOf: resolved.url, options: .mappedIfSafe)
        } catch {
            dropVanished(key: key, file: resolved.file)
            return nil
        }
    }

    /// The file for `key`, as a USE. A caller that reads it over time (a
    /// player) should hold a `lease(_:)` so it is not evicted meanwhile.
    public func fileURL(for key: String) -> URL? {
        resolve(key)?.url
    }

    /// Whether `key` is stored (and not expired), without counting as a use.
    public func contains(_ key: String) -> Bool {
        let now = clock.now
        return state.withLock { state in
            guard let record = state.records[key] else { return false }
            return state.leases[key] != nil || !record.isExpired(at: now, idle: idleLifetime)
        }
    }

    public func tier(of key: String) -> CacheTier? {
        state.withLock { $0.records[key]?.tier }
    }

    public func isLeased(_ key: String) -> Bool {
        state.withLock { $0.leases[key] != nil }
    }

    // MARK: - Writing

    /// Writes `data` under `key`. Same rules as `MemoryCache.insert`: the
    /// higher tier wins over an existing entry, the new entry is never the
    /// victim of its own write, and a speculative write never displaces a
    /// retained entry.
    ///
    /// - Returns: `false` when the entry cannot fit (bigger than the budget or
    ///   than the speculative cap, e.g. 0 when the video pool is off on a
    ///   nearly full disk). Nothing is left on disk then.
    @discardableResult
    public func write(_ data: Data, for key: String, tier: CacheTier = .recent, expiresAt: Date? = nil) throws -> Bool {
        guard admits(size: data.count, key: key, tier: tier) else { return false }
        let file = UUID().uuidString
        let staged = incoming.appending(path: file)
        try data.write(to: staged)
        return try commit(staged: staged, file: file, size: data.count, key: key, tier: tier, expiresAt: expiresAt)
    }

    /// Moves a finished file (a `URLSession` download) into the store under
    /// `key`, without copying its bytes. The source is consumed whether the
    /// entry is kept or refused; it stays only if the move itself throws.
    @discardableResult
    public func moveItem(at source: URL, for key: String, tier: CacheTier = .recent, expiresAt: Date? = nil) throws -> Bool {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard admits(size: size, key: key, tier: tier) else {
            try? FileManager.default.removeItem(at: source)
            return false
        }
        let file = UUID().uuidString
        let staged = incoming.appending(path: file)
        try FileManager.default.moveItem(at: source, to: staged)
        return try commit(staged: staged, file: file, size: size, key: key, tier: tier, expiresAt: expiresAt)
    }

    /// Pins `key`'s file. A speculative entry is promoted to `recent`.
    public func lease(_ key: String) -> CacheLease? {
        let now = clock.now
        let outcome: (file: String?, garbage: [String]) = state.withLock { state in
            guard var record = state.records[key] else { return (nil, []) }
            let wasLeased = state.leases[key] != nil
            if !wasLeased {
                if record.isExpired(at: now, idle: idleLifetime) {
                    state.statistics.recordRemoval(.expiry, bytes: record.size, wasSpeculative: record.tier == .speculative)
                    state.markChanged(structural: true)
                    return (nil, state.remove(key))
                }
                state.unlink(key, record)
            }
            if record.tier == .speculative {
                state.statistics.speculative.recordUsed(bytes: record.size)
            }
            record.promote()
            record.touch(now: now, order: state.takeOrder())
            state.records[key] = record
            state.leases[key, default: 0] += 1
            if !wasLeased { state.link(key, record) }
            state.markChanged(structural: false)
            return (record.file, [])
        }
        delete(outcome.garbage)
        guard let file = outcome.file else { return nil }
        return CacheLease { [weak self] in self?.endLease(key: key, file: file) }
    }

    public func setTier(_ tier: CacheTier, for key: String) {
        let now = clock.now
        let lifetime = speculativeLifetime
        let garbage: [String] = state.withLock { state in
            guard var record = state.records[key] else { return [] }
            if record.tier == .speculative, tier != .speculative {
                state.statistics.speculative.recordUsed(bytes: record.size)
            } else if record.tier != .speculative, tier == .speculative {
                state.statistics.speculative.recordStored(bytes: record.size)
            }
            let leased = state.leases[key] != nil
            if !leased { state.unlink(key, record) }
            record.tier = tier
            record.speculativeDeadline = tier == .speculative ? now.addingTimeInterval(lifetime) : nil
            state.records[key] = record
            if !leased { state.link(key, record) }
            state.markChanged(structural: true)
            return state.enforceLimits(protecting: nil, ceiling: .retained, reason: .budget)
        }
        delete(garbage)
        flushIfNeeded()
    }

    public func removeValue(for key: String) {
        let garbage = state.withLock { state -> [String] in
            guard let record = state.records[key] else { return [] }
            if record.tier == .speculative {
                state.statistics.speculative.recordDiscarded(bytes: record.size)
            }
            state.markChanged(structural: true)
            return state.remove(key)
        }
        delete(garbage)
        flushIfNeeded()
    }

    // MARK: - ManagedCache

    /// Empties the namespace and returns at once: nothing is served after
    /// this call, and the files are deleted on a utility queue. A leased file
    /// stays readable at its path until its last lease ends. A write that
    /// commits after the wipe lands in the fresh folder and is kept.
    public func removeAll() {
        removeAll(reason: .wipe)
    }

    public func removeAll(reason: CacheEvictionReason) {
        let fileManager = FileManager.default
        let trash = directory.appending(path: Self.trashPrefix + UUID().uuidString, directoryHint: .isDirectory)
        let objectsFolder = self.objects
        let outcome: (swapped: Bool, garbage: [String]) = state.withLock { state in
            var garbage: [String] = []
            for (key, record) in state.records {
                state.statistics.recordRemoval(reason, bytes: record.size, wasSpeculative: record.tier == .speculative)
                garbage += state.remove(key)
            }
            state.markChanged(structural: true)
            // One rename hides every file; commits take this lock to move a
            // file in, so none lands in the folder being thrown away.
            guard (try? fileManager.moveItem(at: objectsFolder, to: trash)) != nil else {
                // No folder to swap (iOS purged `Caches`): the files go one by
                // one in the background, and commits get their folder back.
                try? fileManager.createDirectory(at: objectsFolder, withIntermediateDirectories: true)
                return (false, garbage)
            }
            try? fileManager.createDirectory(at: objectsFolder, withIntermediateDirectories: true)
            // Files a player still reads by path come back (a handful at most).
            for file in state.doomed.keys {
                try? fileManager.moveItem(at: trash.appending(path: file), to: objectsFolder.appending(path: file))
            }
            return (true, [])
        }
        Self.janitor.async { [weak self] in
            if outcome.swapped {
                try? fileManager.removeItem(at: trash)
            } else {
                for file in outcome.garbage { try? fileManager.removeItem(at: objectsFolder.appending(path: file)) }
            }
            self?.flush()
        }
    }

    /// Waits for the deletions a wipe or a start-up queued. Tests only.
    static func drainJanitor() {
        janitor.sync {}
    }

    public func setLimits(_ limits: CacheLimits) {
        setLimits(limits, reason: .budget)
    }

    public func setLimits(_ limits: CacheLimits, reason: CacheEvictionReason) {
        let garbage = state.withLock { state -> [String] in
            state.limits = limits
            return state.enforceLimits(protecting: nil, ceiling: .retained, reason: reason)
        }
        delete(garbage)
        flushIfNeeded()
    }

    public func trim(_ depth: TrimDepth) {
        trim(depth, reason: .trim)
    }

    public func trim(_ depth: TrimDepth, reason: CacheEvictionReason) {
        let now = clock.now
        let garbage = state.withLock { state -> [String] in
            let records = state.records
            let victims = state.lru.victims(
                for: depth,
                cost: { records[$0]?.size ?? 0 },
                isExpired: { records[$0]?.isExpired(at: now, idle: idleLifetime) ?? false }
            )
            var garbage: [String] = []
            for key in victims {
                guard let record = records[key] else { continue }
                let expired = record.isExpired(at: now, idle: idleLifetime)
                garbage += state.remove(key)
                state.statistics.recordRemoval(expired ? .expiry : reason, bytes: record.size, wasSpeculative: record.tier == .speculative)
            }
            if !victims.isEmpty { state.markChanged(structural: true) }
            return garbage
        }
        delete(garbage)
        flushIfNeeded()
    }

    /// Writes the index if anything changed since the last write.
    public func flush() {
        flushGate.withLock { _ in
            let snapshot: IndexFile? = state.withLock { state in
                guard state.dirty else { return nil }
                state.dirty = false
                state.changesSinceFlush = 0
                return IndexFile(nextOrder: state.nextOrder, records: Array(state.records.values))
            }
            guard let snapshot else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: indexURL, options: .atomic)
            } catch {
                state.withLock { $0.dirty = true }
            }
        }
    }

    public var usage: CacheUsage {
        state.withLock { state in
            CacheUsage(
                bytes: state.totalBytes + state.doomedBytes,
                count: state.records.count,
                pinnedBytes: state.pinnedBytes + state.doomedBytes,
                bytesByTier: state.tierBytes.filter { $0.value > 0 },
                byteLimit: state.limits.bytes
            )
        }
    }

    public var limits: CacheLimits { state.withLock { $0.limits } }

    public var statistics: CacheStatistics { state.withLock { $0.statistics } }

    /// Unleased keys of `tier`, least recently used first.
    func orderedKeys(in tier: CacheTier) -> [String] {
        state.withLock { $0.lru.list(tier).ordered }
    }

    // MARK: - Internals

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
        }
    }

    private func objectURL(_ file: String) -> URL { objects.appending(path: file) }

    private func delete(_ files: [String]) {
        for file in files {
            try? FileManager.default.removeItem(at: objectURL(file))
        }
    }

    private func flushIfNeeded() {
        let due = state.withLock { $0.changesSinceFlush >= flushThreshold }
        if due { flush() }
    }

    /// A cheap early refusal, so a write that cannot fit costs no I/O. The
    /// authoritative check runs again under the lock in `commit`.
    private func admits(size: Int, key: String, tier: CacheTier) -> Bool {
        state.withLock { state in
            let storedTier = max(state.records[key]?.tier ?? tier, tier)
            if size > state.limits.bytes { return false }
            if storedTier == .speculative, size > state.limits.speculativeBytes { return false }
            return true
        }
    }

    private func commit(staged: URL, file: String, size: Int, key: String, tier: CacheTier, expiresAt: Date?) throws -> Bool {
        let final = objectURL(file)
        let now = clock.now
        let lifetime = speculativeLifetime
        var moveError: (any Error)?
        let outcome: (kept: Bool, garbage: [String]) = state.withLock { state in
            let existing = state.records[key]
            let storedTier = max(existing?.tier ?? tier, tier)
            if size > state.limits.bytes || (storedTier == .speculative && size > state.limits.speculativeBytes) {
                return (false, [])
            }
            // The rename runs under the lock, so a wipe's swap of `objects`
            // can never fall between the file landing and its record.
            do {
                try FileManager.default.moveItem(at: staged, to: final)
            } catch {
                moveError = error
                return (false, [])
            }
            // The old file goes, or waits for its leases (a player reading it).
            let garbage = state.remove(key)
            var record = Record(key: key, file: file, size: size, tier: storedTier, created: now)
            record.expiresAt = expiresAt
            if storedTier == .speculative {
                record.speculativeDeadline = now.addingTimeInterval(lifetime)
            }
            record.touch(now: now, order: state.takeOrder())
            state.records[key] = record
            state.link(key, record)
            state.markChanged(structural: true)
            let evicted = state.enforceLimits(protecting: key, ceiling: storedTier == .speculative ? .recent : .retained, reason: .budget)
            let kept = state.records[key]?.file == file
            // Same fates as `MemoryCache.store`: the speculative entry this
            // write replaced was used if a higher tier took its place.
            if let existing, existing.tier == .speculative {
                if kept, storedTier != .speculative {
                    state.statistics.speculative.recordUsed(bytes: existing.size)
                } else {
                    state.statistics.speculative.recordDiscarded(bytes: existing.size)
                }
            }
            if kept, storedTier == .speculative {
                state.statistics.speculative.recordStored(bytes: size)
            }
            return (kept, garbage + evicted)
        }
        if let moveError {
            try? FileManager.default.removeItem(at: staged)
            throw moveError
        }
        if !outcome.kept, FileManager.default.fileExists(atPath: staged.path) {
            // Refused before the move.
            try? FileManager.default.removeItem(at: staged)
        }
        delete(outcome.garbage)
        flushIfNeeded()
        return outcome.kept
    }

    private func resolve(_ key: String) -> (url: URL, file: String)? {
        let now = clock.now
        let outcome: (file: String?, garbage: [String]) = state.withLock { state in
            guard var record = state.records[key] else {
                state.statistics.misses += 1
                return (nil, [])
            }
            let leased = state.leases[key] != nil
            if !leased, record.isExpired(at: now, idle: idleLifetime) {
                state.statistics.recordRemoval(.expiry, bytes: record.size, wasSpeculative: record.tier == .speculative)
                state.statistics.misses += 1
                state.markChanged(structural: true)
                return (nil, state.remove(key))
            }
            if record.tier == .speculative {
                state.statistics.speculative.recordUsed(bytes: record.size)
            }
            if !leased { state.unlink(key, record) }
            record.promote()
            record.touch(now: now, order: state.takeOrder())
            state.records[key] = record
            if !leased { state.link(key, record) }
            state.statistics.hits += 1
            state.markChanged(structural: false)
            return (record.file, [])
        }
        delete(outcome.garbage)
        return outcome.file.map { (objectURL($0), $0) }
    }

    /// The file was deleted behind the store's back (iOS purging `Caches`).
    private func dropVanished(key: String, file: String) {
        state.withLock { state in
            guard let record = state.records[key], record.file == file, state.leases[key] == nil else { return }
            if record.tier == .speculative {
                state.statistics.speculative.recordDiscarded(bytes: record.size)
            }
            _ = state.remove(key)
            state.markChanged(structural: true)
        }
    }

    private func endLease(key: String, file: String) {
        let garbage: [String] = state.withLock { state in
            if let record = state.records[key], record.file == file, let count = state.leases[key] {
                if count > 1 {
                    state.leases[key] = count - 1
                    return []
                }
                state.leases[key] = nil
                state.link(key, record)
                return state.enforceLimits(protecting: nil, ceiling: .retained, reason: .budget)
            }
            // The entry was replaced or wiped while leased: its file waited for us.
            guard var doomed = state.doomed[file] else { return [] }
            doomed.leases -= 1
            if doomed.leases > 0 {
                state.doomed[file] = doomed
                return []
            }
            state.doomed[file] = nil
            state.doomedBytes -= doomed.size
            return [file]
        }
        delete(garbage)
    }

    /// Loads and reconciles the index with the files on disk.
    private static func recover(indexURL: URL, objects: URL, now: Date, idle idleLifetime: TimeInterval?) -> (records: [String: Record], nextOrder: UInt64, changed: Bool) {
        let fileManager = FileManager.default
        var sizes: [String: Int] = [:]
        let listing = (try? fileManager.contentsOfDirectory(at: objects, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in listing {
            sizes[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        }
        var records: [String: Record] = [:]
        var nextOrder: UInt64 = 0
        var changed = false
        if let data = try? Data(contentsOf: indexURL) {
            if let index = try? JSONDecoder().decode(IndexFile.self, from: data), index.format == IndexFile.currentFormat {
                nextOrder = index.nextOrder
                for record in index.records {
                    guard sizes[record.file] == record.size, !record.isExpired(at: now, idle: idleLifetime) else {
                        changed = true
                        continue
                    }
                    if let duplicate = records[record.key], duplicate.order > record.order {
                        changed = true
                        continue
                    }
                    records[record.key] = record
                    nextOrder = max(nextOrder, record.order + 1)
                }
            } else {
                // Unreadable: start empty. The files are unnamed without it.
                changed = true
            }
        } else if !sizes.isEmpty {
            changed = true
        }
        let referenced = Set(records.values.map(\.file))
        for file in sizes.keys where !referenced.contains(file) {
            try? fileManager.removeItem(at: objects.appending(path: file))
            changed = true
        }
        return (records, nextOrder, changed)
    }

    // MARK: - Records

    struct Record: Codable, Equatable {
        let key: String
        let file: String
        let size: Int
        var tier: CacheTier
        let created: Date
        var lastAccess: Date
        /// Monotonic use order: breaks ties between equal `lastAccess` dates.
        var order: UInt64 = 0
        var speculativeDeadline: Date?
        var expiresAt: Date?

        init(key: String, file: String, size: Int, tier: CacheTier, created: Date) {
            self.key = key
            self.file = file
            self.size = size
            self.tier = tier
            self.created = created
            self.lastAccess = created
        }

        func isExpired(at now: Date, idle idleLifetime: TimeInterval?) -> Bool {
            if let expiresAt, expiresAt <= now { return true }
            if tier == .speculative, let speculativeDeadline, speculativeDeadline <= now { return true }
            if let idleLifetime, lastAccess.addingTimeInterval(idleLifetime) <= now { return true }
            return false
        }

        mutating func promote() {
            guard tier == .speculative else { return }
            tier = .recent
            speculativeDeadline = nil
        }

        mutating func touch(now: Date, order: UInt64) {
            lastAccess = now
            self.order = order
        }
    }

    struct IndexFile: Codable {
        static let currentFormat = 1
        var format = IndexFile.currentFormat
        var nextOrder: UInt64
        var records: [Record]
    }

    private struct Doomed {
        var leases: Int
        let size: Int
    }

    private struct State {
        var records: [String: Record]
        /// Lease counts. A leased record is in no LRU list.
        var leases: [String: Int] = [:]
        /// Files of entries removed or replaced while leased, by file name.
        var doomed: [String: Doomed] = [:]
        var lru = TieredLRU<String>()
        var tierBytes: [CacheTier: Int] = [:]
        /// Bytes of every record, leased or not (doomed files excluded).
        var totalBytes = 0
        var pinnedBytes = 0
        var doomedBytes = 0
        var limits: CacheLimits
        var nextOrder: UInt64
        var dirty = false
        var changesSinceFlush = 0
        var statistics = CacheStatistics()

        init(limits: CacheLimits, records: [String: Record], nextOrder: UInt64) {
            self.limits = limits
            self.records = records
            self.nextOrder = nextOrder
            for record in records.values.sorted(by: { $0.order < $1.order }) {
                link(record.key, record)
                // Speculative entries a previous run left count as stored,
                // so their fates balance.
                if record.tier == .speculative {
                    statistics.speculative.recordStored(bytes: record.size)
                }
            }
        }

        mutating func takeOrder() -> UInt64 {
            defer { nextOrder += 1 }
            return nextOrder
        }

        /// `structural`: the set of files changed (counts toward a flush);
        /// otherwise only access times did.
        mutating func markChanged(structural: Bool) {
            dirty = true
            if structural { changesSinceFlush += 1 }
        }

        mutating func link(_ key: String, _ record: Record) {
            if leases[key] == nil {
                totalBytes += record.size
                lru.append(key, tier: record.tier)
                tierBytes[record.tier, default: 0] += record.size
            } else {
                totalBytes += record.size
                pinnedBytes += record.size
            }
        }

        mutating func unlink(_ key: String, _ record: Record) {
            totalBytes -= record.size
            if leases[key] == nil {
                lru.remove(key, tier: record.tier)
                tierBytes[record.tier, default: 0] -= record.size
            } else {
                pinnedBytes -= record.size
            }
        }

        /// Removes `key`'s record. Returns the file to delete now, or nothing
        /// if leases still read it (it is doomed until they end).
        mutating func remove(_ key: String) -> [String] {
            guard let record = records[key] else { return [] }
            unlink(key, record)
            records[key] = nil
            if let count = leases.removeValue(forKey: key) {
                doomed[record.file] = Doomed(leases: count, size: record.size)
                doomedBytes += record.size
                return []
            }
            return [record.file]
        }

        private mutating func evict(_ key: String, reason: CacheEvictionReason) -> [String] {
            if let record = records[key] {
                statistics.recordRemoval(reason, bytes: record.size, wasSpeculative: record.tier == .speculative)
            }
            return remove(key)
        }

        mutating func enforceLimits(protecting: String?, ceiling: CacheTier, reason: CacheEvictionReason) -> [String] {
            var garbage: [String] = []
            while tierBytes[.speculative, default: 0] > limits.speculativeBytes,
                  let victim = lru.victim(upTo: .speculative, excluding: protecting) {
                garbage += evict(victim, reason: reason)
            }
            // Doomed files still take disk space until their leases end.
            while totalBytes + doomedBytes > limits.bytes,
                  let victim = lru.victim(upTo: ceiling, excluding: protecting) {
                garbage += evict(victim, reason: reason)
            }
            if !garbage.isEmpty { markChanged(structural: true) }
            guard let protecting, let record = records[protecting], leases[protecting] == nil else { return garbage }
            let overSpeculative = record.tier == .speculative && tierBytes[.speculative, default: 0] > limits.speculativeBytes
            if overSpeculative || totalBytes + doomedBytes > limits.bytes {
                garbage += remove(protecting)
                markChanged(structural: true)
            }
            return garbage
        }
    }
}
