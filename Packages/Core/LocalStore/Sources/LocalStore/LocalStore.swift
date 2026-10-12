import CacheKit
import Foundation
import GRDB
import OSLog
import Synchronization

/// The device's copies of server data, in one SQLite file: entities (posts,
/// profiles, counters) as protobuf bytes, and lists (timelines, grids,
/// threads) as pages of entity keys with their cursors. What lets every tab
/// open on its last content at cold start, then revalidate (#893).
///
/// - **Cache, then network.** Repositories read a list here first, then write
///   every network page back in one transaction (`replaceList` for a first
///   page, `appendPage` for the pages after it). The cursor after the last
///   stored page is persisted, so paging goes on after a relaunch.
/// - **One row per entity.** Lists hold keys. A post in For You and in
///   Following is one row; whichever list fetched it last wrote the copy both
///   read (the EntityStore, #896, observes these rows).
/// - **Viewer-scoped.** The rows belong to one viewer (`LocalStoreViewer`),
///   recorded in the file. Nothing is readable by anyone else: a read as
///   another person answers nothing and schedules the wipe, a write as another
///   person wipes first, and a write captured for a viewer who has since left
///   is dropped. A logout, an account switch or a profile switch also wipes
///   through `removeAll()` (the coordinator's `.viewerChanged`).
/// - **Budgeted.** A `ManagedCache` in the `.localStore` disk pool (100 MB in
///   Automatic). Over budget, the lowest tier goes first, least recently used
///   first: a list loses its tail pages before its first page, a first page of
///   a tab (`retained`) goes last. Expired rows are swept on `trim(.expired)`
///   (every background).
/// - **Versioned.** `LocalStoreSchema` migrates forward. A file written by a
///   build that knows migrations this one does not, or a file SQLite cannot
///   open, is deleted and recreated empty: a cache never reads a schema it
///   does not know.
/// - **Private.** Under `Caches/`, excluded from backup, data protection
///   `completeUntilFirstUserAuthentication`, deleted rows zeroed
///   (`secure_delete`).
///
/// Every method may be called from any thread. Reads are synchronous and run
/// on one of the pool's reader connections, in parallel with the writer (WAL):
/// cheap enough for a first frame (one list page is one indexed query).
/// Writes are synchronous too, serialised on the one writer; call them off
/// the main thread.
public final class LocalStore: ManagedCache {
    public static let defaultNamespace = CacheNamespace(
        "localStore", category: .other, scope: .viewer, priorityClass: .preferred
    )

    /// Cost of a row beyond its payload (keys, timestamps, index entries),
    /// so a budget of N bytes is close to N bytes of file.
    static let entityOverhead = 96
    static let itemOverhead = 48
    static let pageOverhead = 64

    public let namespace: CacheNamespace
    public let diskBudget: DiskBudget
    public var budget: CacheBudget { .disk(diskBudget) }
    /// `<directory>/store.sqlite`.
    public let fileURL: URL

