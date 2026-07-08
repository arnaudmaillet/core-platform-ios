import AuthInterface
import CoreContracts
import CoreModels
import Foundation

public enum ChatError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case transport(message: String)
}

/// A conversation summary for the list: a title (the other member(s)), the last
/// message preview, and when it last had activity.
public struct Conversation: Equatable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let lastMessage: String
    public let lastActivityAt: Date?

    public init(id: ConversationID, title: String, lastMessage: String, lastActivityAt: Date?) {
        self.id = id
        self.title = title
        self.lastMessage = lastMessage
        self.lastActivityAt = lastActivityAt
    }
}

/// One message in a thread. `isMine` drives left/right bubble alignment.
public struct ChatMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let senderID: ProfileID
    public let body: String
    public let createdAt: Date
    public let isMine: Bool

    public init(id: String, senderID: ProfileID, body: String, createdAt: Date, isMine: Bool) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

public protocol ChatProviding: Sendable {
    func loadConversations() async throws -> [Conversation]
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage]
    func send(_ body: String, to conversationID: ConversationID) async throws -> ChatMessage
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws
    /// The direct-message conversation with `profileID`, reusing an existing
    /// 1:1 conversation or creating one.
    func directConversation(with profileID: ProfileID) async throws -> ConversationID
}

