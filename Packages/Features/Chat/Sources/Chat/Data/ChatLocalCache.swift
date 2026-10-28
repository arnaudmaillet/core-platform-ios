import CacheKit
import CoreModels
import Foundation
import LocalStore
import OSLog

/// The inbox and the last conversations on the device (#897), in the
/// LocalStore: the Messages inbox opens on its last rows at a cold start,
/// offline included, and a conversation on its last 200 messages, then both
/// revalidate.
///
/// - **Folders** (All, Requests, Hidden requests) are lists of conversation
///   keys with their cursors, so paging goes on from the network where the
///   stored pages stop. A folder stores pages while it holds fewer than 50
///   rows. A conversation is one entity row whichever folders list it.
/// - **Messages** are transcripts: the newest 200 of each of the last 50
///   conversations opened (decided 2026-10-11, epic #890), with the cursor
///   past the oldest. A newest page is merged over what is stored, an older
///   one goes below it, a sent message joins at the newest end, once per id.
/// - **Not stored:** the inbox's pins and session-local choices (pin, delete,
///   accept, decline) stay in-session by design (`InboxCatalog`), and a
///   message still on its way or failed is not kept across a relaunch.
///
/// Rows are versioned JSON records of what the inbox and the thread show
/// (they join chat.v1 with profile.v1 names): a format this build cannot read
/// is a miss. Reads are synchronous (a first frame); writes go to a serial
/// queue, off the caller's thread, each as the viewer captured BEFORE its
/// network call, so a page that lands after a switch is dropped.
final class ChatLocalCache: Sendable {
    static let conversationType = "chat.conversation"
    static let format = 1
    /// A folder stores pages while it holds fewer rows than this: the last
    /// 50 conversations.
    static let maxStoredRows = LocalStorePolicy.transcriptCount

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.chat-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "chat-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    // MARK: - Folders

    /// A folder as stored: its rows in the server's order, and where its next
    /// page starts.
    struct StoredFolder: Equatable {
        var rows: [Conversation]
        var nextCursor: String?
        /// Pages beyond the first are stored: a fresh first page is merged
        /// over them rather than cutting the folder back.
        var pageCount: Int
    }

    func folder(_ folder: InboxFolder) -> StoredFolder? {
        guard let list = store.list(Self.listKey(folder)) else { return nil }
        let rows = list.entries.compactMap(Self.conversation(from:))
        return StoredFolder(rows: rows, nextCursor: list.nextCursor, pageCount: list.pageCount)
    }

