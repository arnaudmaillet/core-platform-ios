import CoreModels
import Foundation

/// Conversation context the list has already paid to load, readable
/// *synchronously* by the thread screen while it is being pushed: the nav-bar
/// identity must be laid out before the transition's first frame, and an
/// async fetch — however fast — always lands mid-flight or later.
///
/// One instance lives on `ChatFeatureBuilder`, so the list (writer) and every
/// thread (reader) share it. Purely a warm-start hint: a cold entry (deep
/// link, push payload) misses and falls back to the async lookup.
@MainActor
public final class ConversationDirectory {
    private var summaries: [ConversationID: Conversation] = [:]

    public init() {}

    public func remember(_ conversations: [Conversation]) {
        for conversation in conversations {
            summaries[conversation.id] = conversation
        }
    }

    public func summary(for id: ConversationID) -> Conversation? {
        summaries[id]
    }

    public func title(for id: ConversationID) -> String? {
        summaries[id]?.title
    }
}
