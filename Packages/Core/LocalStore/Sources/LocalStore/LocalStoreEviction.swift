import CacheKit
import Foundation
import GRDB

/// Budgets, trims and expiry, inside the writer's transactions.
///
/// What can go, lowest tier first and least recently used first:
/// - a list's PAGES, from its tail: evicting page k takes every page after it,
///   so what is left of a list is always its first k pages, and its cursor is
///   page k-1's (paging resumes exactly where the stored pages stop). The
///   entities only those pages held go with them.
/// - entities no list holds (written on their own), by their own tier.
/// - a transcript (a conversation's newest messages), whole. Transcripts are
///   `retained` (the last open conversations), so only a budget takes one,
///   least recently opened first.
///
/// Pages never outrank the page before them (`appendPage`), so the order
/// above always takes a list from its tail.
extension LocalStore {
    /// The cost of a page row beyond its entities, as SQL over `table`.
    static func pageCostSQL(_ table: String) -> String {
        "(\(table).item_count * \(itemOverhead) + \(pageOverhead) + IFNULL(length(\(table).next_cursor), 0))"
    }

    struct Victim {
        enum Kind {
            case page(list: String, index: Int)
            case entity(LocalEntityKey)
            case transcript(String)

            /// Within a tier and an age: loose entities, then transcripts,
            /// then pages.
            var rank: Int {
                switch self {
                case .entity: 0
                case .transcript: 1
                case .page: 2
                }
            }
        }

        let kind: Kind
        let tier: CacheTier
        let accessedAt: Double
        let bytes: Int

