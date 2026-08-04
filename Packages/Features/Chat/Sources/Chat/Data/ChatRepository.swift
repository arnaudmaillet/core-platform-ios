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
    /// The non-viewer member(s). Exactly one for a DM — the identity the
    /// thread header shows and links to.
    public let otherMemberIDs: [ProfileID]
    /// The DM correspondent's handle, when hydration resolved one.
    ///
    /// Carried because the compose picker lists recent correspondents beside
    /// suggestions and search hits, which both have handles: without it those
    /// rows were name-only and the section read as a different, poorer kind of
    /// row. Free to collect — the same `GetProfileById` that resolves the
    /// title already returns it.
    public let directPeerHandle: String?
    /// Whether `lastMessage` is the viewer's own. Free at hydration time (the
    /// sender is already in hand) and the signal `MessageRequestPolicy` reads
    /// to tell a pending request from a conversation the viewer answered.
    public let lastMessageIsMine: Bool
    /// The newest message's id, or empty for a conversation with no messages.
    /// Carried because marking a thread read means moving the read cursor
    /// *to a specific message* — the inbox can't do that from a preview
    /// string, and re-fetching history per row to find it would be absurd.
    public let lastMessageID: String
    /// Whether the viewer has yet to read the latest message.
    ///
    /// Unlike the request partition, this is NOT a heuristic: `chat.v1` tracks
    /// it properly as `MemberView.last_read`, and `markRead` (already sent
    /// when a thread is opened) clears it server-side. A conversation whose
    /// last message is the viewer's own is never unread.
    public let isUnread: Bool
    /// How many of the newest messages the viewer has not read — the number the
    /// All list puts on the sender's avatar.
    ///
    /// Derived, not served: `chat.v1` has no `unread_count`
    /// (`dev/BACKEND_GAPS.md` §17). It is counted from the tail of the history
    /// this hydration already fetches, against the read cursor the member view
    /// already carries, so it costs no extra round trip — only a bigger page.
    ///
    /// ⚠️ **Bounded by that page.** Past `unreadWindow` messages the true figure
    /// is unknowable from one call, and this saturates rather than guessing:
    /// the badge reads "20+" and means it. Zero exactly when `isUnread` is
    /// false, so the two can never disagree about whether anything is waiting.
    public let unreadCount: Int

    public init(
        id: ConversationID,
        title: String,
        lastMessage: String,
        lastActivityAt: Date?,
        otherMemberIDs: [ProfileID] = [],
        directPeerHandle: String? = nil,
        lastMessageIsMine: Bool = false,
        lastMessageID: String = "",
        isUnread: Bool = false,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.lastMessage = lastMessage
        self.lastActivityAt = lastActivityAt
        self.otherMemberIDs = otherMemberIDs
        self.directPeerHandle = directPeerHandle
        self.lastMessageIsMine = lastMessageIsMine
        self.lastMessageID = lastMessageID
        self.isUnread = isUnread
        self.unreadCount = unreadCount
    }

    /// The DM correspondent: the single other member. `nil` for group shapes,
    /// where "the peer" is not a meaningful destination.
    public var directPeerID: ProfileID? {
        otherMemberIDs.count == 1 ? otherMemberIDs.first : nil
    }

    /// The inbox's row order: newest activity first, ties broken on id.
    ///
    /// The tie-break is not decoration — it is what makes this a TOTAL order.
    /// Swift's `sort` is introsort and explicitly **not stable**, so ordering
    /// on the timestamp alone lets rows with equal activity swap places
    /// between two otherwise identical loads. Equal timestamps are ordinary
    /// (messages within the same millisecond, backfills, seeded fixtures), and
    /// the symptom is a list that reshuffles for no visible reason every time
    /// you come back to it.
    public static func isOrderedBefore(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        let left = lhs.lastActivityAt ?? .distantPast
        let right = rhs.lastActivityAt ?? .distantPast
        guard left == right else { return left > right }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// One message in a thread. `isMine` drives left/right bubble alignment.
public struct ChatMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let senderID: ProfileID
    public let body: String
    public let createdAt: Date
    public let isMine: Bool
    /// The id of the message this one replies to, if any — chat.v1's
    /// `reply_to`. `nil` for a normal (non-threaded) message.
    public let replyToID: String?

    public init(
        id: String,
        senderID: ProfileID,
        body: String,
        createdAt: Date,
        isMine: Bool,
        replyToID: String? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isMine = isMine
        self.replyToID = replyToID
    }
}

