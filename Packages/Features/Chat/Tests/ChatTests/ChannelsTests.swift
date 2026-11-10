import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import Testing
import UIKit
@testable import Chat

/// Channels in Messages (#2215), on the mock's channels (`-channels`): the
/// Channels folder and its tab, who gets a composer, joining and the
/// requests an admin answers, the subscriber count, visibility — and the
/// flag off, no tab.
///
/// The mock's viewer: owner of ch-daily (public, 12 400) and of
/// ch-studio-requests (on request, three pending requests); subscriber of
/// ch-botanic; a pending request on ch-film; not in ch-harbour (public, 10).
@MainActor
struct ChannelsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func make(channels: Bool = true) -> ChatRepository {
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
            showsChannels: channels
        )
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private let daily = ConversationID("ch-daily")
    private let botanic = ConversationID("ch-botanic")
    private let film = ConversationID("ch-film")
    private let harbour = ConversationID("ch-harbour")
    private let studio = ConversationID("ch-studio-requests")

    // MARK: - The Channels folder

    @Test func theChannelsFolderHoldsTheViewersChannelsAndOnlyThem() async throws {
        let repository = make()
        let rows = try await repository.loadInbox(.channels, after: nil).conversations
        #expect(Set(rows.map(\.id)) == [daily, botanic, studio], "\(rows.map(\.id.rawValue))")
        #expect(rows.allSatisfy { $0.kind == .channel })
        let chats = try await repository.loadInbox(.inbox, after: nil).conversations
        #expect(!chats.contains { $0.kind == .channel }, "a channel in Chats")
    }

    @Test func aChannelsRowShowsItsPhotoFirstLineAndWhetherTheViewerRunsIt() async throws {
        let rows = try await make().loadInbox(.channels, after: nil).conversations
        let owned = ConversationDisplayModel(conversation: try #require(rows.first { $0.id == daily }))
        #expect(owned.title == "Daily light")
        #expect(owned.groupPhotoURL != nil)
        #expect(owned.runsChannel)
        #expect(owned.previewSender == nil, "a channel's post is signed by the channel")
        let followed = ConversationDisplayModel(conversation: try #require(rows.first { $0.id == botanic }))
        #expect(!followed.runsChannel)
        #expect(followed.peerID == nil, "a channel's owner passed for a DM's peer")

        let row = ConversationRowView()
        row.configure(with: owned)
        #expect(row.debugShowsRunsBadge)
        row.configure(with: followed)
        #expect(!row.debugShowsRunsBadge)
        #expect(ConversationDisplayModel.firstLine(of: "\n  New series  \nstarts Monday") == "New series")
    }

    @Test func theCatalogReadsTheChannelsFolderOnlyWhenAsked() async {
        let repository = make()
        let asked = InboxCatalog(repository: repository)
        asked.loadsChannels = true
        asked.reload()
        await settle { asked.snapshot.phase == .loaded && !asked.snapshot.channels.isEmpty }
        #expect(asked.snapshot.channels.count == 3)
        #expect(!asked.snapshot.active.contains { $0.kind == .channel })

        let unasked = InboxCatalog(repository: repository)
        unasked.reload()
        await settle { unasked.snapshot.phase == .loaded }
        #expect(unasked.snapshot.channels.isEmpty)
    }

    // MARK: - The tab

    @Test func theTabPutsTheRequestsRowFirstThenCreateThenTheChannels() {
        let ids = [daily, botanic]
        #expect(ChannelsViewModel.items(channels: ids, requestCount: 3) == [.joinRequests, .create, .channel(daily), .channel(botanic)])
        #expect(ChannelsViewModel.items(channels: ids, requestCount: 0) == [.create, .channel(daily), .channel(botanic)])
        #expect(ChannelsViewModel.items(channels: [], requestCount: 2).isEmpty, "no channel: the empty state")
    }

    /// The row says which channel the requests are for (the owner,
    /// 2026-11-10: "3 requests to join" — to join what?).
    @Test func theRequestsRowNamesItsChannel() {
        #expect(ChannelCopy.joinRequests(3, channels: ["Studio drops"]) == "3 requests to join Studio drops")
        #expect(ChannelCopy.joinRequests(1, channels: ["Studio drops"]) == "1 request to join Studio drops")
        #expect(ChannelCopy.joinRequests(5, channels: ["Studio drops", "Daily light"]) == "5 requests to join 2 channels")
        #expect(ChannelCopy.joinRequests(2, channels: []) == "2 requests to join", "no name known: the count alone")
    }

    @Test func theTabCountsTheRequestsOfTheChannelsTheViewerRuns() async throws {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        catalog.loadsChannels = true
        let model = ChannelsViewModel(catalog: catalog, service: repository)
        catalog.reload()
        await settle { model.requestCount == 3 }
        #expect(model.requestCount == 3, "ch-studio-requests' three")
        #expect(model.requestingChannelNames == ["Studio drops"], "only the channel with requests is named")
        #expect(Set(model.runChannels.map(\.id)) == [daily, studio])
        guard case .content(let items) = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(items.first == .joinRequests)
        #expect(items.contains(.channel(botanic)))
    }

    @Test func anEmptyTabOffersToCreateAChannel() async {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: false, seedsChannels: false).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(), inboxPageSize: 100, proposals: ProposedChatClient(client: client),
            showsGroups: false, showsChannels: true
        )
        let catalog = InboxCatalog(repository: repository)
        catalog.loadsChannels = true
        let model = ChannelsViewModel(catalog: catalog, service: repository)
        catalog.reload()
        await settle { model.phase == .empty }
        #expect(model.phase == .empty)
    }

    // MARK: - Creating

    @Test func creatingAChannelNeedsANameAndKeepsItsVisibility() async throws {
        let repository = make()
        let creation = ChannelCreationViewModel(service: repository)
        #expect(!creation.canCreate, "a channel needs a name")
        creation.nameChanged("  Night trains  ")
        creation.descriptionChanged(" Timetables and photos ")
        creation.visibilityChanged(.listedOnRequest)
        creation.visibilityChanged(.private)
        #expect(creation.draft == ConversationDraft(
            kind: .channel, name: "Night trains", description: "Timetables and photos", visibility: .listedOnRequest
        ), "private is not a channel's choice here")
        var created: ConversationID?
        creation.onCreated = { created = $0 }
        creation.create()
        await settle { created != nil }
        let details = try await repository.details(of: try #require(created))
        #expect(details.kind == .channel)
        #expect(details.viewerState == .owner)
        #expect(details.visibility == .listedOnRequest)
        #expect(try await repository.loadInbox(.channels, after: nil).conversations.contains { $0.id == created })
    }

    // MARK: - Who gets a composer

    private func identity(_ state: ConversationViewerState, _ visibility: ConversationVisibility = .public) -> ConversationIdentity {
        ConversationIdentity(kind: .channel, name: "C", visibility: visibility, subscriberCount: 5, viewerState: state)
    }

    @Test func ownerAndAdminsPostEveryoneElseReads() {
        typealias Driver = ConversationThreadDriver
        #expect(Driver.readerStanding(for: identity(.owner)) == nil)
        #expect(Driver.readerStanding(for: identity(.admin)) == nil)
        #expect(Driver.readerStanding(for: identity(.subscriber)) == .subscribed)
        #expect(Driver.readerStanding(for: identity(.member)) == .subscribed)
        #expect(Driver.readerStanding(for: identity(.none, .public)) == .canJoin)
        #expect(Driver.readerStanding(for: identity(.none, .listedOnRequest)) == .canRequest)
        #expect(Driver.readerStanding(for: identity(.requested, .listedOnRequest)) == .requested)
        #expect(Driver.readerStanding(for: identity(.banned)) == .unavailable)
        #expect(ConversationViewerState.owner.publishesInChannel && ConversationViewerState.admin.publishesInChannel)
        #expect(!ConversationViewerState.subscriber.publishesInChannel)

        let shown = Driver.channel(identity: identity(.subscriber))
        #expect(shown.isChannel && !shown.canPost)
        #expect(shown.subtitle == "5 subscribers")
        #expect(Driver.channel(identity: identity(.owner)).canPost)
    }

    /// The thread, driven against the mock: an owner gets the composer, a
    /// subscriber the reader bar — the header says the subscriber count.
    @Test func theThreadTellsTheScreenWhoPosts() async throws {
        let repository = make()
        func standing(of id: ConversationID) async -> ConversationThreadGroup? {
            let viewModel = ConversationViewModel(conversationID: id, repository: repository)
            var context = GroupThreadContext(
                service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
                createdAt: { _ in nil }, knownKind: { _ in nil }
            )
            context.kinds = [.channel]
            let driver = ConversationThreadDriver(viewModel: viewModel, viewer: repository, avatars: nil, groupContext: context)
            var group: ConversationThreadGroup?
            driver.onGroupChange = { group = $0 }
            driver.viewDidLoad()
            await settle { group != nil }
            return group
        }
        let owned = try #require(await standing(of: daily))
        #expect(owned.isChannel && owned.canPost)
        #expect(owned.subtitle == "12.4K subscribers")
        let followed = try #require(await standing(of: botanic))
        #expect(followed.readerStanding == .subscribed)
        #expect(followed.subtitle == "820 subscribers")
    }

    /// The mock refuses a subscriber's post, as chat.v1 will.
    @Test func aSubscribersPostIsRefused() async throws {
        let repository = make()
        await #expect(throws: ChatError.self) { _ = try await repository.send("Hello", to: botanic) }
        _ = try await repository.send("Tonight at 8", to: daily)
    }

    // MARK: - Joining

    @Test func joiningAPublicChannelFromItsThreadSubscribesAtOnce() async throws {
        let repository = make()
        let viewModel = ConversationViewModel(conversationID: harbour, repository: repository)
        var context = GroupThreadContext(
            service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
            createdAt: { _ in nil }, knownKind: { _ in nil }
        )
        context.kinds = [.channel]
        var joined: [ConversationID] = []
        context.onMembershipChange = { id, left in if !left { joined.append(id) } }
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: repository, avatars: nil, groupContext: context)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group != nil }
        #expect(group?.readerStanding == .canJoin)
        #expect(group?.subtitle == "10 subscribers")

        driver.join()
        await settle { group?.readerStanding == .subscribed }
        #expect(group?.readerStanding == .subscribed)
        #expect(group?.subtitle == "11 subscribers", "the subscriber count")
        #expect(joined == [harbour], "the inbox wasn't told")
    }

    @Test func requestingOneOnRequestWaitsAndCanBeWithdrawn() async throws {
        let repository = make()
        let viewModel = ConversationViewModel(conversationID: film, repository: repository)
        var context = GroupThreadContext(
            service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
            createdAt: { _ in nil }, knownKind: { _ in nil }
        )
        context.kinds = [.channel]
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: repository, avatars: nil, groupContext: context)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group != nil }
        #expect(group?.readerStanding == .requested)

        driver.cancelJoinRequest()
        await settle { group?.readerStanding == .canRequest }
        #expect(group?.readerStanding == .canRequest, "withdrawn")
        driver.join()
        await settle { group?.readerStanding == .requested }
        #expect(group?.readerStanding == .requested, "on request: Requested until an admin answers")
        #expect(try await repository.details(of: film).subscriberCount == 50_000, "nobody subscribed yet")
    }

    // MARK: - The requests an admin answers

    @Test func anAdminApprovesAndDeclinesOneByOne() async throws {
        let repository = make()
        let run = ChannelsViewModel.RunChannel(id: studio, name: "Studio drops", photoURL: nil)
        let list = ChannelJoinRequestsViewModel(channels: [run], service: repository)
        var changes = 0
        list.onChange = { changes += 1 }
        list.load()
        await settle { list.state.phase == .loaded }
        #expect(list.state.count == 3)
        let rows = try #require(list.state.groups.first?.rows)
        #expect(rows.map(\.requestedAt) == rows.map(\.requestedAt).sorted(by: >), "newest first")

        list.answer(rows[0].id, in: studio, approve: true)
        list.answer(rows[1].id, in: studio, approve: false)
        #expect(list.state.count == 1, "answered rows leave at once")
        await settle { changes == 2 }
        #expect(try await repository.joinRequests(to: studio).map(\.profileID) == [rows[2].id])
        #expect(try await repository.details(of: studio).subscriberCount == 65, "one approved, one subscriber more")
        #expect(try await repository.members(of: studio).contains { $0.profileID == rows[0].id && $0.role == .subscriber })
    }

    @Test func anAdminAnswersThemAll() async throws {
        let repository = make()
        let run = ChannelsViewModel.RunChannel(id: studio, name: "Studio drops", photoURL: nil)
        let list = ChannelJoinRequestsViewModel(channels: [run], service: repository)
        list.load()
        await settle { list.state.phase == .loaded && list.state.count == 3 }
        list.answerAll(approve: false)
        #expect(list.state.isEmpty)
        await settle { !list.state.isWorking }
        #expect(try await repository.joinRequests(to: studio).isEmpty)
        #expect(try await repository.details(of: studio).subscriberCount == 64, "declined: nobody in")
    }

    // MARK: - The info screen

    @Test func whatEachRoleMayDoInAChannel() {
        typealias Info = ChannelInfoViewModel
        let me = ProfileID("me")
        func member(_ id: String, _ role: ConversationRole) -> ConversationMember {
            ConversationMember(profileID: ProfileID(id), role: role, joinedAt: Date())
        }
        #expect(Info.actions(by: .owner, viewer: me, on: member("s", .subscriber)) == [.makeAdmin, .remove, .ban])
        #expect(Info.actions(by: .owner, viewer: me, on: member("a", .admin)) == [.removeAdmin, .transferOwnership, .remove, .ban])
        #expect(Info.actions(by: .admin, viewer: me, on: member("s", .subscriber)) == [.remove, .ban])
        #expect(Info.actions(by: .admin, viewer: me, on: member("a", .admin)).isEmpty)
        #expect(Info.actions(by: .subscriber, viewer: me, on: member("s", .subscriber)).isEmpty)
        #expect(ChannelCopy.leaveBlockedReason(for: .owner) != nil)
        #expect(ChannelCopy.leaveBlockedReason(for: .subscriber) == nil)
    }

    @Test func theOwnerChangesWhoCanJoin() async throws {
        let repository = make()
        let info = ChannelInfoViewModel(conversationID: daily, service: repository)
        info.load()
        await settle { info.state.phase == .loaded }
        #expect(info.state.canEdit && info.state.canManageAdmins)
        #expect(info.state.visibility == .public)
        #expect(info.state.subtitle == "12.4K subscribers")
        #expect(info.state.admins.first?.role == .owner)

        var changed = false
        info.onChange = { changed = true }
        info.setVisibility(.listedOnRequest)
        await settle { info.state.visibility == .listedOnRequest }
        #expect(info.state.visibility == .listedOnRequest)
        #expect(changed)
        #expect(try await repository.details(of: daily).visibility == .listedOnRequest)
        // Someone outside now asks rather than joins.
        let outside = ConversationIdentity(kind: .channel, visibility: .listedOnRequest, viewerState: .none)
        #expect(ConversationThreadDriver.readerStanding(for: outside) == .canRequest)
    }

    @Test func theOwnerIsToldToHandItOverASubscriberLeaves() async throws {
        let repository = make()
        let owned = ChannelInfoViewModel(conversationID: daily, service: repository)
        owned.load()
        await settle { owned.state.phase == .loaded }
        var notice: String?
        owned.onNotice = { title, _ in notice = title }
        owned.leave()
        #expect(notice != nil)

        let followed = ChannelInfoViewModel(conversationID: botanic, service: repository)
        followed.load()
        await settle { followed.state.phase == .loaded }
        #expect(!followed.state.canEdit)
        #expect(followed.state.subscribers.isEmpty, "a subscriber sees no subscribers")
        var left = false
        followed.onLeft = { left = true }
        followed.leave()
        await settle { left }
        #expect(left)
        #expect(try await repository.details(of: botanic).subscriberCount == 819)
        #expect(!(try await repository.loadInbox(.channels, after: nil).conversations).contains { $0.id == botanic })
    }

    @Test func theSubscriberCountReadsCompact() {
        #expect(ChannelCopy.subscriberCount(1) == "1 subscriber")
        #expect(ChannelCopy.subscriberCount(820) == "820 subscribers")
        #expect(ChannelCopy.subscriberCount(12_400) == "12.4K subscribers")
        #expect(ChannelCopy.subscriberCount(0) == "0 subscribers")
    }

    // MARK: - The flag

    private actor Stub: ChatProviding {
        func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
        func loadConversations() async throws -> [Conversation] { [] }
        func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
        func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
            ChatMessage(id: "sent", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
        }
        func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
        func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
    }

    private final class NoScreens: ConversationThreadScreenBuilding {
        func makeConversationThreadViewController(
            driver: any ConversationThreadDriving, mode: ConversationThreadMode, prefill: String
        ) -> UIViewController { UIViewController() }
    }

    private func categories(_ builder: ChatFeatureBuilder) throws -> [MessagesCategory] {
        let inbox = try #require(builder.makeInboxViewController(initialCategory: .all) as? MessagesInboxViewController)
        return inbox.debugCategories
    }

    @Test func withTheFlagOffMessagesHasNoChannelsTab() throws {
        let screens = NoScreens()
        let off = ChatFeatureBuilder(repository: make(channels: false), showsChannels: false, threadScreens: { screens })
        #expect(try categories(off) == [.all, .requests, .suggestions])
        // A repository with no channels shows none, whatever the flag.
        let none = ChatFeatureBuilder(repository: Stub(), showsChannels: true, threadScreens: { screens })
        #expect(try categories(none) == [.all, .requests, .suggestions])
    }

    @Test func withTheFlagOnTheTabFollowsChatsOrRequests() throws {
        let screens = NoScreens()
        let afterChats = ChatFeatureBuilder(repository: make(), showsChannels: true, channelsPlacement: .afterChats,
                                            threadScreens: { screens })
        #expect(try categories(afterChats) == [.all, .channels, .requests, .suggestions])
        let afterRequests = ChatFeatureBuilder(repository: make(), showsChannels: true, channelsPlacement: .afterRequests,
                                               threadScreens: { screens })
        #expect(try categories(afterRequests) == [.all, .requests, .channels, .suggestions])
        #expect(MessagesCategory.channels.title == "Channels")
        #expect(MessagesCategory(rawValue: "channels") == .channels, "`-open-messages channels`")
    }
}
