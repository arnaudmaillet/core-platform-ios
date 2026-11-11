import CoreModels
import Testing
import UIKit
@testable import Chat

/// The inbox reloads its catalog on every appearance (#2116): an unchanged
/// list must not `reloadData` — every visible row was dequeued again in the
/// turn after a tab switch or a pop. A list whose rows changed still does.
@MainActor
struct InboxReloadOnAppearTests {
    private final class CountingTable: UITableView {
        var reloads = 0
        override func reloadData() {
            reloads += 1
            super.reloadData()
        }
    }

    private func model(_ id: String) -> ConversationDisplayModel {
        ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID(id), title: id, lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: [ProfileID("peer-\(id)")],
                lastMessageIsMine: false, lastMessageID: "\(id)-latest",
                isUnread: false, unreadCount: 0
            ),
            now: Date(timeIntervalSince1970: 60),
            isPinned: false, isMuted: false, isUnread: false, unreadCount: 0
        )
    }

    @Test func anUnchangedListIsNotReloaded() {
        let table = CountingTable(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let adapter = ConversationListTableAdapter(tableView: table) { _, _, _ in UITableViewCell() }
        var shown = [model("a"), model("b")]
        adapter.apply(shown, animated: false)
        #expect(table.reloads == 1, "the first rows load")
        adapter.apply(shown, animated: false)
        #expect(table.reloads == 1, "an unchanged list reloaded")
        shown = [model("b"), model("a"), model("c")]
        adapter.apply(shown, animated: false)
        #expect(table.reloads == 2, "changed rows were not reloaded")
        #expect(adapter.allIdentifiers == [ConversationID("b"), ConversationID("a"), ConversationID("c")])
        shown = []
        adapter.apply(shown, animated: false)
        #expect(table.reloads == 3, "an emptied list kept its rows")
    }
}
