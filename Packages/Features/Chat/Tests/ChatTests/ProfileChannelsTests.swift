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

/// A profile's channels (#2232), read through Chat for the profile's
/// Channels tab, on the mock's seeds (`-channels`):
///
/// - prof-12 owns one (Harbour notes, public: Join);
/// - prof-16 owns two (Print room, on request: Request; Press marks: Join);
///   prof-17 admins Print room and owns none;
/// - prof-11 owns five the viewer may see (Film stock club, Requested, and
///   four more) and a private sixth they may not;
/// - prof-19 owns Tide tables, which the viewer follows (Open);
/// - the viewer owns Daily light, Studio drops and Sketchbook (private).
@MainActor
struct ProfileChannelsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private final class NoScreens: ConversationThreadScreenBuilding {
        func makeConversationThreadViewController(
            driver: any ConversationThreadDriving, mode: ConversationThreadMode, prefill: String
        ) -> UIViewController { UIViewController() }
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

    private let viewer = ProfileID(MockSocialDataset.viewerProfileID)

    private func ids(_ owned: [OwnedChannel]) -> [String] { owned.map(\.id.rawValue) }

    // MARK: - Which channels

    /// One, two and five: the seeded owners, each with exactly theirs.
    @Test func eachProfileListsTheChannelsItOwns() async throws {
        let repository = make()
        let one = try await repository.ownedChannels(of: ProfileID("prof-12"))
        let two = try await repository.ownedChannels(of: ProfileID("prof-16"))
        let five = try await repository.ownedChannels(of: ProfileID("prof-11"))
        let none = try await repository.ownedChannels(of: ProfileID("prof-3"))
        #expect(ids(one) == ["ch-harbour"])
        #expect(Set(ids(two)) == ["ch-printroom", "ch-pressmarks"])
        #expect(five.count == 5)
        #expect(none.isEmpty, "a profile with none has a channel")
    }

    /// Someone else's private channel never answers (it can't be probed);
    /// the viewer's own does, marked private.
    @Test func privateChannelsAreTheOwnersAlone() async throws {
        let repository = make()
        let film = try await repository.ownedChannels(of: ProfileID("prof-11"))
        #expect(!ids(film).contains("ch-film-friends"), "someone else's private channel was listed")
        #expect(film.allSatisfy { $0.identity.visibility != .private })
        let backroom = try await repository.ownedChannels(of: ProfileID("prof-18"))
        #expect(backroom.isEmpty, "Backroom sessions is private")

        let own = try await repository.ownedChannels(of: viewer)
        #expect(Set(ids(own)) == ["ch-daily", "ch-studio-requests", "ch-sketchbook"])
        let sketchbook = try #require(own.first { $0.id == ConversationID("ch-sketchbook") })
        #expect(ProfileChannels.profileChannel(sketchbook).isPrivate)
        #expect(own.allSatisfy { $0.identity.viewerState == .owner })
    }

    /// Only the channels a profile OWNS: an admin's stays off their profile.
    @Test func anAdminsChannelIsNotTheirs() async throws {
        let repository = make()
        let printroomAdmin = try await repository.ownedChannels(of: ProfileID("prof-17"))
        let dailyAdmin = try await repository.ownedChannels(of: ProfileID("prof-1"))
        #expect(printroomAdmin.isEmpty, "Print room's admin lists it")
        #expect(!ids(dailyAdmin).contains("ch-daily"))
    }

    /// A channel handed over moves to its new owner's profile.
    @Test func aChannelHandedOverMovesProfile() async throws {
        let repository = make()
        let daily = ConversationID("ch-daily")
        let members = try await repository.members(of: daily)
        let admin = try #require(members.first { $0.role == .admin }?.profileID)
        try await repository.transferOwnership(of: daily, to: admin)
        let formerOwners = try await repository.ownedChannels(of: viewer)
        let newOwners = try await repository.ownedChannels(of: admin)
        #expect(!ids(formerOwners).contains("ch-daily"), "it stayed on the old owner's")
        #expect(ids(newOwners).contains("ch-daily"), "it didn't reach the new owner's")
    }

