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
/// **The baseline is set once, at launch, and never moves again.** Nothing the
/// viewer does inside a session retires a badge — not opening the tab, not
/// reading a conversation, not leaving for another tab. It went through two
/// narrower rules first (clear on selection, then clear on leaving the screen)
/// and both had the same defect at different sizes: the count vanished as a
/// side effect of an action taken for some other reason. Pushing a thread is
/// not a statement about the other fifteen.
///
/// So the reset is a COLD LAUNCH, and it needs no code: a launch builds new
/// view models, each opening a watermark at that moment. What survives a
/// session is a fact about the session — "this is what arrived since you opened
/// the app" — which is a sentence a badge can hold up for as long as the app is
/// running.
///
/// One baseline serves the count and the row marks both, because they are the
/// same question asked of the same instant.
///
/// Time comes from the conversation's own `lastActivityAt`, so this is a pure
/// function of the corpus and a stored watermark — the same shape
/// `ForYouUnread` uses, and for the same reason: a count that is DERIVED cannot
/// drift out of step with the rows it counts.
struct InboxTabWatermark: Equatable {
    /// Everything that arrived after this is new: counted on the tab, marked
    /// on its row. Immutable for the life of the watermark — see the type's
    /// comment for why a session never moves it.
    let baseline: Date

    /// Opens at the moment the screen did, so nothing already on
    /// screen when the viewer arrived is announced as new. A first sight is
    /// never "all new" — the trap `ForYouUnread` documents.
    init(openedAt: Date) {
        baseline = openedAt
    }

    /// How many of these arrived since the app was opened.
    func newCount(in conversations: [Conversation]) -> Int {
        conversations.count { isNewer($0, than: baseline) }
    }

    /// Whether this row carries a mark — the same question the count asks,
    /// of one row.
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
