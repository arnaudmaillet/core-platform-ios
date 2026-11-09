import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

/// A DM opens through `OpenDirectConversation` (#656, #2212): one per pair,
/// under the peer's message settings — open, a request, or refused — never
/// as a group of two made with `CreateConversation`.
struct DirectConversationTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private static let requestOnly = "prof-request-only"
    private static let refusing = "prof-refusing"

    private func make() -> (ChatRepository, MockBFF) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, admission: { _, recipient in
            switch recipient {
            case Self.requestOnly: .request
            case Self.refusing: .refused
            default: .open
            }
        }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session()
        )
        return (repository, bff)
    }

    @Test func aDMOpensThroughOpenDirectConversationNeverCreateConversation() async throws {
        let (repository, bff) = make()
        let opening = try await repository.openDirectConversation(with: ProfileID("prof-stranger"))
        #expect(!opening.isRequest)
        let paths = bff.recordedRequests.map(\.path)
        #expect(paths.contains("/chat.v1.ChatService/OpenDirectConversation"))
        #expect(!paths.contains("/chat.v1.ChatService/CreateConversation"))
        #expect(!paths.contains("/chat.v1.ChatService/JoinAsMember"), "the app joined the peer itself")
    }

    @Test func twoOpensReturnTheSameConversation() async throws {
        let (repository, _) = make()
        let first = try await repository.directConversation(with: ProfileID("prof-stranger"))
        let second = try await repository.directConversation(with: ProfileID("prof-stranger"))
        #expect(first == second)
        // A seeded DM is the pair's one too.
        let author0 = MockSocialDataset().authors[0].profileID
        #expect(try await repository.directConversation(with: ProfileID(author0)) == ConversationID("conv-0"))
    }

    /// Outside the peer's audience the first message is a request; a second
    /// one, before their answer, is refused (CHT-1010).
    @Test func aRequestTakesOneMessage() async throws {
        let (repository, _) = make()
        let opening = try await repository.openDirectConversation(with: ProfileID(Self.requestOnly))
        #expect(opening.isRequest)
        _ = try await repository.send("Hi! Loved your pier series", to: opening.id, replyingTo: nil)
        await #expect(throws: ChatError.requestPending) {
            _ = try await repository.send("Are you there?", to: opening.id, replyingTo: nil)
        }
        // Opened again, it is still the request.
        #expect(try await repository.openDirectConversation(with: ProfileID(Self.requestOnly)) == opening)
        // The viewer's inbox lists it as their own request.
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        let row = try #require(inbox.first { $0.id == opening.id })
        #expect(row.isOutgoingRequest)
        #expect(row.kind == .direct)
        #expect(row.directPeerID == ProfileID(Self.requestOnly))
    }

    @Test func someoneWhoTakesNoMessagesRefusesTheOpening() async throws {
        let (repository, _) = make()
        await #expect(throws: ChatError.messagesRefused) {
            _ = try await repository.openDirectConversation(with: ProfileID(Self.refusing))
        }
    }

    /// Accepting from the Requests folder files it in the inbox; declining
    /// drops it — both written to the server (`RespondToMessageRequest`).
    @Test func answeringARequestIsWritten() async throws {
        let (repository, bff) = make()
        let requests = try await repository.loadInbox(.requests, after: nil).conversations
        let accepted = try #require(requests.first)
        let declined = try #require(requests.dropFirst().first)
        try await repository.respondToMessageRequest(accepted.id, accept: true)
        try await repository.respondToMessageRequest(declined.id, accept: false)
        #expect(bff.recordedRequests.filter { $0.path == "/chat.v1.ChatService/RespondToMessageRequest" }.count == 2)
        let after = try await repository.loadInbox(.requests, after: nil).conversations.map(\.id)
        #expect(!after.contains(accepted.id) && !after.contains(declined.id))
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations.map(\.id)
        #expect(inbox.contains(accepted.id))
        #expect(!inbox.contains(declined.id))
    }

    /// The kind comes from the inbox entry; a group of two is NOT a DM.
    @Test func theKindTellsADMApart() async throws {
        let (repository, _) = make()
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        #expect(!inbox.isEmpty && inbox.allSatisfy { $0.kind == .direct })
        #expect(ChatRepository.kind(of: .direct) == .direct)
        #expect(ChatRepository.kind(of: .group) == .group)
        #expect(ChatRepository.kind(of: .channel) == .channel)
        let pairGroup = Conversation(
            id: ConversationID("legacy"), title: "Ava", lastMessage: "", lastActivityAt: nil,
            otherMemberIDs: [ProfileID("prof-1")], kind: .group
        )
        #expect(pairGroup.directPeerID == nil, "a group of two passed for a DM")
    }

    @MainActor
    @Test func theRequestNoticesSayWhatHappened() {
        let pending = ConversationViewModel.sendFailureNotice(ChatError.requestPending)
        #expect(pending.title == "Request Pending")
        #expect(ConversationViewModel.requestSentNotice.title == "Message Request Sent")
    }
}