    /// The most subscribed first.
    @Test func theMostSubscribedComeFirst() async throws {
        let film = try await make().ownedChannels(of: ProfileID("prof-11"))
        let counts = film.map(\.identity.subscriberCount)
        #expect(counts == counts.sorted(by: >), "\(counts)")
        #expect(film.first?.id == ConversationID("ch-film"), "the 50K channel isn't first")
    }

    // MARK: - The row's action, per state

    /// Each row reads as a showcase card's channel, with its action:
    /// Join (public), Request (on request), Requested, Open (in).
    @Test func eachRowCarriesTheViewersAction() async throws {
        let repository = make()
        let provider = ProfileChannels(service: repository)
        func action(_ owner: String, _ id: String) async throws -> ChannelEmbed.Action? {
            let rows = try await provider.channels(ownedBy: ProfileID(owner))
            return rows.first { $0.id == ConversationID(id) }?.channel.action
        }
        let join = try await action("prof-12", "ch-harbour")
        let request = try await action("prof-16", "ch-printroom")
        let requested = try await action("prof-11", "ch-film")
        let open = try await action("prof-19", "ch-tides")
        let own = try await action(viewer.rawValue, "ch-daily")
        #expect(join == .join)
        #expect(request == .requestToJoin)
        #expect(requested == .requested)
        #expect(open == .open)
        #expect(own == .open, "the owner is offered Open")
    }

    /// A join through the card's actions shows on the profile's next read:
    /// Join becomes Open and the count follows.
    @Test func aJoinShowsOnTheNextRead() async throws {
        let repository = make()
        let provider = ProfileChannels(service: repository)
        let actions = ChannelEmbedActions(service: repository, router: nil, membershipDidChange: {})
        let harbour = ConversationID("ch-harbour")
        let read = try await provider.channels(ownedBy: ProfileID("prof-12"))
        let before = try #require(read.first)
        let state = try await actions.join(harbour)
        #expect(state == .subscriber)
        let reread = try await provider.channels(ownedBy: ProfileID("prof-12"))
        let after = try #require(reread.first)
        #expect(after.channel.action == .open)
        #expect(after.channel.subscriberCount == before.channel.subscriberCount + 1)
    }

    /// The mapping itself: an on-request channel reads as `.onRequest`, a
    /// private one is marked, an owner and an admin are members.
    @Test func theMappingIsTheCards() {
        let owned = OwnedChannel(
            id: ConversationID("c"),
            identity: ConversationIdentity(
                kind: .channel, name: "C", visibility: .listedOnRequest, subscriberCount: 7, viewerState: .admin
            )
        )
        let row = ProfileChannels.profileChannel(owned)
        #expect(row.channel.visibility == .onRequest)
        #expect(row.channel.viewerState == .member)
        #expect(row.channel.subscriberCount == 7)
        #expect(!row.isPrivate)
        let secret = OwnedChannel(id: ConversationID("s"), identity: ConversationIdentity(kind: .channel, visibility: .private))
        #expect(ProfileChannels.profileChannel(secret).isPrivate)
    }

    // MARK: - The flag off

    /// No channels: the repository reads none, and the builder hands no
    /// provider — no profile has the tab.
    @Test func withTheFlagOffNoProfileHasChannels() async throws {
        let read = try await make(channels: false).ownedChannels(of: ProfileID("prof-12"))
        #expect(read.isEmpty)
        let screens = NoScreens()
        let off = ChatFeatureBuilder(
            repository: make(channels: false), showsGroups: false, showsChannels: false, threadScreens: { screens }
        )
        #expect(off.makeProfileChannels() == nil)
        let on = ChatFeatureBuilder(repository: make(), showsGroups: false, showsChannels: true, threadScreens: { screens })
        #expect(on.makeProfileChannels() != nil)
    }
}
