import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import TestSupport
import Testing
import UIKit
@testable import Chat

/// "Share as a Post" on a channel (#2216, part 3): offered to its owner and
/// admins only, on a public or on-request channel, on its info screen and
/// after creating it — with the channel's card for the Text Post screen —
/// and nowhere with the showcases off.
///
/// The mock's viewer (`ChannelsTests`): owner of ch-daily (public) and of
/// ch-studio-requests (on request); subscriber of ch-botanic; not in
/// ch-harbour.
@MainActor
struct ChannelShowcaseShareTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func make() -> ChatRepository {
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

    private let daily = ConversationID("ch-daily")
    private let studio = ConversationID("ch-studio-requests")
    private let botanic = ConversationID("ch-botanic")
    private let harbour = ConversationID("ch-harbour")

    private func loadedInfo(_ id: ConversationID, shares: Bool = true) async -> ChannelInfoViewModel {
        let info = ChannelInfoViewModel(conversationID: id, service: make(), sharesShowcases: shares)
        info.load()
        await settle { info.state.phase == .loaded }
        return info
    }

    // MARK: - Who may share

    @Test func onlyARunnerOfAShowableChannelMayShare() {
        typealias Rule = ChannelShowcase
        #expect(Rule.canShare(viewerState: .owner, visibility: .public))
        #expect(Rule.canShare(viewerState: .admin, visibility: .listedOnRequest))
        #expect(!Rule.canShare(viewerState: .subscriber, visibility: .public), "a subscriber shared a channel")
        #expect(!Rule.canShare(viewerState: .member, visibility: .public))
        #expect(!Rule.canShare(viewerState: .none, visibility: .public))
        #expect(!Rule.canShare(viewerState: .owner, visibility: .private), "a private channel can't be shown")
        #expect(Rule.embed(daily, name: "D", photoURL: nil, description: "", subscriberCount: 1, visibility: .private) == nil)
    }

    // MARK: - The info screen

    @Test func theOwnerIsOfferedShareAsPostWithTheChannelsCard() async throws {
        let info = await loadedInfo(daily)
        #expect(info.state.canShareAsPost)
        let channel = try #require(info.showcaseEmbed?.channel)
        #expect(channel.conversationID == daily)
        #expect(channel.name == info.state.name && !channel.name.isEmpty)
        #expect(channel.subscriberCount == info.state.subscriberCount)
        #expect(channel.visibility == .public)
        #expect(channel.viewerState == .member && channel.action == .open, "the runner's own card")
    }

    @Test func anOnRequestChannelCardSaysSo() async throws {
        let info = await loadedInfo(studio)
        #expect(info.state.canShareAsPost)
        #expect(info.showcaseEmbed?.channel?.visibility == .onRequest)
    }

    @Test func aSubscriberOrAnOutsiderIsNotOffered() async {
        let subscribed = await loadedInfo(botanic)
        #expect(!subscribed.state.canShareAsPost)
        #expect(subscribed.showcaseEmbed == nil)
        let outside = await loadedInfo(harbour)
        #expect(!outside.state.canShareAsPost)
    }

    @Test func withTheShowcasesOffTheOwnerIsNotOffered() async {
        let info = await loadedInfo(daily, shares: false)
        #expect(info.state.canEdit, "the owner still runs it")
        #expect(!info.state.canShareAsPost)
        #expect(info.showcaseEmbed == nil)
    }

    @Test func theInfoScreenListsTheRowAndHandsTheCardOver() async throws {
        let model = ChannelInfoViewModel(conversationID: daily, service: make(), sharesShowcases: true)
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        await settle { screen.debugOffersShareAsPost }
        #expect(screen.debugOffersShareAsPost)
        var shared: PostEmbed?
        screen.onShareAsPost = { shared = $0 }
        screen.debugShareAsPost()
        #expect(shared?.channel?.conversationID == daily)
    }

    @Test func theInfoScreenOfASubscriberHasNoRow() async {
        let model = ChannelInfoViewModel(conversationID: botanic, service: make(), sharesShowcases: true)
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        await settle { model.state.phase == .loaded }
        #expect(!screen.debugOffersShareAsPost)
    }

    // MARK: - After creating

    @Test func creatingEndsOnShareAsPostWithTheNewChannelsCard() async throws {
        let creation = ChannelCreationViewModel(service: make(), sharesShowcases: true)
        let screen = ChannelCreationViewController(viewModel: creation)
        screen.loadViewIfNeeded()
        creation.nameChanged("Night trains")
        creation.descriptionChanged("Timetables and photos")
        creation.visibilityChanged(.listedOnRequest)
        var created: ConversationID?
        creation.onCreated = { created = $0 }
        creation.create()
        await settle { created != nil }
        let id = try #require(created)
        #expect(creation.phase == .created(id))
        #expect(!creation.canCreate, "a second Create after the channel exists")
        let channel = try #require(creation.showcaseEmbed?.channel)
        #expect(channel.conversationID == id)
        #expect(channel.name == "Night trains" && channel.description == "Timetables and photos")
        #expect(channel.visibility == .onRequest && channel.viewerState == .member)

        #expect(screen.debugOffersShareAsPost)
        var shared: (ConversationID, PostEmbed)?
        screen.onShareAsPost = { shared = ($0, $1) }
        screen.debugShareAsPost()
        #expect(shared?.0 == id && shared?.1 == creation.showcaseEmbed)
        var opened: ConversationID?
        screen.onOpen = { opened = $0 }
        screen.debugOpenCreated()
        #expect(opened == id)
    }

    @Test func withTheShowcasesOffCreatingLandsInTheThreadAsBefore() async throws {
        let creation = ChannelCreationViewModel(service: make())
        let screen = ChannelCreationViewController(viewModel: creation)
        screen.loadViewIfNeeded()
        creation.nameChanged("Night trains")
        var created: ConversationID?
        creation.onCreated = { created = $0 }
        creation.create()
        await settle { created != nil }
        #expect(created != nil)
        #expect(creation.phase == .editing)
        #expect(creation.showcaseEmbed == nil)
        #expect(!screen.debugOffersShareAsPost)
    }
}
