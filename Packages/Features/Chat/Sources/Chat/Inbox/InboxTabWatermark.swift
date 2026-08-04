import CoreModels
import Foundation

/// How much of a tab is NEW since the viewer last looked at it.
///
/// The tab badges used to report totals — every unread conversation, every
/// pending request — which meant a number that sat there for as long as the
/// state did. A watermark answers the question a badge is actually asked:
/// *has anything arrived since I last looked?* Visiting the tab answers it, so
/// the badge clears on selection and only comes back when something new lands.
///
/// **Two baselines, and the second one is the point.** `badge` moves to now on
/// every visit, so the count goes to zero the moment the tab is selected.
/// `rows` keeps the PREVIOUS visit's baseline for the length of this one, so
/// the rows that were new stay marked while the viewer is reading them. Moving
/// both together would clear the badge and un-mark every row in the same frame,
/// which is a tab that tells you something arrived and then hides which one.
///
/// Time comes from the conversation's own `lastActivityAt`, so this is a pure
/// function of the corpus and a stored watermark — the same shape
/// `ForYouUnread` uses, and for the same reason: a count that is DERIVED cannot
/// drift out of step with the rows it counts.
struct InboxTabWatermark: Equatable {
    /// Everything after this counts toward the badge.
    private(set) var badge: Date
    /// Everything after this is marked on its row.
    private(set) var rows: Date

    /// Opens both baselines at the moment the screen did, so nothing already on
    /// screen when the viewer arrived is announced as new. A first sight is
    /// never "all new" — the trap `ForYouUnread` documents.
    init(openedAt: Date) {
        badge = openedAt
        rows = openedAt
    }

    /// The tab was selected: clear its badge, and hand the rows the baseline
    /// the badge was counting against so they keep showing WHICH items the
    /// count was about.
    mutating func visit(at now: Date) {
        rows = badge
        badge = now
    }

    /// How many of these arrived since the last visit.
    func newCount(in conversations: [Conversation]) -> Int {
        conversations.count { isNewer($0, than: badge) }
    }

    /// Whether this row should carry a mark for the length of this visit.
    func isNewOnRow(_ conversation: Conversation) -> Bool {
        isNewer(conversation, than: rows)
    }

    /// A conversation with no activity at all has no arrival time, so it cannot
    /// be new — it is a row that has always been there.
    private func isNewer(_ conversation: Conversation, than date: Date) -> Bool {
        guard let activity = conversation.lastActivityAt else { return false }
        return activity > date
    }
}
