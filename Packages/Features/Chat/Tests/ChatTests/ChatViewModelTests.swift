import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Chat

private actor StubChatProvider: ChatProviding {
    var conversations: [Conversation]
    var messages: [ChatMessage]
    private(set) var sentBodies: [String] = []
    private(set) var sentReplyTos: [String?] = []
    private(set) var markReadCalls = 0

    init(conversations: [Conversation] = [], messages: [ChatMessage] = []) {
        self.conversations = conversations
        self.messages = messages
    }

    func loadConversations() async throws -> [Conversation] { conversations }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { messages }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        sentBodies.append(body)
        sentReplyTos.append(replyToID)
        let message = ChatMessage(id: "sent", senderID: ProfileID("me"), body: body, createdAt: Date(timeIntervalSince1970: 200), isMine: true, replyToID: replyToID)
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

private func conversation(_ id: String, title: String = "Ava", others: [String] = ["peer-1"]) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: title,
        lastMessage: "hi",
        lastActivityAt: Date(timeIntervalSince1970: 0),
        otherMemberIDs: others.map { ProfileID($0) }
    )
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

    @Test func pinningReordersPinnedFirstAndFlagsTheRow() async {
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1"), conversation("c2")])
        )
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        await settle()

        viewModel.togglePin(ConversationID("c2"))

        guard case .content(let models) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(models.map(\.id) == [ConversationID("c2"), ConversationID("c1")])
        #expect(models[0].isPinned)
        #expect(!models[1].isPinned)
        #expect(viewModel.isPinned(ConversationID("c2")))
    }

    @Test func mutingFlagsTheRowWithoutReordering() async {
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1"), conversation("c2")])
        )
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        await settle()

        viewModel.toggleMute(ConversationID("c1"))

        guard case .content(let models) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(models.map(\.id) == [ConversationID("c1"), ConversationID("c2")])
        #expect(models[0].isMuted)
        #expect(viewModel.isMuted(ConversationID("c1")))
    }

    @Test func deletionRemovesRowsAndSurvivesReloads() async {
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1"), conversation("c2")])
        )
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        await settle()

        viewModel.delete([ConversationID("c1")])
        guard case .content(let afterDelete) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(afterDelete.map(\.id) == [ConversationID("c2")])

        // A refresh re-fetches both from the repository; the local delete
        // filter must keep the row out for the session.
        viewModel.refresh()
        await settle()
        guard case .content(let afterReload) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(afterReload.map(\.id) == [ConversationID("c2")])
    }

    @Test func deletingEverythingLandsOnEmpty() async {
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1")])
        )
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        await settle()

        viewModel.delete([ConversationID("c1")])
        #expect(last == .empty)
    }

    @Test func composeRoutesToNewMessage() {
        let router = SpyRouter()
        let viewModel = ConversationListViewModel(repository: StubChatProvider(), router: router)

        viewModel.didTapCompose()
        #expect(router.routes == [.newMessage])
    }

    @Test func listWarmsTheConversationDirectory() async {
        let directory = ConversationDirectory()
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1", title: "Ava Moreau")]),
            directory: directory
        )
        viewModel.viewWillAppear()
        await settle()

        #expect(directory.title(for: ConversationID("c1")) == "Ava Moreau")
    }

    /// The push-transition contract: a warm directory binds the header
    /// identity SYNCHRONOUSLY in `viewDidLoad` — no async settle — so it is
    /// laid out before the transition's first frame.
    @Test func warmThreadTitleBindsSynchronously() {
        let directory = ConversationDirectory()
        directory.remember([conversation("c1", title: "Ava Moreau")])
        let viewModel = ConversationViewModel(
            conversationID: ConversationID("c1"),
            repository: StubChatProvider(),
            directory: directory
        )
        var title: String?
        viewModel.onTitleChange = { title = $0 }

        viewModel.viewDidLoad()

        // Asserted immediately: the whole point is no await before the bind.
        #expect(title == "Ava Moreau")
    }

    @Test func identityTapRoutesToThePeerProfile() {
        let router = SpyRouter()
        let directory = ConversationDirectory()
        directory.remember([conversation("c1", others: ["peer-9"])])
        let viewModel = ConversationViewModel(
            conversationID: ConversationID("c1"),
            repository: StubChatProvider(),
            directory: directory,
            router: router
        )
        viewModel.viewDidLoad()

        viewModel.didTapIdentity()
        #expect(router.routes == [.profile(ProfileID("peer-9"), stub: nil)])
    }

    @Test func identityTapResolvesThePeerOnColdEntry() async {
        let router = SpyRouter()
        let viewModel = ConversationViewModel(
            conversationID: ConversationID("c1"),
            repository: StubChatProvider(conversations: [conversation("c1", others: ["peer-9"])]),
            router: router
        )
        viewModel.viewDidLoad()
        await settle()

        viewModel.didTapIdentity()
        #expect(router.routes == [.profile(ProfileID("peer-9"), stub: nil)])
    }

    @Test func identityTapIsANoOpWithoutASinglePeer() {
        let router = SpyRouter()
        let directory = ConversationDirectory()
        // A group shape: two other members — no single profile to open.
        directory.remember([conversation("c1", others: ["peer-1", "peer-2"])])
        let viewModel = ConversationViewModel(
            conversationID: ConversationID("c1"),
            repository: StubChatProvider(),
            directory: directory,
            router: router
        )
        viewModel.viewDidLoad()

        viewModel.didTapIdentity()
        #expect(router.routes.isEmpty)
    }

    // MARK: - Thread

    /// Forward is the last honest stub — reply and delete are wired, so only
    /// forward surfaces a notice now.
    @Test func forwardSurfacesHonestNotice() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        viewModel.viewDidLoad()
        await settle()

        var noticeTitles: [String] = []
        viewModel.onActionNotice = { title, _ in noticeTitles.append(title) }
        var replyDrafts: [ConversationViewModel.ReplyDraft?] = []
        viewModel.onReplyStateChange = { replyDrafts.append($0) }

        viewModel.perform(.reply, on: "m1")
        viewModel.perform(.forward, on: "m1")

        #expect(noticeTitles == ["Forward"])          // reply did NOT notice
        #expect(replyDrafts.compactMap(\.self).map(\.messageID) == ["m1"]) // reply set a draft
    }

    @Test func replyDraftPublishesAndSendCarriesReplyTo() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var drafts: [ConversationViewModel.ReplyDraft?] = []
        viewModel.onReplyStateChange = { drafts.append($0) }
        viewModel.viewDidLoad()
        await settle()

        viewModel.beginReply(to: "m1")
        #expect(drafts.last??.messageID == "m1")
        #expect(drafts.last??.snippet == "m1") // body used as the excerpt

        viewModel.send("on it")
        await settle()

        #expect(await provider.sentReplyTos == ["m1"]) // reply reference threaded through
        #expect(drafts.last == .some(nil))             // reply state cleared on send
    }

    @Test func cancelReplyClearsTheDraft() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var drafts: [ConversationViewModel.ReplyDraft?] = []
        viewModel.onReplyStateChange = { drafts.append($0) }
        viewModel.viewDidLoad()
        await settle()

        viewModel.beginReply(to: "m1")
        viewModel.cancelReply()
        #expect(drafts.last == .some(nil))
    }

    @Test func deleteRemovesMessageAndSurvivesReload() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false), message("m2", mine: true)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.deleteMessage("m1")
        guard case .content(let afterDelete) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(afterDelete.map(\.id) == ["m2"])

        // A reload re-fetches m1 from the repository; the session-local delete
        // set must keep it out.
        viewModel.refresh()
        await settle()
        guard case .content(let afterReload) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(afterReload.map(\.id) == ["m2"])
    }

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
