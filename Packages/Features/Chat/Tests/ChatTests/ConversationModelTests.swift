import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Chat

/// Groups and channels as the app models them (#2213): kind, identity,
/// roles, visibility, the viewer's state — and every write, on the mock's
/// shape of core-platform-backend#995.
struct ConversationModelTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func make(groups: Bool = true, channels: Bool = true, seeds: Bool = true) -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: seeds, seedsChannels: seeds).register(on: bff)
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

    // MARK: - The model

    @Test func eachKindOfEntryBecomesItsModel() async throws {
        let repository = make()
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        let hike = try #require(inbox.first { $0.id == ConversationID("grp-hike") })
        #expect(hike.kind == .group)
        #expect(hike.title == "Weekend hike")
        #expect(hike.identity?.photoURL != nil)
        #expect(hike.identity?.viewerState == .owner)
        #expect(hike.identity?.memberCount == 5)
        #expect(hike.directPeerID == nil, "a group passed for a DM")
        #expect(inbox.contains { $0.kind == .direct }, "the DMs went")

        // Channels sit in Chats with the rest (#2230).
        let channels = inbox.filter { $0.kind == .channel }
        #expect(!channels.isEmpty, "no channel in Chats")
        let daily = try #require(channels.first { $0.id == ConversationID("ch-daily") })
        #expect(daily.title == "Daily light")
        #expect(daily.identity?.subscriberCount == 12_400)
        #expect(daily.identity?.visibility == .public)
    }

    /// A group with no name or photo is named and faced by its members, in
    /// one place.
    @Test func aNamelessGroupIsNamedByItsMembers() async throws {
        let repository = make()
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        let studio = try #require(inbox.first { $0.id == ConversationID("grp-studio") })
        #expect(studio.identity?.name.isEmpty == true)
        #expect(studio.title.contains(" and "), "\(studio.title)")
        #expect(!studio.memberFaces.isEmpty && studio.memberFaces.count <= ConversationIdentity.stackedFaces)

        #expect(ConversationIdentity.memberName(["Alice"]) == "Alice")
        #expect(ConversationIdentity.memberName(["Alice", "Bob"]) == "Alice and Bob")
        #expect(ConversationIdentity.memberName(["Alice", "Bob", "Carla"]) == "Alice, Bob and Carla")
        #expect(ConversationIdentity.memberName(["Alice", "Bob", "Carla"], total: 5) == "Alice, Bob and 3 others")
        #expect(ConversationIdentity.memberName(["Alice", "Bob"], total: 3) == "Alice, Bob and 1 other")
    }

    @Test func theViewersStateInEachCase() async throws {
        let repository = make()
        #expect(try await repository.details(of: ConversationID("grp-hike")).viewerState == .owner)
        #expect(try await repository.details(of: ConversationID("grp-printfair")).viewerState == .member)
        #expect(try await repository.details(of: ConversationID("grp-nightwalk")).viewerState == .invited)
        #expect(try await repository.details(of: ConversationID("ch-botanic")).viewerState == .subscriber)
        #expect(try await repository.details(of: ConversationID("ch-film")).viewerState == .requested)
        #expect(try await repository.details(of: ConversationID("ch-harbour")).viewerState == .none)
        #expect(try await repository.details(of: ConversationID("ch-daily")).viewerState == .owner)
        let members = try await repository.members(of: ConversationID("grp-hike"))
        #expect(members.contains { $0.role == .owner } && members.contains { $0.role == .admin })
    }

    // MARK: - Writes

    @Test func creatingAGroupAndAChannel() async throws {
        let repository = make()
        let group = try await repository.create(
            ConversationDraft(kind: .group, name: "Darkroom", memberIDs: [ProfileID("prof-1"), ProfileID("prof-2")])
        )
        let groupDetails = try await repository.details(of: group)
        #expect(groupDetails.name == "Darkroom" && groupDetails.viewerState == .owner && groupDetails.memberCount == 3)
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        #expect(inbox.contains { $0.id == group })

        let channel = try await repository.create(
            ConversationDraft(kind: .channel, name: "Contact sheets", description: "Weekly", visibility: .listedOnRequest)
        )
        let channelDetails = try await repository.details(of: channel)
        #expect(channelDetails.visibility == .listedOnRequest && channelDetails.viewerState == .owner)
        let chats = try await repository.loadInbox(.inbox, after: nil).conversations
        #expect(chats.contains { $0.id == channel }, "a new channel is in Chats (#2230)")
    }

    @Test func aGroupHoldsFiveHundredAtMost() async throws {
        let repository = make()
        let tooMany = (0..<ConversationDraft.groupCap).map { ProfileID("prof-x\($0)") }
        await #expect(throws: ChatError.self) {
            _ = try await repository.create(ConversationDraft(kind: .group, memberIDs: tooMany))
        }
    }

    @Test func identityIsTheOwnersAndAdminsToEdit() async throws {
        let repository = make()
        try await repository.editIdentity(of: ConversationID("grp-hike"), name: "Sunday hike", photoURL: nil, description: "")
        #expect(try await repository.details(of: ConversationID("grp-hike")).name == "Sunday hike")
        await #expect(throws: ChatError.self) {
            try await repository.editIdentity(of: ConversationID("grp-printfair"), name: "Mine now", photoURL: nil, description: "")
        }
    }

    @Test func anInvitationIsAnswered() async throws {
        let repository = make()
        try await repository.answerInvitation(to: ConversationID("grp-nightwalk"), accept: true)
        #expect(try await repository.details(of: ConversationID("grp-nightwalk")).viewerState == .member)
        try await repository.invite([ProfileID("prof-20")], to: ConversationID("grp-hike"))
    }

    /// Public joins at once; on request waits, and can be cancelled.
    @Test func joiningAPublicChannelAndRequestingOne() async throws {
        let repository = make()
        #expect(try await repository.requestToJoin(ConversationID("ch-harbour")) == .subscriber)
        #expect(try await repository.details(of: ConversationID("ch-harbour")).subscriberCount == 11)
        try await repository.cancelJoinRequest(ConversationID("ch-film"))
        #expect(try await repository.details(of: ConversationID("ch-film")).viewerState == .none)
        #expect(try await repository.requestToJoin(ConversationID("ch-film")) == .requested)
    }

    @Test func anAdminAnswersJoinRequests() async throws {
        let repository = make()
        let channel = ConversationID("ch-studio-requests")
        let pending = try await repository.joinRequests(to: channel)
        #expect(pending.count == 3)
        try await repository.answerJoinRequest(from: pending[0].profileID, to: channel, approve: true)
        try await repository.answerJoinRequest(from: pending[1].profileID, to: channel, approve: false)
        #expect(try await repository.joinRequests(to: channel).count == 1)
        #expect(try await repository.details(of: channel).subscriberCount == 65)
        await #expect(throws: ChatError.self) { _ = try await repository.joinRequests(to: ConversationID("ch-botanic")) }
    }

    @Test func membersAreManagedByTheirOwner() async throws {
        let repository = make()
        let group = ConversationID("grp-hike")
        let members = try await repository.members(of: group)
        let plain = try #require(members.first { $0.role == .member })
        try await repository.setRole(.admin, of: plain.profileID, in: group)
        #expect(try await repository.members(of: group).first { $0.profileID == plain.profileID }?.role == .admin)
        let other = try #require(members.first { $0.role == .member && $0.profileID != plain.profileID })
        try await repository.remove(other.profileID, from: group, ban: true)
        #expect(!(try await repository.members(of: group)).contains { $0.profileID == other.profileID })
        // The owner leaves only after a transfer.
        await #expect(throws: ChatError.self) { try await repository.leave(group) }
        try await repository.transferOwnership(of: group, to: plain.profileID)
        try await repository.leave(group)
        #expect(!(try await repository.loadInbox(.inbox, after: nil).conversations).contains { $0.id == group })
    }

    @Test func visibilityAndSubscriptions() async throws {
        let repository = make()
        try await repository.setVisibility(.public, of: ConversationID("grp-hike"))
        #expect(try await repository.details(of: ConversationID("grp-hike")).visibility == .public)
        try await repository.subscribe(to: ConversationID("ch-harbour"))
        #expect(try await repository.details(of: ConversationID("ch-harbour")).viewerState == .subscriber)
        try await repository.unsubscribe(from: ConversationID("ch-harbour"))
        #expect(try await repository.details(of: ConversationID("ch-harbour")).viewerState == .none)
    }

    // MARK: - The flags

    /// Without `-group-chats` and `-channels` the inbox is DMs only, even
    /// where the server lists more.
    @Test func withTheFlagsOffMessagesIsDMsOnly() async throws {
        let repository = make(groups: false, channels: false)
        let inbox = try await repository.loadInbox(.inbox, after: nil).conversations
        #expect(!inbox.isEmpty && inbox.allSatisfy { $0.kind == .direct })
        // And a mock not asked to seed them lists none.
        let unseeded = make(seeds: false)
        #expect(try await unseeded.loadInbox(.inbox, after: nil).conversations.allSatisfy { $0.kind == .direct })
    }
}