/// Resolves who the viewer is, once, for anyone who needs it.
///
/// Split out of `ChatProviding` so the social surfaces beside the inbox can
/// depend on the identity without depending on chat: they need the same
/// profile id `ChatRepository` already resolves and caches, and two
/// independent resolutions would mean two extra round trips per cold start.
public protocol ViewerIdentityProviding: Sendable {
    func viewerProfileID() async throws -> ProfileID
}

public protocol ChatProviding: ViewerIdentityProviding {
    func loadConversations() async throws -> [Conversation]
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage]
    /// Sends `body`, optionally as a threaded reply to `replyToID` (chat.v1
    /// `reply_to`). Returns the created, viewer-owned message.
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws
    /// The direct-message conversation with `profileID`, reusing an existing
    /// 1:1 conversation or creating one.
    func directConversation(with profileID: ProfileID) async throws -> ConversationID
}

extension ChatProviding {
    /// The thread's header context (title + peer). Default rides
    /// `loadConversations`; conformances can override with a leaner query
    /// once chat.v1 exposes a single-conversation lookup.
    public func conversationSummary(for id: ConversationID) async throws -> Conversation? {
        try await loadConversations().first { $0.id == id }
    }

    /// Non-reply convenience — the common case reads `send(body, to:)`.
    public func send(_ body: String, to conversationID: ConversationID) async throws -> ChatMessage {
        try await send(body, to: conversationID, replyingTo: nil)
    }
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
    private var handleCache: [ProfileID: String] = [:]

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

