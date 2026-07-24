import Connect
import CoreContracts
import Foundation

/// Fake of chat.v1.ChatService over the shared dataset. Seeds two direct
/// conversations (viewer ↔ a dataset author) with a short history, persists
/// sent messages, and accepts MarkRead. Members are dataset authors, so profile
/// hydration resolves.
public final class MockChatService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    private let store = Store()

    /// conversationID → the other (non-viewer) member.
    private var otherMember: [String: String] { ["conv-0": dataset.authors[0].profileID, "conv-1": dataset.authors[1].profileID] }
    private let viewer = MockSocialDataset.viewerProfileID

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/chat.v1.ChatService/ListSubscriptions") { [self] (_: Chat_V1_ListSubscriptionsRequest) in
            var response = Chat_V1_ListSubscriptionsResponse()
            response.conversationIds = ["conv-0", "conv-1"]
            return .success(response)
        }
        bff.register(path: "/chat.v1.ChatService/ListMembers") { [self] (request: Chat_V1_ListMembersRequest) in
            var response = Chat_V1_ListMembersResponse()
            response.members = [member(viewer), member(otherMember[request.conversationID] ?? viewer)]
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
        bff.register(path: "/chat.v1.ChatService/MarkRead") { (_: Chat_V1_MarkReadRequest) in
            .success(Chat_V1_CommandResponse())
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

    private func member(_ profileID: String) -> Chat_V1_MemberView {
        var view = Chat_V1_MemberView()
        view.profileID = profileID
        return view
    }

    private func seedHistory(for conversationID: String) -> [Chat_V1_MessageView] {
        let other = otherMember[conversationID] ?? viewer
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let minute: Int64 = 60_000
        // (sender, body, minutesAgo). conv-0 is the dense thread-screen seed:
        // two day sections, same-sender runs (grouped bubbles), a long-wrap
        // paragraph, and back-to-back turnarounds. conv-1 stays short.
        let morning: Int64 = 25 * 60
        let midday: Int64 = 24 * 60 + 30
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
