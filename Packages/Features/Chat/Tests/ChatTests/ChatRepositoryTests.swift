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

        // Two answered threads plus the two inbound-only request seeds.
        #expect(conversations.count == 4)
        let first = try #require(conversations.first)
        #expect(!first.title.isEmpty)
        #expect(first.title != first.id.rawValue) // hydrated name, not an id
        #expect(!first.lastMessage.isEmpty)       // preview from getHistory
        #expect(first.lastActivityAt != nil)
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
