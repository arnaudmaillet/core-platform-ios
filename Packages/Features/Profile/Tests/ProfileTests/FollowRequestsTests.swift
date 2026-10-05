import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Follow requests for private profiles (#396, backend #655), end to end over
/// the mock BFF: the requester's Follow → Requested → withdraw, and the
/// owner's inbox with Confirm and Delete.
@MainActor
struct FollowRequestsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let repository: ProfileRepository
        let dataset: MockSocialDataset
    }

    private func makeFixture(seedsRequests: Bool = false) -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(
            dataset: dataset,
            isPrivate: { social.isPrivate($0) },
            seedsFollowRequests: seedsRequests
        ).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
        return Fixture(repository: repository, dataset: dataset)
    }

    /// A private author the viewer doesn't follow yet.
    private func privateStranger(in dataset: MockSocialDataset) -> ProfileID {
        let viewerFollows = dataset.followingByProfileID[MockSocialDataset.viewerProfileID] ?? []
        let id = dataset.authors.map(\.profileID).first {
            dataset.isRelationshipsPrivate($0) && !viewerFollows.contains($0)
        }!
        return ProfileID(id)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The requester

    /// Following a private profile asks: the relation reads Requested, no
    /// follower appears, and withdrawing leaves nothing behind.
    @Test func followingAPrivateProfileAsksAndCanBeWithdrawn() async throws {
        let fixture = makeFixture()
        let target = privateStranger(in: fixture.dataset)

        #expect(try await fixture.repository.follow(target) == .requested)
        #expect(try await fixture.repository.relationship(for: target) == .requested)
        #expect(try await fixture.repository.followRelation(to: target) == .requested)
        #expect(!FollowRelation.requested.offersFollow)

        try await fixture.repository.cancelFollowRequest(to: target)
        #expect(try await fixture.repository.relationship(for: target) == .other(isFollowing: false, isMutual: false, isBlocked: false))
        // Withdrawing twice is still done: nothing is pending.
        try await fixture.repository.cancelFollowRequest(to: target)
    }

    /// A public profile is followed straight away.
    @Test func followingAPublicProfileFollows() async throws {
        let fixture = makeFixture()
        let viewerFollows = fixture.dataset.followingByProfileID[MockSocialDataset.viewerProfileID] ?? []
        let target = ProfileID(fixture.dataset.authors.map(\.profileID).first {
            !fixture.dataset.isRelationshipsPrivate($0) && !viewerFollows.contains($0)
        }!)
        #expect(try await fixture.repository.follow(target) == .following)
        #expect(try await fixture.repository.followRelation(to: target) == .following)
    }

    /// The profile's button: Follow → Requested (the follower count doesn't
    /// move), the next visit still reads Requested, and a second tap
    /// withdraws.
    @Test func theProfileButtonGoesFollowRequestedFollow() async throws {
        let fixture = makeFixture()
        let target = privateStranger(in: fixture.dataset)
        let viewModel = ProfileViewModel(repository: fixture.repository, source: .profile(target))
        var buttons: [ProfileViewModel.FollowButton] = []
        viewModel.onFollowButtonChange = { buttons.append($0) }
        viewModel.viewDidLoad()
        await settle { buttons.last == .follow }
        #expect(buttons.last == .follow)

        viewModel.toggleFollow()
        #expect(buttons.last == .requested, "a private profile is asked at once, not followed")
        await settle { false }
        #expect(buttons.last == .requested)
        #expect(try await fixture.repository.relationship(for: target) == .requested)

        viewModel.toggleFollow()
        #expect(buttons.last == .follow)
        await settle { false }
        #expect(try await fixture.repository.relationship(for: target) == .other(isFollowing: false, isMutual: false, isBlocked: false))
    }

    // MARK: - The owner

    /// The inbox lists the requesters newest first, hydrated; Confirm makes a
    /// real follower, Delete drops the request.
    @Test func theOwnerConfirmsOrDeletesRequests() async throws {
        let fixture = makeFixture(seedsRequests: true)
        let viewModel = FollowRequestsViewModel(requests: fixture.repository)
        await viewModel.load()
        guard case .loaded(let requests) = viewModel.phase else {
            Issue.record("the inbox didn't load")
            return
        }
        #expect(requests.count == 3)
        #expect(try await fixture.repository.pendingFollowRequestCount() == 3)
        #expect(requests.allSatisfy { $0.handle != $0.id.rawValue }, "rows carry the requester's handle, not their id")
        let dates = requests.compactMap(\.requestedAt)
        #expect(dates == dates.sorted(by: >), "newest first")

        let confirmed = requests[0]
        try await viewModel.confirm(confirmed)
        #expect(try await fixture.repository.followRelation(to: confirmed.id) == .followedBy, "they now follow the owner")

        let deleted = requests[1]
        try await viewModel.delete(deleted)
        #expect(try await fixture.repository.followRelation(to: deleted.id) == .notFollowing)

        guard case .loaded(let left) = viewModel.phase else { return }
        #expect(left.map(\.id) == [requests[2].id])
        #expect(try await fixture.repository.pendingFollowRequestCount() == 1)
    }

    /// A block drops pending requests both ways.
    @Test func aBlockDropsTheRequest() async throws {
        let fixture = makeFixture(seedsRequests: true)
        let requester = try await fixture.repository.followRequests()[0].id
        try await fixture.repository.setBlocked(true, for: requester)
        #expect(try await fixture.repository.followRequests().map(\.id).contains(requester) == false)
    }

    @Test func theCountReadsPlainly() {
        #expect(PrivacySectionViewController.requestCountText(nil) == nil)
        #expect(PrivacySectionViewController.requestCountText(0) == nil)
        #expect(PrivacySectionViewController.requestCountText(3) == "3")
        #expect(FollowRequestsViewController.footer.contains("aren't told"))
    }
}