        /// Lowest tier first, least recently used first; within a list, its
        /// tail first; an entity no list holds before a page of equal rank.
        static func evictionOrder(_ lhs: Victim, _ rhs: Victim) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.accessedAt != rhs.accessedAt { return lhs.accessedAt < rhs.accessedAt }
            switch (lhs.kind, rhs.kind) {
            case let (.page(_, left), .page(_, right)): return left > right
            case let (.entity(left), .entity(right)): return (left.type, left.id) < (right.type, right.id)
            case let (.transcript(left), .transcript(right)): return left < right
            default: return lhs.kind.rank < rhs.kind.rank
            }
        }
    }

    // MARK: - Budget

    /// Evicts until the store fits `limits` (and its speculative pages fit
    /// their cap), never above `ceiling`, and the pages of `protecting`'s list
    /// (or the `transcript` written) last: if nothing else can go, the page
    /// just written goes (with the pages after it), or the transcript, and
    /// the write did not fit.
    func enforce(
        _ db: Database, limits: CacheLimits, now: Date,
        protecting written: (list: String, index: Int)?, transcript writtenTranscript: String?, ceiling: CacheTier
    ) throws -> (evicted: Int, fits: Bool) {
        var evicted = 0
        // A few rounds: a page shares entities with other lists, so what a
        // round frees is measured again rather than trusted.
        for _ in 0..<16 {
            let total = try totalBytes(db)
            let speculative = try speculativeBytes(db)
            let overTotal = total - limits.bytes
            let overSpeculative = speculative - limits.speculativeBytes
            guard overTotal > 0 || overSpeculative > 0 else { return (evicted, true) }
            var freedTotal = 0
            var freedSpeculative = 0
            var progress = false
            var gone: [String: Int] = [:]
            for victim in try victims(db, maximumTier: ceiling) {
                let needsTotal = freedTotal < overTotal
                let needsSpeculative = freedSpeculative < overSpeculative
                guard needsTotal || needsSpeculative else { break }
                if !needsTotal, victim.tier != .speculative { continue }
                if case .page(let list, let index) = victim.kind {
                    if list == written?.list { continue }
                    if let first = gone[list], index >= first { continue }
                    gone[list] = min(gone[list] ?? .max, index)
                }
                if case .transcript(let key) = victim.kind, key == writtenTranscript { continue }
                try delete(victim, in: db)
                freedTotal += victim.bytes
                if victim.tier == .speculative { freedSpeculative += victim.bytes }
                evicted += 1
                progress = true
            }
            guard progress else { break }
        }
        let fits = try totalBytes(db) <= limits.bytes && speculativeBytes(db) <= limits.speculativeBytes
        guard !fits else { return (evicted, fits) }
        if let written {
            // Never kept: what it counted as stored leaves as discarded.
            try deletePages(of: written.list, from: written.index, in: db, prefetchedFate: .discarded)
            return (evicted + 1, false)
        }
        if let writtenTranscript {
            try deleteTranscript(writtenTranscript, in: db)
            return (evicted + 1, false)
        }
        return (evicted, fits)
    }

    func totalBytes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT IFNULL((SELECT SUM(size) FROM entity), 0)
                 + IFNULL((SELECT SUM(\(Self.pageCostSQL("list_page"))) FROM list_page), 0)
                 + \(Self.transcriptBytesSQL)
            """) ?? 0
    }

    /// Every transcript's cost, as SQL: its items and its own row.
    static let transcriptBytesSQL = """
        (IFNULL((SELECT SUM(size) FROM transcript_item), 0) + (SELECT COUNT(*) FROM transcript) * \(transcriptOverhead))
        """

    /// Bytes of prefetched pages nobody read yet: their own cost and the
    /// entities only they hold.
    private func speculativeBytes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT IFNULL(SUM(\(Self.pageCostSQL("p")) + \(Self.exclusiveEntityBytesSQL)), 0)
            FROM list_page p WHERE p.tier = 0
            """) ?? 0
    }

    /// The bytes of the entities page `p` alone holds, as SQL.
    static let exclusiveEntityBytesSQL = """
        IFNULL((SELECT SUM(e.size) FROM list_item i
                JOIN entity e ON e.type = i.entity_type AND e.id = i.entity_id
                WHERE i.list_key = p.list_key AND i.page_index = p.page_index AND e.tier = 0
                  AND (SELECT COUNT(*) FROM list_item j
                       WHERE j.entity_type = e.type AND j.entity_id = e.id) = 1), 0)
        """

    /// Every evictable page and every entity no list holds, in eviction order.
    func victims(_ db: Database, maximumTier: CacheTier = .retained) throws -> [Victim] {
        var victims: [Victim] = []
        let pages = try Row.fetchAll(db, sql: """
            SELECT p.list_key, p.page_index, p.tier, l.accessed_at,
                   \(Self.pageCostSQL("p")) + \(Self.exclusiveEntityBytesSQL)
            FROM list_page p JOIN list l ON l.key = p.list_key
            WHERE p.tier <= ?
            """, arguments: [maximumTier.storedRank])
        for row in pages {
            victims.append(Victim(
                kind: .page(list: row[0], index: row[1]),
                tier: CacheTier(storedRank: row[2]), accessedAt: row[3], bytes: row[4]
            ))
        }
        let loose = try Row.fetchAll(db, sql: """
            SELECT type, id, tier, accessed_at, size FROM entity e
            WHERE e.tier <= ?
              AND NOT EXISTS (SELECT 1 FROM list_item i WHERE i.entity_type = e.type AND i.entity_id = e.id)
            """, arguments: [maximumTier.storedRank])
        for row in loose {
            victims.append(Victim(
                kind: .entity(LocalEntityKey(type: row[0], id: row[1])),
                tier: CacheTier(storedRank: row[2]), accessedAt: row[3], bytes: row[4]
            ))
        }
        if maximumTier >= .retained {
            let transcripts = try Row.fetchAll(db, sql: """
                SELECT t.key, t.accessed_at,
                       IFNULL((SELECT SUM(size) FROM transcript_item WHERE transcript_key = t.key), 0) + \(Self.transcriptOverhead)
                FROM transcript t
                """)
            for row in transcripts {
                victims.append(Victim(kind: .transcript(row[0]), tier: .retained, accessedAt: row[1], bytes: row[2]))
            }
        }
        return victims.sorted(by: Victim.evictionOrder)
    }

    func delete(_ victim: Victim, in db: Database) throws {
        switch victim.kind {
        case .entity(let key):
            try db.execute(sql: "DELETE FROM entity WHERE type = ? AND id = ?", arguments: [key.type, key.id])
        case .page(let list, let index):
            // Evicted: a prefetched page among them was never read.
            try deletePages(of: list, from: index, in: db, prefetchedFate: .wasted)
        case .transcript(let key):
            try deleteTranscript(key, in: db)
        }
    }

    /// A transcript and its items.
    func deleteTranscript(_ key: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM transcript WHERE key = ?", arguments: [key])
    }

    /// Deletes pages `index...` of `list` (the whole list from 0) and the
    /// entities only they held. The prefetched pages among them, never read,
    /// are counted as `prefetchedFate` (#970's waste ratio).
    func deletePages(of list: String, from index: Int, in db: Database, prefetchedFate: PrefetchedFate) throws {
        recordPrefetched(prefetchedFate, try prefetchedPageBytes(of: list, from: index, in: db))
        let arguments: StatementArguments = ["list": list, "index": index]
        try db.execute(sql: """
            DELETE FROM entity
            WHERE tier = 0
              AND (type, id) IN (SELECT entity_type, entity_id FROM list_item
                                 WHERE list_key = :list AND page_index >= :index)
              AND NOT EXISTS (SELECT 1 FROM list_item j
                              WHERE j.entity_type = entity.type AND j.entity_id = entity.id
                                AND NOT (j.list_key = :list AND j.page_index >= :index))
            """, arguments: arguments)
        if index <= 0 {
            try db.execute(sql: "DELETE FROM list WHERE key = :list", arguments: arguments)
        } else {
            try db.execute(sql: "DELETE FROM list_page WHERE list_key = :list AND page_index >= :index", arguments: arguments)
        }
    }

    // MARK: - Prefetched pages (#970)

    /// What became of a prefetched page: the four fates of
    /// `CacheSpeculativeStatistics`.
    enum PrefetchedFate {
        case stored
        /// Read, or shown (`markShown`): promoted to `recent`.
        case used
        /// Evicted or expired unread.
        case wasted
        /// Replaced by a refresh, removed, wiped, or never kept.
        case discarded
    }

    /// Each prefetched page's bytes, by the measure the speculative cap
    /// uses: its own cost and the entities only it holds. Of `list`'s pages
    /// `index...last`, or of every list.
    func prefetchedPageBytes(
        of list: String? = nil, from index: Int = 0, through last: Int = .max, in db: Database
    ) throws -> [Int] {
        let cost: String = "\(Self.pageCostSQL("p")) + \(Self.exclusiveEntityBytesSQL)"
        guard let list else {
            return try Int.fetchAll(db, sql: "SELECT \(cost) FROM list_page p WHERE p.tier = 0")
        }
        return try Int.fetchAll(db, sql: """
            SELECT \(cost) FROM list_page p
            WHERE p.list_key = ? AND p.page_index >= ? AND p.page_index <= ? AND p.tier = 0
            """, arguments: [list, index, last])
    }

    /// Counts `pages` (their bytes) under `fate`.
    func recordPrefetched(_ fate: PrefetchedFate, _ pages: [Int]) {
        guard !pages.isEmpty else { return }
        state.withLock { state in
            for bytes in pages {
                switch fate {
                case .stored: state.statistics.speculative.recordStored(bytes: bytes)
                case .used: state.statistics.speculative.recordUsed(bytes: bytes)
                case .wasted: state.statistics.speculative.recordWasted(bytes: bytes)
                case .discarded: state.statistics.speculative.recordDiscarded(bytes: bytes)
                }
            }
        }
    }

    /// Promotes `list`'s prefetched pages up to `last` to `recent`, counting
    /// them as used. Every page up to it, not that one alone: a page never
    /// outranks the one before it (`appendPage`), so eviction keeps taking a
    /// list from its tail.
    func promotePrefetchedPages(of list: String, through last: Int, in db: Database) throws {
        let promoted = try prefetchedPageBytes(of: list, through: last, in: db)
        guard !promoted.isEmpty else { return }
        try db.execute(
            sql: "UPDATE list_page SET tier = ? WHERE list_key = ? AND tier = ? AND page_index <= ?",
            arguments: [CacheTier.recent.storedRank, list, CacheTier.speculative.storedRank, last]
        )
        recordPrefetched(.used, promoted)
    }

    // MARK: - Trims

    /// Applies `depth`: expired rows always; then prefetched pages, half of
    /// `recent`, everything below `retained`, or everything.
    func trimRows(_ db: Database, depth: TrimDepth, now: Date) throws -> (expired: Int, evicted: Int) {
        let expired = try sweepExpired(db, now: now)
        var evicted = 0
        switch depth {
        case .expired:
            break
        case .speculative:
            evicted = try evict(try victims(db, maximumTier: .speculative), in: db)
        case .speculativeAndHalfRecent:
            evicted = try evict(try victims(db, maximumTier: .speculative), in: db)
            let recent = try victims(db, maximumTier: .recent)
            let half = recent.reduce(0) { $0 + $1.bytes } / 2
            var freed = 0
            var chosen: [Victim] = []
            for victim in recent where freed < half {
                chosen.append(victim)
                freed += victim.bytes
            }
            evicted += try evict(chosen, in: db)
        case .belowRetained:
            evicted = try evict(try victims(db, maximumTier: .recent), in: db)
        case .allButPinned:
            recordPrefetched(.wasted, try prefetchedPageBytes(in: db))
            evicted = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM entity) + (SELECT COUNT(*) FROM list_page) + (SELECT COUNT(*) FROM transcript)
                """) ?? 0
            try db.execute(sql: "DELETE FROM list; DELETE FROM entity; DELETE FROM transcript;")
        }
        return (expired, evicted)
    }

    private func evict(_ victims: [Victim], in db: Database) throws -> Int {
        var gone: [String: Int] = [:]
        var count = 0
        for victim in victims {
            if case .page(let list, let index) = victim.kind {
                if let first = gone[list], index >= first { continue }
                gone[list] = min(gone[list] ?? .max, index)
            }
            try delete(victim, in: db)
            count += 1
        }
        return count
    }

    /// Lists past their lifetime (with the entities only they held),
    /// entities past theirs, and transcripts past theirs. Returns how many
    /// rows went.
    private func sweepExpired(_ db: Database, now: Date) throws -> Int {
        let lists = try String.fetchAll(db, sql: "SELECT key FROM list WHERE expires_at <= ?", arguments: [now.timeIntervalSince1970])
        for list in lists {
            try deletePages(of: list, from: 0, in: db, prefetchedFate: .wasted)
        }
        try db.execute(sql: "DELETE FROM entity WHERE expires_at <= ?", arguments: [now.timeIntervalSince1970])
        let entities = db.changesCount
        try db.execute(sql: "DELETE FROM transcript WHERE expires_at <= ?", arguments: [now.timeIntervalSince1970])
        return lists.count + entities + db.changesCount
    }
}
