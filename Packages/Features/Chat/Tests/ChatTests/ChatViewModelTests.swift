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

    /// What the next load answers — so a reload is seen to land.
    func setConversations(_ value: [Conversation]) { conversations = value }
    func setMessages(_ value: [ChatMessage]) { messages = value }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
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
    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time: a
    /// starved runner spends none of the budget (#1115). Returns whether
    /// `condition` came to hold, and every caller asserts it — a wait that
    /// gives up silently lets the next line read the state from before.
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func isContent(_ phase: ConversationListViewModel.Phase?) -> Bool {
        if case .content = phase { true } else { false }
    }

    private func ids(_ phase: ConversationListViewModel.Phase?) -> [ConversationID] {
        if case .content(let sections) = phase { sections.all.map(\.id) } else { [] }
    }

    private func isContent(_ phase: ConversationViewModel.Phase?) -> Bool {
        if case .content = phase { true } else { false }
    }

    private func messageIDs(_ phase: ConversationViewModel.Phase?) -> [String] {
        if case .content(let models) = phase { models.map(\.id) } else { [] }
    }

    // MARK: - Conversation list

    @Test func listLoadsIntoContent() async {
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: [conversation("c1"), conversation("c2")]))
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewWillAppear()
        #expect(await settle { isContent(last) })

        #expect(ids(last) == [ConversationID("c1"), ConversationID("c2")])
    }

    @Test func emptyConversationList() async {
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: []))
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        #expect(await settle { last == .empty })
    }

    @Test func selectingConversationRoutesToIt() async {
        let router = SpyRouter()
        let viewModel = ConversationListViewModel(repository: StubChatProvider(conversations: [conversation("c7")]), router: router)
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        #expect(await settle { isContent(last) })

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
        #expect(await settle { isContent(last) })

        viewModel.togglePin(ConversationID("c2"))

        guard case .content(let modelsSections) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        let models = modelsSections.all
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
        #expect(await settle { isContent(last) })

        viewModel.toggleMute(ConversationID("c1"))

        guard case .content(let modelsSections) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        let models = modelsSections.all
        #expect(models.map(\.id) == [ConversationID("c1"), ConversationID("c2")])
        #expect(models[0].isMuted)
        #expect(viewModel.isMuted(ConversationID("c1")))
    }

    @Test func deletionRemovesRowsAndSurvivesReloads() async {
        let provider = StubChatProvider(conversations: [conversation("c1"), conversation("c2")])
        let viewModel = ConversationListViewModel(repository: provider)
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        #expect(await settle { isContent(last) })

        viewModel.delete([ConversationID("c1")])
        guard case .content(let afterDeleteSections) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        let afterDelete = afterDeleteSections.all
        #expect(afterDelete.map(\.id) == [ConversationID("c2")])

        // A refresh re-fetches c1 from the repository; the local delete
        // filter must keep the row out for the session. The reload also
        // brings c3, which says it landed.
        await provider.setConversations([conversation("c1"), conversation("c2"), conversation("c3")])
        viewModel.refresh()
        #expect(await settle { ids(last).contains(ConversationID("c3")) })
        #expect(ids(last) == [ConversationID("c2"), ConversationID("c3")])
    }

    @Test func deletingEverythingLandsOnEmpty() async {
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1")])
        )
        var last: ConversationListViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewWillAppear()
        #expect(await settle { isContent(last) })

        viewModel.delete([ConversationID("c1")])
        #expect(last == .empty)
    }


    @Test func listWarmsTheConversationDirectory() async {
        let directory = ConversationDirectory()
        let viewModel = ConversationListViewModel(
            repository: StubChatProvider(conversations: [conversation("c1", title: "Ava Moreau")]),
            directory: directory
        )
        viewModel.viewWillAppear()
        #expect(await settle { directory.title(for: ConversationID("c1")) == "Ava Moreau" })
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
        // The header's name rides along, never an invented handle (#1860).
        #expect(router.routes == [.profile(ProfileID("peer-9"), stub: viewModel.peerStub)])
        #expect(viewModel.peerStub?.handle == nil)
        #expect(viewModel.peerStub?.displayName.isEmpty == false, "the header's name did not ride along")
    }

    /// The toolbar's peer pill opens the peer's profile CARD (#1524); the
    /// header's other ways in still push the profile.
    @Test func thePeerPillRoutesToTheProfileCard() {
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

        viewModel.didTapIdentityPill()
        #expect(router.routes == [.profileCard(ProfileID("peer-9"), stub: viewModel.peerStub)])
    }

    @Test func identityTapResolvesThePeerOnColdEntry() async {
        let router = SpyRouter()
        let viewModel = ConversationViewModel(
            conversationID: ConversationID("c1"),
            repository: StubChatProvider(conversations: [conversation("c1", others: ["peer-9"])]),
            router: router
        )
        var peer: ProfileID?
        viewModel.onPeerChange = { peer = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { peer == ProfileID("peer-9") })

        viewModel.didTapIdentity()
        #expect(router.routes == [.profile(ProfileID("peer-9"), stub: viewModel.peerStub)])
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
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { messageIDs(last) == ["m1"] })

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
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { messageIDs(last) == ["m1"] })

        viewModel.beginReply(to: "m1")
        #expect(drafts.last??.messageID == "m1")
        #expect(drafts.last??.snippet == "m1") // body used as the excerpt

        viewModel.send("on it")
        #expect(await settle { await !provider.sentReplyTos.isEmpty })

        #expect(await provider.sentReplyTos == ["m1"]) // reply reference threaded through
        #expect(drafts.last == .some(nil))             // reply state cleared on send
    }

    @Test func cancelReplyClearsTheDraft() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var drafts: [ConversationViewModel.ReplyDraft?] = []
        viewModel.onReplyStateChange = { drafts.append($0) }
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { messageIDs(last) == ["m1"] })

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
        #expect(await settle { messageIDs(last) == ["m1", "m2"] })

        viewModel.deleteMessage("m1")
        guard case .content(let afterDelete) = last else {
            Issue.record("expected content, got \(String(describing: last))")
            return
        }
        #expect(afterDelete.map(\.id) == ["m2"])

        // A reload re-fetches m1 from the repository; the session-local delete
        // set must keep it out. It also brings m3, which says it landed.
        await provider.setMessages([message("m1", mine: false), message("m2", mine: true), message("m3", mine: false)])
        viewModel.refresh()
        #expect(await settle { messageIDs(last).contains("m3") })
        #expect(messageIDs(last) == ["m2", "m3"])
    }

    @Test func threadLoadsMessagesAndMarksRead() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false), message("m2", mine: true)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }

        viewModel.viewDidLoad()
        #expect(await settle { isContent(last) })

        #expect(messageIDs(last) == ["m1", "m2"])
        #expect(await settle { await provider.markReadCalls >= 1 })
    }

    @Test func sendingAppendsMessage() async {
        let provider = StubChatProvider(messages: [message("m1", mine: false)])
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        var last: ConversationViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { messageIDs(last) == ["m1"] })

        viewModel.send("  hello  ")
        #expect(await settle { messageIDs(last).last == "sent" })

        #expect(await provider.sentBodies == ["hello"]) // trimmed
        #expect(messageIDs(last) == ["m1", "sent"]) // appended
    }
}
