import CoreModels
import Foundation

/// One section of the notifications list.
///
/// ⚠️ SECTIONS BY DATE, NOT BY READ STATE (#1571, the owner 2026-10-22):
/// "New" used to be the server's unread, so a close and a reopen — which mark
/// everything read — emptied it. A row's section is now its day, on the
/// viewer's calendar; whether it has been seen is the row's own business
/// (#1572's dot). A section with nothing in it is left out.
public struct NotificationSection: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Today, since local midnight.
        case new
        /// The day before.
        case yesterday
        /// 2 to 7 days ago.
        case lastWeek
        /// 8 to 30 days ago.
        case lastMonth
        /// 31 to 365 days ago.
        case lastYear
        /// Before that.
        case older

        /// The section a notification of `date` falls in, `now` on
        /// `calendar` — whole calendar days, so 23:59 yesterday is
        /// "Yesterday" at 00:01 today. A date ahead of `now` (a skewed clock)
        /// is today's.
        static func of(_ date: Date, now: Date, calendar: Calendar) -> Kind {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
            switch days {
            case ...0: return .new
            case 1: return .yesterday
            case 2...7: return .lastWeek
            case 8...30: return .lastMonth
            case 31...365: return .lastYear
            default: return .older
            }
        }
    }

    public let kind: Kind
    /// The rows shown.
    public let rows: [NotificationDisplayModel]
    /// Rows held back behind "Show more".
    public let hiddenCount: Int

    public var title: String {
        switch kind {
        case .new: "New"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last week"
        case .lastMonth: "Last month"
        case .lastYear: "Last year"
        case .older: "Older"
        }
    }
}

/// Builds the list's sections from loaded notifications.
enum NotificationSectionBuilder {
    /// How many rows a section shows before "Show more" (#1571).
    static let sectionLimit = 6
    /// The LAST section shown takes a little more: nothing comes after it to
    /// scroll on to.
    static let lastSectionLimit = 12

    /// `expanded`: the sections whose "Show more" the viewer pressed.
    ///
    /// ⚠️ "Show more" never hides ONE row: a button the height of a row that
    /// reveals a single row is a tap for nothing, so up to `limit + 1` rows
    /// simply all show.
    static func sections(
        from items: [NotificationItem],
        expanded: Set<NotificationSection.Kind> = [],
        now: Date,
        calendar: Calendar = .current,
        limit: Int = NotificationSectionBuilder.sectionLimit,
        lastLimit: Int = NotificationSectionBuilder.lastSectionLimit
    ) -> [NotificationSection] {
        let kindOf = { (item: NotificationItem) in NotificationSection.Kind.of(item.createdAt, now: now, calendar: calendar) }
        let grouped = NotificationGrouping.grouped(items, section: kindOf)
        var byKind: [NotificationSection.Kind: [NotificationDisplayModel]] = [:]
        for item in grouped {
            byKind[kindOf(item), default: []].append(NotificationDisplayModel(item: item, now: now))
        }
        let kinds = NotificationSection.Kind.allCases.filter { byKind[$0]?.isEmpty == false }
        return kinds.enumerated().map { index, kind in
            let rows = byKind[kind] ?? []
            let cap = index == kinds.count - 1 ? lastLimit : limit
            let collapses = !expanded.contains(kind) && rows.count > cap + 1
            let shown = collapses ? Array(rows.prefix(cap)) : rows
            return NotificationSection(kind: kind, rows: shown, hiddenCount: rows.count - shown.count)
        }
    }
}

/// Folds notifications about the same thing into one row: "Ava and 2 others
/// liked your post" instead of three rows saying the same thing about the same
/// post.
///
/// The server already collapses (`sender_count`, `sample_sender_ids`); this is
/// the client's fallback for rows it delivered separately — the same action on
/// the same post, in the same section and read state. Never across sections
/// (a like today and one last month are two pieces of news) nor read states
/// (a seen like and a new one: folding would hide the new one's dot).
enum NotificationGrouping {
    private struct Key: Hashable {
        let action: NotificationItem.Action
        let post: PostID
        let isRead: Bool
        let section: NotificationSection.Kind?
    }

    /// Most recent first, with rows about the same (action, post, read state)
    /// folded into the most recent of them.
    static func grouped(
        _ items: [NotificationItem],
        section: (NotificationItem) -> NotificationSection.Kind? = { _ in nil }
    ) -> [NotificationItem] {
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
            let key = Key(action: item.action, post: post, isRead: item.isRead, section: section(item))
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
