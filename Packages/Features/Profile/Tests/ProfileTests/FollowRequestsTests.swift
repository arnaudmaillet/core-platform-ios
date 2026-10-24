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

    private func makeFixture(seedsRequests: Bool = false, followEvents: FollowGraphEvents? = nil) -> Fixture {
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
            authSession: Session(),
            followEvents: followEvents
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

    /// A private author who follows the viewer, unfollowed back.
    private func privateFollower(in dataset: MockSocialDataset) -> ProfileID {
        let viewer = MockSocialDataset.viewerProfileID
        let viewerFollows = dataset.followingByProfileID[viewer] ?? []
        let id = dataset.authors.map(\.profileID).first {
            dataset.isRelationshipsPrivate($0) && !viewerFollows.contains($0)
                && dataset.followingByProfileID[$0]?.contains(viewer) == true
        }!
        return ProfileID(id)
    }

    /// Waits on STATE, not time: polls until `condition` holds and returns at
    /// once when it does, giving up after 2,000 looks (about 10 s on a free
    /// main actor).
    ///
    /// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE. On CI the whole test process has
    /// frozen for two minutes (run 37318287644, #525): a 10 s deadline
    /// expired while this wait could not even run, and the one look left at
    /// the end came before the profile load had had its turn. A frozen
    /// process now costs no budget. A short budget that gave up silently made
    /// the next step a no-op (#521); the waits that matter are `#require`d.
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
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
        // Both reads: the relationship can answer before the profile, and the
        // button acts on a loaded profile only.
        try #require(await settle { buttons.last == .follow && viewModel.profile != nil }, "the profile never loaded")
        #expect(buttons.last == .follow)

        viewModel.toggleFollow()
        #expect(buttons.last == .requested, "a private profile is asked at once, not followed")
        // The server's answer, not a guess at how long it takes.
        try #require(await settle { !viewModel.followInFlight }, "the request never came back")
        #expect(buttons.last == .requested)
        #expect(try await fixture.repository.relationship(for: target) == .requested)

        viewModel.toggleFollow()
        #expect(buttons.last == .follow)
        try #require(await settle { !viewModel.followInFlight }, "the withdrawal never came back")
        #expect(try await fixture.repository.relationship(for: target) == .other(isFollowing: false, isMutual: false, isBlocked: false))
    }

    /// ⚠️ #1450: a request already pending is "Requested", not a failure.
    /// The mock answers the second ask SGR-1005, as the graph does.
    @Test func askingAgainWithARequestPendingIsRequested() async throws {
        let fixture = makeFixture()
        let target = privateStranger(in: fixture.dataset)
        #expect(try await fixture.repository.follow(target) == .requested)
        #expect(try await fixture.repository.follow(target) == .requested, "a pending request read as a failure")
    }

    /// The profile's button reads "Follow" while a request is already pending
    /// (asked from elsewhere, unheard): its tap ends on "Requested", with no
    /// failure toast (#1450).
    @Test func theProfileTapOnAPendingRequestEndsOnRequested() async throws {
        let fixture = makeFixture()
        let target = privateStranger(in: fixture.dataset)
        let viewModel = ProfileViewModel(repository: fixture.repository, source: .profile(target))
        var buttons: [ProfileViewModel.FollowButton] = []
        var failed = false
        viewModel.onFollowButtonChange = { buttons.append($0) }
        viewModel.onActionResult = { if case .followFailed = $0 { failed = true } }
        viewModel.viewDidLoad()
        try #require(await settle { buttons.last == .follow && viewModel.profile != nil }, "the profile never loaded")
        // Asked from somewhere this profile did not hear.
        #expect(try await fixture.repository.follow(target) == .requested)

        viewModel.toggleFollow()
        try #require(await settle { !viewModel.followInFlight }, "the request never came back")
        #expect(buttons.last == .requested, "the duplicate ask did not end on Requested: \(buttons)")
        #expect(!failed, "a pending request showed a failure toast")
    }

    /// ⚠️ #1670: a card seen once, then a request made from a feed's "+"
    /// while no card was alive, then the card opened again on the same cache
    /// — it read "Follow". It opens on "Requested", and settles there.
    @Test func aCardReopenedAfterARequestElsewhereReadsRequested() async throws {
        let events = FollowGraphEvents()
        let fixture = makeFixture(followEvents: events)
        let target = privateStranger(in: fixture.dataset)
        let cache = ProfileCache()
        cache.observe(events)
        var first: ProfileViewModel? = ProfileViewModel(
            repository: fixture.repository, source: .profile(target), cache: cache, followEvents: events
        )
        var firstButtons: [ProfileViewModel.FollowButton] = []
        first?.onFollowButtonChange = { firstButtons.append($0) }
        first?.viewDidLoad()
        try #require(await settle { firstButtons.last == .follow && first?.profile != nil }, "the card never loaded")
        first = nil

        #expect(try await fixture.repository.follow(target) == .requested)
        try #require(await settle { cache.relationship(for: target) == .requested }, "the cache kept \(String(describing: cache.relationship(for: target)))")

        let again = ProfileViewModel(
            repository: fixture.repository, source: .profile(target), cache: cache, followEvents: events
        )
        var buttons: [ProfileViewModel.FollowButton] = []
        again.onFollowButtonChange = { buttons.append($0) }
        again.viewDidLoad()
        #expect(buttons.first == .requested, "the card opened on \(buttons)")
        // The read that revalidates it agrees: nothing moves.
        try #require(await settle { again.profile != nil && !again.isLoadingRelationship }, "the card never loaded")
        #expect(buttons == [.requested], "the card moved: \(buttons)")
    }

    /// ⚠️ #1670, backend #972: a private person who already FOLLOWS the
    /// viewer. The graph's status hides the request behind `FOLLOWED_BY`; the
    /// repository keeps it for the session, so every read says Requested
    /// until it is withdrawn — then Follow (follow back) again.
    @Test func aRequestToSomeoneWhoFollowsTheViewerStaysRequested() async throws {
        let fixture = makeFixture()
        let target = privateFollower(in: fixture.dataset)
        #expect(try await fixture.repository.followRelation(to: target) == .followedBy)

        #expect(try await fixture.repository.follow(target) == .requested)
        #expect(try await fixture.repository.relationship(for: target) == .requested)
        #expect(try await fixture.repository.followRelation(to: target) == .requested)

        try await fixture.repository.cancelFollowRequest(to: target)
        #expect(try await fixture.repository.relationship(for: target) == .other(isFollowing: false, isMutual: false, isBlocked: false))
        #expect(try await fixture.repository.followRelation(to: target) == .followedBy)
    }

    /// The same request asked by ANOTHER writer (a list row, a suggestion)
    /// reaches the repository through the follow channel.
    @Test func aRequestHeardFromAnotherWriterStaysRequested() async throws {
        let events = FollowGraphEvents()
        let fixture = makeFixture(followEvents: events)
        let target = privateFollower(in: fixture.dataset)
        let viewer = ProfileID(MockSocialDataset.viewerProfileID)
        events.publish(FollowRequestChange(profileID: target, isPending: true, viewerID: viewer))
        #expect(try await fixture.repository.followRelation(to: target) == .requested)
        events.publish(FollowRequestChange(profileID: target, isPending: false, viewerID: viewer))
        #expect(try await fixture.repository.followRelation(to: target) == .followedBy)
    }

    /// A request made from a list row or a suggestion turns the profile
    /// underneath to "Requested", and a withdrawal back to "Follow" (#1450).
    @Test func aRequestMadeElsewhereReachesTheProfileUnderneath() async throws {
        let events = FollowGraphEvents()
        let fixture = makeFixture(followEvents: events)
        let target = privateStranger(in: fixture.dataset)
        let viewModel = ProfileViewModel(repository: fixture.repository, source: .profile(target), followEvents: events)
        var buttons: [ProfileViewModel.FollowButton] = []
        viewModel.onFollowButtonChange = { buttons.append($0) }
        viewModel.viewDidLoad()
        try #require(await settle { buttons.last == .follow && viewModel.profile != nil }, "the profile never loaded")

        #expect(try await fixture.repository.follow(target) == .requested)
        #expect(await settle { buttons.last == .requested }, "the profile underneath still reads Follow: \(buttons)")

        try await fixture.repository.cancelFollowRequest(to: target)
        #expect(await settle { buttons.last == .follow }, "the withdrawal did not reach the profile: \(buttons)")
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