/// Reads/writes conversations via chat.v1, hydrating member names via
/// profile.v1 (the chat views carry only ids). Live delivery (streamConversation)
/// is intentionally not wired — the realtime gateway resets connections
/// (`dev/BACKEND_GAPS.md` §1); the UI works on request/response + refresh.
public actor ChatRepository: ChatProviding {
    private let chatClient: any Chat_V1_ChatServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let pageSize: Int32

    private var viewerProfileID: ProfileID?
    private var nameCache: [ProfileID: String] = [:]

    public init(
        chatClient: any Chat_V1_ChatServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        pageSize: Int32 = 50
    ) {
        self.chatClient = chatClient
        self.profileClient = profileClient
        self.authSession = authSession
        self.pageSize = pageSize
    }

    // MARK: - Conversations

    public func loadConversations() async throws -> [Conversation] {
        let viewer = try await resolveViewerProfileID()

        var request = Chat_V1_ListSubscriptionsRequest()
        request.subscriberID = viewer.rawValue
        request.limit = pageSize
        let response = await chatClient.listSubscriptions(request: request, headers: [:])
        let ids: [String]
        switch response.result {
        case .success(let body): ids = body.conversationIds
        case .failure(let error): throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }

        var conversations: [Conversation] = []
        for id in ids {
            if let conversation = await hydrateConversation(ConversationID(id), viewer: viewer) {
                conversations.append(conversation)
            }
        }
        // Most recent activity first; conversations without messages sink.
        return conversations.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    private func hydrateConversation(_ id: ConversationID, viewer: ProfileID) async -> Conversation? {
        // Members → the title (the other participant(s)).
        var membersRequest = Chat_V1_ListMembersRequest()
        membersRequest.conversationID = id.rawValue
        membersRequest.requesterID = viewer.rawValue
        let membersResponse = await chatClient.listMembers(request: membersRequest, headers: [:])
        guard let members = membersResponse.message?.members else { return nil }
        let otherIDs = members.map { ProfileID($0.profileID) }.filter { $0 != viewer }

        // Last message → preview + activity time.
        var historyRequest = Chat_V1_GetHistoryRequest()
        historyRequest.conversationID = id.rawValue
        historyRequest.requesterID = viewer.rawValue
        historyRequest.limit = 1
        let historyResponse = await chatClient.getHistory(request: historyRequest, headers: [:])
        let latest = historyResponse.message?.messages.max { $0.createdAtMs < $1.createdAtMs }

        await hydrateNames(for: otherIDs)
        let title = otherIDs.isEmpty
            ? "Conversation"
            : otherIDs.compactMap { nameCache[$0] }.joined(separator: ", ")

        return Conversation(
            id: id,
            title: title.isEmpty ? "Conversation" : title,
            lastMessage: latest?.body ?? "",
            lastActivityAt: latest.map { Date(timeIntervalSince1970: TimeInterval($0.createdAtMs) / 1000) }
        )
    }

    // MARK: - Messages

    public func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_GetHistoryRequest()
        request.conversationID = conversationID.rawValue
        request.requesterID = viewer.rawValue
        request.limit = pageSize
        let response = await chatClient.getHistory(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            // Oldest first (newest at the bottom of the thread).
            return body.messages
                .sorted { $0.createdAtMs < $1.createdAtMs }
                .map { Self.makeMessage(from: $0, viewer: viewer) }
        case .failure(let error):
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func send(_ body: String, to conversationID: ConversationID) async throws -> ChatMessage {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_SendMessageRequest()
        request.conversationID = conversationID.rawValue
        request.senderID = viewer.rawValue
        request.contentType = .text
        request.body = body
        let response = await chatClient.sendMessage(request: request, headers: [:])
        switch response.result {
        case .success(let created):
            return ChatMessage(
                id: created.messageID,
                senderID: viewer,
                body: body,
                createdAt: Date(),
                isMine: true
            )
        case .failure(let error):
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {
        guard !messageID.isEmpty else { return }
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_MarkReadRequest()
        request.conversationID = conversationID.rawValue
        request.memberID = viewer.rawValue
        request.messageID = messageID
        _ = await chatClient.markRead(request: request, headers: [:])
    }

    // MARK: - Direct message

    public func directConversation(with profileID: ProfileID) async throws -> ConversationID {
        let viewer = try await resolveViewerProfileID()

        // Reuse an existing 1:1 conversation (exactly viewer + target) if any.
        if let existing = await existingDirectConversation(viewer: viewer, other: profileID) {
            return existing
        }

        // Otherwise create one and add both members.
        var create = Chat_V1_CreateConversationRequest()
        create.kind = .group
        create.ownerID = viewer.rawValue
        let response = await chatClient.createConversation(request: create, headers: [:])
        guard let id = response.message?.conversationID, !id.isEmpty else {
            throw ChatError.transport(message: response.error?.message ?? "couldn't start a conversation")
        }
        let conversationID = ConversationID(id)
        for member in [viewer, profileID] {
            await joinAndSubscribe(conversationID, member: member)
        }
        return conversationID
    }

    private func existingDirectConversation(viewer: ProfileID, other: ProfileID) async -> ConversationID? {
        var request = Chat_V1_ListSubscriptionsRequest()
        request.subscriberID = viewer.rawValue
        request.limit = pageSize
        guard let ids = (await chatClient.listSubscriptions(request: request, headers: [:])).message?.conversationIds else {
            return nil
        }
        let wanted: Set<ProfileID> = [viewer, other]
        for id in ids {
            var membersRequest = Chat_V1_ListMembersRequest()
            membersRequest.conversationID = id
            membersRequest.requesterID = viewer.rawValue
            let members = (await chatClient.listMembers(request: membersRequest, headers: [:]))
                .message?.members.map { ProfileID($0.profileID) } ?? []
            if Set(members) == wanted {
                return ConversationID(id)
            }
        }
        return nil
    }

    private func joinAndSubscribe(_ conversationID: ConversationID, member: ProfileID) async {
        var join = Chat_V1_JoinAsMemberRequest()
        join.conversationID = conversationID.rawValue
        join.profileID = member.rawValue
        _ = await chatClient.joinAsMember(request: join, headers: [:])

        var subscribe = Chat_V1_SubscribeRequest()
        subscribe.conversationID = conversationID.rawValue
        subscribe.subscriberID = member.rawValue
        _ = await chatClient.subscribe(request: subscribe, headers: [:])
    }

    // MARK: - Hydration

    private func hydrateNames(for ids: [ProfileID]) async {
        let missing = Set(ids).filter { nameCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }
        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, String)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view.displayName)
                }
            }
            return await group.reduce(into: [(ProfileID, String)]()) { partial, pair in
                if let pair { partial.append(pair) }
            }
        }
        for (id, name) in fetched { nameCache[id] = name }
    }

    private static func makeMessage(from view: Chat_V1_MessageView, viewer: ProfileID) -> ChatMessage {
        let sender = ProfileID(view.senderID)
        return ChatMessage(
            id: view.messageID,
            senderID: sender,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000),
            isMine: sender == viewer
        )
    }

    private func resolveViewerProfileID() async throws -> ProfileID {
        if let viewerProfileID {
            return viewerProfileID
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ChatError.notAuthenticated
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            guard let profile = body.profiles.first else { throw ChatError.noProfileForAccount }
            let id = ProfileID(profile.profileID)
            viewerProfileID = id
            return id
        case .failure(let error):
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
