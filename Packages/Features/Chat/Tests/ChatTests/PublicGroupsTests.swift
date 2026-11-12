import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import TestSupport
import Testing
import UIKit
@testable import Chat

/// Public groups (#2217), on the mock's groups (`-group-chats`): the
/// Public / Private switch, an outsider's Join / Follow, a follower's view,
/// the 500-member cap, and a group turned private closing to its followers.
///
/// The mock's viewer: owner of grp-hike (private, 5 members); not in
/// grp-coastal (public, 40 members, 2 300 followers) nor grp-darkroom
/// (public, full at 500); follower of grp-riverside (public, muted in the
/// inbox).
@MainActor
struct PublicGroupsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// The repository, and the mock's wire as any account — the one way to
    /// act as the group's owner or another reader.
    private struct Rig {
        let repository: ChatRepository
        let proposals: ProposedChatClient
        let chat: Chat_V1_ChatServiceClient
    }

    private func make() -> Rig {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: true, seedsChannels: false).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let chat = Chat_V1_ChatServiceClient(client: client)
        let proposals = ProposedChatClient(client: client)
        let repository = ChatRepository(
            chatClient: chat,
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            inboxPageSize: 100,
            proposals: proposals,
            showsGroups: true,
            showsChannels: false
        )
        return Rig(repository: repository, proposals: proposals, chat: chat)
    }

    private let hike = ConversationID("grp-hike")
    private let printfair = ConversationID("grp-printfair")
    private let coastal = ConversationID("grp-coastal")
    private let darkroom = ConversationID("grp-darkroom")
    private let riverside = ConversationID("grp-riverside")

    /// A thread's driver on `id`, reading the group as the screen does.
    private func makeDriver(
        _ rig: Rig, on id: ConversationID, catalog: InboxCatalog? = nil,
        onMembershipChange: @escaping @MainActor (ConversationID, Bool) -> Void = { _, _ in }
    ) -> ConversationThreadDriver {
        let viewModel = ConversationViewModel(conversationID: id, repository: rig.repository)
        var context = GroupThreadContext(
            service: rig.repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
            createdAt: { _ in nil }, knownKind: { _ in nil }
        )
        context.onMembershipChange = onMembershipChange
        return ConversationThreadDriver(
            viewModel: viewModel, viewer: rig.repository, avatars: nil, pins: catalog, groupContext: context
        )
    }

    private func ownerID(of id: ConversationID, _ rig: Rig) async throws -> String {
        let members = try await rig.repository.members(of: id)
        return try #require(members.first { $0.role == .owner }).profileID.rawValue
    }

    // MARK: - The visibility switch

    @Test func theOwnerMakesTheGroupPublicAndItsHeaderCountsFollowers() async throws {
        let rig = make()
        let info = GroupInfoViewModel(conversationID: hike, service: rig.repository)
        var changed = false
        info.onChange = { changed = true }
        info.load()
        await settle { info.state.phase == .loaded }
        #expect(info.state.visibility == .private)
        #expect(info.state.canChangeVisibility)
        #expect(info.state.subtitle == "5 members", "a private group counts no audience")

        info.setVisibility(.public)
        await settle { info.state.visibility == .public }
        #expect(info.state.visibility == .public)
        #expect(changed, "the thread behind wasn't told")
        #expect(info.state.subtitle == "5 members · 0 followers")
        #expect(try await rig.repository.details(of: hike).visibility == .public)

        info.setVisibility(.private)
        await settle { info.state.visibility == .private }
        #expect(try await rig.repository.details(of: hike).visibility == .private)
    }

    @Test func aMemberCantSwitchIt() async throws {
        let rig = make()
        let info = GroupInfoViewModel(conversationID: printfair, service: rig.repository)
        info.load()
        await settle { info.state.phase == .loaded }
        #expect(!info.state.canChangeVisibility)
        info.setVisibility(.public)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await rig.repository.details(of: printfair).visibility == .private)
        await #expect(throws: ChatError.self) { try await rig.repository.setVisibility(.public, of: printfair) }
    }

    @Test func goingPublicWarnsThatWhatIsSaidFromNowOnIsReadable() {
        let toPublic = GroupCopy.visibilityConfirmation(.public)
        #expect(toPublic.message.contains("from now on"))
        #expect(toPublic.message.contains("Earlier messages stay among members"))
        #expect(GroupCopy.visibilityConfirmation(.private).message.contains("followers"))
        #expect(GroupCopy.choosableVisibilities == [.private, .public])
        #expect(GroupCopy.visibilityTitle(.public) == "Public")
        #expect(GroupCopy.visibilityTitle(.private) == "Private")
    }

    /// Readable from the moment it went public, not before (chat.v1's
    /// public-since watermark).
    @Test func anOutsiderReadsAGroupMadePublicFromThatMomentOnly() async throws {
        let rig = make()
        try await rig.repository.setVisibility(.public, of: hike)
        var request = Chat_V1_GetHistoryRequest()
        request.conversationID = hike.rawValue
        request.requesterID = "prof-outsider"
        let outsider = await rig.chat.getHistory(request: request, headers: [:])
        #expect(outsider.message?.messages.isEmpty == true, "the history before it went public leaked")
        #expect(!(try await rig.repository.loadMessages(in: hike)).isEmpty, "a member reads everything")
    }

    // MARK: - The header

    @Test func aPublicGroupsHeaderCountsMembersAndFollowersApart() {
        #expect(GroupCopy.header(memberCount: 40, followerCount: 2_300, visibility: .public) == "40 members · 2.3K followers")
        #expect(GroupCopy.header(memberCount: 1, followerCount: 1, visibility: .public) == "1 member · 1 follower")
        #expect(GroupCopy.header(memberCount: 40, followerCount: 2_300, visibility: .private) == "40 members")

        // Followers are never members: not listed, not counted.
        let me = ProfileID("me")
        let members = [
            ConversationMember(profileID: ProfileID("o"), role: .owner, joinedAt: Date()),
            ConversationMember(profileID: ProfileID("f"), role: .subscriber, joinedAt: Date()),
        ]
        let group = ConversationThreadDriver.group(
            identity: ConversationIdentity(name: "Coast", visibility: .public, memberCount: 1, subscriberCount: 1),
            members: members, profiles: [:], viewer: me
        )
        #expect(group.members[ProfileID("f")] == nil, "a follower listed as a member")
        #expect(group.subtitle == "1 member · 1 follower")
    }

    // MARK: - Where the viewer stands

    @Test func eachStandingInAGroupGetsItsBar() {
        typealias Driver = ConversationThreadDriver
        func identity(_ state: ConversationViewerState, _ visibility: ConversationVisibility = .public, members: Int = 40) -> ConversationIdentity {
            ConversationIdentity(kind: .group, visibility: visibility, memberCount: members, viewerState: state)
        }
        #expect(Driver.groupReaderStanding(for: identity(.member)) == nil, "a member writes")
        #expect(Driver.groupReaderStanding(for: identity(.owner)) == nil)
        #expect(Driver.groupReaderStanding(for: identity(.none)) == .canJoinOrFollow(isFull: false))
        #expect(Driver.groupReaderStanding(for: identity(.none, members: 500)) == .canJoinOrFollow(isFull: true))
        #expect(Driver.groupReaderStanding(for: identity(.subscriber)) == .following(isFull: false))
        #expect(Driver.groupReaderStanding(for: identity(.subscriber, members: 500)) == .following(isFull: true))
        #expect(Driver.groupReaderStanding(for: identity(.none, .private)) == .closed)
        #expect(Driver.groupReaderStanding(for: identity(.banned)) == .unavailable)
        #expect(ConversationIdentity(kind: .group, memberCount: ConversationDraft.groupCap).isFull)
        #expect(!ConversationIdentity(kind: .group, memberCount: ConversationDraft.groupCap - 1).isFull)
        #expect(!ConversationIdentity(kind: .channel, memberCount: 9_999).isFull, "a channel has no cap")
    }

    @Test func anOutsiderReadsAPublicGroupWithJoinAndFollow() async throws {
        let rig = make()
        let driver = makeDriver(rig, on: coastal)
        var group: ConversationThreadGroup?
        var messages: [ConversationThreadMessage] = []
        driver.onGroupChange = { group = $0 }
        driver.onPhaseChange = { if case .content(let shown) = $0 { messages = shown } }
        driver.viewDidLoad()
        await settle { group?.readerStanding != nil && !messages.isEmpty }

        let shown = try #require(group)
        #expect(shown.name == "Coastal cleanup")
        #expect(shown.subtitle == "40 members · 2.3K followers")
        #expect(shown.readerStanding == .canJoinOrFollow(isFull: false))
        #expect(!shown.canPost, "an outsider got the composer")
        #expect(!messages.isEmpty, "an outsider reads the stream")
        #expect(!shown.members.isEmpty)
    }

    @Test func followingPutsTheGroupInTheInboxMuted() async throws {
        let rig = make()
        let catalog = InboxCatalog(repository: rig.repository)
        var memberships: [(ConversationID, Bool)] = []
        let driver = makeDriver(rig, on: coastal, catalog: catalog) { memberships.append(($0, $1)) }
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding == .canJoinOrFollow(isFull: false) }

        driver.follow()
        await settle { group?.readerStanding == .following(isFull: false) && !memberships.isEmpty }
        #expect(group?.readerStanding == .following(isFull: false))
        #expect(group?.subtitle == "40 members · 2.3K followers", "a follower is not a member")
        #expect(memberships.first.map { $0.0 == coastal && !$0.1 } == true, "the inbox wasn't told")
        #expect(catalog.isMuted(coastal))
        let row = try #require(try await rig.repository.loadInbox(.inbox, after: nil).conversations.first { $0.id == coastal })
        #expect(row.isMuted, "followed, the group joins the inbox muted")
        #expect(try await rig.repository.details(of: coastal).subscriberCount == 2_301)
    }

    @Test func joiningMakesAMemberWhoWrites() async throws {
        let rig = make()
        let driver = makeDriver(rig, on: coastal)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding != nil }

        driver.join()
        await settle { group?.readerStanding == nil && group != nil }
        #expect(group?.canPost == true, "a member got no composer")
        #expect(group?.subtitle == "41 members · 2.3K followers")
        #expect(try await rig.repository.details(of: coastal).viewerState == .member)
    }

    @Test func aFollowerReadsWithJoinAndFollowingAndFindsItMutedInTheInbox() async throws {
        let rig = make()
        let row = try #require(try await rig.repository.loadInbox(.inbox, after: nil).conversations.first { $0.id == riverside })
        #expect(row.isMuted)
        let driver = makeDriver(rig, on: riverside)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding != nil }
        #expect(group?.readerStanding == .following(isFull: false))

        // A follower who joins becomes a member, and leaves the audience.
        let followers = try await rig.repository.details(of: riverside).subscriberCount
        _ = try await rig.repository.requestToJoin(riverside)
        let joined = try await rig.repository.details(of: riverside)
        #expect(joined.viewerState == .member)
        #expect(joined.subscriberCount == followers - 1)
    }

    @Test func aFollowerUnfollows() async throws {
        let rig = make()
        var memberships: [(ConversationID, Bool)] = []
        let driver = makeDriver(rig, on: riverside) { memberships.append(($0, $1)) }
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding == .following(isFull: false) }
        driver.unfollow()
        await settle { group?.readerStanding == .canJoinOrFollow(isFull: false) }
        #expect(group?.readerStanding == .canJoinOrFollow(isFull: false), "unfollowed, they read it as anyone")
        #expect(memberships.contains { $0.0 == riverside && $0.1 })
        #expect(!(try await rig.repository.loadInbox(.inbox, after: nil).conversations).contains { $0.id == riverside })
    }

    // MARK: - The cap

    @Test func aFullGroupOffersFollowOnly() async throws {
        let rig = make()
        let details = try await rig.repository.details(of: darkroom)
        #expect(details.memberCount == ConversationDraft.groupCap)
        #expect(details.isFull)
        let driver = makeDriver(rig, on: darkroom)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group?.readerStanding != nil }
        #expect(group?.readerStanding == .canJoinOrFollow(isFull: true))

        // The server refuses a join past the cap; following still works.
        await #expect(throws: ChatError.self) { _ = try await rig.repository.requestToJoin(darkroom) }
        try await rig.repository.subscribe(to: darkroom)
        #expect(try await rig.repository.details(of: darkroom).viewerState == .subscriber)
    }

    @Test func aRefusedJoinOnAFullGroupSaysSoAndShowsFollowOnly() async throws {
        let rig = make()
        let driver = makeDriver(rig, on: darkroom)
        var group: ConversationThreadGroup?
        var notice: String?
        driver.onGroupChange = { group = $0 }
        driver.onActionNotice = { _, message in notice = message }
        driver.viewDidLoad()
        await settle { group?.readerStanding != nil }
        driver.join()
        await settle { notice != nil }
        #expect(notice == "This group is full.")
        #expect(group?.readerStanding == .canJoinOrFollow(isFull: true))
    }

    // MARK: - Turning private

    @Test func turningPrivateClosesItForFollowersAtOnce() async throws {
        let rig = make()
        let owner = try await ownerID(of: riverside, rig)
        _ = try await rig.proposals.call(.setVisibility(viewer: owner, conversationID: riverside.rawValue, visibility: .private))

        // Answered as a missing conversation, everywhere.
        await #expect(throws: ChatError.self) { _ = try await rig.repository.details(of: riverside) }
        await #expect(throws: ChatError.self) { _ = try await rig.repository.loadMessages(in: riverside) }
        let inbox = try await rig.repository.loadInbox(.inbox, after: nil).conversations
        #expect(!inbox.contains { $0.id == riverside }, "a former follower still has it in the inbox")
        // Its members still read it.
        var request = Chat_V1_GetHistoryRequest()
        request.conversationID = riverside.rawValue
        request.requesterID = owner
        #expect((await rig.chat.getHistory(request: request, headers: [:])).message?.messages.isEmpty == false)
    }

    @Test func aFollowerWithTheThreadOpenSeesItIsPrivateNow() async throws {
        let rig = make()
        var memberships: [(ConversationID, Bool)] = []
        let driver = makeDriver(rig, on: riverside) { memberships.append(($0, $1)) }
        driver.audienceWatchInterval = .milliseconds(20)
        var group: ConversationThreadGroup?
        var messages: [ConversationThreadMessage] = []
        driver.onGroupChange = { group = $0 }
        driver.onPhaseChange = { if case .content(let shown) = $0 { messages = shown } }
        driver.viewDidLoad()
        await settle { group?.readerStanding == .following(isFull: false) && !messages.isEmpty }
        let read = messages.filter { !$0.isSystem }.count

        let owner = try await ownerID(of: riverside, rig)
        _ = try await rig.proposals.call(.setVisibility(viewer: owner, conversationID: riverside.rawValue, visibility: .private))
        await settle { group?.readerStanding == .closed }

        #expect(group?.readerStanding == .closed)
        #expect(group?.canPost == false, "a former follower got the composer")
        #expect(messages.last?.isSystem == true)
        #expect(messages.last?.body == "This group is private now")
        #expect(messages.filter { !$0.isSystem }.count == read, "what it showed went")
        #expect(memberships.contains { $0.0 == riverside && $0.1 }, "the inbox kept it")
    }

    @Test func aMembersThreadDoesntWatchOrClose() async throws {
        let rig = make()
        try await rig.repository.setVisibility(.public, of: hike)
        let driver = makeDriver(rig, on: hike)
        driver.audienceWatchInterval = .milliseconds(20)
        var group: ConversationThreadGroup?
        driver.onGroupChange = { group = $0 }
        driver.viewDidLoad()
        await settle { group != nil && group?.subtitle.contains("followers") == true }
        try await rig.repository.setVisibility(.private, of: hike)
        try await Task.sleep(for: .milliseconds(100))
        #expect(group?.readerStanding == nil, "a member's thread closed")
        #expect(driver.closedAt == nil)
    }
}
