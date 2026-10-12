import CacheKit
import Foundation
import GRDB

/// Transcripts (#897): a conversation's newest messages, so a thread opens on
/// them offline and at cold start, then revalidates.
///
/// - **Bounded.** At most `LocalStorePolicy.transcriptLength` items per
///   transcript (the newest), and `LocalStorePolicy.transcriptCount`
///   transcripts (the least recently opened go first). Decided 2026-10-11,
///   epic #890: 50 conversations × 200 messages.
/// - **Contiguous.** The stored items are one run, from the newest page the
///   network answered back to a page boundary: the oldest stored item always
///   carries the cursor its page answered, so paging older goes on from
///   there, and a transcript that would end anywhere else is cut back to the
///   last boundary (or dropped).
/// - **Incremental.** A newest page that overlaps what is stored is merged
///   over it (what it no longer carries went away; everything older stays);
///   one with a gap behind it replaces it. A live item (a sent message) is
///   added at the newest end, once per id.
/// - Viewer-scoped, budgeted and wiped like everything else in the store;
///   `retained`, like the first page of a tab.
extension LocalStore {
    /// Cost of a transcript row and of an item beyond its payload.
    static let transcriptOverhead = 64
    static let transcriptItemOverhead = 64

    // MARK: - Reading

    /// The stored items of `key`, oldest first, and the cursor past the
    /// oldest. nil when nothing is stored, the transcript expired, or the rows
    /// are not this viewer's. A read is a USE: the transcript moves up the
    /// LRU that keeps the last ones.
    public func transcript(_ key: String) -> LocalTranscript? {
        guard admitsRead() else { return nil }
        let now = clock.now
        let found: LocalTranscript? = try? pool.read { db in
            guard let header = try Row.fetchOne(
                db.cachedStatement(sql: "SELECT fetched_at, expires_at FROM transcript WHERE key = ?"), arguments: [key]
            ), (header[1] as Double) > now.timeIntervalSince1970 else { return nil }
            let rows = try Row.fetchAll(
                db.cachedStatement(sql: """
                    SELECT id, sort_key, format, payload, boundary, older_cursor FROM transcript_item
                    WHERE transcript_key = ? ORDER BY sort_key, id
                    """),
                arguments: [key]
            )
            // Not ending at a boundary: nobody knows where paging goes on, so
            // the stored run cannot be offered as the newest messages.
            if let oldest = rows.first, (oldest[4] as Int) == 0 { return nil }
            return LocalTranscript(
                key: key,
                items: rows.map { LocalTranscriptItem(id: $0[0], sortKey: $0[1], payload: $0[3], format: $0[2]) },
                olderCursor: rows.first?[5],
                fetchedAt: Date(timeIntervalSince1970: header[0])
            )
        }
        state.withLock {
            if found == nil { $0.statistics.misses += 1 } else { $0.statistics.hits += 1 }
        }
        if found != nil {
            pool.asyncWriteWithoutTransaction { db in
                try? db.execute(
                    sql: "UPDATE transcript SET accessed_at = ? WHERE key = ?",
                    arguments: [now.timeIntervalSince1970, key]
                )
            }
        }
        return found
    }

    // MARK: - Writing

    /// Writes the NEWEST page the network answered for `key`.
    ///
    /// Over a stored transcript it overlaps (an item in common, or a page
    /// that reaches the start), the page is merged: stored items at least as
    /// recent as the page's oldest that it no longer carries went away, and
    /// older ones stay with their cursor. Otherwise (nothing stored, or a gap
    /// between the page and what is stored) the page replaces it. An empty
    /// page that reaches the start stores an empty transcript.
    ///
    /// - Returns: false when nothing is stored: the viewer changed, the page
    ///   is empty with more behind it, or it did not fit the budget.
    @discardableResult
    public func storeNewest(_ page: LocalTranscriptPage, in key: String, as writer: LocalStoreViewer?) throws -> Bool {
        try write(as: writer) { db, now in
            guard let oldest = page.items.min(by: Self.isOrderedBefore) else {
                // An empty page with more behind it says nothing.
                guard page.olderCursor == nil else { return nil }
                try deleteTranscript(key, in: db)
                try touchTranscript(key, fetched: true, now: now, in: db)
                return Footprint(transcript: key, tier: .retained, evicted: try boundTranscripts(keeping: key, in: db))
            }
            let stored = try storedItems(of: key, now: now, in: db)
            let pageIDs = Set(page.items.map(\.id))
            if let stored, page.olderCursor == nil || stored.contains(where: { pageIDs.contains($0.id) }) {
                // A page that reaches the start IS the transcript: everything
                // it does not carry went away.
                let gone = stored.filter { item in
                    !pageIDs.contains(item.id) && (page.olderCursor == nil || !Self.isOrderedBefore(item, oldest))
                }
                let delete = try db.cachedStatement(sql: "DELETE FROM transcript_item WHERE transcript_key = ? AND id = ?")
                for item in gone {
                    try delete.execute(arguments: [key, item.id])
                }
            } else {
                try deleteTranscript(key, in: db)
            }
            try touchTranscript(key, fetched: true, now: now, in: db)
            try upsertItems(page.items, boundary: (oldest.id, page.olderCursor), in: key, db: db)
            let trimmed = try trimTranscript(key, in: db)
            guard trimmed.survives else { return nil }
            return Footprint(
                transcript: key, tier: .retained,
                evicted: trimmed.evicted + (try boundTranscripts(keeping: key, in: db))
            )
        }
    }

