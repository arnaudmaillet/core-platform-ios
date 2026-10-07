import CoreModels
import Foundation
import Testing
@testable import Chat

// The inbox, page by page (#593).

private func row(_ id: String, at seconds: TimeInterval) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: id,
        lastMessage: "hi",
        lastActivityAt: Date(timeIntervalSince1970: seconds),
        otherMemberIDs: [ProfileID("peer-\(id)")],
        lastMessageID: "\(id)-latest"
    )
}

private struct PagingStubError: Error {}

/// Serves each folder's pages by token (nil = the first) and records every ask.
private actor PagedInbox: ChatProviding {
    private var pages: [InboxFolder: [String?: InboxPage]]
    private var failuresLeft: [String: Int] = [:]
    private(set) var requests: [(InboxFolder, String?)] = []

    init(inbox: [String?: InboxPage], requests: [String?: InboxPage] = [:]) {
        pages = [.inbox: inbox, .requests: requests]
    }

    func setPage(_ page: InboxPage, of folder: InboxFolder, for token: String?) { pages[folder, default: [:]][token] = page }
    func failOnce(_ token: String) { failuresLeft[token] = 1 }
    func asks(for folder: InboxFolder) -> [String?] { requests.filter { $0.0 == folder }.map(\.1) }

    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        requests.append((folder, pageToken))
        if let token = pageToken, let left = failuresLeft[token], left > 0 {
            failuresLeft[token] = left - 1
            throw PagingStubError()
        }
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
struct InboxPagingTests {
    /// A ceiling, not a pace: returns as soon as `condition` holds.
    private func settle(until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Grace for "nothing more should happen".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func loaded(_ provider: PagedInbox) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: provider)
        catalog.reload()
        await settle { catalog.snapshot.phase == .loaded }
        return catalog
    }

    private func ids(_ rows: [Conversation]) -> [String] { rows.map(\.id.rawValue) }

    @Test func nearingTheEndAppendsTheNextPageOnceAndStopsAtTheEnd() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40), row("b", at: 30)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("c", at: 20), row("d", at: 10)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)
        #expect(ids(catalog.snapshot.active) == ["a", "b"])
        #expect(catalog.snapshot.hasMore == [.inbox])

        catalog.loadMore(.inbox)
        catalog.loadMore(.inbox) // the same approach, reported twice
        await settle { catalog.snapshot.active.count == 4 }
        #expect(ids(catalog.snapshot.active) == ["a", "b", "c", "d"])
        #expect(catalog.snapshot.hasMore.isEmpty)

        catalog.loadMore(.inbox) // the end: nothing left to ask
        await settle()
        #expect(await provider.asks(for: .inbox) == [nil, "p2"])
    }

    /// A page that lands wholly on screen asks for the next one WHILE it
    /// renders (its rows' `willDisplay`). That ask must be taken: dropped, the
    /// list stops short under a spinner, since every row has displayed and
    /// none will ask again (seen on the simulator with 5-row pages).
    @Test func aPageAskingForTheNextWhileItRendersIsHeard() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("b", at: 30)], nextPageToken: "p3"),
            "p3": InboxPage(conversations: [row("c", at: 20)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)
        // Every render near the end asks for more, as the list's rows do.
        let token = catalog.observe { snapshot in
            if snapshot.hasMore.contains(.inbox), snapshot.active.count > 1 { catalog.loadMore(.inbox) }
        }

        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 3 }

        #expect(ids(catalog.snapshot.active) == ["a", "b", "c"])
        #expect(await provider.asks(for: .inbox) == [nil, "p2", "p3"])
        _ = token
    }

    @Test func eachFolderPagesOnItsOwn() async {
        let provider = PagedInbox(
            inbox: [nil: InboxPage(conversations: [row("a", at: 40)], nextPageToken: nil)],
            requests: [
                nil: InboxPage(conversations: [row("r1", at: 30)], nextPageToken: "r2"),
                "r2": InboxPage(conversations: [row("r2", at: 20)], nextPageToken: nil),
            ]
        )
        let catalog = await loaded(provider)
        #expect(catalog.snapshot.hasMore == [.requests])

        catalog.loadMore(.inbox) // no more there: no ask
        catalog.loadMore(.requests)
        await settle { catalog.snapshot.requests.count == 2 }

        #expect(ids(catalog.snapshot.requests) == ["r1", "r2"])
        #expect(ids(catalog.snapshot.active) == ["a"])
        #expect(await provider.asks(for: .inbox) == [nil])
    }

    @Test func aPageFilteredToNothingMovesStraightOnToTheNext() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [], nextPageToken: "p3"),
            "p3": InboxPage(conversations: [row("b", at: 10)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)

        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 2 }

        #expect(ids(catalog.snapshot.active) == ["a", "b"])
        #expect(await provider.asks(for: .inbox) == [nil, "p2", "p3"])
    }

    @Test func aFailedPageKeepsTheListAndIsRetriedOnTheNextApproach() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("b", at: 10)], nextPageToken: nil),
        ])
        await provider.failOnce("p2")
        let catalog = await loaded(provider)

        catalog.loadMore(.inbox)
        await settle { await provider.asks(for: .inbox).count == 2 }
        await settle()
        #expect(ids(catalog.snapshot.active) == ["a"])
        #expect(catalog.snapshot.hasMore == [.inbox])

        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 2 }
        #expect(ids(catalog.snapshot.active) == ["a", "b"])
    }

    /// Coming back from a thread reloads the inbox: with a second page on
    /// screen, the first is refreshed and the second stays.
    @Test func aReloadKeepsThePagesBelowTheFirst() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40), row("b", at: 30)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("c", at: 20), row("d", at: 10)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)
        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 4 }

        await provider.setPage(
            InboxPage(conversations: [row("new", at: 50), row("a", at: 40)], nextPageToken: "p2"),
            of: .inbox, for: nil
        )
        catalog.reload()
        await settle { catalog.snapshot.active.first?.id == ConversationID("new") }

        #expect(ids(catalog.snapshot.active) == ["new", "a", "b", "c", "d"])
        // The cursor past the last page loaded stands: the end stays the end.
        #expect(catalog.snapshot.hasMore.isEmpty)
    }

    /// A conversation on both sides of a page boundary shows once.
    @Test func aRowRepeatedAcrossPagesShowsOnce() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40), row("b", at: 30)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("b", at: 30), row("c", at: 20)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)

        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 3 }

        #expect(ids(catalog.snapshot.active) == ["a", "b", "c"])
    }

    /// A sent message hoists ONLY its own row: the rest keep the server's
    /// order across pages.
    @Test func aSentMessageHoistsItsRowAndMovesNothingElse() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40), row("b", at: 30)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("c", at: 20)], nextPageToken: nil),
        ])
        let catalog = await loaded(provider)
        catalog.loadMore(.inbox)
        await settle { catalog.snapshot.active.count == 3 }

        catalog.recordSentMessage(
            ChatMessage(id: "m", senderID: ProfileID("me"), body: "hey", createdAt: Date(timeIntervalSince1970: 60), isMine: true),
            in: ConversationID("c")
        )

        #expect(ids(catalog.snapshot.active) == ["c", "a", "b"])
    }

    /// The All surface asks for more and says whether there is any.
    @Test func theAllSurfacePagesThroughItsViewModel() async {
        let provider = PagedInbox(inbox: [
            nil: InboxPage(conversations: [row("a", at: 40)], nextPageToken: "p2"),
            "p2": InboxPage(conversations: [row("b", at: 10)], nextPageToken: nil),
        ])
        let catalog = InboxCatalog(repository: provider)
        let viewModel = ConversationListViewModel(catalog: catalog)
        var hasMoreChanges: [Bool] = []
        viewModel.onHasMoreChange = { hasMoreChanges.append($0) }
        catalog.reload()
        await settle { viewModel.hasMore }

        viewModel.loadMore()
        await settle { !viewModel.hasMore }

        #expect(ids(catalog.snapshot.active) == ["a", "b"])
        #expect(hasMoreChanges == [true, false])
    }

    // MARK: - The merge rule

    @Test func mergingAFreshFirstPageOverLaterPages() {
        let shown = [row("gone", at: 45), row("a", at: 40), row("b", at: 30), row("c", at: 20)]
        let fresh = [row("new", at: 50), row("a", at: 40)]

        let merged = InboxCatalog.merging(firstPage: fresh, over: shown)

        #expect(ids(merged) == ["new", "a", "b", "c"])
    }
}
