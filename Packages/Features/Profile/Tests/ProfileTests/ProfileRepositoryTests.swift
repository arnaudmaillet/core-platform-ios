import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

private struct AuthenticatedSessionStub: AuthSessionProviding {
    var accountID = AccountID(MockAuthService.accountID)

    func currentState() async -> AuthState { .authenticated(accountID) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(accountID)); $0.finish() }
    }
    func logout() async {}
}

private struct UnauthenticatedSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .unauthenticated }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.unauthenticated); $0.finish() }
    }
    func logout() async {}
}

/// Drives the full read path — repository → generated clients → real
/// ProtocolClient → MockBFF — with production wire bytes, in-process.
struct ProfileRepositoryTests {
    private func makeRepository(
        session: any AuthSessionProviding = AuthenticatedSessionStub(),
        dataset: MockSocialDataset = MockSocialDataset()
    ) -> ProfileRepository {
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: session
        )
    }

    @Test func resolvesViewerIdentityFromAccount() async throws {
        let repository = makeRepository()

        let profile = try await repository.currentUserProfile()

        // account → ListProfilesByAccount → GetProfileById, end to end.
        #expect(profile.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(profile.handle == "you")
        #expect(profile.displayName == "Demo Viewer")
    }

    @Test func listsAccountProfilesAndSwitchesActive() async throws {
        let repository = makeRepository()

        // The account lists the viewer plus two more switchable profiles.
        let profiles = try await repository.accountProfiles()
        #expect(profiles.count == 3)
        #expect(profiles.first?.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(profiles.map(\.handle) == ["you", "ava.moreau", "lena_klein"])

        // Active defaults to the first (viewer).
        #expect(await repository.activeProfileID() == ProfileID(MockSocialDataset.viewerProfileID))

        // Switching changes who `currentUserProfile` (profile screen + avatar)
        // resolves to — the whole point of the switch.
        await repository.setActiveProfile(ProfileID("prof-0"))
        #expect(await repository.activeProfileID() == ProfileID("prof-0"))
        let switched = try await repository.currentUserProfile()
        #expect(switched.id == ProfileID("prof-0"))
        #expect(switched.displayName == "Ava Moreau")
    }

    @Test func fetchesAnyProfileByID() async throws {
        // Routing to another user resolves their view directly (no account hop).
        let repository = makeRepository()

        let profile = try await repository.profile(id: ProfileID(MockSocialDataset.viewerProfileID))

        #expect(profile.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(profile.handle == "you")
    }

    @Test func degradesToUnavailableWhenNeitherSourceHasCounts() async throws {
        // MockBFF serves only LIKE on counter.v1 and has no social_graph route,
        // so both the primary read and the fallback come up empty; the
        // repository must surface `.unavailable` (rendered "—"), never `.exact(0)`.
        let repository = makeRepository()

        let profile = try await repository.currentUserProfile()

        #expect(profile.followerCount == .unavailable)
        #expect(profile.followingCount == .unavailable)
        // VIEW has no counter projection and no fallback source at all.
        #expect(profile.viewCount == .unavailable)
    }

    @Test func readsProfileReactionsFromCounterAggregate() async throws {
        // Profile-scoped LIKE is the one metric the mock projects: the sum of
        // like counts across the author's posts, served `.exact` — the
        // distinction this covers is exact-versus-`.unavailable`, not the
        // particular number.
        //
        // The viewer used to assert `.exact(0)`, which was true only because
        // the fixtures gave them no posts. They have a gallery now, so the
        // zero is gone and with it the one case that showed a truthful zero
        // reaching the UI as `.exact` rather than `.unavailable`. No seeded
        // profile has zero posts any more, so that case is not reachable here;
        // it is worth a fixture of its own if it ever matters.
        let repository = makeRepository()

        let author = try await repository.profile(id: ProfileID("prof-3"))
        guard case .exact(let total) = author.reactionCount else {
            Issue.record("expected an exact reaction count, got \(author.reactionCount)")
            return
        }
        #expect(total > 0)

        let viewer = try await repository.currentUserProfile()
        guard case .exact(let viewerTotal) = viewer.reactionCount else {
            Issue.record("the viewer's own total stopped being exact: \(viewer.reactionCount)")
            return
        }
        #expect(viewerTotal > 0, "the viewer owns posts now, so their aggregate is not zero")
    }

    @Test func throwsWhenNotAuthenticated() async {
        let repository = makeRepository(session: UnauthenticatedSessionStub())

        await #expect(throws: ProfileError.notAuthenticated) {
            _ = try await repository.currentUserProfile()
        }
    }

    // MARK: - Relationship / follow

    /// A repository whose social_graph is stubbed with a fixed relation status
    /// and a capture box that records follow/unfollow commands.
    private func makeRepositoryWithGraph(
        status: SocialGraph_V1_RelationStatus = .none,
        followSucceeds: Bool = true,
        blockSucceeds: Bool = true,
        blockRejects: Set<String> = []
    ) -> (ProfileRepository, GraphCapture) {
        let capture = GraphCapture()
        let bff = MockBFF()
        MockSocialServices(dataset: MockSocialDataset()).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: MockSocialDataset())).register(on: bff)

        bff.register(path: "/social_graph.v1.SocialGraphService/GetRelationStatus") { (request: SocialGraph_V1_GetRelationStatusRequest) in
            var view = SocialGraph_V1_RelationStatusView()
            view.actorID = request.actorID
            view.targetID = request.targetID
            view.status = status
            return .success(view)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Follow") { (request: SocialGraph_V1_FollowRequest) in
            capture.record(following: true, actor: request.actorID, target: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = followSucceeds
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unfollow") { (request: SocialGraph_V1_UnfollowRequest) in
            capture.record(following: false, actor: request.actorID, target: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Block") { (request: SocialGraph_V1_BlockRequest) in
            capture.record(blocked: true, actor: request.actorID, target: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = blockSucceeds && !blockRejects.contains(request.targetID)
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unblock") { (request: SocialGraph_V1_UnblockRequest) in
            capture.record(blocked: false, actor: request.actorID, target: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }

        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )
        return (repository, capture)
    }

    @Test func ownProfileRelationshipIsMe() async throws {
        let (repository, _) = makeRepositoryWithGraph()

        let relationship = try await repository.relationship(for: ProfileID(MockSocialDataset.viewerProfileID))

        #expect(relationship == .me)
    }

    @Test func readsFollowStatusForOthers() async throws {
        let (following, _) = makeRepositoryWithGraph(status: .following)
        #expect(try await following.relationship(for: ProfileID("prof-3")) == .other(isFollowing: true, isBlocked: false))

        // `.mutual` also counts as "the viewer follows them" — AND is
        // reported as mutual, which is what lets the map offer a friend the
        // choice of rail. Collapsing the two is what had to be undone.
        let (mutual, _) = makeRepositoryWithGraph(status: .mutual)
        #expect(
            try await mutual.relationship(for: ProfileID("prof-3"))
                == .other(isFollowing: true, isMutual: true, isBlocked: false)
        )
        // ...and a one-way follow is NOT mutual.
        #expect(
            try await following.relationship(for: ProfileID("prof-3"))
                != .other(isFollowing: true, isMutual: true, isBlocked: false)
        )

        // `.followedBy` means they follow the viewer, not the other way around.
        let (followedBy, _) = makeRepositoryWithGraph(status: .followedBy)
        #expect(try await followedBy.relationship(for: ProfileID("prof-3")) == .other(isFollowing: false, isBlocked: false))
    }

    @Test func readsBlockStatus() async throws {
        // `.blocking` is the viewer's OUTBOUND block — the state the overflow
        // menu reads to offer Unblock.
        let (blocking, _) = makeRepositoryWithGraph(status: .blocking)
        #expect(try await blocking.relationship(for: ProfileID("prof-3")) == .other(isFollowing: false, isBlocked: true))

        // `.blockedBy` is the inbound direction and is deliberately NOT
        // surfaced: the viewer must not learn they were blocked.
        let (blockedBy, _) = makeRepositoryWithGraph(status: .blockedBy)
        #expect(try await blockedBy.relationship(for: ProfileID("prof-3")) == .other(isFollowing: false, isBlocked: false))
    }

    @Test func blockSendsViewerAsActorAndTargetProfile() async throws {
        let (repository, capture) = makeRepositoryWithGraph()

        try await repository.setBlocked(true, for: ProfileID("prof-3"))

        let call = capture.lastBlock
        #expect(call?.blocked == true)
        #expect(call?.actor == MockSocialDataset.viewerProfileID)
        #expect(call?.target == "prof-3")
    }

    @Test func unblockSendsTheUnblockCommand() async throws {
        let (repository, capture) = makeRepositoryWithGraph()

        try await repository.setBlocked(false, for: ProfileID("prof-3"))

        #expect(capture.lastBlock?.blocked == false)
    }

    @Test func blockingYourselfIsANoOp() async throws {
        let (repository, capture) = makeRepositoryWithGraph()

        try await repository.setBlocked(true, for: ProfileID(MockSocialDataset.viewerProfileID))

        #expect(capture.lastBlock == nil)
    }

    @Test func accountBlockCoversEveryProfileOnTheAccount() async throws {
        // prof-5 and prof-6 are seeded as aliases of ONE stranger's account.
        let (repository, capture) = makeRepositoryWithGraph()

        let blocked = try await repository.blockAccount(behind: ProfileID("prof-5"))

        #expect(blocked == [ProfileID("prof-5"), ProfileID("prof-6")])
        #expect(Set(capture.blockTargets) == ["prof-5", "prof-6"])
    }

    /// A single-profile account degrades to exactly the profile asked about —
    /// no phantom aliases, no failure.
    @Test func accountBlockOnASoloAccountBlocksJustThatProfile() async throws {
        let (repository, capture) = makeRepositoryWithGraph()

        let blocked = try await repository.blockAccount(behind: ProfileID("prof-3"))

        #expect(blocked == [ProfileID("prof-3")])
        #expect(capture.blockTargets == ["prof-3"])
    }

    /// The viewer's own profiles are never blocked, even when the target
    /// shares an account with them — the command layer would reject it, and
    /// self-blocking is nonsense to attempt.
    @Test func accountBlockNeverTargetsTheViewersOwnProfile() async throws {
        // prof-0 sits on the VIEWER's account in the seeded data.
        let (repository, capture) = makeRepositoryWithGraph()

        _ = try? await repository.blockAccount(behind: ProfileID("prof-0"))

        #expect(!capture.blockTargets.contains(MockSocialDataset.viewerProfileID))
    }

    /// Partial failure blocks what it can and reports only that — it must not
    /// claim the whole account when one command was rejected.
    @Test func accountBlockReportsOnlyWhatSucceeded() async throws {
        let (repository, _) = makeRepositoryWithGraph(blockRejects: ["prof-6"])

        let blocked = try await repository.blockAccount(behind: ProfileID("prof-5"))

        #expect(blocked == [ProfileID("prof-5")])
    }

    @Test func accountBlockThrowsWhenNothingCouldBeBlocked() async {
        let (repository, _) = makeRepositoryWithGraph(blockRejects: ["prof-5", "prof-6"])

        await #expect(throws: ProfileError.self) {
            _ = try await repository.blockAccount(behind: ProfileID("prof-5"))
        }
    }

    @Test func rejectedBlockThrows() async {
        let (repository, _) = makeRepositoryWithGraph(blockSucceeds: false)

        await #expect(throws: ProfileError.self) {
            try await repository.setBlocked(true, for: ProfileID("prof-3"))
        }
    }

    @Test func followSendsViewerAsActorAndTargetProfile() async throws {
        let (repository, capture) = makeRepositoryWithGraph()

        try await repository.setFollowing(true, for: ProfileID("prof-3"))

        let call = capture.last
        #expect(call?.following == true)
        #expect(call?.actor == MockSocialDataset.viewerProfileID)
        #expect(call?.target == "prof-3")
    }

    @Test func throwsWhenFollowRejected() async {
        let (repository, _) = makeRepositoryWithGraph(followSucceeds: false)

        await #expect(throws: ProfileError.self) {
            try await repository.setFollowing(true, for: ProfileID("prof-3"))
        }
    }

    // MARK: - Edit

    @Test func updateSendsEditedFieldsForTheViewerProfile() async throws {
        let capture = UpdateCapture()
        let bff = MockBFF()
        MockSocialServices(dataset: MockSocialDataset()).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: MockSocialDataset())).register(on: bff)
        bff.register(path: "/profile.v1.ProfileService/UpdateProfile") { (request: Profile_V1_UpdateProfileRequest) in
            capture.record(id: request.profileID, displayName: request.displayName, bio: request.bio, website: request.websiteURL)
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: AuthenticatedSessionStub()
        )

        _ = try await repository.updateCurrentUserProfile(displayName: "New Name", bio: "New bio", website: "https://new.dev", links: [])

        #expect(capture.lastID == MockSocialDataset.viewerProfileID)
        #expect(capture.lastDisplayName == "New Name")
        #expect(capture.lastBio == "New bio")
        #expect(capture.lastWebsite == "https://new.dev")
    }
}

