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
        // (sender, body, minutesAgo)
        let specs: [(String, String, Int64)] = [
            (other, "Hey! Did you see the new build?", 60),
            (viewer, "Yeah, shipping it today 🚀", 58),
            (other, "Nice — ping me when it's live", 55)
        ]
        return specs.map { sender, body, minutesAgo in
            var view = Chat_V1_MessageView()
            view.messageID = "\(conversationID)-m\(minutesAgo)"
            view.senderID = sender
            view.body = body
            view.createdAtMs = nowMs - minutesAgo * minute
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
                view.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                sent[request.conversationID, default: []].append(view)
                return id
            }
        }
    }
}
