import CoreModels
import Foundation

/// How much of a tab is NEW since the viewer last looked at it.
///
/// The tab badges used to report totals — every unread conversation, every
/// pending request — which meant a number that sat there for as long as the
/// state did. A watermark answers the question a badge is actually asked:
/// *has anything arrived since I last looked?* — and only a new arrival brings
/// it back.
///
/// **The baseline moves when the viewer LEAVES, never when they arrive.** A
/// badge that cleared on selection was gone before it had been read: the tap
/// that shows you the tab is the same tap that empties its count, so the number
/// you were reacting to is the one thing you cannot then look at. Moving it on
/// the way out means the badge — and the marks on the rows it counted — stay up
/// for as long as the viewer is actually there, and the next arrival is what
/// brings them back.
///
/// One baseline does both jobs, because they now change at the same moment: the
/// count and the row marks are the same question asked of the same instant.
///
/// Time comes from the conversation's own `lastActivityAt`, so this is a pure
/// function of the corpus and a stored watermark — the same shape
/// `ForYouUnread` uses, and for the same reason: a count that is DERIVED cannot
/// drift out of step with the rows it counts.
struct InboxTabWatermark: Equatable {
    /// Everything that arrived after this is new: counted on the tab, marked
    /// on its row.
    private(set) var baseline: Date

    /// Opens at the moment the screen did, so nothing already on
    /// screen when the viewer arrived is announced as new. A first sight is
    /// never "all new" — the trap `ForYouUnread` documents.
    init(openedAt: Date) {
        baseline = openedAt
    }

    /// The viewer has left the tab — paged away, or left the screen. What was
    /// new has now been seen, so the next arrival is measured from here.
    mutating func leave(at now: Date) {
        baseline = now
    }

    /// How many of these arrived since the viewer last left.
    func newCount(in conversations: [Conversation]) -> Int {
        conversations.count { isNewer($0, than: baseline) }
    }

    /// Whether this row carries a mark — the same question the count asks, of
    /// one row.
    func isNewOnRow(_ conversation: Conversation) -> Bool {
        isNewer(conversation, than: baseline)
    }

    /// A conversation with no activity at all has no arrival time, so it cannot
    /// be new — it is a row that has always been there.
    private func isNewer(_ conversation: Conversation, than date: Date) -> Bool {
        guard let activity = conversation.lastActivityAt else { return false }
        return activity > date
    }
}