private final class UpdateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastID: String?
    private(set) var lastDisplayName: String?
    private(set) var lastBio: String?
    private(set) var lastWebsite: String?
    func record(id: String, displayName: String, bio: String, website: String) {
        lock.withLock {
            lastID = id; lastDisplayName = displayName; lastBio = bio; lastWebsite = website
        }
    }
}

/// Records the follow/unfollow commands the repository issues over the wire.
private final class GraphCapture: @unchecked Sendable {
    struct Call: Sendable { let following: Bool; let actor: String; let target: String }
    struct BlockCall: Sendable { let blocked: Bool; let actor: String; let target: String }
    private let lock = NSLock()
    private var calls: [Call] = []
    private var blockCalls: [BlockCall] = []
    func record(following: Bool, actor: String, target: String) {
        lock.withLock { calls.append(Call(following: following, actor: actor, target: target)) }
    }
    func record(blocked: Bool, actor: String, target: String) {
        lock.withLock { blockCalls.append(BlockCall(blocked: blocked, actor: actor, target: target)) }
    }
    var last: Call? { lock.withLock { calls.last } }
    var lastBlock: BlockCall? { lock.withLock { blockCalls.last } }
    /// Every profile a Block command was aimed at, for asserting fan-out.
    var blockTargets: [String] { lock.withLock { blockCalls.filter(\.blocked).map(\.target) } }
}
