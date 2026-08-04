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

/// The two words every sectioned inbox list uses.
///
/// Both lists say "New" and "Recent" — the same split deserves the same pair,
/// and a viewer paging between the tabs should not have to re-read a header to
/// work out that it means what the last one meant.
extension InboxListSection {
    var title: String {
        switch self {
        case .new: "New"
        case .earlier: "Recent"
        }
    }
}

typealias SectionedConversationDataSource =
    UITableViewDiffableDataSource<InboxListSection, ConversationID>

extension UITableViewDiffableDataSource<InboxListSection, ConversationID> {
    /// The section at an index, or `nil` when the list is a single unlabelled
    /// block — titling the whole list says nothing, so it goes unheaded.
    func headedSection(at index: Int) -> InboxListSection? {
        let current = snapshot()
        guard current.numberOfSections > 1 else { return nil }
        return current.sectionIdentifiers[index]
    }

    /// Puts a section's first row directly under the header, which is what
    /// tapping that header's pill means: "show me this part".
    ///
    /// A no-op for a section with no rows, and for a list too short to scroll —
    /// `scrollToRow` cannot invent content, so a two-section list that already
    /// fits on screen simply stays where it is. That is correct, and it is also
    /// why this is verified on the longest list rather than the shortest.
    func scroll(_ tableView: UITableView, toSectionAt index: Int) {
        guard snapshot().numberOfSections > index,
              tableView.numberOfRows(inSection: index) > 0
        else { return }
        tableView.scrollToRow(at: IndexPath(row: 0, section: index), at: .top, animated: true)
    }

    /// Where a section currently sits, or `nil` if the list does not have one.
    func index(of section: InboxListSection) -> Int? {
        snapshot().sectionIdentifiers.firstIndex(of: section)
    }
}
