import CacheKit
import CoreModels
import Foundation
import LocalStore
import OSLog

/// The drawer's last notifications on the device (#897), in the LocalStore:
/// the drawer opens on its last page at a cold start, offline included, then
/// revalidates (stale-while-revalidate).
///
/// One list (`notifications`), its pages with their cursors, so paging goes
/// on from the network where the stored pages stop: the last 100 rows, a page
/// stored while the list holds fewer. A notification is a versioned JSON
/// record of the row as the drawer draws it (it joins notification.v1 with
/// profile.v1 names and post.v1 stills): a format this build cannot read is
/// a miss. Reads are synchronous (a first frame); writes go to a serial
/// queue, each as the viewer captured BEFORE its network call.
final class NotificationsLocalCache: Sendable {
    static let listKey = "notifications"
    static let entityType = "notification"
    static let format = 1
    /// The last 100 notifications (#897).
    static let maxStoredRows = 100
    /// A week: the viewer's own activity, readable offline long after a feed.
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.notifications-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "notifications-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    /// The stored rows, most recent first, and where the next page starts.
    struct Stored: Equatable {
        var items: [NotificationItem]
        var nextCursor: String?
    }

    func stored() -> Stored? {
        guard let list = store.list(Self.listKey) else { return nil }
        let items = list.entries.compactMap { entity -> NotificationItem? in
            guard entity.format == Self.format,
                  let record = try? JSONDecoder().decode(Record.self, from: entity.payload) else { return nil }
            return record.item
        }
        return Stored(items: items, nextCursor: list.nextCursor)
    }

    /// Replaces the list with its first page: the drawer's `retained` page.
    func storeFirstPage(_ page: NotificationsPage, as viewer: LocalStoreViewer?) {
        write { store in
            try store.replaceList(Self.listKey, with: Self.listPage(page, tier: .retained), as: viewer, lifetime: Self.lifetime)
        }
    }

    /// Appends the page fetched with `cursor`, while the list holds fewer
    /// than `maxStoredRows`.
    func storeNextPage(_ page: NotificationsPage, after cursor: String, as viewer: LocalStoreViewer?) {
        write { store in
            try store.appendPage(
                Self.listPage(page, tier: .recent), to: Self.listKey, after: cursor, as: viewer, maxEntries: Self.maxStoredRows
            )
        }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    private func write(_ body: @escaping @Sendable (LocalStore) throws -> Bool) {
        let store = store
        let logger = logger
        queue.async {
            do {
                _ = try body(store)
            } catch {
                logger.error("notifications cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func listPage(_ page: NotificationsPage, tier: CacheTier) -> LocalListPage {
        let writes = page.items.compactMap { item -> LocalEntityWrite? in
            guard let payload = try? JSONEncoder().encode(Record(item)) else { return nil }
            return LocalEntityWrite(
                key: LocalEntityKey(type: entityType, id: item.id), payload: payload, format: format, lifetime: lifetime
            )
        }
        return LocalListPage(items: writes.map(\.key), entities: writes, nextCursor: page.nextPageToken, tier: tier)
    }

    // MARK: - Records

    /// One row as stored.
    struct Record: Codable, Equatable {
        struct Actor: Codable, Equatable {
            var id: String
            var name: String
            var avatarURL: URL?
        }

        var id: String
        var action: String
        var sender: Actor
        var otherSenderCount: Int
        var sampleSenders: [Actor]
        var postSubjectID: String?
        var thumbnailURL: URL?
        var excerpt: String?
        var hasPreview: Bool
        /// The other side of a supervision (#1106). Optional, so a row stored
        /// before it existed still reads (format unchanged).
        var subjectAccountID: String?
        var isRead: Bool
        var createdAt: Date

        init(_ item: NotificationItem) {
            subjectAccountID = item.subjectAccountID
            id = item.id
            action = item.action.storedName
            sender = Actor(id: item.senderID.rawValue, name: item.senderName, avatarURL: item.senderAvatarURL)
            otherSenderCount = item.otherSenderCount
            sampleSenders = item.sampleSenders.map { Actor(id: $0.id.rawValue, name: $0.name, avatarURL: $0.avatarURL) }
            postSubjectID = item.postSubjectID?.rawValue
            thumbnailURL = item.subjectPreview?.thumbnailURL
            excerpt = item.subjectPreview?.excerpt
            hasPreview = item.subjectPreview != nil
            isRead = item.isRead
            createdAt = item.createdAt
        }

        var item: NotificationItem {
            NotificationItem(
                id: id,
                action: NotificationItem.Action(storedName: action),
                senderID: ProfileID(sender.id),
                senderName: sender.name,
                senderAvatarURL: sender.avatarURL,
                otherSenderCount: otherSenderCount,
                sampleSenders: sampleSenders.map { NotificationActor(id: ProfileID($0.id), name: $0.name, avatarURL: $0.avatarURL) },
                postSubjectID: postSubjectID.map { PostID($0) },
                subjectPreview: hasPreview ? NotificationSubjectPreview(thumbnailURL: thumbnailURL, excerpt: excerpt) : nil,
                subjectAccountID: subjectAccountID,
                isRead: isRead,
                createdAt: createdAt
            )
        }
    }
}

extension NotificationItem.Action {
    /// The name stored for each action. Fixed strings, never the case order:
    /// the file outlives the code.
    var storedName: String {
        switch self {
        case .reaction: "reaction"
        case .comment: "comment"
        case .reply: "reply"
        case .mention: "mention"
        case .supervisionStarted: "supervisionStarted"
        case .supervisionEnded: "supervisionEnded"
        case .supervisionCameOfAge: "supervisionCameOfAge"
        case .other: "other"
        }
    }

    init(storedName: String) {
        switch storedName {
        case "reaction": self = .reaction
        case "comment": self = .comment
        case "reply": self = .reply
        case "mention": self = .mention
        case "supervisionStarted": self = .supervisionStarted
        case "supervisionEnded": self = .supervisionEnded
        case "supervisionCameOfAge": self = .supervisionCameOfAge
        default: self = .other
        }
    }
}
