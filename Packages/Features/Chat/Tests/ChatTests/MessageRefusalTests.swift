import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

/// A message to someone who takes none ("Who Can Message": No One, #397,
/// backend #656) is refused by the server, and the app says so instead of
/// dropping it.
struct MessageRefusalTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository(refusing refused: String) -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, mayMessage: { _, recipient in recipient != refused }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session()
        )
    }

    @Test func aMessageToSomeoneWhoTakesNoneIsRefused() async throws {
        let refused = ProfileID("prof-30")
        let repository = makeRepository(refusing: refused.rawValue)
        let conversation = try await repository.directConversation(with: refused)
        await #expect(throws: ChatError.messagesRefused) {
            _ = try await repository.send("Hi!", to: conversation, replyingTo: nil)
        }

        let open = try await repository.directConversation(with: ProfileID("prof-31"))
        let sent = try await repository.send("Hi!", to: open, replyingTo: nil)
        #expect(sent.body == "Hi!")
    }

    @MainActor
    @Test func theNoticeSaysWhy() {
        #expect(ConversationViewModel.sendFailureNotice(ChatError.messagesRefused).message == "This account doesn't take messages.")
        #expect(ConversationViewModel.sendFailureNotice(ChatError.transport(message: "x")).title == "Couldn't send")
    }
}
