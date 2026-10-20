import CoreModels
import Foundation
import LocalStore
import OSLog

/// The device tier behind the comments' first pages (#893): a post opened in
/// an earlier session opens its comments on the last page it showed, then
/// revalidates, exactly as a post opened twice in one session does.
///
/// One entity per post (`comments.first`): the first page, threaded and
/// hydrated with authors as the panel renders it. Not a contract message (it
/// joins `comment.v1` with `profile.v1` names), so a versioned JSON record: a
/// format this build cannot read is a miss.
///
/// Reads are synchronous (the panel mounts inside a layout pass); writes go
/// to a serial queue, off the caller's thread.
final class CommentsDiskTier: Sendable {
    static let entityType = "comments.first"
    static let format = 1

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.comments-disk-tier", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "comments-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    func firstPage(for postID: PostID) -> [CommentEntry]? {
        guard let entity = store.entity(LocalEntityKey(type: Self.entityType, id: postID.rawValue)),
              entity.format == Self.format,
              let records = try? JSONDecoder().decode([Record].self, from: entity.payload) else { return nil }
        return records.map(\.entry)
    }

    func save(_ entries: [CommentEntry], for postID: PostID, as viewer: LocalStoreViewer?) {
        let store = store
        let logger = logger
        queue.async {
            guard let payload = try? JSONEncoder().encode(entries.map(Record.init)) else { return }
            do {
                try store.write([LocalEntityWrite(
                    key: LocalEntityKey(type: Self.entityType, id: postID.rawValue),
                    payload: payload, format: Self.format,
                    // A first page is a list page: a day, like the feed's.
                    lifetime: LocalStorePolicy.listLifetime, tier: .recent
                )], as: viewer)
            } catch {
                logger.error("comments cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    /// One comment as stored.
    struct Record: Codable, Equatable {
        var id: String
        var authorID: String
        var authorName: String
        var authorHandle: String
        var authorAvatarURL: URL?
        /// Absent from a record written before #943: decodes as none.
        var authorAvatarFrameID: String?
        var body: String
        var createdAt: Date
        var parentID: String?
        var isHeld: Bool
        /// Absent from a record written before #637: decodes as unknown.
        var replyCount: Int?

        init(_ entry: CommentEntry) {
            id = entry.id
            authorID = entry.authorID.rawValue
            authorName = entry.authorName
            authorHandle = entry.authorHandle
            authorAvatarURL = entry.authorAvatarURL
            authorAvatarFrameID = entry.authorAvatarFrameID
            body = entry.body
            createdAt = entry.createdAt
            parentID = entry.parentID
            isHeld = entry.isHeld
            replyCount = entry.replyCount
        }

        var entry: CommentEntry {
            CommentEntry(
                id: id, authorID: ProfileID(authorID), authorName: authorName, authorHandle: authorHandle,
                authorAvatarURL: authorAvatarURL, authorAvatarFrameID: authorAvatarFrameID, body: body,
                createdAt: createdAt, parentID: parentID, isHeld: isHeld,
                replyCount: replyCount
            )
        }
    }
}
