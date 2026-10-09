import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import MediaCore
import UIKit

public enum ChatError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    /// CHT-1011: the recipient takes no messages ("Who Can Message": No
    /// One, #397). A narrower audience makes the message a request instead.
    case messagesRefused
    /// The photo or video could not be uploaded (#681); nothing was sent.
    case mediaUpload(message: String)
    /// This provider sends no media.
    case mediaUnsupported
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
    /// inbox entry's preview names its sender).
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
    /// The viewer muted the conversation's pushes (chat.v1 `InboxEntryView
    /// .muted`, #654) — the thread's bell (#719).
    public let isMuted: Bool

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
        unreadCount: Int = 0,
        isMuted: Bool = false
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
        self.isMuted = isMuted
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
    /// The photo or video a MEDIA message carries (#681); `body` is then its
    /// caption, often empty.
    public let media: ChatMedia?

    public init(
        id: String,
        senderID: ProfileID,
        body: String,
        createdAt: Date,
        isMine: Bool,
        replyToID: String? = nil,
        media: ChatMedia? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.isMine = isMine
        self.replyToID = replyToID
        self.media = media
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

/// A folder of the viewer's inbox (chat.v1 `InboxFolder`, #593).
public enum InboxFolder: Sendable, Hashable {
    /// Accepted conversations — the All tab.
    case inbox
    /// Unanswered message requests to the viewer — the Requests tab.
    case requests
    /// Requests caught by the viewer's hidden words or offensive filter,
    /// sorted at read time with the CURRENT filter (#552) — the Hidden
    /// requests row at the bottom of Requests.
    case hiddenRequests
}

/// One page of a conversation's history, oldest first, and where the OLDER
/// page before it starts (#600).
public struct MessagePage: Equatable, Sendable {
    public let messages: [ChatMessage]
    /// Nil when there is nothing older.
    public let olderPageToken: String?

    public init(messages: [ChatMessage], olderPageToken: String?) {
        self.messages = messages
        self.olderPageToken = olderPageToken
    }
}

/// One page of one inbox folder, newest activity first, and where the next
/// one starts.
public struct InboxPage: Equatable, Sendable {
    public let conversations: [Conversation]
    /// Nil when the folder has no more.
    public let nextPageToken: String?

    public init(conversations: [Conversation], nextPageToken: String?) {
        self.conversations = conversations
        self.nextPageToken = nextPageToken
    }
}

public protocol ChatProviding: ViewerIdentityProviding {
    /// The first page of both folders, newest activity first — for a lookup
    /// that needs to know a conversation, not for the inbox's lists.
    func loadConversations() async throws -> [Conversation]
    /// A page of one folder: the first when `pageToken` is nil, otherwise the
    /// one that token starts (#593).
    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage]
    /// A page of a conversation's history, oldest first: the newest messages
    /// when `pageToken` is nil, otherwise the older ones that token starts
    /// (#600).
    func loadMessagesPage(in conversationID: ConversationID, before pageToken: String?) async throws -> MessagePage
    /// Sends `body`, optionally as a threaded reply to `replyToID` (chat.v1
    /// `reply_to`). Returns the created, viewer-owned message.
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage
    /// Uploads `media` (media.v1), then sends it as a MEDIA message with
    /// `caption` as its body (#681). Returns the created, viewer-owned
    /// message. `ChatError.mediaUpload` when the upload failed.
    func send(
        media: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws
    /// Mutes the conversation's pushes for the viewer, or unmutes them
    /// (chat.v1 `MuteConversation`, #654) — the thread's bell (#719).
    func setMuted(_ muted: Bool, for conversationID: ConversationID) async throws
    /// Mutes until `until` (nil: until turned back on) — the bell's long-press
    /// durations (#729, `MuteConversation.until_ms`).
    func setMuted(_ muted: Bool, until: Date?, for conversationID: ConversationID) async throws
    /// The direct-message conversation with `profileID`, reusing an existing
    /// 1:1 conversation or creating one.
    func directConversation(with profileID: ProfileID) async throws -> ConversationID
}

extension ChatProviding {
    /// Providers with no mute to write (fakes): the inbox keeps it locally.
    public func setMuted(_ muted: Bool, for conversationID: ConversationID) async throws {}

    /// Providers with no durations: a mute is a mute.
    public func setMuted(_ muted: Bool, until: Date?, for conversationID: ConversationID) async throws {
        try await setMuted(muted, for: conversationID)
    }

    /// Providers that don't page: everything they have, once.
    public func loadMessagesPage(in conversationID: ConversationID, before pageToken: String?) async throws -> MessagePage {
        guard pageToken == nil else { return MessagePage(messages: [], olderPageToken: nil) }
        return MessagePage(messages: try await loadMessages(in: conversationID), olderPageToken: nil)
    }

    /// Providers with no folders: everything is the inbox, in one page.
    public func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        guard folder == .inbox, pageToken == nil else { return InboxPage(conversations: [], nextPageToken: nil) }
        return InboxPage(conversations: try await loadConversations(), nextPageToken: nil)
    }

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

    /// Providers that send no media (previews, fakes).
    public func send(
        media: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        throw ChatError.mediaUnsupported
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
    /// Conversations per inbox page (#593).
    private let inboxPageSize: Int32

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding
    private var nameCache: [ProfileID: String] = [:]
    private var handleCache: [ProfileID: String] = [:]
    /// Uploads a message's photo or video (#681); nil sends no media.
    private let mediaUploader: MediaAssetUploader?
    private let encoder: MediaEncoder

    public init(
        chatClient: any Chat_V1_ChatServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        mediaUploader: MediaAssetUploader? = nil,
        encoder: MediaEncoder = MediaEncoder(),
        pageSize: Int32 = 50,
        inboxPageSize: Int32 = 20
    ) {
        self.mediaUploader = mediaUploader
        self.encoder = encoder
        self.chatClient = chatClient
        self.profileClient = profileClient
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this repository's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
        self.pageSize = pageSize
        self.inboxPageSize = inboxPageSize
    }

    // MARK: - Conversations

    public func viewerProfileID() async throws -> ProfileID {
        try await resolveViewerProfileID()
    }

    public func loadConversations() async throws -> [Conversation] {
        async let inbox = loadInbox(.inbox, after: nil)
        async let requests = loadInbox(.requests, after: nil)
        return try await (inbox.conversations + requests.conversations).sorted(by: Conversation.isOrderedBefore)
    }

    /// One `ListInbox` page, the rows built from the entries themselves.
    ///
    /// ⚠️ This replaced `ListSubscriptions` plus a `ListMembers` AND a
    /// `GetHistory` for every conversation — 1 + 2N calls for an inbox
    /// capped at 50. The entry carries the peer, the preview, the activity
    /// time and whether it is unread, so a read direct conversation now
    /// costs nothing beyond its peer's name (cached across pages). Two
    /// shapes still read more, each for one thing the entry lacks: a GROUP
    /// its members (the title), and an UNREAD row its read cursor and a
    /// history window (the count on its avatar).
    ///
    /// Rows keep the server's order — newest activity first — so a page
    /// appended below never reorders the ones above it. The server filters
    /// each page after reading it: follow the token, never the count.
    public func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_ListInboxRequest()
        request.profileID = viewer.rawValue
        request.folder = switch folder {
        case .inbox: .inbox
        case .requests: .requests
        case .hiddenRequests: .hiddenRequests
        }
        request.limit = inboxPageSize
        request.pageToken = pageToken ?? ""
        let response = await chatClient.listInbox(request: request, headers: [:])
        let entries: [Chat_V1_InboxEntryView]
        let nextToken: String
        switch response.result {
        case .success(let body):
            entries = body.entries
            nextToken = body.nextPageToken
        case .failure(let error):
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }

        let details = await Self.fetchDetails(for: entries, viewer: viewer, client: chatClient)
        // A cancelled load must REPORT cancellation, not hand back what it
        // managed to resolve: cancelled Connect calls fail rather than throw,
        // and a row whose details failed is still built — so without this a
        // superseded load returns rows that look real and are not.
        try Task.checkCancellation()
        let peers = entries.flatMap { entry in
            entry.peerID.isEmpty
                ? (details[entry.conversationID]?.members ?? []).map { ProfileID($0.profileID) }
                : [ProfileID(entry.peerID)]
        }
        await hydrateNames(for: peers.filter { $0 != viewer })
        try Task.checkCancellation()
        let conversations = entries.map { conversation(from: $0, detail: details[$0.conversationID], viewer: viewer) }
        return InboxPage(conversations: conversations, nextPageToken: nextToken.isEmpty ? nil : nextToken)
    }

    /// What an entry doesn't carry, read only where it is needed: a group's
    /// members (its title), an unread row's members (its read cursor) and
    /// history window (its count). Concurrently — a page's unread rows don't
    /// wait on each other.
    private struct EntryDetail: Sendable {
        var members: [Chat_V1_MemberView]?
        var window: [Chat_V1_MessageView] = []
    }

    private static func fetchDetails(
        for entries: [Chat_V1_InboxEntryView],
        viewer: ProfileID,
        client: any Chat_V1_ChatServiceClientInterface
    ) async -> [String: EntryDetail] {
        await withTaskGroup(of: (String, EntryDetail).self) { group in
            for entry in entries where entry.peerID.isEmpty || entry.unread {
                let id = entry.conversationID
                let readsHistory = entry.unread
                group.addTask {
                    var membersRequest = Chat_V1_ListMembersRequest()
                    membersRequest.conversationID = id
                    membersRequest.requesterID = viewer.rawValue
                    var detail = EntryDetail()
                    detail.members = (await client.listMembers(request: membersRequest, headers: [:])).message?.members
                    if readsHistory {
                        // The count is bounded by this window — see `unreadCount`.
                        var historyRequest = Chat_V1_GetHistoryRequest()
                        historyRequest.conversationID = id
                        historyRequest.requesterID = viewer.rawValue
                        historyRequest.limit = Int32(unreadWindow)
                        detail.window = (await client.getHistory(request: historyRequest, headers: [:])).message?.messages ?? []
                    }
                    return (id, detail)
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

    private func conversation(from entry: Chat_V1_InboxEntryView, detail: EntryDetail?, viewer: ProfileID) -> Conversation {
        let otherIDs = entry.peerID.isEmpty
            ? (detail?.members ?? []).map { ProfileID($0.profileID) }.filter { $0 != viewer }
            : [ProfileID(entry.peerID)]
        let title = otherIDs.compactMap { nameCache[$0] }.joined(separator: ", ")
        let last = entry.hasLastMessage ? entry.lastMessage : nil
        let viewerLastRead = detail?.members?.first { ProfileID($0.profileID) == viewer }?.lastRead
        return Conversation(
            id: ConversationID(entry.conversationID),
            title: title.isEmpty ? "Conversation" : title,
            lastMessage: last.map(Self.previewText) ?? "",
            // Only a delivered message is activity on the row: an entry with
            // none dates from when the viewer joined, which is no news.
            lastActivityAt: last.map { _ in Date(timeIntervalSince1970: TimeInterval(entry.lastActivityMs) / 1000) },
            otherMemberIDs: otherIDs,
            directPeerHandle: otherIDs.count == 1 ? handleCache[otherIDs[0]] : nil,
            lastMessageIsMine: last.map { ProfileID($0.senderID) == viewer } ?? false,
            lastMessageID: last?.messageID ?? "",
            isUnread: entry.unread,
            unreadCount: Self.unreadCount(
                in: detail?.window ?? [],
                viewer: viewer,
                viewerLastRead: viewerLastRead,
                isUnread: entry.unread
            ),
            isMuted: entry.muted
        )
    }

    public func setMuted(_ muted: Bool, for conversationID: ConversationID) async throws {
        try await setMuted(muted, until: nil, for: conversationID)
    }

    public func setMuted(_ muted: Bool, until: Date?, for conversationID: ConversationID) async throws {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_MuteConversationRequest()
        request.conversationID = conversationID.rawValue
        request.memberID = viewer.rawValue
        request.muted = muted
        // 0 is "until turned back on".
        request.untilMs = muted ? until.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0 : 0
        let response = await chatClient.muteConversation(request: request, headers: [:])
        if let error = response.error {
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Messages

    public func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] {
        try await loadMessagesPage(in: conversationID, before: nil).messages
    }

    /// chat.v1 lists history newest first; each `next_page_token` reads
    /// strictly OLDER messages. A page that isn't full carries none.
    public func loadMessagesPage(in conversationID: ConversationID, before pageToken: String?) async throws -> MessagePage {
        let viewer = try await resolveViewerProfileID()
        var request = Chat_V1_GetHistoryRequest()
        request.conversationID = conversationID.rawValue
        request.requesterID = viewer.rawValue
        request.limit = pageSize
        request.pageToken = pageToken ?? ""
        let response = await chatClient.getHistory(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            // Oldest first (newest at the bottom of the thread).
            let messages = body.messages
                .sorted { $0.createdAtMs < $1.createdAtMs }
                .map { Self.makeMessage(from: $0, viewer: viewer) }
            return MessagePage(messages: messages, olderPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken)
        case .failure(let error):
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        let viewer = try await resolveViewerProfileID(forWrite: "send")
        return try await sendMessage(
            body: body, media: nil, as: viewer, to: conversationID, replyingTo: replyToID
        )
    }

    public func send(
        media upload: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        guard let mediaUploader else { throw ChatError.mediaUnsupported }
        let viewer = try await resolveViewerProfileID(forWrite: "send")
        guard case .authenticated(let account) = await authSession.currentState() else {
            throw ChatError.notAuthenticated
        }
        let media: ChatMedia
        do {
            media = try await Self.upload(upload, ownerID: account.rawValue, uploader: mediaUploader, encoder: encoder)
        } catch let error as MediaAssetUploader.UploadError {
            throw ChatError.mediaUpload(message: error.message)
        } catch {
            throw ChatError.mediaUpload(message: String(describing: error))
        }
        return try await sendMessage(
            body: caption, media: media, as: viewer, to: conversationID, replyingTo: replyToID
        )
    }

    /// The photo, or the clip and its still (best effort: a clip sends
    /// without one), through media.v1.
    private static func upload(
        _ upload: ChatMediaUpload, ownerID: String, uploader: MediaAssetUploader, encoder: MediaEncoder
    ) async throws -> ChatMedia {
        switch upload {
        case .image(let image):
            let encoded = try encoder.encode(image)
            let asset = try await uploader.upload(
                .data(encoded.data), ownerID: ownerID, mimeType: encoded.mimeType,
                sizeBytes: encoded.byteSize, sha256: encoded.sha256Hex
            )
            return ChatMedia(
                kind: .image, url: asset.url, pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight
            )
        case .video(let video):
            let fingerprint = try video.fingerprint()
            let asset = try await uploader.upload(
                .file(video.fileURL), ownerID: ownerID, mimeType: video.mimeType,
                sizeBytes: fingerprint.size, sha256: fingerprint.sha256
            )
            var posterURL: URL?
            if let poster = video.poster, let encoded = try? encoder.encode(poster) {
                posterURL = try? await uploader.upload(
                    .data(encoded.data), ownerID: ownerID, mimeType: encoded.mimeType,
                    sizeBytes: encoded.byteSize, sha256: encoded.sha256Hex
                ).url
            }
            return ChatMedia(
                kind: .video, url: asset.url, posterURL: posterURL,
                pixelWidth: video.pixelWidth, pixelHeight: video.pixelHeight, duration: video.duration
            )
        }
    }

    /// chat.v1 `SendMessage`: TEXT with `body`, or MEDIA with the reference
    /// (`ChatMediaRef`) and `body` as its caption.
    private func sendMessage(
        body: String, media: ChatMedia?, as viewer: ProfileID,
        to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        var request = Chat_V1_SendMessageRequest()
        request.conversationID = conversationID.rawValue
        request.senderID = viewer.rawValue
        request.contentType = media == nil ? .text : .media
        request.body = body
        if let media { request.mediaRef = ChatMediaRef.encode(media) }
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
                replyToID: replyToID,
                media: media
            )
        case .failure(let error):
            if (error.message ?? "").contains("CHT-1011") { throw ChatError.messagesRefused }
            throw ChatError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {
        guard !messageID.isEmpty else { return }
        let viewer = try await resolveViewerProfileID(forWrite: "markRead")
        var request = Chat_V1_MarkReadRequest()
        request.conversationID = conversationID.rawValue
        request.memberID = viewer.rawValue
        request.messageID = messageID
        _ = await chatClient.markRead(request: request, headers: [:])
    }

    // MARK: - Direct message

    public func directConversation(with profileID: ProfileID) async throws -> ConversationID {
        let viewer = try await resolveViewerProfileID(forWrite: "directConversation")

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

    /// How many messages the inbox reads per unread conversation, and so how
    /// far the unread count can see. Twenty is well past the point where a badge stops
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

    /// The inbox row's line: the preview, or — a MEDIA message with no
    /// caption, whose preview is empty — what it carries (#681). The preview
    /// holds no reference, so the line cannot say which of the two.
    static func previewText(_ preview: Chat_V1_MessagePreview) -> String {
        guard preview.preview.isEmpty, preview.contentType == .media else { return preview.preview }
        return "Photo or video"
    }

    private static func makeMessage(from view: Chat_V1_MessageView, viewer: ProfileID) -> ChatMessage {
        let sender = ProfileID(view.senderID)
        return ChatMessage(
            id: view.messageID,
            senderID: sender,
            body: view.body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(view.createdAtMs) / 1000),
            isMine: sender == viewer,
            replyToID: view.replyTo.isEmpty ? nil : view.replyTo,
            media: view.contentType == .media ? ChatMediaRef.decode(view.mediaRef) : nil
        )
    }

    /// `write` names the caller when it is a write, so a guest reaching it is
    /// reported (`GateAudit`): the member gate should have stopped them first.
    private func resolveViewerProfileID(forWrite write: String? = nil) async throws -> ProfileID {
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            if let write { GateAudit.ungatedWrite(write) }
            throw ChatError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw ChatError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw ChatError.transport(message: error.message)
        }
    }
}