    /// Replaces `folder` with its first page: the tab's `retained` page.
    func storeFirstPage(_ page: InboxPage, of folder: InboxFolder, as viewer: LocalStoreViewer?) {
        let store = store
        let logger = logger
        queue.async {
            do {
                try store.replaceList(
                    Self.listKey(folder), with: Self.listPage(page, tier: .retained), as: viewer,
                    lifetime: LocalStorePolicy.transcriptLifetime
                )
            } catch {
                logger.error("chat cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Appends the page fetched with `cursor`, while the folder holds fewer
    /// than `maxStoredRows`.
    func storeNextPage(_ page: InboxPage, of folder: InboxFolder, after cursor: String, as viewer: LocalStoreViewer?) {
        let store = store
        let logger = logger
        queue.async {
            do {
                try store.appendPage(
                    Self.listPage(page, tier: .recent), to: Self.listKey(folder), after: cursor, as: viewer,
                    maxEntries: Self.maxStoredRows
                )
            } catch {
                logger.error("chat cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func listKey(_ folder: InboxFolder) -> String {
        switch folder {
        case .inbox: "chat.inbox"
        case .requests: "chat.requests"
        case .hiddenRequests: "chat.hiddenRequests"
        }
    }

    private static func listPage(_ page: InboxPage, tier: CacheTier) -> LocalListPage {
        let writes = page.conversations.compactMap { conversation -> LocalEntityWrite? in
            guard let payload = try? JSONEncoder().encode(ConversationRecord(conversation)) else { return nil }
            return LocalEntityWrite(
                key: LocalEntityKey(type: conversationType, id: conversation.id.rawValue),
                payload: payload, format: format, lifetime: LocalStorePolicy.transcriptLifetime
            )
        }
        return LocalListPage(
            items: writes.map(\.key), entities: writes, nextCursor: page.nextPageToken, tier: tier
        )
    }

    private static func conversation(from entity: LocalEntity) -> Conversation? {
        guard entity.key.type == conversationType, entity.format == format,
              let record = try? JSONDecoder().decode(ConversationRecord.self, from: entity.payload) else { return nil }
        return record.conversation
    }

    // MARK: - Suggestions (#1776)

    static let suggestionType = "chat.suggestion"
    static let suggestionsListKey = "chat.suggestions"

    /// The Suggestions surface's first page as last read: what it opens on
    /// at a cold start, before it asks again. Nil when nothing readable is
    /// stored.
    func suggestions() -> SuggestionsPage? {
        guard let list = store.list(Self.suggestionsListKey, maxPages: 1) else { return nil }
        let rows = list.entries.compactMap(Self.suggestion(from:))
        guard !rows.isEmpty else { return nil }
        return SuggestionsPage(accounts: rows, nextPageToken: list.nextCursor)
    }

    /// Replaces the stored first page. People rows: kept a profile's
    /// lifetime, revalidated at every open.
    func storeSuggestions(_ page: SuggestionsPage, as viewer: LocalStoreViewer?) {
        let writes = page.accounts.compactMap { account -> LocalEntityWrite? in
            guard let payload = try? JSONEncoder().encode(SuggestionRecord(account)) else { return nil }
            return LocalEntityWrite(
                key: LocalEntityKey(type: Self.suggestionType, id: account.id.rawValue),
                payload: payload, format: Self.format, lifetime: LocalStorePolicy.profileLifetime
            )
        }
        let listPage = LocalListPage(items: writes.map(\.key), entities: writes, nextCursor: page.nextPageToken, tier: .retained)
        write { store in
            try store.replaceList(Self.suggestionsListKey, with: listPage, as: viewer, lifetime: LocalStorePolicy.profileLifetime)
        }
    }

    private static func suggestion(from entity: LocalEntity) -> SuggestedAccount? {
        guard entity.key.type == suggestionType, entity.format == format,
              let record = try? JSONDecoder().decode(SuggestionRecord.self, from: entity.payload) else { return nil }
        return record.account
    }

    /// One suggestion row as stored; the reason in fixed words, so a file
    /// outlives the enum's shape.
    struct SuggestionRecord: Codable, Equatable {
        var id: String
        var handle: String
        var displayName: String
        var avatarURL: URL?
        var reason: String
        var followedByNames: [String]?
        var followedByTotal: Int?
        var isPrivate: Bool

        init(_ account: SuggestedAccount) {
            id = account.id.rawValue
            handle = account.handle
            displayName = account.displayName
            avatarURL = account.avatarURL
            isPrivate = account.isPrivate
            switch account.reason {
            case .followsYou: reason = "followsYou"
            case .followedBy(let names, let total):
                reason = "followedBy"
                followedByNames = names
                followedByTotal = total
            case .suggestedForYou: reason = "suggestedForYou"
            }
        }

        var account: SuggestedAccount? {
            let decoded: SuggestedAccount.Reason
            switch reason {
            case "followsYou": decoded = .followsYou
            case "followedBy": decoded = .followedBy(names: followedByNames ?? [], total: followedByTotal ?? 0)
            case "suggestedForYou": decoded = .suggestedForYou
            default: return nil
            }
            return SuggestedAccount(
                id: ProfileID(id), handle: handle, displayName: displayName, avatarURL: avatarURL,
                reason: decoded, isPrivate: isPrivate
            )
        }
    }

    // MARK: - Messages

    /// A conversation's stored messages, oldest first, and the cursor for
    /// the ones older than the oldest (nil: they reach its start).
    struct StoredTranscript: Equatable {
        var messages: [ChatMessage]
        var olderCursor: String?
    }

    func transcript(of conversationID: ConversationID) -> StoredTranscript? {
        guard let transcript = store.transcript(Self.transcriptKey(conversationID)) else { return nil }
        var messages: [ChatMessage] = []
        for item in transcript.items {
            // One unreadable message would leave a hole: the stored run is
            // not offered at all.
            guard item.format == Self.format,
                  let record = try? JSONDecoder().decode(MessageRecord.self, from: item.payload) else { return nil }
            messages.append(record.message)
        }
        return StoredTranscript(messages: messages, olderCursor: transcript.olderCursor)
    }

    /// The newest page the network answered, merged over what is stored.
    func storeNewest(_ page: MessagePage, in conversationID: ConversationID, as viewer: LocalStoreViewer?) {
        write { store in
            try store.storeNewest(
                LocalTranscriptPage(items: Self.items(page.messages), olderCursor: page.olderPageToken),
                in: Self.transcriptKey(conversationID), as: viewer
            )
        }
    }

    /// An older page, fetched with `cursor`, below what is stored.
    func storeOlder(_ page: MessagePage, in conversationID: ConversationID, after cursor: String, as viewer: LocalStoreViewer?) {
        write { store in
            try store.storeOlder(
                LocalTranscriptPage(items: Self.items(page.messages), olderCursor: page.olderPageToken),
                in: Self.transcriptKey(conversationID), after: cursor, as: viewer
            )
        }
    }

    /// The viewer's message, accepted by the server, at the newest end.
    func storeSent(_ message: ChatMessage, in conversationID: ConversationID, as viewer: LocalStoreViewer?) {
        write { store in
            try store.insertLive(Self.items([message]), in: Self.transcriptKey(conversationID), as: viewer)
        }
    }

    static func transcriptKey(_ conversationID: ConversationID) -> String {
        "chat.messages.\(conversationID.rawValue)"
    }

    private static func items(_ messages: [ChatMessage]) -> [LocalTranscriptItem] {
        messages.compactMap { message in
            guard let payload = try? JSONEncoder().encode(MessageRecord(message)) else { return nil }
            return LocalTranscriptItem(
                id: message.id, sortKey: Int64((message.createdAt.timeIntervalSince1970 * 1000).rounded()),
                payload: payload, format: format
            )
        }
    }

    private func write(_ body: @escaping @Sendable (LocalStore) throws -> Bool) {
        let store = store
        let logger = logger
        queue.async {
            do {
                _ = try body(store)
            } catch {
                logger.error("chat cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    // MARK: - Records

    /// One inbox row as stored.
    struct ConversationRecord: Codable, Equatable {
        var id: String
        var title: String
        var lastMessage: String
        var lastActivityAt: Date?
        var otherMemberIDs: [String]
        var directPeerHandle: String?
        var lastMessageIsMine: Bool
        var lastMessageID: String
        var isUnread: Bool
        var unreadCount: Int
        var isMuted: Bool

        init(_ conversation: Conversation) {
            id = conversation.id.rawValue
            title = conversation.title
            lastMessage = conversation.lastMessage
            lastActivityAt = conversation.lastActivityAt
            otherMemberIDs = conversation.otherMemberIDs.map(\.rawValue)
            directPeerHandle = conversation.directPeerHandle
            lastMessageIsMine = conversation.lastMessageIsMine
            lastMessageID = conversation.lastMessageID
            isUnread = conversation.isUnread
            unreadCount = conversation.unreadCount
            isMuted = conversation.isMuted
        }

        var conversation: Conversation {
            Conversation(
                id: ConversationID(id), title: title, lastMessage: lastMessage, lastActivityAt: lastActivityAt,
                otherMemberIDs: otherMemberIDs.map { ProfileID($0) }, directPeerHandle: directPeerHandle,
                lastMessageIsMine: lastMessageIsMine, lastMessageID: lastMessageID, isUnread: isUnread,
                unreadCount: unreadCount, isMuted: isMuted
            )
        }
    }

    /// One message as stored. Its photo or video as the reference chat.v1
    /// carries (`ChatMediaRef`).
    struct MessageRecord: Codable, Equatable {
        var id: String
        var senderID: String
        var body: String
        var createdAt: Date
        var isMine: Bool
        var replyToID: String?
        var media: String?

        init(_ message: ChatMessage) {
            id = message.id
            senderID = message.senderID.rawValue
            body = message.body
            createdAt = message.createdAt
            isMine = message.isMine
            replyToID = message.replyToID
            media = message.media.map(ChatMediaRef.encode)
        }

        var message: ChatMessage {
            ChatMessage(
                id: id, senderID: ProfileID(senderID), body: body, createdAt: createdAt, isMine: isMine,
                replyToID: replyToID, media: media.flatMap(ChatMediaRef.decode)
            )
        }
    }
}
