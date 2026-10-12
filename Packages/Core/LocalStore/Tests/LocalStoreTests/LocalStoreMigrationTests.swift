import CacheKit
import Foundation
import GRDB
import Testing
@testable import LocalStore

/// The file across launches and builds: cold-start reads, migrations, a newer
/// schema, a broken file (#893).
final class LocalStoreMigrationTests {
    private let folder = TemporaryFolder()
    private let viewer = ViewerBox()

    @Test func aNewFileHasTheSchemaWalAndIncrementalVacuum() throws {
        let store = try LocalStore.test(in: folder, viewer: viewer)
        for table in ["entity", "list", "list_page", "list_item", "meta", "transcript", "transcript_item"] {
            #expect(try store.tableExists(table), "\(table)")
        }
        #expect(try store.pragma("journal_mode") == "wal")
        // 2 = INCREMENTAL: a trim or a wipe gives its pages back.
        #expect(try store.pragma("auto_vacuum") == "2")
        #expect(try store.completedMigrations() == ["v1-entities-and-lists", "v2-transcripts"])
    }

    /// A file the first LocalStore build wrote (v1 only) gains the
    /// transcripts' tables and keeps its lists (#897).
    @Test func aV1FileGainsTheTranscriptsAndKeepsItsLists() throws {
        do {
            let store = try LocalStore.test(in: folder, viewer: viewer)
            try store.replaceList("forYou", with: page(["p1", "p2"], author: "a1", cursor: "c1"), as: alice)
            // Back to the file v1 wrote: no transcripts, v2 never run.
            try store.databasePool.write { db in
                try db.execute(sql: """
                    DROP TABLE transcript_item;
                    DROP TABLE transcript;
                    DELETE FROM grdb_migrations WHERE identifier = 'v2-transcripts';
                    """)
            }
            #expect(try store.completedMigrations() == ["v1-entities-and-lists"])
        }
        let upgraded = try LocalStore.test(in: folder, viewer: viewer)
        #expect(try upgraded.completedMigrations() == ["v1-entities-and-lists", "v2-transcripts"])
        #expect(ids(upgraded.list("forYou")) == ["p1", "p2"])
        #expect(upgraded.list("forYou")?.nextCursor == "c1")
        #expect(try upgraded.storeNewest(
            LocalTranscriptPage(items: [LocalTranscriptItem(id: "m1", sortKey: 1, payload: Data("hi".utf8))], olderCursor: nil),
            in: "conv-1", as: alice
        ))
        #expect(upgraded.transcript("conv-1")?.items.map(\.id) == ["m1"])
    }

    @Test func aColdStartReadsTheLastListAndItsCursor() throws {
        do {
            let store = try LocalStore.test(in: folder, viewer: viewer)
            #expect(try store.replaceList("forYou", with: page(["p1", "p2"], author: "a1", cursor: "c1"), as: alice))
            #expect(try store.appendPage(page(["p3"], cursor: "c2", tier: .recent), to: "forYou", after: "c1", as: alice))
        }
        // A new process: the same file, opened again.
        let reopened = try LocalStore.test(in: folder, viewer: viewer)
        let list = try #require(reopened.list("forYou"))
        #expect(ids(list) == ["p1", "p2", "p3"])
        #expect(list.nextCursor == "c2", "paging goes on from the last stored page")
        #expect(list.pageCount == 2)
        #expect(text(list.attachments[profileKey("a1")]) == "profile a1")
        #expect(text(list.entries.first) == "post p1")
    }

    @Test func anUpgradeRunsTheNewMigrationAndKeepsTheRows() throws {
        do {
            let store = try LocalStore.test(in: folder, viewer: viewer)
            try store.replaceList("following", with: page(["p1"], cursor: nil), as: alice)
        }
        let upgraded = try LocalStore.test(in: folder, viewer: viewer, extraMigrations: [
            ("v2-test-messages", { db in
                try db.execute(sql: "CREATE TABLE message (id TEXT PRIMARY KEY NOT NULL, body BLOB NOT NULL)")
            })
        ])
        #expect(ids(upgraded.list("following")) == ["p1"])
        #expect(try upgraded.tableExists("message"))
    }

    @Test func aFileANewerBuildWroteIsDeletedNotMisread() throws {
        do {
            let newer = try LocalStore.test(in: folder, viewer: viewer, extraMigrations: [
                ("v2-from-the-future", { db in try db.execute(sql: "CREATE TABLE future (x INTEGER)") })
            ])
            try newer.replaceList("following", with: page(["p1"], cursor: nil), as: alice)
        }
        // This build does not know `v2-from-the-future`.
        let older = try LocalStore.test(in: folder, viewer: viewer)
        #expect(older.list("following") == nil)
        #expect(try !older.tableExists("future"))
        #expect(try older.completedMigrations() == ["v1-entities-and-lists", "v2-transcripts"])
        // And it works as a fresh store.
        #expect(try older.replaceList("following", with: page(["p2"], cursor: nil), as: alice))
        #expect(ids(older.list("following")) == ["p2"])
    }

    @Test func aFileSQLiteCannotOpenIsRecreated() throws {
        try Data("not a database, just bytes".utf8).write(to: folder.fileURL)
        let store = try LocalStore.test(in: folder, viewer: viewer)
        #expect(store.list("following") == nil)
        #expect(try store.replaceList("following", with: page(["p1"], cursor: nil), as: alice))
        #expect(ids(store.list("following")) == ["p1"])
    }

    @Test func theFileIsExcludedFromBackup() throws {
        _ = try LocalStore.test(in: folder, viewer: viewer)
        let values = try folder.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
