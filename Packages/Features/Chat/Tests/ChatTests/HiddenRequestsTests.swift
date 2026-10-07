import CoreModels
import Foundation
import Testing
@testable import Chat

// The Hidden requests folder (#552).

private func row(_ id: String, at seconds: TimeInterval, unread: Bool = true) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: id,
        lastMessage: "hi",
        lastActivityAt: Date(timeIntervalSince1970: seconds),
        otherMemberIDs: [ProfileID("peer-\(id)")],
        lastMessageID: "\(id)-latest",
        isUnread: unread
    )
}

/// Serves each folder's pages by token (nil = the first) and records every ask.
private actor FolderedInbox: ChatProviding {
    private let pages: [InboxFolder: [String?: InboxPage]]
    private(set) var asks: [(InboxFolder, String?)] = []

    init(_ pages: [InboxFolder: [String?: InboxPage]]) { self.pages = pages }

    func asks(for folder: InboxFolder) -> [String?] { asks.filter { $0.0 == folder }.map(\.1) }

    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        asks.append((folder, pageToken))
        return pages[folder]?[pageToken] ?? InboxPage(conversations: [], nextPageToken: nil)
    }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

@MainActor
struct HiddenRequestsTests {
    /// Whether `condition` came to hold within `looks` looks. A budget of
    /// LOOKS, not of wall-clock time: a starved runner that deschedules the
    /// process spends none of it (#528, #556, #599). Returns as soon as the
    /// condition holds.
    private func settle(looks: Int = 3_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func loaded(_ provider: FolderedInbox) async throws -> InboxCatalog {
        let catalog = InboxCatalog(repository: provider)
        catalog.reload()
        try #require(await settle { catalog.snapshot.phase == .loaded })
        return catalog
    }

    private func ids(_ rows: [Conversation]) -> [String] { rows.map(\.id.rawValue) }

    private func rowIDs(_ phase: MessageRequestsViewModel.Phase) -> [String]? {
        guard case .content(let sections) = phase else { return nil }
        return sections.all.map(\.id.rawValue)
    }

    private static let everyFolder: [InboxFolder: [String?: InboxPage]] = [
        .inbox: [nil: InboxPage(conversations: [row("a", at: 50, unread: false)], nextPageToken: nil)],
        .requests: [nil: InboxPage(conversations: [row("r1", at: 40)], nextPageToken: nil)],
        .hiddenRequests: [nil: InboxPage(conversations: [row("h1", at: 30), row("h2", at: 20)], nextPageToken: nil)],
    ]

    @Test func aLoadReadsTheHiddenFolderApartFromRequests() async throws {
        let provider = FolderedInbox(Self.everyFolder)
        let catalog = try await loaded(provider)

        #expect(ids(catalog.snapshot.hiddenRequests) == ["h1", "h2"])
        #expect(ids(catalog.snapshot.requests) == ["r1"])
        #expect(ids(catalog.snapshot.active) == ["a"])
        #expect(await provider.asks(for: .hiddenRequests) == [nil])
    }

    /// The Requests list ends on the Hidden requests row when the hidden
    /// folder holds any, and a hidden request announces nothing: Requests'
    /// badge counts only its own.
    @Test func requestsEndOnTheHiddenRowAndCountOnlyTheirOwn() async throws {
        let catalog = try await loaded(FolderedInbox(Self.everyFolder))
        let requests = MessageRequestsViewModel(catalog: catalog, now: { Date(timeIntervalSince1970: 0) })

        #expect(requests.showsHiddenRequestsRow)
        #expect(rowIDs(requests.phase) == ["r1"])
        #expect(requests.newCount == 1)
    }

    @Test func noHiddenRequestsMeansNoRow() async throws {
        var pages = Self.everyFolder
        pages[.hiddenRequests] = nil
        let catalog = try await loaded(FolderedInbox(pages))
        let requests = MessageRequestsViewModel(catalog: catalog)

        #expect(!requests.showsHiddenRequestsRow)
        #expect(rowIDs(requests.phase) == ["r1"])
    }

    /// No visible request but hidden ones: the list still shows, empty, so
    /// its Hidden requests row stays reachable — not the "No requests" state.
    @Test func onlyHiddenRequestsStillReachTheRow() async throws {
        var pages = Self.everyFolder
        pages[.requests] = nil
        let catalog = try await loaded(FolderedInbox(pages))
        let requests = MessageRequestsViewModel(catalog: catalog)

        #expect(requests.showsHiddenRequestsRow)
        #expect(rowIDs(requests.phase) == [])
    }

    /// The hidden list: its folder's rows, in one unheaded section (no New
    /// split, no badge), and no row leading further.
    @Test func theHiddenListShowsTheHiddenFolderAndAnnouncesNothing() async throws {
        let catalog = try await loaded(FolderedInbox(Self.everyFolder))
        let hidden = MessageRequestsViewModel(
            catalog: catalog, folder: .hiddenRequests, now: { Date(timeIntervalSince1970: 0) }
        )

        #expect(rowIDs(hidden.phase) == ["h1", "h2"])
        guard case .content(let sections) = hidden.phase else { return }
        #expect(sections.new.isEmpty)
        #expect(hidden.newCount == 0)
        #expect(!hidden.showsHiddenRequestsRow)
        // The rows still wear the unread treatment, as any request's do.
        #expect(sections.all.allSatisfy { $0.isUnread })
    }

    @Test func theHiddenListIsEmptyWhenTheFolderIs() async throws {
        var pages = Self.everyFolder
        pages[.hiddenRequests] = nil
        let catalog = try await loaded(FolderedInbox(pages))
        let hidden = MessageRequestsViewModel(catalog: catalog, folder: .hiddenRequests)

        #expect(hidden.phase == .empty)
    }

    /// Accepting one works like any request: it leaves the hidden list and
    /// joins All. Declining one drops it from the hidden list, and the row
    /// leaves Requests once the folder is empty.
    @Test func acceptingAndDecliningWorkLikeAnyRequest() async throws {
        let catalog = try await loaded(FolderedInbox(Self.everyFolder))
        let requests = MessageRequestsViewModel(catalog: catalog)
        let hidden = MessageRequestsViewModel(catalog: catalog, folder: .hiddenRequests)

        hidden.accept(ConversationID("h1"))
        #expect(rowIDs(hidden.phase) == ["h2"])
        #expect(ids(catalog.snapshot.active) == ["a", "h1"])
        #expect(rowIDs(requests.phase) == ["r1"])

        hidden.decline(ConversationID("h2"))
        #expect(hidden.phase == .empty)
        #expect(!ids(catalog.snapshot.active).contains("h2"))
        #expect(!requests.showsHiddenRequestsRow)
    }

    /// Replying to a hidden request answers it: it moves to All ahead of the
    /// next load, as a reply to any request does.
    @Test func aReplyFilesAHiddenRequestInTheInbox() async throws {
        let catalog = try await loaded(FolderedInbox(Self.everyFolder))
        let reply = ChatMessage(id: "m1", senderID: ProfileID("me"), body: "hey", createdAt: Date(timeIntervalSince1970: 60), isMine: true)

        catalog.recordSentMessage(reply, in: ConversationID("h2"))

        #expect(ids(catalog.snapshot.hiddenRequests) == ["h1"])
        #expect(ids(catalog.snapshot.active).first == "h2")
    }

    /// The hidden folder pages on its own cursor, like the other two.
    @Test func theHiddenFolderPagesOnItsOwn() async throws {
        var pages = Self.everyFolder
        pages[.hiddenRequests] = [
            nil: InboxPage(conversations: [row("h1", at: 30)], nextPageToken: "h2"),
            "h2": InboxPage(conversations: [row("h2", at: 20)], nextPageToken: nil),
        ]
        let provider = FolderedInbox(pages)
        let catalog = try await loaded(provider)
        let hidden = MessageRequestsViewModel(catalog: catalog, folder: .hiddenRequests)
        #expect(hidden.hasMore)

        hidden.loadMore()
        try #require(await settle { catalog.snapshot.hiddenRequests.count == 2 })

        #expect(rowIDs(hidden.phase) == ["h1", "h2"])
        #expect(!hidden.hasMore)
        #expect(await provider.asks(for: .hiddenRequests) == [nil, "h2"])
        #expect(await provider.asks(for: .requests) == [nil])
    }
}