    public func viewerProfileID() async throws -> ProfileID {
        try await resolveViewerProfileID()
    }

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
            // A cancelled load must REPORT cancellation, not hand back what it
            // managed to hydrate first. Cancelling in-flight Connect calls
            // makes them fail rather than throw, and `hydrateConversation`
            // skips failures — so without this check a superseded load returns
            // a truncated inbox that looks exactly like a real, shorter one.
            try Task.checkCancellation()
            if let conversation = await hydrateConversation(ConversationID(id), viewer: viewer) {
                conversations.append(conversation)
            }
        }
        try Task.checkCancellation()
        // Most recent activity first; conversations without messages sink.
        return conversations.sorted(by: Conversation.isOrderedBefore)
    }

    private func hydrateConversation(_ id: ConversationID, viewer: ProfileID) async -> Conversation? {
        // Members → the title (the other participant(s)).
        var membersRequest = Chat_V1_ListMembersRequest()
        membersRequest.conversationID = id.rawValue
        membersRequest.requesterID = viewer.rawValue
        let membersResponse = await chatClient.listMembers(request: membersRequest, headers: [:])
        guard let members = membersResponse.message?.members else { return nil }
        let otherIDs = members.map { ProfileID($0.profileID) }.filter { $0 != viewer }

        // Last message → preview + activity time. And the tail behind it →
        // how many messages are waiting.
        //
        // ⚠️ The limit was 1. It is a WINDOW now, and the difference is payload,
        // not round trips: this call already happens once per conversation
        // (which is why the inbox is expensive at all), so counting the unread
        // tail costs a bigger page rather than another request. The window is
        // what bounds the count — see `Conversation.unreadCount`.
        var historyRequest = Chat_V1_GetHistoryRequest()
        historyRequest.conversationID = id.rawValue
        historyRequest.requesterID = viewer.rawValue
        historyRequest.limit = Int32(Self.unreadWindow)
        let historyResponse = await chatClient.getHistory(request: historyRequest, headers: [:])
        let window = historyResponse.message?.messages ?? []
        let latest = window.max { $0.createdAtMs < $1.createdAtMs }

        await hydrateNames(for: otherIDs)
        let title = otherIDs.isEmpty
            ? "Conversation"
            : otherIDs.compactMap { nameCache[$0] }.joined(separator: ", ")

        let latestIsMine = latest.map { ProfileID($0.senderID) == viewer } ?? false
        // The viewer's own membership carries how far they have read. Both
        // sides of the comparison come from calls this hydration already
        // makes, so unread costs no extra traffic.
        let viewerLastRead = members.first { ProfileID($0.profileID) == viewer }?.lastRead

        return Conversation(
            id: id,
            title: title.isEmpty ? "Conversation" : title,
            lastMessage: latest?.body ?? "",
            lastActivityAt: latest.map { Date(timeIntervalSince1970: TimeInterval($0.createdAtMs) / 1000) },
            otherMemberIDs: otherIDs,
            directPeerHandle: otherIDs.count == 1 ? handleCache[otherIDs[0]] : nil,
            lastMessageIsMine: latestIsMine,
            lastMessageID: latest?.messageID ?? "",
            isUnread: Self.isUnread(latest: latest, viewerLastRead: viewerLastRead, latestIsMine: latestIsMine),
            unreadCount: Self.unreadCount(
                in: window,
                viewer: viewer,
                viewerLastRead: viewerLastRead,
                isUnread: Self.isUnread(latest: latest, viewerLastRead: viewerLastRead, latestIsMine: latestIsMine)
            )
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

    public func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_SendMessageRequest()
        request.conversationID = conversationID.rawValue
        request.senderID = viewer.rawValue
        request.contentType = .text
        request.body = body
        if let replyToID { request.replyTo = replyToID }
        let response = await chatClient.sendMessage(request: request, headers: [:])
        switch response.result {
        case .success(let created):
            return ChatMessage(
                id: created.messageID,
                senderID: viewer,
                body: body,
                createdAt: Date(),
                isMine: true,
                replyToID: replyToID
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
        let fetched = await withTaskGroup(of: (ProfileID, String, String)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    let response = await client.getProfileByID(request: request, headers: [:])
                    guard let view = response.message else { return nil }
                    return (id, view.displayName, view.handle)
                }
            }
            return await group.reduce(into: [(ProfileID, String, String)]()) { partial, triple in
                if let triple { partial.append(triple) }
            }
        }
        for (id, name, handle) in fetched {
            nameCache[id] = name
            if !handle.isEmpty { handleCache[id] = handle }
        }
    }

    /// A conversation is unread when its newest message is someone else's and
    /// the viewer's read cursor hasn't reached it. An empty cursor means the
    /// viewer has never read the thread, which is unread by definition.
    private static func isUnread(
        latest: Chat_V1_MessageView?,
        viewerLastRead: String?,
        latestIsMine: Bool
    ) -> Bool {
        guard let latest, !latestIsMine else { return false }
        return viewerLastRead != latest.messageID
    }

    /// How many messages the inbox reads per conversation, and so how far the
    /// unread count can see. Twenty is well past the point where a badge stops
    /// being a number anyone reads and starts being "a lot".
    static let unreadWindow = 20

    /// The unread tail: inbound messages newer than the viewer's read cursor.
    ///
    /// Anchored on the CURSOR's position rather than on timestamps — the cursor
    /// is a message id, and comparing ids is exact where comparing times has to
    /// pick a side when two messages share a millisecond. A cursor that is not
    /// in the window means the viewer has read nothing recent, so everything in
    /// the window that is not theirs counts.
    ///
    /// Gated on `isUnread` so the count and the flag can never disagree: that
    /// flag already knows the cases a raw count does not, such as a thread whose
    /// newest message is the viewer's own.
    static func unreadCount(
        in window: [Chat_V1_MessageView],
        viewer: ProfileID,
        viewerLastRead: String?,
        isUnread: Bool
    ) -> Int {
        guard isUnread else { return 0 }
        let ordered = window.sorted { $0.createdAtMs < $1.createdAtMs }
        let tail: [Chat_V1_MessageView]
        if let cursor = viewerLastRead, !cursor.isEmpty,
           let readIndex = ordered.firstIndex(where: { $0.messageID == cursor }) {
            tail = Array(ordered[ordered.index(after: readIndex)...])
        } else {
            tail = ordered
        }
        return tail.count { ProfileID($0.senderID) != viewer }
    }

    private static func makeMessage(from view: Chat_V1_MessageView, viewer: ProfileID) -> ChatMessage {
        let sender = ProfileID(view.senderID)
        return ChatMessage(
            id: view.messageID,
            senderID: sender,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000),
            isMine: sender == viewer,
            replyToID: view.replyTo.isEmpty ? nil : view.replyTo
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
