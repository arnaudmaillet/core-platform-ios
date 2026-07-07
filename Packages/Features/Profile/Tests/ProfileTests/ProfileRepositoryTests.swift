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
        followSucceeds: Bool = true
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
        #expect(try await following.relationship(for: ProfileID("prof-3")) == .other(isFollowing: true))

        // `.mutual` also counts as "the viewer follows them".
        let (mutual, _) = makeRepositoryWithGraph(status: .mutual)
        #expect(try await mutual.relationship(for: ProfileID("prof-3")) == .other(isFollowing: true))

        // `.followedBy` means they follow the viewer, not the other way around.
        let (followedBy, _) = makeRepositoryWithGraph(status: .followedBy)
        #expect(try await followedBy.relationship(for: ProfileID("prof-3")) == .other(isFollowing: false))
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

        _ = try await repository.updateCurrentUserProfile(displayName: "New Name", bio: "New bio", website: "https://new.dev")

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
    private let lock = NSLock()
    private var calls: [Call] = []
    func record(following: Bool, actor: String, target: String) {
        lock.withLock { calls.append(Call(following: following, actor: actor, target: target)) }
    }
    var last: Call? { lock.withLock { calls.last } }
}
