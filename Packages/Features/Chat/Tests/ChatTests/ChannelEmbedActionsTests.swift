import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

/// A channel showcase's card actions (#2216), over Chat's repository on the
/// mock's channels: Join subscribes — muted (#2230) — and the channel lands
/// in Chats; Request to join asks, and the cancel takes it back; Open routes
/// to the conversation.
@MainActor
struct ChannelEmbedActionsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    @MainActor
    private final class SpyRouter: Router {
        private(set) var routes: [AppRoute] = []
        func route(to route: AppRoute) { routes.append(route) }
    }

    @MainActor
    private final class Counter {
        var count = 0
        var ids: [ConversationID] = []
    }

    private func repository() -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: false, seedsChannels: true).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            inboxPageSize: 100,
            proposals: ProposedChatClient(client: client),
            showsGroups: false,
            showsChannels: true
        )
    }

    @Test func joinSubscribesMutedAndChatsFollows() async throws {
        let repository = repository()
        let reloads = Counter()
        let subscribed = Counter()
        let actions = ChannelEmbedActions(
            service: repository, router: nil, membershipDidChange: { reloads.count += 1 },
            didSubscribe: { subscribed.ids.append($0) }
        )
        let harbour = ConversationID("ch-harbour")
        let state = try await actions.join(harbour)
        #expect(state == .subscriber)
        #expect(reloads.count == 1, "Chats was not told")
        #expect(subscribed.ids == [harbour], "the join wasn't muted (#2230)")
        let rows = try await repository.loadInbox(.inbox, after: nil).conversations
        let row = try #require(rows.first { $0.id == harbour }, "a joined channel missing from Chats")
        #expect(row.isMuted, "the mock didn't mute the join (#2230)")
    }

    @Test func requestThenCancel() async throws {
        let repository = repository()
        let reloads = Counter()
        let actions = ChannelEmbedActions(service: repository, router: nil) { reloads.count += 1 }
        let printroom = ConversationID("ch-printroom")
        #expect(try await actions.requestToJoin(printroom) == .requested)
        #expect(try await repository.details(of: printroom).viewerState == .requested)
        #expect(try await actions.cancelJoinRequest(printroom) == ChannelEmbed.ViewerState.none)
        #expect(try await repository.details(of: printroom).viewerState == .none)
        #expect(reloads.count == 0, "a request reloaded Chats")
    }

    @Test func aRefusalThrows() async {
        let actions = ChannelEmbedActions(service: repository(), router: nil) {}
        // Not public: Join is refused (the card offers Request instead).
        await #expect(throws: (any Error).self) { _ = try await actions.join(ConversationID("ch-printroom")) }
    }

    @Test func openRoutesToTheConversation() {
        let router = SpyRouter()
        let actions = ChannelEmbedActions(service: repository(), router: router) {}
        actions.open(ConversationID("ch-botanic"))
        #expect(router.routes == [.conversation(ConversationID("ch-botanic"))])
    }

    @Test func anOwnerAndAnAdminAreMembersToTheCard() {
        #expect(ChannelEmbedActions.embedState(.owner) == .member)
        #expect(ChannelEmbedActions.embedState(.admin) == .member)
        #expect(ChannelEmbedActions.embedState(.subscriber) == .subscriber)
        #expect(ChannelEmbedActions.embedState(.invited) == ChannelEmbed.ViewerState.none)
        #expect(ChannelEmbedActions.embedState(.banned) == .banned)
    }
}
