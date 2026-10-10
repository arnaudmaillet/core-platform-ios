import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import Testing
@testable import Chat

/// A text message on its way (#719) — drawn at once, delivered or failed with
/// a retry — and the conversation's mute, written through chat.v1.
@MainActor
struct ChatSendAndMuteTests {
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func settleAsync(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - Sending

    /// ⚠️ OPTIMISTIC: the text is on screen before the server answers, on its
    /// way, then turns into the delivered message — once, not twice.
    @Test func aTextShowsAtOnceThenIsDelivered() async throws {
        let provider = TextStubProvider(failures: 0)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: provider)
        var phases: [ConversationViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        var sending: [Bool] = []
        viewModel.onSendingChange = { sending.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { if case .content = phases.last { true } else { false } })

        viewModel.send("  hello  ")
        guard case .content(let pending) = phases.last else { Issue.record("no content"); return }
        let bubble = try #require(pending.last, "the message waited for the server")
        #expect(bubble.body == "hello")
        #expect(bubble.isMine)
        #expect(bubble.delivery == .sending)
        #expect(sending.last == true, "the send button does not spin")

        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .sent } else { false }
        }, "the message was never delivered")
        guard case .content(let delivered) = phases.last else { return }
        #expect(delivered.filter { $0.body == "hello" }.count == 1, "the pending row outlived its delivery")
        #expect(delivered.last?.id == "t1")
        // Waited for, not read: the send marks the conversation read after
        // the delivered message lands, and the button stops spinning after
        // that await.
        #expect(await settle { sending.last == false }, "the send button kept spinning")
    }

    /// A failed text stays, says so, and is sent again by a retry.
    @Test func aFailedTextIsRetried() async throws {
        let provider = TextStubProvider(failures: 1)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: provider)
        var phases: [ConversationViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        var notices: [String] = []
        viewModel.onActionNotice = { title, _ in notices.append(title) }
        viewModel.viewDidLoad()
        #expect(await settle { if case .content = phases.last { true } else { false } })

        viewModel.send("hello")
        guard case .content(let pending) = phases.last, let bubble = pending.last else {
            Issue.record("no pending bubble"); return
        }
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .failed } else { false }
        }, "a failed send did not stay on screen")
        #expect(!notices.isEmpty, "a failed text was not said")

        viewModel.retry(bubble.id)
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .sent } else { false }
        }, "the retry did not deliver")
        guard case .content(let delivered) = phases.last else { return }
        #expect(delivered.map(\.body) == ["hello"])
        #expect(await provider.sentBodies == ["hello", "hello"])
    }

    /// The driver hands the screen the delivery of a text, as it does a photo's.
    @Test func theDriverForwardsATextsDelivery() async {
        let provider = TextStubProvider(failures: 0)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: provider)
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: provider, avatars: nil)
        var last: [ConversationThreadMessage] = []
        driver.onPhaseChange = { phase in if case .content(let messages) = phase { last = messages } }
        driver.viewDidLoad()
        _ = await settle { false }
        driver.send("hi")
        #expect(last.last?.body == "hi")
        #expect(last.last?.delivery == .sending)
        #expect(await settle { last.last?.delivery == .sent })
    }

    // MARK: - Muting

    /// The bell is the inbox's mute: toggled from the thread it writes
    /// through `setMuted`, and a toggle from the inbox reaches the screen.
    @Test func theBellIsTheInboxsMuteAndWritesThrough() async {
        let provider = TextStubProvider(failures: 0)
        let catalog = InboxCatalog(repository: provider)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: provider, avatars: nil, pins: catalog)
        var reported: [Bool?] = []
        driver.onMutedChange = { reported.append($0) }
        driver.viewDidLoad()
        #expect(reported == [false], "the screen hears the mute from its first frame")

        driver.toggleMuted()
        #expect(catalog.isMuted(ConversationID("c1")), "the toggle waited for the server")
        #expect(reported == [false, true])
        var mutes: [MuteCall] = []
        for _ in 0..<400 where mutes.isEmpty {
            mutes = await provider.mutes
            if mutes.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(mutes == [MuteCall(id: "c1", muted: true)], "the mute was not written through")

        catalog.toggleMute(ConversationID("c1"))
        #expect(reported == [false, true, false])

        // Another conversation's mute is not this screen's news.
        catalog.toggleMute(ConversationID("c2"))
        #expect(reported == [false, true, false])
    }

    /// A refused mute is put back.
    @Test func aRefusedMuteIsRolledBack() async {
        let provider = TextStubProvider(failures: 0, refusesMute: true)
        let catalog = InboxCatalog(repository: provider)
        catalog.toggleMute(ConversationID("c1"))
        #expect(catalog.isMuted(ConversationID("c1")))
        #expect(await settle { !catalog.isMuted(ConversationID("c1")) }, "a refused mute stayed on")
    }

    /// ⚠️ A MUTE IS CONFIRMED ONCE THE SERVER HAS ANSWERED (#802): the row
    /// flips at once, the confirmation waits for the write.
    @Test func aMuteConfirmsOnlyAfterTheServerAnswers() async {
        let provider = TextStubProvider(failures: 0)
        let catalog = InboxCatalog(repository: provider)
        let answers = Answers()
        catalog.setMute(ConversationID("c1"), muted: true, until: nil) { answers.items.append($0) }
        #expect(catalog.isMuted(ConversationID("c1")), "the row waited for the server")
        #expect(answers.items.isEmpty, "confirmed before the server answered")
        #expect(await settle { !answers.items.isEmpty })
        #expect(answers.items == [true])
        #expect(await provider.mutes == [MuteCall(id: "c1", muted: true)])
    }

    /// A refused mute answers false, after it has been put back.
    @Test func aRefusedMuteAnswersFalseOnceRolledBack() async {
        let provider = TextStubProvider(failures: 0, refusesMute: true)
        let catalog = InboxCatalog(repository: provider)
        let mutedWhenAnswered = Answers()
        let answers = Answers()
        catalog.toggleMute(ConversationID("c1")) { confirmed in
            answers.items.append(confirmed)
            mutedWhenAnswered.items.append(catalog.isMuted(ConversationID("c1")))
        }
        #expect(await settle { !answers.items.isEmpty })
        #expect(answers.items == [false])
        #expect(mutedWhenAnswered.items == [false], "the refusal was answered before the rollback")
    }

    /// Muting from the inbox's row menu says so once the server has (#803):
    /// it used to show nothing at all.
    @Test func anInboxMuteIsAnsweredInWords() async {
        let provider = TextStubProvider(failures: 0)
        let list = ConversationListViewModel(repository: provider)
        let answers = Answers()
        var messages: [String] = []
        list.onMuteAnswered = { message, _, confirmed in
            messages.append(message)
            answers.items.append(confirmed)
        }
        list.toggleMute(ConversationID("c1"))
        #expect(messages.isEmpty, "answered before the server")
        #expect(await settle { !answers.items.isEmpty })
        #expect(messages == ["Notifications muted"])
        #expect(answers.items == [true])

        #expect(ConversationListViewModel.muteAnswer(muting: false, confirmed: true) == "Notifications on")
        #expect(ConversationListViewModel.muteAnswer(muting: true, confirmed: false) == "Couldn't mute notifications")
    }

    /// ⚠️ ANSWERS OUT OF ORDER: a mute then an unmute, the unmute answered
    /// first and the mute refused after. Only the latest request speaks — the
    /// stale refusal neither toasts "Couldn't mute" nor puts the mute back.
    @Test func aSupersededMuteNeverSpeaksOrRollsBack() async {
        let provider = GatedMuteProvider()
        let catalog = InboxCatalog(repository: provider)
        let said = Said()
        catalog.setMute(ConversationID("c1"), muted: true, until: nil) { said.items.append("mute \($0)") }
        catalog.setMute(ConversationID("c1"), muted: false, until: nil) { said.items.append("unmute \($0)") }
        #expect(await settleAsync { await provider.pendingCount == 2 })

        await provider.answer(muted: false, refused: false)
        #expect(await settle { catalog.muteAnswersHandled == 1 })
        #expect(said.items == ["unmute true"])

        await provider.answer(muted: true, refused: true)
        #expect(await settle { catalog.muteAnswersHandled == 2 })
        #expect(said.items == ["unmute true"], "the superseded mute spoke")
        #expect(!catalog.isMuted(ConversationID("c1")), "the stale refusal put the mute back")
    }

    /// What a completion answered, read after an await.
    @MainActor
    private final class Answers {
        var items: [Bool] = []
    }

    /// What the completions said, in order.
    @MainActor
    private final class Said {
        var items: [String] = []
    }

    /// The server's mute reaches the inbox on load (`InboxEntryView.muted`).
    @Test func theServersMuteIsAdopted() async {
        let provider = TextStubProvider(failures: 0, mutedOnServer: ["c1"])
        let catalog = InboxCatalog(repository: provider)
        catalog.reload()
        #expect(await settle { catalog.isMuted(ConversationID("c1")) }, "the server's mute was ignored")
        #expect(!catalog.isMuted(ConversationID("c2")))
    }

    /// End to end on the mock BFF: `MuteConversation` is remembered and
    /// `ListInbox` gives it back.
    @Test func theMockRemembersAMute() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session()
        )
        let first = try #require(try await repository.loadConversations().first)
        #expect(!first.isMuted)
        try await repository.setMuted(true, for: first.id)
        let reloaded = try await repository.loadConversations()
        #expect(reloaded.first { $0.id == first.id }?.isMuted == true, "the mute did not come back")
        try await repository.setMuted(false, for: first.id)
        #expect(try await repository.loadConversations().first { $0.id == first.id }?.isMuted == false)

        // A mute for a while (#729): muted until then, unmuted after.
        try await repository.setMuted(true, until: Date().addingTimeInterval(3_600), for: first.id)
        #expect(try await repository.loadConversations().first { $0.id == first.id }?.isMuted == true)
        try await repository.setMuted(true, until: Date().addingTimeInterval(-1), for: first.id)
        #expect(try await repository.loadConversations().first { $0.id == first.id }?.isMuted == false,
                "an expired mute still mutes")
    }

    /// The bell's durations reach the contract: the driver mutes until a
    /// time, through the inbox (#729).
    @Test func aDurationMutesUntilThatTime() async {
        let provider = TextStubProvider(failures: 0)
        let catalog = InboxCatalog(repository: provider)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: provider)
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: provider, avatars: nil, pins: catalog)
        var reported: [Bool?] = []
        driver.onMutedChange = { reported.append($0) }
        driver.viewDidLoad()
        let until = Date().addingTimeInterval(8 * 3_600)
        driver.setMuted(true, until: until)
        #expect(reported.last == true)
        var untils: [Date?] = []
        for _ in 0..<200 where untils.isEmpty {
            untils = await provider.untils
            if untils.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(untils.first??.timeIntervalSince1970 == until.timeIntervalSince1970, "the duration was dropped")
        driver.setMuted(false, until: nil)
        #expect(reported.last == false)
    }

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }
}

