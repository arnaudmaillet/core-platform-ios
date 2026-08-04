import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

private struct AuthenticatedSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

struct ChatRepositoryTests {
    private func makeRepository() -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff) // viewer resolve + member hydration
        MockChatService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )
    }

    @Test func loadsConversationsWithHydratedTitleAndPreview() async throws {
        let repository = makeRepository()

        let conversations = try await repository.loadConversations()

        // Asserted as a shape, not a tally: the seed exists to populate a
        // screen, so its size is expected to move as that screen's needs do.
        // What must hold is that EVERY row hydrated — a count would have
        // passed just as happily with half of them blank.
        #expect(conversations.count > 5)
        #expect(conversations.contains { $0.id == ConversationID("conv-req-0") })
        for conversation in conversations {
            #expect(!conversation.title.isEmpty)
            #expect(conversation.title != conversation.id.rawValue) // name, not an id
            #expect(!conversation.lastMessage.isEmpty)              // preview from getHistory
            #expect(conversation.lastActivityAt != nil)
        }
    }

    /// The peer's handle rides along from the same `GetProfileById` that
    /// resolves the title. The compose picker's Recent rows are the only
    /// consumer, and without it they render name-only beside sections that
    /// show a handle.
    @Test func hydrationCarriesThePeerHandle() async throws {
        let conversations = try await makeRepository().loadConversations()

        let direct = try #require(conversations.first { $0.directPeerID != nil })
        let handle = try #require(direct.directPeerHandle)
        #expect(!handle.isEmpty)
        #expect(!handle.hasPrefix("@"))
    }

    /// `lastMessageIsMine` is what tells an unanswered request from a
    /// conversation the viewer replied to, so it has to survive hydration.
    @Test func hydrationFlagsWhoSentTheLastMessage() async throws {
        let conversations = try await makeRepository().loadConversations()

        let answered = try #require(conversations.first { $0.id == ConversationID("conv-0") })
        #expect(answered.lastMessageIsMine)
        let request = try #require(conversations.first { $0.id == ConversationID("conv-req-0") })
        #expect(!request.lastMessageIsMine)
    }

    @Test func loadsMessagesWithMineFlag() async throws {
        let repository = makeRepository()

        // conv-1 keeps the short 3-message seed (conv-0 is the dense
        // thread-screen demo seed and grows with it).
        let messages = try await repository.loadMessages(in: ConversationID("conv-1"))

        #expect(messages.count == 3)
        // Ordered oldest → newest.
        #expect(messages.map(\.createdAt) == messages.map(\.createdAt).sorted())
        // The seeded history includes one message from the viewer.
        #expect(messages.contains { $0.isMine })
        #expect(messages.contains { !$0.isMine })
    }

    @Test func sendReturnsMyMessageAndPersists() async throws {
        let repository = makeRepository()

        let sent = try await repository.send("On my way", to: ConversationID("conv-1"))
        #expect(sent.isMine)
        #expect(sent.body == "On my way")

        let messages = try await repository.loadMessages(in: ConversationID("conv-1"))
        #expect(messages.last?.body == "On my way")
    }

    @Test func directConversationReusesAnExistingDM() async throws {
        // conv-0 is viewer ↔ authors[0]; messaging that author must reuse it.
        let repository = makeRepository()
        let author0 = MockSocialDataset().authors[0].profileID

        let id = try await repository.directConversation(with: ProfileID(author0))

        #expect(id == ConversationID("conv-0"))
    }

    @Test func directConversationCreatesWhenNoneExists() async throws {
        // A profile with no existing 1:1 conversation → a fresh one is created.
        let repository = makeRepository()

        let id = try await repository.directConversation(with: ProfileID("prof-stranger"))

        #expect(id.rawValue.hasPrefix("conv-created-"))
    }
}

// MARK: - Unread count

/// The count the All list badges an avatar with, derived from the history
/// window and the read cursor — because `chat.v1` serves no `unread_count`
/// (`dev/BACKEND_GAPS.md` §17).
struct UnreadCountTests {
    private let viewer = ProfileID("me")

    private func message(_ id: String, from sender: String, at ms: Int64) -> Chat_V1_MessageView {
        var view = Chat_V1_MessageView()
        view.messageID = id
        view.senderID = sender
        view.createdAtMs = ms
        return view
    }

    private func count(
        _ window: [Chat_V1_MessageView],
        lastRead: String?,
        isUnread: Bool = true
    ) -> Int {
        ChatRepository.unreadCount(
            in: window, viewer: viewer, viewerLastRead: lastRead, isUnread: isUnread
        )
    }

    /// Only what arrived AFTER the cursor, and only what someone else sent.
    @Test func countsInboundMessagesPastTheCursor() {
        let window = [
            message("m0", from: "peer", at: 10),
            message("m1", from: "me", at: 20),
            message("m2", from: "peer", at: 30),
            message("m3", from: "peer", at: 40)
        ]
        #expect(count(window, lastRead: "m1") == 2)
    }

    /// A thread the viewer has never opened: everything inbound is waiting.
    @Test func anEmptyCursorCountsTheWholeWindow() {
        let window = [
            message("m0", from: "peer", at: 10),
            message("m1", from: "peer", at: 20)
        ]
        #expect(count(window, lastRead: "") == 2)
        #expect(count(window, lastRead: nil) == 2)
    }

    /// The viewer's own messages are never unread, wherever they sit.
    @Test func theViewersOwnMessagesNeverCount() {
        let window = [
            message("m0", from: "peer", at: 10),
            message("m1", from: "me", at: 20),
            message("m2", from: "me", at: 30)
        ]
        #expect(count(window, lastRead: "m0") == 0)
    }

    /// Order comes from timestamps, not from the order the transport happened
    /// to return: the cursor's POSITION is what splits read from unread.
    @Test func theWindowIsOrderedBeforeItIsSplit() {
        let window = [
            message("m2", from: "peer", at: 30),
            message("m0", from: "peer", at: 10),
            message("m1", from: "me", at: 20)
        ]
        #expect(count(window, lastRead: "m1") == 1)
    }

    /// A cursor pointing outside the window means nothing recent has been read,
    /// so the window is the answer — never a negative or a crash.
    @Test func aCursorOutsideTheWindowCountsEverythingInIt() {
        let window = [
            message("m8", from: "peer", at: 80),
            message("m9", from: "peer", at: 90)
        ]
        #expect(count(window, lastRead: "m0-long-since-paged-out") == 2)
    }

    /// Gated on the flag, so the badge and the row treatment can never disagree
    /// about whether anything is waiting.
    @Test func aReadConversationCountsZeroWhateverTheWindowHolds() {
        let window = [message("m0", from: "peer", at: 10)]
        #expect(count(window, lastRead: "", isUnread: false) == 0)
    }
}
