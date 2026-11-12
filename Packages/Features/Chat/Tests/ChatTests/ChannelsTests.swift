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

/// Channels in Messages (#2215), on the mock's channels (`-channels`):
/// their rows in Chats with every other conversation (#2230), who gets a
/// composer, joining (muted, #2230) and the requests an admin answers — now
/// in Requests (#2230) — the subscriber count, visibility, and the flag off.
///
/// The mock's viewer: owner of ch-daily (public, 12 400) and of
/// ch-studio-requests (on request, three pending requests); subscriber of
/// ch-botanic (joined muted) and of ch-tides (notifications on); a pending
/// request on ch-film; not in ch-harbour (public, 10). Owner too of
/// ch-sketchbook (private, #2232): their own profile lists it with a lock.
@MainActor
struct ChannelsTests {
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

    private func make(channels: Bool = true, groups: Bool = false) -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: groups, seedsChannels: true).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            inboxPageSize: 100,
            proposals: ProposedChatClient(client: client),
            showsGroups: groups,
            showsChannels: channels
        )
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loadedCatalog(_ repository: ChatRepository) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository)
        catalog.reload()
        await settle { catalog.snapshot.phase == .loaded }
        return catalog
    }

    private let daily = ConversationID("ch-daily")
    private let botanic = ConversationID("ch-botanic")
    private let tides = ConversationID("ch-tides")
    private let film = ConversationID("ch-film")
    private let harbour = ConversationID("ch-harbour")
    private let studio = ConversationID("ch-studio-requests")
    private let sketchbook = ConversationID("ch-sketchbook")

    // MARK: - Channels in Chats (#2230)

    @Test func channelsSitInChatsSortedWithTheRest() async throws {
        let repository = make()
        let rows = try await repository.loadInbox(.inbox, after: nil).conversations
        let channels = rows.filter { $0.kind == .channel }
        #expect(Set(channels.map(\.id)) == [daily, botanic, tides, studio, sketchbook], "\(channels.map(\.id.rawValue))")
        #expect(rows.contains { $0.kind == .direct }, "the DMs went")
        // One list, newest activity first, channels among the DMs.
        #expect(rows == rows.sorted(by: Conversation.isOrderedBefore), "a channel sorted apart")

        let catalog = await loadedCatalog(repository)
        let active = catalog.snapshot.active
        #expect(Set(active.filter { $0.kind == .channel }.map(\.id)) == [daily, botanic, tides, studio, sketchbook])
        #expect(active == active.sorted(by: Conversation.isOrderedBefore))
        // Pinned, a channel rises like any row.
        catalog.togglePin(botanic)
        #expect(catalog.snapshot.active.first?.id == botanic)
    }

    @Test func withTheFlagOffChatsHasNoChannel() async throws {
        let rows = try await make(channels: false).loadInbox(.inbox, after: nil).conversations
        #expect(!rows.isEmpty)
        #expect(!rows.contains { $0.kind == .channel })
    }

    @Test func everyChannelRowWearsTheMegaphoneAndAPreviewWithoutASender() async throws {
        let rows = try await make(groups: true).loadInbox(.inbox, after: nil).conversations
        let owned = ConversationDisplayModel(conversation: try #require(rows.first { $0.id == daily }))
        #expect(owned.title == "Daily light")
        #expect(owned.groupPhotoURL != nil, "the channel's photo")
        #expect(owned.isChannel && owned.runsChannel && owned.ownsChannel)
        #expect(owned.previewSender == nil, "a channel's post is signed by the channel")
        #expect(owned.previewLine == owned.preview)
        let followed = ConversationDisplayModel(conversation: try #require(rows.first { $0.id == botanic }))
        #expect(followed.isChannel && !followed.runsChannel && !followed.ownsChannel)
        #expect(followed.peerID == nil, "a channel's owner passed for a DM's peer")
        #expect(followed.previewSender == nil)
        // A group keeps "Alice: …"; a DM is unchanged.
        let group = ConversationDisplayModel(conversation: try #require(rows.first { $0.id == ConversationID("grp-hike") }))
        #expect(!group.isChannel && group.previewSender != nil)
        let direct = ConversationDisplayModel(conversation: try #require(rows.first { $0.kind == .direct }))
        #expect(!direct.isChannel && direct.previewSender == nil)

        let row = ConversationRowView()
        row.configure(with: owned)
        #expect(row.debugShowsChannelBadge, "the megaphone on a channel the viewer runs")
        row.configure(with: followed)
        #expect(row.debugShowsChannelBadge, "the megaphone on a channel the viewer follows")
        #expect(row.debugPreviewText == followed.preview, "a sender on a channel's preview")
        row.configure(with: group)
        #expect(!row.debugShowsChannelBadge)
        row.configure(with: direct)
        #expect(!row.debugShowsChannelBadge)
        #expect(ConversationDisplayModel.firstLine(of: "\n  New series  \nstarts Monday") == "New series")
    }

    @Test func searchFindsChannelsWithTheConversations() async throws {
        let repository = make()
        let catalog = await loadedCatalog(repository)
        let search = InboxSearchViewModel(
            catalog: catalog, viewer: repository, debounce: .zero, showsNewGroup: false, showsNewChannel: false
        )
        var phase: InboxSearchViewModel.Phase?
        search.onPhaseChange = { phase = $0 }
        search.queryChanged("Botanical")
        await settle { if case .content = phase { true } else { false } }
        guard case .content(let sections) = phase else { Issue.record("\(String(describing: phase))"); return }
        #expect(sections.first { $0.kind == .messages }?.rows.contains(.conversation(botanic)) == true)
    }

    // MARK: - The noise (#2230)

    @Test func aMutedChannelsPostsStayOnItsRowAndOffTheBadge() async throws {
        let repository = make()
        let catalog = await loadedCatalog(repository)
        #expect(catalog.isMuted(botanic), "a followed channel joined muted")
        #expect(!catalog.isMuted(tides), "notifications turned on")
        let snapshot = catalog.snapshot
        #expect(snapshot.unreadIDs.contains(botanic) && snapshot.unreadIDs.contains(tides))

        let list = ConversationListViewModel(catalog: catalog)
        await settle { if case .content = list.phase { true } else { false } }
        guard case .content(let rows) = list.phase else { Issue.record("\(list.phase)"); return }
        let muted = try #require(rows.first { $0.id == botanic })
        #expect(muted.isUnread && muted.unreadCount > 0, "the row still shows its posts")
        #expect(!muted.countsInBadge)
        let notifying = try #require(rows.first { $0.id == tides })
        #expect(notifying.countsInBadge)
        // The badge: every unread row's messages but the muted channel's.
        let expected = snapshot.active
            .filter { $0.id != botanic && snapshot.unreadIDs.contains($0.id) }
            .reduce(0) { $0 + $1.unreadCount }
        #expect(list.newCount == expected)
        // Its count is grey, new or not (#2292): muted.
        #expect(muted.unreadInk == .neutral)

        // Notifications on: its posts count again.
        catalog.setMute(botanic, muted: false, until: nil)
        #expect(list.newCount == expected + muted.unreadCount)
    }

    @Test func aMutedDMOrGroupStillCounts() {
        let dm = Conversation(id: ConversationID("dm"), title: "Ada", lastMessage: "hi", lastActivityAt: Date(),
                              otherMemberIDs: [ProfileID("ada")], isUnread: true, unreadCount: 2)
        let model = ConversationDisplayModel(conversation: dm, isMuted: true, isUnread: true, unreadCount: 2)
        #expect(model.countsInBadge)
        // Counted, but its row's count is grey (#2292): muted.
        #expect(model.unreadInk == .neutral)
    }

    @Test func joiningFromTheThreadMutesTheChannel() async throws {
        let repository = make()
        let catalog = await loadedCatalog(repository)
        let viewModel = ConversationViewModel(conversationID: harbour, repository: repository)
        var context = GroupThreadContext(
            service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
            createdAt: { _ in nil }, knownKind: { _ in nil }
        )
        context.kinds = [.channel]
        var joined: [ConversationID] = []
        context.onMembershipChange = { id, left in if !left { joined.append(id) } }
        let driver = ConversationThreadDriver(
            viewModel: viewModel, viewer: repository, avatars: nil, pins: catalog, groupContext: context
        )
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding == .canJoin }
        driver.join()
        await settle { !joined.isEmpty }
        #expect(catalog.isMuted(harbour), "a channel joins muted")
        #expect(joined == [harbour])
        catalog.reload()
        await settle { catalog.snapshot.active.contains { $0.id == harbour } }
        #expect(try #require(catalog.snapshot.active.first { $0.id == harbour }).isMuted, "the server's word: muted")
    }

    @Test func aChannelTheViewerCreatesIsNotMuted() async throws {
        let repository = make()
        let created = try await repository.create(ConversationDraft(kind: .channel, name: "Night trains"))
        let rows = try await repository.loadInbox(.inbox, after: nil).conversations
        let row = try #require(rows.first { $0.id == created }, "a new channel missing from Chats")
        #expect(!row.isMuted, "the viewer posts there: no mute")
    }

    @Test func anApprovedRequesterJoinsMuted() async throws {
        // The mock's own rule for #995: an approval subscribes muted too.
        let repository = make()
        let requests = try await repository.joinRequests(to: studio)
        let requester = try #require(requests.first).profileID
        try await repository.answerJoinRequest(from: requester, to: studio, approve: true)
        #expect(try await repository.members(of: studio).contains { $0.profileID == requester && $0.role == .subscriber })
    }

    // MARK: - Leaving from the row (#2230)

    @Test func leavingFromTheRowUnsubscribesAndTheOwnerIsSentToTheTransfer() async throws {
        let repository = make()
        let catalog = await loadedCatalog(repository)
        var written: Bool?
        catalog.leaveChannel(botanic) { written = $0 }
        #expect(!catalog.snapshot.active.contains { $0.id == botanic }, "the row goes at once")
        await settle { written != nil }
        #expect(written == true)
        #expect(try await repository.details(of: botanic).viewerState == .none)

        // The owner can't: the row never lets them through.
        var ownerWritten: Bool?
        catalog.leaveChannel(daily) { ownerWritten = $0 }
        #expect(ownerWritten == false)
        #expect(catalog.snapshot.active.contains { $0.id == daily })
        #expect(try await repository.details(of: daily).viewerState == .owner)
        let owned = ConversationDisplayModel(conversation: try #require(catalog.snapshot.active.first { $0.id == daily }))
        #expect(owned.ownsChannel)
        #expect(ChannelCopy.leaveTitle("Botanical prints") == "Leave Botanical prints?")
    }

    // MARK: - Join requests in Requests (#2230)

    @Test func theDigestListsTheChannelsTheViewerRunsWithRequestsWaiting() async throws {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        let digest = ChannelJoinRequestsDigest(catalog: catalog, service: repository)
        catalog.reload()
        await settle { digest.total == 3 }
        #expect(Set(digest.runChannels.map(\.id)) == [daily, studio, sketchbook])
        #expect(digest.entries.map(\.id) == [studio], "only the channel with requests: ch-daily has none")
        #expect(digest.entries.first?.count == 3)
        #expect(digest.entries.first?.channel.name == "Studio drops")
    }

    @Test func theRowSaysTheChannelAndItsCount() {
        #expect(ChannelCopy.joinRequestsRow(channel: "Night walks", count: 3) == "Night walks · 3 requests")
        #expect(ChannelCopy.joinRequestsRow(channel: "Night walks", count: 1) == "Night walks · 1 request")
        let a = RunChannel(id: daily, name: "Daily light", photoURL: nil)
        let b = RunChannel(id: studio, name: "Studio drops", photoURL: nil)
        let entries = ChannelJoinRequestsDigest.entries([a, b], counts: [daily: 0, studio: 2])
        #expect(entries == [ChannelJoinRequestsDigest.Entry(channel: b, count: 2)], "a channel with none answered leaves")
        let cell = JoinRequestsCell(style: .default, reuseIdentifier: nil)
        cell.configure(with: ChannelJoinRequestsDigest.Entry(channel: b, count: 2))
        #expect(cell.debugTitle == "Studio drops · 2 requests")
    }

    @Test func requestsCountTheJoinRequestsInTheirBadgeAndLeaveOnceAnswered() async throws {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        let digest = ChannelJoinRequestsDigest(catalog: catalog, service: repository)
        let requests = MessageRequestsViewModel(catalog: catalog, joinRequests: digest)
        let plain = MessageRequestsViewModel(catalog: catalog)
        catalog.reload()
        await settle { requests.joinRequests.count == 1 && catalog.snapshot.phase == .loaded }
        #expect(requests.joinRequests.map(\.id) == [studio])
        #expect(requests.newCount == plain.newCount + 3, "one per request waiting, as a message request is one")
        guard case .content = requests.phase else { Issue.record("\(requests.phase)"); return }

        // Answered, all of them: the section empties, the badge falls.
        let list = ChannelJoinRequestsViewModel(channels: [RunChannel(id: studio, name: "Studio drops", photoURL: nil)],
                                                service: repository)
        list.onChange = { requests.refreshJoinRequests() }
        list.load()
        await settle { list.state.count == 3 }
        list.answerAll(approve: true)
        await settle { requests.joinRequests.isEmpty }
        #expect(requests.joinRequests.isEmpty, "a channel whose requests were all answered leaves the section")
        #expect(requests.newCount == plain.newCount)
    }

    /// A screen laid out at a phone's size.
    private func laidOut<Screen: UIViewController>(_ screen: Screen) -> Screen {
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()
        return screen
    }

    /// Requests with the mock's one channel waiting (ch-studio-requests),
    /// loaded.
    private func requestsWithJoinRequests() async -> (MessageRequestsViewModel, InboxCatalog) {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        let digest = ChannelJoinRequestsDigest(catalog: catalog, service: repository)
        let requests = MessageRequestsViewModel(catalog: catalog, joinRequests: digest)
        catalog.reload()
        await settle { requests.joinRequests.count == 1 && catalog.snapshot.phase == .loaded }
        return (requests, catalog)
    }

    /// The Requests snapshot (#2328): the join requests rows come first,
    /// with NO HEADER — no title, no count — then the conversation requests;
    /// the gap under the last channel row stays.
    @Test func theJoinRequestsRowsLeadTheRequestsWithNoHeader() async throws {
        let (requests, _) = await requestsWithJoinRequests()
        guard case .content(let rows) = requests.phase else { Issue.record("\(requests.phase)"); return }

        let list = laidOut(MessageRequestsViewController(viewModel: requests))
        #expect(list.debugSections == (rows.isEmpty ? [.joinRequests] : [.joinRequests, .conversations]))
        #expect(list.debugHeadedSections.isEmpty, "a header over the join requests: \(list.debugHeadedSections)")
        #expect(list.debugRowIDs(in: .joinRequests) == [studio])
        #expect(list.debugRowIDs(in: .conversations) == rows.map(\.id))

        // The very first row is the channel's, at the top of the list.
        let table = list.debugTableView
        let first = try #require(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? JoinRequestsCell)
        #expect(first.debugTitle == "Studio drops · 3 requests")
        #expect(table.rectForRow(at: IndexPath(row: 0, section: 0)).minY < 1, "something sits above the first row")
        if !rows.isEmpty {
            #expect(list.debugGap(underSectionAt: 0) >= 1, "the gap under the channel rows went")
        }
    }

    /// No section is headed on either tab (#2292, #2328): Chats, and
    /// Requests with join requests waiting.
    @Test func noSectionIsHeadedOnEitherTab() async throws {
        let (requests, catalog) = await requestsWithJoinRequests()
        let chatsModel = ConversationListViewModel(catalog: catalog)
        chatsModel.refresh()
        await settle { chatsModel.phase != .loading }

        let chats = laidOut(ConversationListViewController(viewModel: chatsModel))
        let chatsTable = chats.debugTableView
        for index in 0..<chatsTable.numberOfSections {
            let height = chatsTable.delegate?.tableView?(chatsTable, heightForHeaderInSection: index) ?? 0
            #expect(height < 1, "Chats headed section \(index): \(height)")
            #expect(chatsTable.headerView(forSection: index) == nil)
        }

        let list = laidOut(MessageRequestsViewController(viewModel: requests))
        #expect(list.debugSections.first == .joinRequests)
        #expect(list.debugHeadedSections.isEmpty, "Requests headed \(list.debugHeadedSections)")
    }

    /// The bar names no section when the list scrolls (#2328): after the
    /// bell, nothing, on Requests with join requests waiting as on Chats.
    @Test func theBarNamesNoSectionWhenScrolled() async throws {
        let (requests, catalog) = await requestsWithJoinRequests()
        let chats = ConversationListViewController(viewModel: ConversationListViewModel(catalog: catalog))
        let list = MessageRequestsViewController(viewModel: requests)
        let screen = MessagesInboxViewController(surfaces: [chats, list])
        let bell = UIBarButtonItem(customView: UIView())
        screen.setLeadingAccessoryItem(bell)
        _ = laidOut(screen)

        func onlyTheBell(_ moment: String) {
            let leading = screen.navigationItem.leftBarButtonItems ?? []
            #expect(leading.count == 1 && leading.first === bell, "\(moment): \(leading)")
        }

        screen.setCategory(.requests, animated: false)
        list.view.layoutIfNeeded()
        onlyTheBell("Requests at its top")

        // Down past where the Join requests header used to stick.
        let table = list.debugTableView
        table.contentOffset.y = 200
        table.layoutIfNeeded()
        await Task.yield()
        onlyTheBell("Requests scrolled")

        screen.setCategory(.all, animated: false)
        chats.debugTableView.contentOffset.y = 200
        await Task.yield()
        onlyTheBell("Chats scrolled")

        screen.setCategory(.requests, animated: false)
        await Task.yield()
        onlyTheBell("back on Requests")
    }

    @Test func theHiddenRequestsListNeverShowsJoinRequests() async {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        let digest = ChannelJoinRequestsDigest(catalog: catalog, service: repository)
        let hidden = MessageRequestsViewModel(catalog: catalog, folder: .hiddenRequests, joinRequests: digest)
        catalog.reload()
        await settle { digest.total == 3 }
        #expect(hidden.joinRequests.isEmpty)
        #expect(hidden.newCount == 0)
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
        #expect(try await repository.loadInbox(.inbox, after: nil).conversations.contains { $0.id == created })
    }

    /// From the "+": Messages, on Chats, then the thread pushed over it —
    /// the app's cross-tab routes. From the inbox search: the thread alone.
    @Test func createLandsInMessagesOnChatsFromThePlusMenu() {
        let id = ConversationID("ch-new-1")
        #expect(ChatFeatureBuilder.landingRoutes(for: id, landing: .inMessages) == [.messages(.all), .conversation(id)])
        #expect(ChatFeatureBuilder.landingRoutes(for: id, landing: .onTheStack) == [.conversation(id)])
        #expect(ChannelCopy.whatItIs.contains("channel"), "the sheet says what a channel is")
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

    /// #2236: Leave is the thread's ⋯ menu's now — left, the thread stays,
    /// and the bar comes back with the way in: Join for a public channel,
    /// Request to Join for one on request. The inbox drops the row.
    @Test func leavingFromTheThreadKeepsItWithTheWayBackIn() async throws {
        let repository = make()
        func leave(_ id: ConversationID) async -> (ConversationThreadGroup?, [ConversationID]) {
            let viewModel = ConversationViewModel(conversationID: id, repository: repository)
            var context = GroupThreadContext(
                service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
                createdAt: { _ in nil }, knownKind: { _ in nil }
            )
            context.kinds = [.channel]
            var left: [ConversationID] = []
            context.onMembershipChange = { changed, didLeave in if didLeave { left.append(changed) } }
            let driver = ConversationThreadDriver(viewModel: viewModel, viewer: repository, avatars: nil, groupContext: context)
            var group: ConversationThreadGroup?
            driver.onGroupChange = { group = $0 }
            driver.viewDidLoad()
            await settle { group?.readerStanding == .subscribed }
            driver.leave(from: UIViewController())
            await settle { group?.readerStanding != .subscribed }
            return (group, left)
        }
        let (publicChannel, leftPublic) = await leave(tides)
        #expect(publicChannel?.readerStanding == .canJoin, "a public channel offers Join again")
        #expect(leftPublic == [tides], "the inbox wasn't told")
        let (onRequest, leftOnRequest) = await leave(botanic)
        #expect(onRequest?.readerStanding == .canRequest, "one on request offers Request to Join")
        #expect(leftOnRequest == [botanic])
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
        let run = RunChannel(id: studio, name: "Studio drops", photoURL: nil)
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
        let run = RunChannel(id: studio, name: "Studio drops", photoURL: nil)
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
        #expect(!ChannelInfoViewModel.listTabs(for: followed.state).contains { $0.id == "subscribers" }, "a subscriber sees no subscribers")
        #expect(try await followed.page(of: .subscribers, after: nil).rows.isEmpty)
        var left = false
        followed.onLeft = { left = true }
        followed.leave()
        await settle { left }
        #expect(left)
        #expect(try await repository.details(of: botanic).subscriberCount == 819)
        #expect(!(try await repository.loadInbox(.inbox, after: nil).conversations).contains { $0.id == botanic })
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

    /// Messages has three pages whatever the flags (#2230): the channels
    /// are in Chats. A "channels" token — a debug hook, a stored tab — no
    /// longer parses, and the callers' fallback is Chats.
    @Test func messagesHasThreePagesAndNoChannelsCategory() throws {
        let screens = NoScreens()
        let off = ChatFeatureBuilder(
            repository: make(channels: false), showsGroups: false, showsChannels: false, threadScreens: { screens }
        )
        #expect(try categories(off) == [.all, .requests, .suggestions])
        let on = ChatFeatureBuilder(repository: make(), showsGroups: true, showsChannels: true, threadScreens: { screens })
        #expect(try categories(on) == [.all, .requests, .suggestions])
        #expect(MessagesCategory.allCases == [.all, .requests, .suggestions])
        #expect(MessagesCategory(rawValue: "channels") == nil, "`-open-messages channels`")
        #expect((MessagesCategory(rawValue: "channels") ?? .all) == .all, "a route to it lands on Chats")
        #expect(MessagesCategory.all.title == "Chats")
    }

    /// The "+" menu's "New Channel" exists only with the channels: the
    /// builder makes the sheet, or nothing (the menu then has no entry).
    @Test func theCreationSheetExistsOnlyWithTheChannels() throws {
        let screens = NoScreens()
        let on = ChatFeatureBuilder(repository: make(), showsChannels: true, threadScreens: { screens })
        let sheet = try #require(on.makeChannelCreationViewController() as? UINavigationController)
        #expect(sheet.viewControllers.first is ChannelCreationViewController)
        let off = ChatFeatureBuilder(repository: make(channels: false), showsChannels: false, threadScreens: { screens })
        #expect(off.makeChannelCreationViewController() == nil)
        // A repository with no channels makes none, whatever the flag.
        let none = ChatFeatureBuilder(repository: Stub(), showsChannels: true, threadScreens: { screens })
        #expect(none.makeChannelCreationViewController() == nil)
    }

    /// The empty search's create rows, for each pair of flags (#2230): one
    /// "Create" section, no section with neither.
    @Test func theSearchOffersItsCreateRowsForEachPairOfFlags() async {
        typealias Search = InboxSearchViewModel
        #expect(Search.createRows(showsNewGroup: true, showsNewChannel: true) == [.newGroup, .newChannel])
        #expect(Search.createRows(showsNewGroup: true, showsNewChannel: false) == [.newGroup])
        #expect(Search.createRows(showsNewGroup: false, showsNewChannel: true) == [.newChannel])
        #expect(Search.createRows(showsNewGroup: false, showsNewChannel: false).isEmpty)

        let repository = make()
        let catalog = await loadedCatalog(repository)
        for (groups, channels) in [(true, true), (true, false), (false, true), (false, false)] {
            let search = Search(catalog: catalog, viewer: repository, showsNewGroup: groups, showsNewChannel: channels)
            var phase: Search.Phase?
            search.onPhaseChange = { phase = $0 }
            search.queryChanged("")
            guard case .content(let sections) = phase else { Issue.record("\(String(describing: phase))"); continue }
            let create = sections.first { $0.kind == .create }
            if groups || channels {
                #expect(sections.first?.kind == .create, "the create rows lead the empty field")
                #expect(create?.title == "Create")
                #expect(create?.rows == Search.createRows(showsNewGroup: groups, showsNewChannel: channels))
            } else {
                #expect(create == nil, "no section with neither flag")
            }
        }
        var picked = false
        let search = Search(catalog: catalog, viewer: repository, showsNewGroup: false, showsNewChannel: true)
        search.onNewChannel = { picked = true }
        search.didSelect(.newChannel)
        #expect(picked)
    }
}
