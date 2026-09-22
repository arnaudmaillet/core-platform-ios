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

/// Which rows a diffable list has to re-render even though its diff is empty.
///
/// ⚠️ **A conversation row changes without its identity changing.** Reading one
/// clears its bold preview and its count; pinning or muting one changes its
/// accessories — and none of that touches the `ConversationID` the snapshot is
/// keyed on. The diff therefore reports nothing to do and the cell provider
/// never runs again, so the row keeps rendering the state it had when it was
/// first dequeued. That is not a stale-data bug in the model layer: the model
/// is already correct and the list is simply not asking for it.
///
/// Shared by both conversation lists because it is one rule about one row type.
/// It lived inline in the All list and was missing from Requests, which is
/// exactly how a read request kept its badge while a read conversation didn't.
enum InboxRowDiff {
    /// Rows present both before and after whose content differs. New rows are
    /// excluded on purpose — the diff already inserts those, and reconfiguring
    /// an item the snapshot is adding in the same pass is not a thing to ask
    /// for.
    static func changedRows(
        in models: [ConversationDisplayModel],
        against previous: [ConversationID: ConversationDisplayModel]
    ) -> [ConversationID] {
        models.filter { previous[$0.id] != nil && previous[$0.id] != $0 }.map(\.id)
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

    /// Puts a section's first row directly under the bar — see
    /// `UITableView.scrollFirstRow(ofSection:toPinLine:)` for why not
    /// `scrollToRow(at:.top)`. A no-op for a section with no rows.
    func scroll(_ tableView: UITableView, toSectionAt index: Int) {
        guard snapshot().numberOfSections > index,
              tableView.numberOfRows(inSection: index) > 0
        else { return }
        tableView.scrollFirstRow(ofSection: index)
    }

    /// Where a section currently sits, or `nil` if the list does not have one.
    func index(of section: InboxListSection) -> Int? {
        snapshot().sectionIdentifiers.firstIndex(of: section)
    }
}

extension UITableView {
    /// Puts a section's first row on the PIN LINE — the top of the visible
    /// content, under the bar — which is what tapping that section's name
    /// means: "show me this part".
    ///
    /// ⚠️ NOT `scrollToRow(at:.top)`. A plain table keeps its pinned header's
    /// box in front of the row it scrolls to, which was right while the
    /// capsule was drawn in that box. The capsule is in the navigation bar now
    /// and the pinned header is invisible (`InboxSectionHeaderView`), so
    /// `.top` landed the row under an empty band as tall as the header — a
    /// blank strip between the bar and the first row, measured on the inbox
    /// at 55pt. The offset is set by hand instead: the row's own top on the
    /// line, its (invisible) header stuck over it exactly as it is mid-scroll.
    ///
    /// Clamped for a list too short to scroll — an offset cannot invent
    /// content, so a two-section list that already fits on screen stays where
    /// it is.
    func scrollFirstRow(ofSection section: Int, animated: Bool = true) {
        guard numberOfSections > section, numberOfRows(inSection: section) > 0 else { return }
        layoutIfNeeded()
        let row = rectForRow(at: IndexPath(row: 0, section: section))
        let inset = adjustedContentInset
        let furthest = contentSize.height + inset.bottom - bounds.height
        let target = min(row.minY - inset.top, furthest)
        setContentOffset(CGPoint(x: 0, y: max(-inset.top, target)), animated: animated)
    }

    /// Where the list RESTS: the first row on the pin line, its header above
    /// the resting position — in the flow, out of view, and one pull away.
    func restPastLeadingHeader() {
        scrollFirstRow(ofSection: 0, animated: false)
    }

    /// A scroll that ends INSIDE the first header's band — between the top of
    /// the content and the first row — snaps past it, the way a large title
    /// snaps shown or hidden rather than resting half-revealed. A release
    /// that pulled far enough to refresh is not a scroll end and is left alone.
    func snapPastLeadingHeader() {
        guard numberOfSections > 0, numberOfRows(inSection: 0) > 0 else { return }
        let inset = adjustedContentInset
        let headerTop = rect(forSection: 0).minY - inset.top
        let rowTop = rectForRow(at: IndexPath(row: 0, section: 0)).minY - inset.top
        let offset = contentOffset.y
        guard offset > headerTop - 0.5, offset < rowTop - 0.5 else { return }
        scrollFirstRow(ofSection: 0)
    }
}