    /// Writes an OLDER page, fetched with `cursor`, below the stored items of
    /// `key`. Its oldest item now carries its cursor.
    ///
    /// - Returns: false when it is not stored: nothing is stored for `key`,
    ///   `cursor` is not the one past the oldest stored item (the page does
    ///   not follow what is stored), the transcript is already full, or for
    ///   the reasons `storeNewest` gives.
    @discardableResult
    public func storeOlder(
        _ page: LocalTranscriptPage, in key: String, after cursor: String, as writer: LocalStoreViewer?
    ) throws -> Bool {
        try write(as: writer) { db, now in
            guard let stored = try storedItems(of: key, now: now, in: db),
                  stored.count < LocalStorePolicy.transcriptLength,
                  let oldest = try Row.fetchOne(
                      db.cachedStatement(sql: """
                          SELECT boundary, older_cursor FROM transcript_item WHERE transcript_key = ?
                          ORDER BY sort_key, id LIMIT 1
                          """),
                      arguments: [key]
                  ),
                  (oldest[0] as Int) == 1, (oldest[1] as String?) == cursor
            else { return nil }
            let known = Set(stored.map(\.id))
            try upsertItems(page.items.filter { !known.contains($0.id) }, boundary: nil, in: key, db: db)
            // The oldest item now is this page's (or, when it brought nothing
            // older, still the one before): either way the page's cursor goes
            // on from it.
            try db.execute(
                sql: """
                    UPDATE transcript_item SET boundary = 1, older_cursor = ?
                    WHERE transcript_key = ? AND id = (
                        SELECT id FROM transcript_item WHERE transcript_key = ? ORDER BY sort_key, id LIMIT 1
                    )
                    """,
                arguments: [page.olderCursor, key, key]
            )
            try touchTranscript(key, fetched: false, now: now, in: db)
            let trimmed = try trimTranscript(key, in: db)
            guard trimmed.survives else { return nil }
            return Footprint(transcript: key, tier: .retained, evicted: trimmed.evicted)
        }
    }

    /// Adds items that arrived on their own (the viewer's sent message) at the
    /// newest end of `key`. An item already stored is replaced in place; the
    /// newest page that later carries it replaces it again (one row per id).
    ///
    /// - Returns: false when nothing is stored for `key` (a lone message is not
    ///   a transcript: nothing would say what is older), or the items are all
    ///   older than what is stored.
    @discardableResult
    public func insertLive(_ items: [LocalTranscriptItem], in key: String, as writer: LocalStoreViewer?) throws -> Bool {
        guard !items.isEmpty else { return false }
        return try write(as: writer) { db, now in
            guard let stored = try storedItems(of: key, now: now, in: db) else { return nil }
            if let oldest = stored.min(by: Self.isOrderedBefore) {
                let fresh = items.filter { !Self.isOrderedBefore($0, oldest) }
                guard !fresh.isEmpty else { return nil }
                try upsertItems(fresh, boundary: nil, in: key, db: db)
            } else if let first = items.min(by: Self.isOrderedBefore) {
                // An empty conversation: its first message is its start.
                try upsertItems(items, boundary: (first.id, nil), in: key, db: db)
            }
            try touchTranscript(key, fetched: false, now: now, in: db)
            let trimmed = try trimTranscript(key, in: db)
            guard trimmed.survives else { return nil }
            return Footprint(transcript: key, tier: .retained, evicted: trimmed.evicted)
        }
    }

    // MARK: - Rows

    /// The transcript's order: time, then id (a total order).
    static func isOrderedBefore(_ lhs: LocalTranscriptItem, _ rhs: LocalTranscriptItem) -> Bool {
        lhs.sortKey != rhs.sortKey ? lhs.sortKey < rhs.sortKey : lhs.id < rhs.id
    }

