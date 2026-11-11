import CoreModels
import Foundation
import UIKit

/// The sections of an inbox list (#2292, the owner 2026-11-11): ONE LIST PER
/// TAB.
///
/// Chats and Requests were split into "New" and "Recent" by
/// `InboxTabWatermark` (#1210, #2171). The split went: "new" meant "since the
/// cold launch", a rule nobody can see, and an unread row older than it sat
/// in "Recent", still bold and counted, so the two sections read alike. The
/// list is sorted by recency anyway, so the new rows are at the top without
/// a header. The watermark now only decides the ink of a row's unread count
/// (`ConversationDisplayModel.unreadInk`).
///
/// What keeps a section of its own is another KIND of row: Requests' join
/// requests for a channel the viewer runs (#2230). It wears no header either
/// (#2328, the owner 2026-11-11): the row already says what it is ("Studio
/// drops · 3 requests", its line, its disc and chevron), as "Hidden requests"
/// does at the other end of the same list. The section stays for the data
/// source's sake, and for the gap under its last row.
enum InboxListSection: Hashable {
    /// The channels the viewer runs with requests waiting (#2230): Requests'
    /// first section, one row per channel, with no header (#2328). Never in
    /// Chats.
    case joinRequests
    /// The conversations — on Requests, the conversation requests — in one
    /// list sorted by recency (pinned first on Chats), with no header.
    case conversations
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
