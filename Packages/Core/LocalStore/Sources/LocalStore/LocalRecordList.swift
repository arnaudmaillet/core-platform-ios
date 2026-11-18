import CacheKit
import Foundation
import OSLog

/// A screen's list kept on the device as JSON records (#2390): the one shape
/// the features' local caches shared, written once.
///
/// - **Read** (`read`) on the caller's thread: the list's entries of this
///   type and format, decoded. An entry of another type, an older format or
///   bytes that no longer decode is left out, as a miss.
/// - **Write** (`write`) off the caller's thread, on this list's own serial
///   queue: each record encoded, the list replaced whole. A failed write is
///   logged and dropped; the cache is best-effort and the network answers.
/// - **`waitForPendingWrites`**, for tests: this queue, then the store's.
///
/// Each feature keeps what is its own: the record's fields and how it maps
/// to the feature's model, the list keys, the lifetime and how many to keep.
public nonisolated final class LocalRecordList<Record: Codable & Sendable>: Sendable {
    public let entityType: String
    public let format: Int

    private let store: LocalStore
    private let queue: DispatchQueue
    private let logger: Logger
    private let name: String

    /// - Parameters:
    ///   - entityType: the type every entry is stored under, e.g. `map.person`.
    ///   - format: the records' encoding; bump it when `Record` changes shape.
    ///   - name: the cache's name in its queue label (`cn.wynn.<name>-local-cache`),
    ///     its log category (`<name>-cache`) and its failure message.
    public init(store: LocalStore, entityType: String, format: Int, name: String) {
        self.store = store
        self.entityType = entityType
        self.format = format
        self.name = name
        queue = DispatchQueue(label: "cn.wynn.\(name)-local-cache", qos: .utility)
        logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "\(name)-cache")
    }

    /// The viewer the store answers for now: a write carries the viewer it
    /// was fetched for, so a write landing after a switch is refused.
    public var viewer: LocalStoreViewer? { store.currentViewer }

    /// What `read` found under a key.
    public struct Stored {
        /// In list order.
        public let records: [Record]
        /// The cursor after them; nil when the list ends there.
        public let nextCursor: String?
        /// When the list was last written.
        public let fetchedAt: Date
    }

    /// The records stored under `key`; nil when nothing is stored.
    public func read(_ key: String, maxPages: Int? = nil) -> Stored? {
        guard let list = store.list(key, maxPages: maxPages) else { return nil }
        let decoder = JSONDecoder()
        let records = list.entries.compactMap { entity -> Record? in
            guard entity.key.type == entityType, entity.format == format else { return nil }
            return try? decoder.decode(Record.self, from: entity.payload)
        }
        return Stored(records: records, nextCursor: list.nextCursor, fetchedAt: list.fetchedAt)
    }

    /// Replaces the list under `key` with `records`, each stored under its
    /// id, as `viewer`'s. A record that does not encode is left out. Each
    /// record lives `lifetime`; the list itself `listLifetime` (`lifetime`
    /// when not given).
    public func write(
        _ records: [(id: String, record: Record)], to key: String, nextCursor: String? = nil,
        as viewer: LocalStoreViewer?, lifetime: TimeInterval, listLifetime: TimeInterval? = nil,
        tier: CacheTier = .retained
    ) {
        let store = store
        let logger = logger
        let name = name
        let entityType = entityType
        let format = format
        queue.async {
            let encoder = JSONEncoder()
            let writes = records.compactMap { item -> LocalEntityWrite? in
                guard let payload = try? encoder.encode(item.record) else { return nil }
                return LocalEntityWrite(
                    key: LocalEntityKey(type: entityType, id: item.id),
                    payload: payload, format: format, lifetime: lifetime
                )
            }
            let page = LocalListPage(items: writes.map(\.key), entities: writes, nextCursor: nextCursor, tier: tier)
            do {
                try store.replaceList(key, with: page, as: viewer, lifetime: listLifetime ?? lifetime)
            } catch {
                logger.error("\(name, privacy: .public) cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Returns once every write asked for so far has landed.
    public func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }
}