    /// The stored items of `key` (ids and order only); nil when no live
    /// transcript is stored.
    private func storedItems(of key: String, now: Date, in db: Database) throws -> [LocalTranscriptItem]? {
        guard try Bool.fetchOne(
            db.cachedStatement(sql: "SELECT 1 FROM transcript WHERE key = ? AND expires_at > ?"),
            arguments: [key, now.timeIntervalSince1970]
        ) == true else { return nil }
        return try Row.fetchAll(
            db.cachedStatement(sql: "SELECT id, sort_key FROM transcript_item WHERE transcript_key = ?"), arguments: [key]
        ).map { LocalTranscriptItem(id: $0[0], sortKey: $0[1], payload: Data()) }
    }

    /// Creates the transcript's row or marks it used; `fetched`: a newest page
    /// was written, which also restarts its lifetime.
    private func touchTranscript(_ key: String, fetched: Bool, now: Date, in db: Database) throws {
        let time = now.timeIntervalSince1970
        let expiry = now.addingTimeInterval(LocalStorePolicy.transcriptLifetime).timeIntervalSince1970
        if fetched {
            try db.execute(
                sql: """
                    INSERT INTO transcript (key, fetched_at, expires_at, accessed_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        fetched_at = excluded.fetched_at, expires_at = excluded.expires_at, accessed_at = excluded.accessed_at
                    """,
                arguments: [key, time, expiry, time]
            )
        } else {
            try db.execute(sql: "UPDATE transcript SET accessed_at = ? WHERE key = ?", arguments: [time, key])
        }
    }

    /// Writes `items`; `boundary` names the one that was its page's oldest,
    /// with the cursor that page answered. An item already stored keeps the
    /// boundary it had, unless it is this page's.
    private func upsertItems(
        _ items: [LocalTranscriptItem], boundary: (id: String, cursor: String?)?, in key: String, db: Database
    ) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO transcript_item (transcript_key, id, sort_key, format, payload, size, boundary, older_cursor)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(transcript_key, id) DO UPDATE SET
                sort_key = excluded.sort_key,
                format = excluded.format,
                payload = excluded.payload,
                size = excluded.size,
                boundary = MAX(transcript_item.boundary, excluded.boundary),
                older_cursor = CASE WHEN excluded.boundary = 1 THEN excluded.older_cursor ELSE transcript_item.older_cursor END
            """)
        for item in items {
            let isBoundary = item.id == boundary?.id
            let cursor = isBoundary ? boundary?.cursor : nil
            let cursorBytes: Int = cursor?.utf8.count ?? 0
            let size: Int = item.payload.count + item.id.utf8.count + cursorBytes + Self.transcriptItemOverhead
            try statement.execute(arguments: [
                key, item.id, item.sortKey, item.format, item.payload, size, isBoundary ? 1 : 0, cursor
            ])
        }
    }

    /// Keeps the newest `transcriptLength` items, cut back to the last page
    /// boundary among them so the oldest kept still knows where paging goes
    /// on. With no boundary among them, the transcript goes whole.
    private func trimTranscript(_ key: String, in db: Database) throws -> (evicted: Int, survives: Bool) {
        let rows = try Row.fetchAll(
            db.cachedStatement(sql: """
                SELECT id, boundary FROM transcript_item WHERE transcript_key = ? ORDER BY sort_key DESC, id DESC
                """),
            arguments: [key]
        )
        guard rows.count > LocalStorePolicy.transcriptLength else { return (0, true) }
        let newest = rows.prefix(LocalStorePolicy.transcriptLength)
        guard let lastBoundary = newest.lastIndex(where: { ($0[1] as Int) == 1 }) else {
            try deleteTranscript(key, in: db)
            return (1, false)
        }
        let delete = try db.cachedStatement(sql: "DELETE FROM transcript_item WHERE transcript_key = ? AND id = ?")
        for row in rows[(lastBoundary + 1)...] {
            try delete.execute(arguments: [key, row[0] as String])
        }
        return (rows.count - lastBoundary - 1, true)
    }

    /// Keeps `key` and the most recently used others, `transcriptCount` in
    /// all. Returns how many went.
    private func boundTranscripts(keeping key: String, in db: Database) throws -> Int {
        let doomed = try String.fetchAll(
            db,
            sql: "SELECT key FROM transcript WHERE key != ? ORDER BY accessed_at DESC, key DESC LIMIT -1 OFFSET ?",
            arguments: [key, LocalStorePolicy.transcriptCount - 1]
        )
        for victim in doomed {
            try deleteTranscript(victim, in: db)
        }
        return doomed.count
    }
}
