import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

// A conversation's history, older page by older page (#600).

private func message(_ id: String, at seconds: TimeInterval) -> ChatMessage {
    ChatMessage(id: id, senderID: ProfileID("them"), body: id, createdAt: Date(timeIntervalSince1970: seconds), isMine: false)
}

private struct HistoryStubError: Error {}

/// Serves history pages by token (nil = the newest) and records every ask.
private actor PagedHistory: ChatProviding {
    private var pages: [String?: MessagePage]
    private var failuresLeft: [String: Int] = [:]
    private(set) var requests: [String?] = []

    init(_ pages: [String?: MessagePage]) { self.pages = pages }

    func setPage(_ page: MessagePage, for token: String?) { pages[token] = page }
    func failOnce(_ token: String) { failuresLeft[token] = 1 }

    func loadMessagesPage(in conversationID: ConversationID, before pageToken: String?) async throws -> MessagePage {
        requests.append(pageToken)
        if let token = pageToken, let left = failuresLeft[token], left > 0 {
            failuresLeft[token] = left - 1
            throw HistoryStubError()
        }
        return pages[pageToken] ?? MessagePage(messages: [], olderPageToken: nil)
    }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] {
        try await loadMessagesPage(in: conversationID, before: nil).messages
    }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "sent", senderID: ProfileID("me"), body: body, createdAt: Date(timeIntervalSince1970: 1_000), isMine: true)
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

@MainActor
struct HistoryPagingTests {
    private final class Shown {
        var ids: [String] = []
    }

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

    private func open(_ provider: PagedHistory) async -> (ConversationViewModel, Shown) {
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        let shown = Shown()
        viewModel.onPhaseChange = {
            guard case .content(let models) = $0 else { return }
            shown.ids = models.map(\.id)
        }
        viewModel.viewDidLoad()
        await settle { !shown.ids.isEmpty }
        return (viewModel, shown)
    }

    @Test func nearingTheTopPrependsTheOlderPageOnceAndStopsAtTheStart() async {
        let provider = PagedHistory([
            nil: MessagePage(messages: [message("c", at: 30), message("d", at: 40)], olderPageToken: "p2"),
            "p2": MessagePage(messages: [message("a", at: 10), message("b", at: 20)], olderPageToken: nil),
        ])
        let (viewModel, shown) = await open(provider)
        #expect(shown.ids == ["c", "d"])

        viewModel.loadOlder()
        viewModel.loadOlder() // the same approach, reported twice
        await settle { shown.ids.count == 4 }
        #expect(shown.ids == ["a", "b", "c", "d"])

        viewModel.loadOlder() // the start: nothing left to ask
        await settle()
        #expect(await provider.requests == [nil, "p2"])
    }

    @Test func aFailedPageKeepsTheTranscriptAndIsRetriedOnTheNextApproach() async {
        let provider = PagedHistory([
            nil: MessagePage(messages: [message("b", at: 20)], olderPageToken: "p2"),
            "p2": MessagePage(messages: [message("a", at: 10)], olderPageToken: nil),
        ])
        await provider.failOnce("p2")
        let (viewModel, shown) = await open(provider)

        viewModel.loadOlder()
        await settle { await provider.requests.count == 2 }
        await settle()
        #expect(shown.ids == ["b"])

        viewModel.loadOlder()
        await settle { shown.ids.count == 2 }
        #expect(shown.ids == ["a", "b"])
    }

    /// A page that lands wholly on screen asks for the next one WHILE it
    /// renders. That ask must be taken (#596).
    @Test func aPageAskingForTheNextWhileItRendersIsHeard() async {
        let provider = PagedHistory([
            nil: MessagePage(messages: [message("c", at: 30)], olderPageToken: "p2"),
            "p2": MessagePage(messages: [message("b", at: 20)], olderPageToken: "p3"),
            "p3": MessagePage(messages: [message("a", at: 10)], olderPageToken: nil),
        ])
        let (viewModel, shown) = await open(provider)
        let render = viewModel.onPhaseChange
        viewModel.onPhaseChange = { phase in
            render?(phase)
            // The screen near the top, after this very render.
            if case .content(let models) = phase, models.count > 1 { viewModel.loadOlder() }
        }

        viewModel.loadOlder()
        await settle { shown.ids.count == 3 }

        #expect(shown.ids == ["a", "b", "c"])
        #expect(await provider.requests == [nil, "p2", "p3"])
    }

    /// Pull-to-refresh with older history on screen: the newest page is
    /// refreshed, the older pages stay.
    @Test func aRefreshKeepsTheOlderPages() async {
        let provider = PagedHistory([
            nil: MessagePage(messages: [message("c", at: 30), message("d", at: 40)], olderPageToken: "p2"),
            "p2": MessagePage(messages: [message("a", at: 10), message("b", at: 20)], olderPageToken: nil),
        ])
        let (viewModel, shown) = await open(provider)
        viewModel.loadOlder()
        await settle { shown.ids.count == 4 }

        await provider.setPage(
            MessagePage(messages: [message("d", at: 40), message("e", at: 50)], olderPageToken: "p2"), for: nil
        )
        viewModel.refresh()
        await settle { shown.ids.last == "e" }

        // "c" slid back out of the newest page: older than its oldest, kept.
        #expect(shown.ids == ["a", "b", "c", "d", "e"])
    }

    @Test func mergingANewestPageOverOlderPages() {
        let shown = [message("a", at: 10), message("b", at: 20), message("gone", at: 45), message("d", at: 40)]
        let fresh = [message("d", at: 40), message("e", at: 50)]

        let merged = ConversationViewModel.merging(newestPage: fresh, over: shown)

        #expect(merged.map(\.id) == ["a", "b", "d", "e"])
    }

    // MARK: - The repository, against the mock

    /// The first request sends a page size, every next one the token the
    /// last returned, until there is nothing older: the mock's long
    /// conversation, across two page boundaries, oldest first in each page.
    @Test func theRepositoryFollowsTheTokenBackThroughTheMocksLongHistory() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: HistorySessionStub(),
            pageSize: 50
        )
        let conversation = ConversationID(MockChatService.longHistoryConversationID)

        var pages = [try await repository.loadMessagesPage(in: conversation, before: nil)]
        while let token = pages.last?.olderPageToken, pages.count < 10 {
            pages.append(try await repository.loadMessagesPage(in: conversation, before: token))
        }

        #expect(pages.count == 3)
        #expect(pages.last?.olderPageToken == nil)
        let transcript = pages.reversed().flatMap(\.messages)
        #expect(Set(transcript.map(\.id)).count == transcript.count)
        #expect(transcript.count == MockChatService.longHistoryOlderCount + 3)
        #expect(transcript.first?.body.hasPrefix("#1 ") == true)
        let times = transcript.map(\.createdAt)
        #expect(times == times.sorted())
    }
}

private struct HistorySessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}