    private let pool: DatabasePool
    private let viewer: @Sendable () -> LocalStoreViewer?
    private let clock: any CacheClock
    private let state: Mutex<State>
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "local-store")

    private struct State {
        /// Whose rows the file holds; nil when it holds none.
        var owner: LocalStoreViewer?
        var limits: CacheLimits
        var statistics = CacheStatistics()
    }

    /// `Caches/LocalStore`: purgeable by iOS, never backed up.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalStore", directoryHint: .isDirectory)
    }

    /// Opens (or creates) the store.
    ///
    /// - Parameters:
    ///   - directory: where the file lives; `defaultDirectory` in the app,
    ///     a temporary folder in tests.
    ///   - viewer: who is using the app now, asked on every read and write
    ///     (the app maps `StorageScope.shared.owner`). Must be cheap and
    ///     must not call back into the store.
    ///   - limits: until the coordinator sets its own, the Automatic budget.
    public convenience init(
        directory: URL = LocalStore.defaultDirectory,
        viewer: @escaping @Sendable () -> LocalStoreViewer?,
        limits: CacheLimits = CacheLimits(bytes: DiskPool.localStore.automaticBytes, speculativeShare: CacheCoordinator.speculativeShare),
        clock: any CacheClock = SystemCacheClock(),
        namespace: CacheNamespace = LocalStore.defaultNamespace,
        budget: DiskBudget = DiskBudget(pool: .localStore)
    ) throws {
        try self.init(
            directory: directory, viewer: viewer, limits: limits, clock: clock,
            namespace: namespace, budget: budget, migrator: LocalStoreSchema.migrator()
        )
    }

    init(
        directory: URL,
        viewer: @escaping @Sendable () -> LocalStoreViewer?,
        limits: CacheLimits,
        clock: any CacheClock,
        namespace: CacheNamespace,
        budget: DiskBudget,
        migrator: DatabaseMigrator
    ) throws {
        let fileManager = FileManager.default
        var folder = directory
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        try folder.setResourceValues(exclusion)
        // New files in the folder (the -wal and -shm files SQLite creates
        // later) take the folder's class.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path
        )
        let fileURL = folder.appending(path: "store.sqlite")

        self.fileURL = fileURL
        self.namespace = namespace
        self.diskBudget = budget
        self.viewer = viewer
        self.clock = clock
        self.pool = try Self.openPool(at: fileURL, migrator: migrator)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path
        )
        let owner = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'owner'").flatMap(LocalStoreViewer.init(encoded:))
        }
        state = Mutex(State(owner: owner, limits: limits))
    }

    // MARK: - Opening

    /// Opens and migrates the file; a file that is not a database, is
    /// corrupt, or that a newer schema wrote, is deleted and recreated once.
    ///
    /// ⚠️ ONLY those. Any other failure (a lock held a moment too long, an I/O
    /// error) is thrown, and the app runs without the store for this launch:
    /// deleting a healthy file on a transient error would throw away every
    /// tab's last content for nothing.
    static func openPool(at url: URL, migrator: DatabaseMigrator) throws -> DatabasePool {
        do {
            return try openAndMigrate(at: url, migrator: migrator)
        } catch let error where isUnreadable(error) {
            Logger(subsystem: "cn.wynn.core-platform-ios", category: "local-store")
                .error("local store reset: \(String(describing: error), privacy: .public)")
            deleteFiles(at: url)
            return try openAndMigrate(at: url, migrator: migrator)
        }
    }

    private static func isUnreadable(_ error: any Error) -> Bool {
        if error is SupersededSchema { return true }
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT
    }

    private struct SupersededSchema: Error {}

    private static func openAndMigrate(at url: URL, migrator: DatabaseMigrator) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "LocalStore"
        configuration.maximumReaderCount = 4
        // A connection waits a moment for a lock rather than failing at once
        // (a checkpoint, the writer finishing a page).
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            // Deleted rows are zeroed where it costs no extra I/O: a wiped
            // viewer's bytes do not linger in free pages.
            try db.execute(sql: "PRAGMA secure_delete = FAST")
            // Before the first table exists (and before WAL is set up), so
            // freed pages go back to the file system after a trim or a wipe.
            // A no-op on an existing file.
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                // The log is reused after each checkpoint; past this size it
                // is cut back, so a burst of pages never leaves it large.
                try db.execute(sql: "PRAGMA journal_size_limit = \(Self.journalSizeLimit)")
            }
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        do {
            let superseded = try pool.read { db in try migrator.hasBeenSuperseded(db) }
            guard !superseded else { throw SupersededSchema() }
            try migrator.migrate(pool)
            return pool
        } catch {
            try? pool.close()
            throw error
        }
    }

    private static func deleteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: - Viewer

    /// Who is using the app now: what a repository captures BEFORE its network
    /// call and passes to the write, so a page fetched for someone who has
    /// since left is dropped.
    public var currentViewer: LocalStoreViewer? { viewer() }

    /// Whether the rows may be read by whoever is here now. A store holding
    /// someone else's rows answers no, and wipes them in the background.
    private func admitsRead() -> Bool {
        guard let current = viewer() else { return false }
        guard let owner = state.withLock({ $0.owner }) else { return false }
        if owner.isSamePerson(as: current) { return true }
        pool.asyncWriteWithoutTransaction { [weak self] db in
            guard let self, let current = viewer(),
                  let owner = state.withLock({ $0.owner }), !owner.isSamePerson(as: current) else { return }
            try? db.inTransaction {
                try deleteEverything(db)
                return .commit
            }
            state.withLock { $0.owner = nil }
            try? compact(db, truncatingLog: true)
        }
        return false
    }

    /// Inside the write's transaction: drops a write captured for someone who
    /// is no longer here, wipes another person's rows, and records the owner.
    ///
    /// - Returns: the owner once the write commits; nil to drop the write.
    private func admitWrite(_ db: Database, as writer: LocalStoreViewer?) throws -> LocalStoreViewer? {
        guard let writer, let current = viewer(), writer.isSamePerson(as: current) else { return nil }
        let arriving = current.merged(with: writer)
        let stored = state.withLock { $0.owner }
        var owner = arriving
        if let stored {
            if stored.isSamePerson(as: arriving) {
                owner = stored.merged(with: arriving)
            } else {
                try deleteEverything(db)
            }
        }
        if owner != stored {
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('owner', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [owner.encoded]
            )
        }
        return owner
    }

    /// What a write put in the store, for the budget that follows it.
    struct Footprint {
        /// The page written, kept over everything else of its tier or below:
        /// a write never evicts what it just wrote unless nothing else can go.
        var page: (list: String, index: Int)?
        /// A write never displaces content of a higher tier.
        var tier: CacheTier
    }

    /// Runs `body` in one write transaction if `writer` may write, then
    /// enforces the budget. The owner is published once committed.
    ///
    /// - Returns: whether what `body` wrote is in the store: false when the
    ///   write was dropped, when `body` wrote nothing (nil), or when it did
    ///   not fit the budget and went again.
    private func write(as writer: LocalStoreViewer?, _ body: (Database, Date) throws -> Footprint?) throws -> Bool {
        let now = clock.now
        let currentLimits = state.withLock { $0.limits }
        let outcome: (owner: LocalStoreViewer, evicted: Int, kept: Bool)? = try pool.write { db in
            guard let owner = try admitWrite(db, as: writer) else { return nil }
            guard let footprint = try body(db, now) else { return (owner, 0, false) }
            let budget = try enforce(db, limits: currentLimits, now: now, protecting: footprint.page, ceiling: footprint.tier)
            return (owner, budget.evicted, budget.fits)
        }
        guard let outcome else { return false }
        state.withLock {
            $0.owner = outcome.owner
            $0.statistics.evictions += outcome.evicted
        }
        if outcome.evicted > 0 { compactLater() }
        return outcome.kept
    }

    // MARK: - Reading

    /// A stored list, its entities in order (missing or expired ones left
    /// out) and the cursor after the last page read. nil when nothing is
    /// stored, the list expired, or the rows are not this viewer's. A read is
    /// a USE: the list moves up the LRU, and prefetched pages read become
    /// `recent`.
    ///
    /// - Parameter maxPages: the first pages only. A screen opening on its
    ///   last content reads its FIRST page (what its first load will answer
    ///   again), with that page's cursor; `page(of:after:)` serves the rest.
    public func list(_ key: String, maxPages: Int? = nil) -> LocalList? {
        let limit = max(1, maxPages ?? Int.max)
        return read(key) { db, now in
            guard let last = try Row.fetchOne(
                db.cachedStatement(sql: """
                    SELECT page_index, next_cursor FROM list_page WHERE list_key = ? AND page_index < ?
                    ORDER BY page_index DESC LIMIT 1
                    """),
                arguments: [key, limit]
            ) else { return nil }
            let lastIndex: Int = last[0]
            return (0...lastIndex, last[1])
        }
    }

    /// The stored page that the network would answer for `cursor`: the page
    /// after the one whose cursor `cursor` is. What a list pages through when
    /// the network cannot answer (offline after a cold start). Its entries
    /// only; its attachments with those of the pages before it.
    public func page(of key: String, after cursor: String) -> LocalList? {
        read(key) { db, now in
            guard let page = try Row.fetchOne(
                db.cachedStatement(sql: """
                    SELECT p.page_index, p.next_cursor FROM list_page p
                    JOIN list_page previous ON previous.list_key = p.list_key AND previous.page_index = p.page_index - 1
                    WHERE p.list_key = ? AND previous.next_cursor = ?
                    """),
                arguments: [key, cursor]
            ) else { return nil }
            let index: Int = page[0]
            return (index...index, page[1])
        }
    }

    /// Reads the entries of the pages `locate` names, with every attachment up
    /// to the last of them, and counts the read as a use.
    private func read(
        _ key: String,
        locate: (Database, Date) throws -> (pages: ClosedRange<Int>, nextCursor: String?)?
    ) -> LocalList? {
        guard admitsRead() else { return nil }
        let now = clock.now
        let answer: (list: LocalList, through: Int)? = try? pool.read { db in
            guard let header = try Row.fetchOne(
                db.cachedStatement(sql: "SELECT fetched_at, expires_at FROM list WHERE key = ?"), arguments: [key]
            ) else { return nil }
            let expiresAt: Double = header[1]
            guard expiresAt > now.timeIntervalSince1970, let located = try locate(db, now) else { return nil }
            let rows = try Row.fetchAll(
                db.cachedStatement(sql: """
                    SELECT i.entity_type, i.entity_id, e.payload, e.format, e.fetched_at, e.expires_at, i.role, i.page_index
                    FROM list_item i
                    JOIN entity e ON e.type = i.entity_type AND e.id = i.entity_id
                    WHERE i.list_key = ? AND i.page_index <= ? AND e.expires_at > ?
                    ORDER BY i.position
                    """),
                arguments: [key, located.pages.upperBound, now.timeIntervalSince1970]
            )
            var entries: [LocalEntity] = []
            var attachments: [LocalEntityKey: LocalEntity] = [:]
            for row in rows {
                let entity = Self.entity(from: row)
                if (row[6] as Int) == Self.entryRole {
                    if located.pages.contains(row[7]) { entries.append(entity) }
                } else {
                    attachments[entity.key] = entity
                }
            }
            let decoded = LocalList(
                key: key,
                entries: entries,
                attachments: attachments,
                nextCursor: located.nextCursor,
                pageCount: located.pages.count,
                fetchedAt: Date(timeIntervalSince1970: header[0])
            )
            return (decoded, located.pages.upperBound)
        }
        let list = answer?.list
        state.withLock {
            if list == nil { $0.statistics.misses += 1 } else { $0.statistics.hits += 1 }
        }
        if let through = answer?.through {
            pool.asyncWriteWithoutTransaction { db in
                try? db.execute(
                    sql: """
                        UPDATE list SET accessed_at = ? WHERE key = ?;
                        UPDATE list_page SET tier = ? WHERE list_key = ? AND tier = ? AND page_index <= ?;
                        """,
                    arguments: [
                        now.timeIntervalSince1970, key,
                        CacheTier.recent.storedRank, key, CacheTier.speculative.storedRank, through
                    ]
                )
            }
        }
        return list
    }

    /// The stored entities among `keys` (missing and expired ones left out).
    public func entities(_ keys: [LocalEntityKey]) -> [LocalEntityKey: LocalEntity] {
        guard !keys.isEmpty, admitsRead() else { return [:] }
        let now = clock.now
        let found: [LocalEntityKey: LocalEntity] = (try? pool.read { db in
            var matches: [LocalEntityKey: LocalEntity] = [:]
            for (type, ids) in Dictionary(grouping: keys, by: \.type) {
                let unique = Array(Set(ids.map(\.id)))
                // SQLite's default limit is 32,766 bound variables.
                for start in stride(from: 0, to: unique.count, by: 500) {
                    let chunk = Array(unique[start..<min(start + 500, unique.count)])
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    var arguments: StatementArguments = [type, now.timeIntervalSince1970]
                    arguments += StatementArguments(chunk)
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT type, id, payload, format, fetched_at, expires_at FROM entity
                        WHERE type = ? AND expires_at > ? AND id IN (\(marks))
                        """, arguments: arguments)
                    for row in rows {
                        let entity = Self.entity(from: row)
                        matches[entity.key] = entity
                    }
                }
            }
            return matches
        }) ?? [:]
        state.withLock {
            $0.statistics.hits += found.count
            $0.statistics.misses += Set(keys).count - found.count
        }
        if !found.isEmpty {
            let touched = Array(found.keys)
            pool.asyncWriteWithoutTransaction { db in
                guard let statement = try? db.cachedStatement(sql: "UPDATE entity SET accessed_at = ? WHERE type = ? AND id = ?") else { return }
                try? db.inTransaction {
                    for key in touched {
                        try statement.execute(arguments: [now.timeIntervalSince1970, key.type, key.id])
                    }
                    return .commit
                }
            }
        }
        return found
    }

    public func entity(_ key: LocalEntityKey) -> LocalEntity? {
        entities([key])[key]
    }

    private static func entity(from row: Row) -> LocalEntity {
        LocalEntity(
            key: LocalEntityKey(type: row[0], id: row[1]),
            payload: row[2],
            format: row[3],
            fetchedAt: Date(timeIntervalSince1970: row[4]),
            expiresAt: Date(timeIntervalSince1970: row[5])
        )
    }

    // MARK: - Writing

    /// Replaces `key` with its first page: what a first load or a refresh
    /// answered. The page's entities are written in the same transaction.
    ///
    /// - Returns: false when the page is not stored: `writer` is nobody, or
    ///   is no longer the person using the app (the write is dropped), or the
    ///   page does not fit the budget beside content of a higher tier.
    @discardableResult
    public func replaceList(
        _ key: String, with page: LocalListPage, as writer: LocalStoreViewer?,
        lifetime: TimeInterval = LocalStorePolicy.listLifetime
    ) throws -> Bool {
        try write(as: writer) { db, now in
            // The old pages go first, with the entities only they held; those
            // the new page carries again are written back just below.
            try deletePages(of: key, from: 0, in: db)
            try upsert(page.entities, in: db, now: now, tier: .speculative)
            try db.execute(
                sql: "INSERT INTO list (key, fetched_at, expires_at, accessed_at) VALUES (?, ?, ?, ?)",
                arguments: [key, now.timeIntervalSince1970, now.addingTimeInterval(lifetime).timeIntervalSince1970, now.timeIntervalSince1970]
            )
            try insertPage(page, index: 0, tier: page.tier, firstPosition: 0, list: key, in: db, now: now)
            return Footprint(page: (key, 0), tier: page.tier)
        }
    }

    /// Appends the page fetched with `cursor` after the last stored page of
    /// `key`. Entries already in the list are skipped (first occurrence kept).
    ///
    /// - Returns: false when the page is not stored: the list is gone
    ///   (expired, evicted, wiped, replaced by a refresh) or `cursor` is no
    ///   longer the one after its last page, so this page does not follow what
    ///   is stored; or for the reasons `replaceList` gives. The list's cursor
    ///   is then still where its stored pages stop.
    @discardableResult
    public func appendPage(_ page: LocalListPage, to key: String, after cursor: String, as writer: LocalStoreViewer?) throws -> Bool {
        try write(as: writer) { db, now in
            guard let last = try Row.fetchOne(
                db.cachedStatement(sql: """
                    SELECT p.page_index, p.next_cursor, p.tier,
                           (SELECT IFNULL(MAX(position), -1) FROM list_item WHERE list_key = p.list_key)
                    FROM list_page p JOIN list l ON l.key = p.list_key
                    WHERE p.list_key = ? AND l.expires_at > ?
                    ORDER BY p.page_index DESC LIMIT 1
                    """),
                arguments: [key, now.timeIntervalSince1970]
            ), (last[1] as String?) == cursor else { return nil }
            try upsert(page.entities, in: db, now: now, tier: .speculative)
            // Never above the page before it, so evicting a list from its tail
            // always keeps what is left contiguous.
            let tier = min(page.tier, CacheTier(storedRank: last[2]))
            let index = (last[0] as Int) + 1
            try insertPage(page, index: index, tier: tier, firstPosition: (last[3] as Int) + 1, list: key, in: db, now: now)
            return Footprint(page: (key, index), tier: tier)
        }
    }

    /// Writes entities on their own (a visited profile, a post opened from a
    /// link), kept at `tier` while no list holds them.
    @discardableResult
    public func write(_ entities: [LocalEntityWrite], as writer: LocalStoreViewer?) throws -> Bool {
        guard !entities.isEmpty else { return true }
        return try write(as: writer) { db, now in
            try upsert(entities, in: db, now: now, tier: nil)
            return Footprint(page: nil, tier: entities.map(\.tier).max() ?? .recent)
        }
    }

    /// Forgets entities the server no longer serves (a deleted post): every
    /// list that held them skips them from now on.
    public func removeEntities(_ keys: [LocalEntityKey]) throws {
        guard !keys.isEmpty else { return }
        try pool.write { db in
            let statement = try db.cachedStatement(sql: "DELETE FROM entity WHERE type = ? AND id = ?")
            for key in keys {
                try statement.execute(arguments: [key.type, key.id])
            }
        }
    }

    public func removeList(_ key: String) throws {
        try pool.write { db in
            try deletePages(of: key, from: 0, in: db)
        }
    }

    /// `tier` nil: each write's own tier (entities written on their own).
    /// Otherwise the entities ride with a page: an entity already kept on its
    /// own keeps its higher tier.
    private func upsert(_ entities: [LocalEntityWrite], in db: Database, now: Date, tier: CacheTier?) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO entity (type, id, format, payload, size, tier, fetched_at, expires_at, accessed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(type, id) DO UPDATE SET
                format = excluded.format,
                payload = excluded.payload,
                size = excluded.size,
                tier = MAX(entity.tier, excluded.tier),
                fetched_at = excluded.fetched_at,
                expires_at = excluded.expires_at,
                accessed_at = excluded.accessed_at
            """)
        for entity in entities {
            let size = entity.payload.count + entity.key.type.utf8.count + entity.key.id.utf8.count + Self.entityOverhead
            try statement.execute(arguments: [
                entity.key.type, entity.key.id, entity.format, entity.payload, size,
                (tier ?? entity.tier).storedRank,
                now.timeIntervalSince1970, now.addingTimeInterval(entity.lifetime).timeIntervalSince1970,
                now.timeIntervalSince1970
            ])
        }
    }

    private func insertPage(
        _ page: LocalListPage, index: Int, tier: CacheTier, firstPosition: Int, list key: String, in db: Database, now: Date
    ) throws {
        try db.execute(
            sql: "INSERT INTO list_page (list_key, page_index, tier, item_count, next_cursor, fetched_at) VALUES (?, ?, ?, 0, ?, ?)",
            arguments: [key, index, tier.storedRank, page.nextCursor, now.timeIntervalSince1970]
        )
        // OR IGNORE: a key already in the list (`list_item_once`) stays on
        // the page that first carried it.
        let insert = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO list_item (list_key, position, page_index, role, entity_type, entity_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        var position = firstPosition
        let entryKeys = Set(page.items)
        let attached = page.entities.map(\.key).filter { !entryKeys.contains($0) }
        for (role, keys) in [(Self.entryRole, page.items), (Self.attachmentRole, attached)] {
            for item in keys {
                try insert.execute(arguments: [key, position, index, role, item.type, item.id])
                guard db.changesCount > 0 else { continue }
                position += 1
            }
        }
        try db.execute(
            sql: "UPDATE list_page SET item_count = ? WHERE list_key = ? AND page_index = ?",
            arguments: [position - firstPosition, key, index]
        )
    }

    static let entryRole = 0
    static let attachmentRole = 1

    // MARK: - ManagedCache

    public var usage: CacheUsage {
        let limit = state.withLock { $0.limits.bytes }
        let measured: CacheUsage? = try? pool.read { db in
            var byTier: [CacheTier: Int] = [:]
            // An entity a list holds counts in the highest tier holding it;
            // one no list holds, in its own.
            let entityRows = try Row.fetchAll(db, sql: """
                SELECT IFNULL((SELECT MAX(p.tier) FROM list_item i
                               JOIN list_page p ON p.list_key = i.list_key AND p.page_index = i.page_index
                               WHERE i.entity_type = e.type AND i.entity_id = e.id), e.tier),
                       SUM(e.size), COUNT(*)
                FROM entity e GROUP BY 1
                """)
            var count = 0
            for row in entityRows {
                byTier[CacheTier(storedRank: row[0]), default: 0] += row[1] as Int
                count += row[2] as Int
            }
            for row in try Row.fetchAll(db, sql: "SELECT tier, SUM(\(Self.pageCostSQL("list_page"))) FROM list_page GROUP BY tier") {
                byTier[CacheTier(storedRank: row[0]), default: 0] += row[1] as Int
            }
            let bytes = byTier.values.reduce(0, +)
            return CacheUsage(bytes: bytes, count: count, pinnedBytes: 0, bytesByTier: byTier.filter { $0.value > 0 }, byteLimit: limit)
        }
        return measured ?? CacheUsage(byteLimit: limit)
    }

    public var limits: CacheLimits { state.withLock { $0.limits } }

    public var statistics: CacheStatistics { state.withLock { $0.statistics } }

    // The coordinator calls the maintenance below on whatever thread a signal
    // arrives (main, for the app's lifecycle): each returns at once and runs
    // on the writer's queue, in order with the writes around it.

    /// New limits take effect for every write from now on; the eviction they
    /// call for runs on the writer's queue.
    public func setLimits(_ limits: CacheLimits) {
        state.withLock { $0.limits = limits }
        let now = clock.now
        pool.asyncWriteWithoutTransaction { [weak self] db in
            guard let self else { return }
            do {
                var evicted = 0
                try db.inTransaction {
                    evicted = try enforce(db, limits: limits, now: now, protecting: nil, ceiling: .retained).evicted
                    return .commit
                }
                state.withLock { $0.statistics.evictions += evicted }
                if evicted > 0 { try compact(db, truncatingLog: false) }
            } catch {
                logger.error("local store budget failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func trim(_ depth: TrimDepth) {
        let now = clock.now
        pool.asyncWriteWithoutTransaction { [weak self] db in
            guard let self else { return }
            do {
                var counts = (expired: 0, evicted: 0)
                try db.inTransaction {
                    counts = try trimRows(db, depth: depth, now: now)
                    return .commit
                }
                state.withLock {
                    $0.statistics.expirations += counts.expired
                    $0.statistics.evictions += counts.evicted
                }
                if counts.expired + counts.evicted > 0 { try compact(db, truncatingLog: false) }
            } catch {
                logger.error("local store trim failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The wipe of a logout, an account or profile switch, or a Settings
    /// clear: every row, the owner included, and the freed pages returned to
    /// the file system.
    ///
    /// Returns at once, on any thread (the coordinator calls it on main): from
    /// this moment nothing is readable (the store holds no owner), and the
    /// rows are deleted on the writer's queue, ahead of any write made after
    /// this call.
    public func removeAll() {
        state.withLock { $0.owner = nil }
        pool.asyncWriteWithoutTransaction { [weak self] db in
            guard let self else { return }
            do {
                try db.inTransaction {
                    try deleteEverything(db)
                    return .commit
                }
                // A write admitted before this call may have published its
                // owner since: the rows are gone, so is the owner.
                state.withLock { $0.owner = nil }
                try compact(db, truncatingLog: true)
            } catch {
                logger.error("local store wipe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Moves the write-ahead log into the file and empties it (when the app
    /// goes to the background). Skipped, not waited for, while a read runs.
    public func flush() {
        pool.asyncWriteWithoutTransaction { db in
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    static let journalSizeLimit = 4 * 1_048_576

    // MARK: - Maintenance

    private func deleteEverything(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM list_item;
            DELETE FROM list_page;
            DELETE FROM list;
            DELETE FROM entity;
            DELETE FROM meta WHERE key = 'owner';
            """)
    }

    /// Gives freed pages back to the file system; `truncatingLog` also empties
    /// the write-ahead log, which still holds copies of deleted rows.
    private func compact(_ db: Database, truncatingLog: Bool) throws {
        try db.execute(sql: "PRAGMA incremental_vacuum")
        if truncatingLog {
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private func compactLater() {
        pool.asyncWriteWithoutTransaction { [weak self] db in
            try? self?.compact(db, truncatingLog: false)
        }
    }

    /// Waits until every write scheduled so far (wipes, budgets, trims,
    /// touches, compactions) has run. For tests, here and in the features
    /// that write through the store.
    public func waitForPendingWrites() {
        try? pool.writeWithoutTransaction { _ in }
    }

    /// The pool, for the EntityStore's observations (#896) and tests.
    var databasePool: DatabasePool { pool }

    /// What the file takes on disk now: the database and its log.
    public var fileBytes: Int {
        ["", "-wal"].reduce(0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path + suffix)
            return total + ((attributes?[.size] as? Int) ?? 0)
        }
    }
}

extension CacheTier {
    /// The rank stored in the file. Fixed numbers, never the enum's order:
    /// the file outlives the code.
    var storedRank: Int {
        switch self {
        case .speculative: 0
        case .recent: 1
        case .retained: 2
        }
    }

    init(storedRank: Int) {
        switch storedRank {
        case ...0: self = .speculative
        case 1: self = .recent
        default: self = .retained
        }
    }
}
