import CacheKit
import Foundation
import GRDB
import Synchronization
@testable import LocalStore

/// A private folder per suite instance, deleted with it.
final class TemporaryFolder: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "LocalStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var fileURL: URL { url.appending(path: "store.sqlite") }
}

/// Who is using the app, as a test sets it (the app's `StorageScope`).
final class ViewerBox: Sendable {
    private let current: Mutex<LocalStoreViewer?>

    init(_ viewer: LocalStoreViewer? = .member(account: "acct-1", profile: "prof-1")) {
        current = Mutex(viewer)
    }

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    var provider: @Sendable () -> LocalStoreViewer? { { [self] in viewer } }
}

let alice = LocalStoreViewer.member(account: "acct-1", profile: "prof-1")
let aliceSecondProfile = LocalStoreViewer.member(account: "acct-1", profile: "prof-2")
let aliceUnresolved = LocalStoreViewer.member(account: "acct-1", profile: nil)
let bob = LocalStoreViewer.member(account: "acct-2", profile: "prof-9")

func postKey(_ id: String) -> LocalEntityKey { LocalEntityKey(type: "post", id: id) }
func profileKey(_ id: String) -> LocalEntityKey { LocalEntityKey(type: "profile", id: id) }

func post(_ id: String, _ payload: String? = nil, bytes: Int? = nil) -> LocalEntityWrite {
    let data = bytes.map { Data(repeating: 7, count: $0) } ?? Data((payload ?? "post \(id)").utf8)
    return LocalEntityWrite(key: postKey(id), payload: data, lifetime: LocalStorePolicy.postLifetime)
}

func profile(_ id: String, _ payload: String? = nil, tier: CacheTier = .recent) -> LocalEntityWrite {
    LocalEntityWrite(
        key: profileKey(id), payload: Data((payload ?? "profile \(id)").utf8),
        lifetime: LocalStorePolicy.profileLifetime, tier: tier
    )
}

/// A page of posts `ids`, each by `author`.
func page(_ ids: [String], author: String? = nil, cursor: String?, tier: CacheTier = .retained, bytes: Int? = nil) -> LocalListPage {
    var entities = ids.map { post($0, bytes: bytes) }
    if let author { entities.append(profile(author)) }
    return LocalListPage(items: ids.map(postKey), entities: entities, nextCursor: cursor, tier: tier)
}

func ids(_ list: LocalList?) -> [String] {
    list?.entries.map(\.key.id) ?? []
}

func text(_ entity: LocalEntity?) -> String? {
    entity.map { String(decoding: $0.payload, as: UTF8.self) }
}

extension LocalStore {
    /// Opens a store in `folder` with the test's viewer and clock.
    static func test(
        in folder: TemporaryFolder,
        viewer: ViewerBox,
        clock: ManualCacheClock = ManualCacheClock(),
        limits: CacheLimits = .unlimited,
        extraMigrations: [(String, @Sendable (Database) throws -> Void)] = []
    ) throws -> LocalStore {
        try LocalStore(
            directory: folder.url,
            viewer: viewer.provider,
            limits: limits,
            clock: clock,
            namespace: LocalStore.defaultNamespace,
            budget: DiskBudget(pool: .localStore),
            migrator: LocalStoreSchema.migrator(extra: extraMigrations)
        )
    }

    /// The stored lists, read without touching them (a read is a use).
    func listKeys() throws -> Set<String> {
        try databasePool.read { db in Set(try String.fetchAll(db, sql: "SELECT key FROM list")) }
    }

    func tableExists(_ table: String) throws -> Bool {
        try databasePool.read { db in try db.tableExists(table) }
    }

    func pragma(_ name: String) throws -> String? {
        try databasePool.read { db in try String.fetchOne(db, sql: "PRAGMA \(name)") }
    }

    func completedMigrations() throws -> [String] {
        try databasePool.read { db in try LocalStoreSchema.migrator().completedMigrations(db) }
    }

    func rowCount(_ table: String) throws -> Int {
        try databasePool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}
