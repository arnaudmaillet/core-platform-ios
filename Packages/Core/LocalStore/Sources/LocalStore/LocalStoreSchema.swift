import GRDB

/// The file's schema, as an append-only list of migrations.
///
/// ⚠️ NEVER EDIT A SHIPPED MIGRATION: add one. A build meets files written by
/// every earlier build, and `DatabaseMigrator` runs only the migrations a
/// file has not seen. A file that has seen a migration THIS build does not
/// know (an app downgraded, a TestFlight build rolled back) is deleted and
/// recreated, never read blindly (`LocalStore.open`).
///
/// Anything that needs tables of its own adds a migration here rather than a
/// second database: one file, one budget, one wipe. Conversations' messages
/// did (`v2`, #897).
enum LocalStoreSchema {
    static func migrator(extra: [(String, @Sendable (Database) throws -> Void)] = []) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-entities-and-lists", migrate: v1)
        migrator.registerMigration("v2-transcripts", migrate: v2)
        // Tests append migrations to prove an upgrade keeps the data.
        for (identifier, migrate) in extra {
            migrator.registerMigration(identifier, migrate: migrate)
        }
        return migrator
    }

    /// Entities by (type, id), lists of keys in pages, and who owns the rows.
    ///
    /// - `entity`: one row per server entity, its protobuf bytes in `payload`.
    ///   `size` is the row's cost against the budget; `tier` matters only for
    ///   an entity no list holds (written on its own, or left by a page that
    ///   went).
    /// - `list` / `list_page` / `list_item`: a list is pages of keys, each
    ///   page with the cursor that fetches the one after it; the last page's
    ///   is where the list goes on. An item is an ENTRY (role 0, the list's
    ///   order) or an ATTACHMENT (role 1: an entry's author, its counters),
    ///   held by the page that brought it so it goes with that page. A key
    ///   appears once per list (`list_item_once`), on the first page that
    ///   carried it; across lists it is the same entity row.
    /// - `meta`: the owner (`LocalStoreViewer.encoded`).
    static func v1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE entity (
                type TEXT NOT NULL,
                id TEXT NOT NULL,
                format INTEGER NOT NULL,
                payload BLOB NOT NULL,
                size INTEGER NOT NULL,
                tier INTEGER NOT NULL,
                fetched_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                accessed_at REAL NOT NULL,
                PRIMARY KEY (type, id)
            );
            CREATE INDEX entity_expiry ON entity(expires_at);

            CREATE TABLE list (
                key TEXT PRIMARY KEY NOT NULL,
                fetched_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                accessed_at REAL NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE list_page (
                list_key TEXT NOT NULL REFERENCES list(key) ON DELETE CASCADE,
                page_index INTEGER NOT NULL,
                tier INTEGER NOT NULL,
                item_count INTEGER NOT NULL,
                next_cursor TEXT,
                fetched_at REAL NOT NULL,
                PRIMARY KEY (list_key, page_index)
            ) WITHOUT ROWID;

            CREATE TABLE list_item (
                list_key TEXT NOT NULL,
                position INTEGER NOT NULL,
                page_index INTEGER NOT NULL,
                role INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                PRIMARY KEY (list_key, position),
                FOREIGN KEY (list_key, page_index)
                    REFERENCES list_page(list_key, page_index) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE INDEX list_item_entity ON list_item(entity_type, entity_id);
            CREATE UNIQUE INDEX list_item_once ON list_item(list_key, entity_type, entity_id);
            """)
    }

    /// Transcripts (#897): the newest items of a time-ordered collection (a
    /// conversation's messages), at most `LocalStorePolicy.transcriptLength`
    /// of them, for at most `LocalStorePolicy.transcriptCount` collections.
    ///
    /// - `transcript`: one row per collection; `accessed_at` orders the LRU
    ///   that keeps the last ones.
    /// - `transcript_item`: an item's bytes, ordered by `sort_key` (its time,
    ///   in ms) then `id`. An item that was the OLDEST of the network page
    ///   that brought it is a `boundary`, with the cursor that page answered
    ///   (`older_cursor`; NULL: nothing older exists). The stored items always
    ///   end at a boundary, so the oldest one's cursor is where paging goes on.
    static func v2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE transcript (
                key TEXT PRIMARY KEY NOT NULL,
                fetched_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                accessed_at REAL NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE transcript_item (
                transcript_key TEXT NOT NULL REFERENCES transcript(key) ON DELETE CASCADE,
                id TEXT NOT NULL,
                sort_key INTEGER NOT NULL,
                format INTEGER NOT NULL,
                payload BLOB NOT NULL,
                size INTEGER NOT NULL,
                boundary INTEGER NOT NULL,
                older_cursor TEXT,
                PRIMARY KEY (transcript_key, id)
            ) WITHOUT ROWID;
            CREATE INDEX transcript_item_order ON transcript_item(transcript_key, sort_key, id);
            """)
    }
}
