import CoreModels
import Foundation

/// One section of the notifications list.
///
/// There are two, and the split replaces the old unread TINT: a row's place
/// says whether it is new, so no row has to be painted differently from its
/// neighbours to say it (and nothing changes colour under the viewer's eye
/// when it is marked read — it simply is in "Earlier" next time).
public struct NotificationSection: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Unread — what arrived since the viewer last opened the drawer.
        case new
        /// Everything already seen.
        case earlier
    }

    public let kind: Kind
    /// The rows shown.
    public let rows: [NotificationDisplayModel]
    /// Rows held back behind "Show more" — only ever non-zero for `.new`.
    public let hiddenCount: Int

    public var title: String {
        switch kind {
        case .new: "New"
        case .earlier: "Earlier"
        }
    }
}

/// Builds the list's sections from loaded notifications.
enum NotificationSectionBuilder {
    /// How many new rows show before "Show more": the six most recent.
    static let newLimit = 6

    /// `newExpanded` is the viewer having pressed "Show more".
    ///
    /// ⚠️ "Show more" never hides ONE row: a button the height of a row that
    /// reveals a single row is a tap for nothing, so up to `newLimit + 1` new
    /// rows simply all show.
    static func sections(
        from items: [NotificationItem],
        newExpanded: Bool,
        now: Date,
        newLimit: Int = NotificationSectionBuilder.newLimit
    ) -> [NotificationSection] {
        let grouped = NotificationGrouping.grouped(items)
        let unread = grouped.filter { !$0.isRead }.map { NotificationDisplayModel(item: $0, now: now) }
        let read = grouped.filter(\.isRead).map { NotificationDisplayModel(item: $0, now: now) }

        var sections: [NotificationSection] = []
        if !unread.isEmpty {
            let collapses = !newExpanded && unread.count > newLimit + 1
            let shown = collapses ? Array(unread.prefix(newLimit)) : unread
            sections.append(NotificationSection(kind: .new, rows: shown, hiddenCount: unread.count - shown.count))
        }
        if !read.isEmpty {
            sections.append(NotificationSection(kind: .earlier, rows: read, hiddenCount: 0))
        }
        return sections
    }
}

/// Folds notifications about the same thing into one row: "Ava and 2 others
/// liked your post" instead of three rows saying the same thing about the same
/// post.
///
/// The server already collapses (`sender_count`, `sample_sender_ids`); this is
/// the client's fallback for rows it delivered separately — the same action on
/// the same post, in the same section. Never across sections: a like already
/// seen and a new like on the same post are two pieces of news, and folding
/// them would either hide the new one in "Earlier" or re-announce the old one.
enum NotificationGrouping {
    private struct Key: Hashable {
        let action: NotificationItem.Action
        let post: PostID
        let isRead: Bool
    }

    /// Most recent first, with rows about the same (action, post, read state)
    /// folded into the most recent of them.
    static func grouped(_ items: [NotificationItem]) -> [NotificationItem] {
        let ordered = items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.createdAt != rhs.element.createdAt
                    ? lhs.element.createdAt > rhs.element.createdAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        var result: [NotificationItem] = []
        var indexByKey: [Key: Int] = [:]
        for item in ordered {
            // Only rows about a post fold: "mentioned you" twice, with no
            // subject, are two different mentions.
            guard let post = item.postSubjectID else {
                result.append(item)
                continue
            }
            let key = Key(action: item.action, post: post, isRead: item.isRead)
            if let index = indexByKey[key] {
                result[index] = merge(newer: result[index], older: item)
            } else {
                indexByKey[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// One row standing for both. The newer row leads (its sender, time and
    /// id); the count is the distinct people both rows NAME, plus whoever each
    /// counted without naming.
    ///
    /// ⚠️ The unnamed part can double-count a person counted — but not named
    /// — by both rows; no id is available to tell. Rows the server delivers
    /// singly (the case this exists for) name everyone, so they are exact.
    static func merge(newer: NotificationItem, older: NotificationItem) -> NotificationItem {
        var named: [NotificationActor] = []
        var seen = Set<ProfileID>()
        for actor in [newer.sender] + newer.sampleSenders + [older.sender] + older.sampleSenders
        where seen.insert(actor.id).inserted {
            named.append(actor)
        }
        let unnamed = unnamedCount(of: newer) + unnamedCount(of: older)
        return NotificationItem(
            id: newer.id,
            action: newer.action,
            senderID: newer.senderID,
            senderName: newer.senderName,
            senderAvatarURL: newer.senderAvatarURL,
            otherSenderCount: named.count + unnamed - 1,
            sampleSenders: Array(named.dropFirst()),
            postSubjectID: newer.postSubjectID,
            subjectPreview: newer.subjectPreview ?? older.subjectPreview,
            isRead: newer.isRead,
            createdAt: newer.createdAt
        )
    }

    /// People a row counts but does not name.
    private static func unnamedCount(of item: NotificationItem) -> Int {
        max(0, item.otherSenderCount - item.sampleSenders.count)
    }
}
