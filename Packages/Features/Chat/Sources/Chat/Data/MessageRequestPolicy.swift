import CoreModels

/// Splits the viewer's conversations into the active inbox and pending
/// message requests.
///
/// **This is a client-side stand-in, and deliberately a small one.** `chat.v1`
/// has no request/approval plane: `ListSubscriptions` returns a flat list with
/// no `is_request` flag and no accept/decline RPCs (`dev/BACKEND_GAPS.md`).
/// Every heuristic the product needs is therefore concentrated in this one
/// pure function so that, when the service grows the plane, the call site
/// swaps a server flag in and this file is deleted — no surface, view model,
/// or cell changes.
///
/// The rule: a conversation is a **request** when the viewer does not follow
/// the other member *and* the last message is not the viewer's own. Following
/// someone means you asked for their messages; having replied means you
/// answered the ask. Conversations with no messages at all are never requests
/// — there is nothing pending to accept.
///
/// Group shapes (more than one other member) are never requests: "the sender"
/// isn't a single account the viewer can vet.
enum MessageRequestPolicy {
    struct Partition: Equatable {
        var active: [Conversation]
        var requests: [Conversation]
    }

    /// - Parameters:
    ///   - followedPeers: peers the viewer follows. Unknown peers count as
    ///     *not* followed only when the relation lookup succeeded; callers that
    ///     couldn't resolve relations at all should pass every peer, so an
    ///     outage can never quarantine a real conversation into Requests.
    ///   - accepted: requests the viewer let through this session.
    ///   - declined: requests the viewer dismissed this session.
    ///   - deleted: conversations removed from the inbox this session.
    static func partition(
        _ conversations: [Conversation],
        followedPeers: Set<ProfileID>,
        accepted: Set<ConversationID> = [],
        declined: Set<ConversationID> = [],
        deleted: Set<ConversationID> = []
    ) -> Partition {
        var active: [Conversation] = []
        var requests: [Conversation] = []
        for conversation in conversations where !deleted.contains(conversation.id) {
            if declined.contains(conversation.id) { continue }
            if accepted.contains(conversation.id) {
                active.append(conversation)
                continue
            }
            if isRequest(conversation, followedPeers: followedPeers) {
                requests.append(conversation)
            } else {
                active.append(conversation)
            }
        }
        return Partition(active: active, requests: requests)
    }

    static func isRequest(_ conversation: Conversation, followedPeers: Set<ProfileID>) -> Bool {
        guard let peer = conversation.directPeerID else { return false }
        guard conversation.lastActivityAt != nil else { return false }
        return !followedPeers.contains(peer) && !conversation.lastMessageIsMine
    }
}
