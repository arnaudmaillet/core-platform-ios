import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Server-side list privacy and RemoveFollower (#403, backend #720), end to
/// end over the mock BFF.
@MainActor
struct ListPrivacyTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let profiles: ProfileRepository
        let lists: ProfileRelationshipsRepository
        let dataset: MockSocialDataset
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let profiles = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
        let lists = ProfileRelationshipsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: profiles,
            supportsFollowerRemoval: true
        )
        return Fixture(profiles: profiles, lists: lists, dataset: dataset)
    }

    /// The viewer's lists default to Everyone; a change sticks and touches
    /// only the list it names.
    @Test func theAudienceIsStoredPerList() async throws {
        let fixture = makeFixture()
        #expect(try await fixture.profiles.listPrivacy() == ListPrivacy(followers: .everyone, following: .everyone))

        let saved = try await fixture.profiles.setListPrivacy(followers: .onlyMe, following: nil)
        #expect(saved == ListPrivacy(followers: .onlyMe, following: .everyone))
        #expect(try await fixture.profiles.listPrivacy() == saved)

        _ = try await fixture.profiles.setListPrivacy(followers: nil, following: .mutuals)
        #expect(try await fixture.profiles.listPrivacy() == ListPrivacy(followers: .onlyMe, following: .mutuals))
    }

    /// The owner always reads their own lists, whatever they chose.
    @Test func theOwnerStillSeesTheirHiddenLists() async throws {
        let fixture = makeFixture()
        _ = try await fixture.profiles.setListPrivacy(followers: .onlyMe, following: .onlyMe)
        let viewer = ProfileID(MockSocialDataset.viewerProfileID)
        let page = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 20)
        #expect(!page.relations.isEmpty)
    }

    /// Someone else's hidden list reads as private, not as empty or failed —
    /// and Friends, made from both lists, follows the stricter one.
    @Test func someoneElsesHiddenListIsPrivate() async throws {
        let fixture = makeFixture()
        let viewerFollows = fixture.dataset.followingByProfileID[MockSocialDataset.viewerProfileID] ?? []
        // The mock seeds one public, unfollowed author whose Following is Only Me.
        let hider = ProfileID(fixture.dataset.authors.map(\.profileID).first { id in
            !fixture.dataset.isRelationshipsPrivate(id) && !viewerFollows.contains(id) && id != "prof-4"
        }!)
        await #expect(throws: RelationshipsError.forbidden) {
            _ = try await fixture.lists.relationships(for: hider, direction: .following, pageToken: "", limit: 20)
        }
        await #expect(throws: RelationshipsError.forbidden) {
            _ = try await fixture.lists.relationships(for: hider, direction: .friends, pageToken: "", limit: 20)
        }
        // Their followers stay visible: Everyone.
        _ = try await fixture.lists.relationships(for: hider, direction: .followers, pageToken: "", limit: 20)
    }

    /// ⚠️ THE LIST IS HIDDEN, NOT ITS NUMBER (#718, the owner's call
    /// 2026-10-09): a hidden Following still counts on the profile, read from
    /// the relation status rather than from the list nobody may sample.
    @Test func aHiddenListStillShowsItsCount() async throws {
        let fixture = makeFixture()
        let viewerFollows = fixture.dataset.followingByProfileID[MockSocialDataset.viewerProfileID] ?? []
        let hider = ProfileID(fixture.dataset.authors.map(\.profileID).first { id in
            !fixture.dataset.isRelationshipsPrivate(id) && !viewerFollows.contains(id) && id != "prof-4"
        }!)
        let profile = try await fixture.profiles.profile(id: hider)
        let following = Int64(fixture.dataset.followingByProfileID[hider.rawValue]?.count ?? 0)
        #expect(profile.followingCount == .exact(following), "\(profile.followingCount)")
        #expect(profile.followerCount != .unavailable)
    }

    /// RemoveFollower drops the row for good, and they no longer follow.
    @Test func removingAFollowerUndoesTheirFollow() async throws {
        let fixture = makeFixture()
        let viewer = ProfileID(MockSocialDataset.viewerProfileID)
        let first = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        let follower = try #require(first.relations.first { !$0.isViewer })

        try await fixture.lists.removeFollower(follower.id)
        let after = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        #expect(!after.relations.map(\.id).contains(follower.id))
        let relation = try await fixture.profiles.followRelation(to: follower.id)
        #expect(relation == .following || relation == .notFollowing, "they don't follow the viewer any more")
    }

    @Test func theScreenSaysWhatEachAudienceMeans() {
        #expect(ListAudience.allCases.map(\.title) == ["Everyone", "Followers", "Friends", "Only Me"])
        #expect(ListPrivacyViewController.header(.followers) == "Who Can See Your Followers")
        #expect(ListPrivacyViewController.footer.contains("everyone's app"))
    }
}
