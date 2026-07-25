import Connect
import CoreContracts
import Foundation

/// Fake of chat.v1.ChatService over the shared dataset. Seeds four direct
/// conversations (viewer ↔ a dataset author) with a short history, persists
/// sent messages, and accepts MarkRead. Members are dataset authors, so profile
/// hydration resolves.
public final class MockChatService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// The epoch every seeded timestamp is measured back from, pinned ONCE per
    /// instance. Recomputing `Date()` per `GetHistory` call made two seeds with
    /// the same relative age land microseconds apart — or exactly equal —
    /// depending on timing, so the inbox's ordering jittered between loads.
    private let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    private let store = Store()

    /// conversationID → the other (non-viewer) member.
    ///
    /// `conv-0`/`conv-1`/`conv-2` are with authors the viewer follows — the
    /// active inbox. `conv-0` ends on the viewer's own message (never unread);
    /// `conv-1` and `conv-2` end on an inbound one, so mock mode has TWO
    /// unread conversations. Two matters: with only one, reading it empties
    /// the Unread tab entirely, which hides whether a read row actually
    /// leaves a still-populated list.
    ///
    /// `conv-req-0`/`conv-req-1` are with authors the viewer does NOT follow
    /// and has never answered, which is exactly what `MessageRequestPolicy`
    /// partitions into the Requests tab.
    private var otherMember: [String: String] {
        [
            "conv-0": dataset.authors[0].profileID,
            "conv-1": dataset.authors[1].profileID,
            "conv-2": dataset.authors[2].profileID,
            "conv-req-0": dataset.authors[5].profileID,
            "conv-req-1": dataset.authors[6].profileID
        ]
    }
    private let viewer = MockSocialDataset.viewerProfileID

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/chat.v1.ChatService/ListSubscriptions") { [self] (_: Chat_V1_ListSubscriptionsRequest) in
            var response = Chat_V1_ListSubscriptionsResponse()
            response.conversationIds = ["conv-0", "conv-1", "conv-2", "conv-req-0", "conv-req-1"]
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/ListMembers") { [self] (request: Chat_V1_ListMembersRequest) in
            var response = Chat_V1_ListMembersResponse()
            // The viewer's member view carries `last_read`, which is what the
            // inbox derives its Unread tab from — so it has to be real state,
            // not a blank field, and MarkRead below has to move it.
            response.members = [
                member(viewer, lastRead: store.lastRead(in: request.conversationID, for: viewer)),
                member(otherMember[request.conversationID] ?? viewer)
            ]
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/GetHistory") { [self] (request: Chat_V1_GetHistoryRequest) in
            var response = Chat_V1_GetHistoryResponse()
            let all = store.messages(for: request.conversationID, seed: seedHistory(for: request.conversationID))
            response.messages = request.limit == 1 ? Array(all.suffix(1)) : all
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/SendMessage") { [self] (request: Chat_V1_SendMessageRequest) in
            let id = store.append(request)
            var response = Chat_V1_SendMessageResponse()
            response.messageID = id
            return .success(response)
        }
        // Persisted, so opening a thread genuinely clears its unread state and
        // the Unread tab can empty out (and disappear) for real.
        bff.register(path: "/chat.v1.ChatService/MarkRead") { [self] (request: Chat_V1_MarkReadRequest) in
            store.markRead(request.messageID, in: request.conversationID, for: request.memberID)
            return .success(Chat_V1_CommandResponse())
        }
        bff.register(path: "/chat.v1.ChatService/CreateConversation") { [self] (_: Chat_V1_CreateConversationRequest) in
            var response = Chat_V1_CreateConversationResponse()
            response.conversationID = store.newConversationID()
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/JoinAsMember") { (_: Chat_V1_JoinAsMemberRequest) in
            .success(Chat_V1_CommandResponse())
        }
        bff.register(path: "/chat.v1.ChatService/Subscribe") { (_: Chat_V1_SubscribeRequest) in
            .success(Chat_V1_CommandResponse())
        }
    }

    private func member(_ profileID: String, lastRead: String = "") -> Chat_V1_MemberView {
        var view = Chat_V1_MemberView()
        view.profileID = profileID
        view.lastRead = lastRead
        return view
    }

    private func seedHistory(for conversationID: String) -> [Chat_V1_MessageView] {
        let other = otherMember[conversationID] ?? viewer
        let minute: Int64 = 60_000
        // (sender, body, minutesAgo). conv-0 is the dense thread-screen seed:
        // two day sections, same-sender runs (grouped bubbles), a long-wrap
        // paragraph, and back-to-back turnarounds. conv-1 stays short.
        let morning: Int64 = 25 * 60
        let midday: Int64 = 24 * 60 + 30
        // Request threads are inbound-only and unanswered by construction —
        // that IS the partition rule, so seeding a viewer reply here would
        // quietly move the row into the active inbox.
        if conversationID.hasPrefix("conv-req-") {
            let opener = conversationID == "conv-req-0"
                ? "Hi! Loved your shot of the pier — any chance you sell prints?"
                : "Hey, we're putting together a small show next month and I'd love to include your work."
            let inbound: [(String, String, Int64)] = [
                (other, opener, 90), (other, "No pressure either way 🙂", 88)
            ]
            return inbound
                .enumerated()
                .map { index, spec in
                    var view = Chat_V1_MessageView()
                    view.messageID = "\(conversationID)-m\(index)"
                    view.senderID = spec.0
                    view.body = spec.1
                    view.createdAtMs = nowMs - spec.2 * minute
                    return view
                }
        }
        if conversationID == "conv-2" {
            let inbound: [(String, String, Int64)] = [
                (viewer, "Sent you the venue list", 200),
                (other, "Perfect, thanks! One more thing —", 40),
                (other, "can you make Thursday instead?", 38)
            ]
            return inbound.enumerated().map { index, spec in
                var view = Chat_V1_MessageView()
                view.messageID = "\(conversationID)-m\(index)"
                view.senderID = spec.0
                view.body = spec.1
                view.createdAtMs = nowMs - spec.2 * minute
                return view
            }
        }
        let specs: [(String, String, Int64)] = conversationID == "conv-0"
            ? [
                (other, "Morning! Standup moved to 9:30 today", morning),
                (other, "Room 4 this time", morning - 1),
                (other, "And bring the tab bar demo if it's ready", morning - 2),
                (viewer, "👍 on my way", morning - 4),
                (viewer, "Demo's ready — pushed the branch last night", morning - 5),
                (other, "Saw it. The thread screen rebuild is next, right? The list one is starting to feel very 2015.", midday),
                (viewer, "Yep, Telegram-style bubbles, day chips, glass input bar — the works. Native UIKit only though, no custom layout engine.", midday - 10),
                (other, "Bold claim 😄", midday - 11),
                (viewer, "Watch me", midday - 15),
                (other, "Hey! Did you see the new build?", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (viewer, "Just cleaning up the last QA notes", 57),
                (other, "Nice — ping me when it's live", 55),
                (other, "No rush, I'm in reviews all morning anyway", 54),
                (viewer, "Will do", 12)
            ]
            : [
                (other, "Hey! Did you see the new build?", 60),
                (viewer, "Yeah, shipping it today 🚀", 58),
                (other, "Nice — ping me when it's live", 55)
            ]
        // Seeded threaded replies (message index → the index it answers), so
        // the quoted-reply rendering is present in the dense demo thread
        // without having to compose one. conv-0 only.
        let replyLinks: [Int: Int] = conversationID == "conv-0" ? [6: 5, 8: 7] : [:]
        return specs.enumerated().map { index, spec in
            let (sender, body, minutesAgo) = spec
            var view = Chat_V1_MessageView()
            view.messageID = "\(conversationID)-m\(index)"
            view.senderID = sender
            view.body = body
            view.createdAtMs = nowMs - minutesAgo * minute
            if let target = replyLinks[index] { view.replyTo = "\(conversationID)-m\(target)" }
            return view
        }
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String: [Chat_V1_MessageView]] = [:]
        private var createdCount = 0
        /// conversationID → memberID → last read message id.
        private var readCursors: [String: [String: String]] = [:]

        func lastRead(in conversationID: String, for memberID: String) -> String {
            lock.withLock { readCursors[conversationID]?[memberID] ?? "" }
        }

        func markRead(_ messageID: String, in conversationID: String, for memberID: String) {
            guard !messageID.isEmpty else { return }
            lock.withLock { readCursors[conversationID, default: [:]][memberID] = messageID }
        }

        func newConversationID() -> String {
            lock.withLock {
                createdCount += 1
                return "conv-created-\(createdCount)"
            }
        }

        func messages(for conversationID: String, seed: [Chat_V1_MessageView]) -> [Chat_V1_MessageView] {
            lock.withLock { seed + (sent[conversationID] ?? []) }
        }

        func append(_ request: Chat_V1_SendMessageRequest) -> String {
            lock.withLock {
                let id = "\(request.conversationID)-sent-\(sent[request.conversationID]?.count ?? 0)"
                var view = Chat_V1_MessageView()
                view.messageID = id
                view.senderID = request.senderID
                view.body = request.body
                view.replyTo = request.replyTo
                view.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                sent[request.conversationID, default: []].append(view)
                return id
            }
        }
    }
}