struct MuteCall: Equatable {
    let id: String
    let muted: Bool
}

/// Holds every mute until the test answers it, so answers can arrive in any
/// order.
private actor GatedMuteProvider: ChatProviding {
    private var pending: [(muted: Bool, continuation: CheckedContinuation<Void, Error>)] = []
    var pendingCount: Int { pending.count }

    /// Answers the waiting request for `muted`.
    func answer(muted: Bool, refused: Bool) {
        guard let index = pending.firstIndex(where: { $0.muted == muted }) else { return }
        let request = pending.remove(at: index)
        if refused {
            request.continuation.resume(throwing: ChatError.transport(message: "refused"))
        } else {
            request.continuation.resume()
        }
    }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        throw ChatError.transport(message: "unused")
    }
    func send(
        media: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        throw ChatError.mediaUpload(message: "unused")
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("c") }
    func setMuted(_ muted: Bool, for conversationID: ConversationID) async throws {
        try await withCheckedThrowingContinuation { pending.append((muted, $0)) }
    }
    func setMuted(_ muted: Bool, until: Date?, for conversationID: ConversationID) async throws {
        try await setMuted(muted, for: conversationID)
    }
}

/// Fails the first `failures` text sends, then delivers; records mutes.
private actor TextStubProvider: ChatProviding {
    private var failures: Int
    private let refusesMute: Bool
    private let mutedOnServer: Set<String>
    private var count = 0
    private(set) var sentBodies: [String] = []
    private(set) var mutes: [MuteCall] = []

    init(failures: Int, refusesMute: Bool = false, mutedOnServer: Set<String> = []) {
        self.failures = failures
        self.refusesMute = refusesMute
        self.mutedOnServer = mutedOnServer
    }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] {
        ["c1", "c2"].map { id in
            Conversation(
                id: ConversationID(id), title: id, lastMessage: "", lastActivityAt: Date(),
                isMuted: mutedOnServer.contains(id)
            )
        }
    }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        sentBodies.append(body)
        try await Task.sleep(for: .milliseconds(20))
        if failures > 0 {
            failures -= 1
            throw ChatError.transport(message: "offline")
        }
        count += 1
        return ChatMessage(id: "t\(count)", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func send(
        media: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        throw ChatError.mediaUpload(message: "unused")
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("c") }
    func setMuted(_ muted: Bool, for conversationID: ConversationID) async throws {
        mutes.append(MuteCall(id: conversationID.rawValue, muted: muted))
        if refusesMute { throw ChatError.transport(message: "refused") }
    }
    private(set) var untils: [Date?] = []
    func setMuted(_ muted: Bool, until: Date?, for conversationID: ConversationID) async throws {
        untils.append(until)
        try await setMuted(muted, for: conversationID)
    }
}
