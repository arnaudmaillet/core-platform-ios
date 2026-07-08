import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Chat

private actor StubChatProvider: ChatProviding {
    var conversations: [Conversation]
    var messages: [ChatMessage]
    private(set) var sentBodies: [String] = []
    private(set) var markReadCalls = 0

    init(conversations: [Conversation] = [], messages: [ChatMessage] = []) {
        self.conversations = conversations
        self.messages = messages
    }

    func loadConversations() async throws -> [Conversation] { conversations }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { messages }
    func send(_ body: String, to conversationID: ConversationID) async throws -> ChatMessage {
        sentBodies.append(body)
        let message = ChatMessage(id: "sent", senderID: ProfileID("me"), body: body, createdAt: Date(timeIntervalSince1970: 200), isMine: true)
        messages.append(message)
        return message
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws { markReadCalls += 1 }
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private func conversation(_ id: String, title: String = "Ava") -> Conversation {
    Conversation(id: ConversationID(id), title: title, lastMessage: "hi", lastActivityAt: Date(timeIntervalSince1970: 0))
}

private func message(_ id: String, mine: Bool) -> ChatMessage {
    ChatMessage(id: id, senderID: ProfileID(mine ? "me" : "them"), body: id, createdAt: Date(timeIntervalSince1970: 0), isMine: mine)
}

@MainActor
struct ChatViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Conversation list

    @Test func listLoadsIntoContent() async {
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: [conversation("c1"), conversation("c2")]))
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewWillAppear()
        await settle()

        guard case .content(let models) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(models.map(\.id) == [ConversationID("c1"), ConversationID("c2")])
    }

    @Test func emptyConversationList() async {
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: []))
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        await settle()
        #expect(last == .empty)
    }

    @Test func selectingConversationRoutesToIt() async {
        let router = SpyRouter()
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: [conversation("c7")]), router: router)
        viewModel.viewWillAppear()
        await settle()

        viewModel.didSelect(ConversationID("c7"))
        #expect(router.routes == [.conversation(ConversationID("c7"))])
    }

    // MARK: - Thread

    @Test func threadLoadsMessagesAndMarksRead() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false), message("m2", mine: true)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .content(let models) = last else {
            Issue.record("expected content")
            return
        }
        #expect(models.map(\.id) == ["m1", "m2"])
        #expect(await provider.markReadCalls >= 1)
    }

    @Test func sendingAppendsMessage() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.send("  hello  ")
        await settle()

        #expect(await provider.sentBodies == ["hello"]) // trimmed
        guard case .content(let models) = last else {
            Issue.record("expected content")
            return
        }
        #expect(models.map(\.id) == ["m1", "sent"]) // appended
    }
}
