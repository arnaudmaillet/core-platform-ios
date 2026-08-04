import CoreModels
import Foundation
import UIKit

/// An inbox list split in two: what arrived since the viewer last left the
/// screen, and everything that was already there.
///
/// **The first section and the tab's badge are the same number, by
/// construction.** Both come from one `InboxTabWatermark` inside one view
/// model, so a badge reading 3 sits over a section holding exactly three rows —
/// they cannot drift, because there is nothing to keep in step. A count derived
/// in the header and a filter applied in the list would be two answers to one
/// question, and the bug where they disagree is invisible until someone counts.
///
/// ⚠️ For the All list, "new" is NOT the same as "unread". Unread is server
/// truth — a read cursor — and a conversation can sit unread for a week without
/// being new. New is "since you last looked at this screen". So an unread row
/// whose last message predates the visit belongs in the second section, still
/// bold, still badged: it is waiting, but it is not news.
public struct InboxListSections: Equatable, Sendable {
    public var new: [ConversationDisplayModel] = []
    public var earlier: [ConversationDisplayModel] = []

    public var isEmpty: Bool { new.isEmpty && earlier.isEmpty }

    /// Every row in display order, for the callers that do not care about the
    /// split — a tap resolving an id, a test asserting ordering.
    public var all: [ConversationDisplayModel] { new + earlier }

    /// Splits rows by a predicate, preserving the order they arrive in. The
    /// list is already sorted by recency, so the new section is the recent end
    /// of it and neither section needs sorting of its own.
    public init(rows: [ConversationDisplayModel], isNew: (ConversationDisplayModel) -> Bool) {
        for row in rows {
            if isNew(row) { new.append(row) } else { earlier.append(row) }
        }
    }

    public init() {}
}

/// The two halves of an inbox list, and the titles they wear.
///
/// The first section's count is the tab badge's count — see
/// `InboxListSections`. A section with nothing in it is not appended at all, so
/// an inbox with no arrivals renders as one unlabelled list rather than as an
/// empty header over everything.
enum InboxListSection: Hashable {
    case new
    case earlier
}

/// A diffable source that can title its sections.
///
/// `UITableViewDiffableDataSource` answers the data source protocol itself, so
/// a `titleForHeaderInSection` on the delegate is never asked — the header has
/// to come from here or not at all.
final class SectionedConversationDataSource: UITableViewDiffableDataSource<InboxListSection, ConversationID> {
    /// What each section is called, set by the list that owns it: "Unread" and
    /// "Recent" in All, "New Requests" and "Earlier" in Requests.
    var titles: [InboxListSection: String] = [:]

    override func tableView(_ tableView: UITableView, titleForHeaderInSection index: Int) -> String? {
        // A single section is the whole list; titling it says nothing.
        guard snapshot().numberOfSections > 1 else { return nil }
        return titles[snapshot().sectionIdentifiers[index]]
    }
}
