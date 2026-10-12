import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Synchronization
import Testing
@testable import Profile

/// The relationships lists' row states are the VIEWER's: whom they follow,
/// whom they asked, who refused them. A viewer change (another account, a
/// sign-out, a profile switch) drops every one of them (#892).
struct RelationshipsViewerChangeTests {
    /// Whose side the repository asks from, swapped the way a switch swaps it.
    private final class SwitchableViewer: ProfileViewerResolving {
        private let id = Mutex<ProfileID?>(ProfileID("prof-a"))
        func viewerProfileID() async -> ProfileID? { id.withLock { $0 } }
        func set(_ new: ProfileID?) { id.withLock { $0 = new } }
    }

    /// A follows x and y; B follows nobody. Everyone is followed by `p`
    /// (private: a follow is a request) and `q` (refuses any follow).
    private func makeRepository(
        viewer: SwitchableViewer, followEvents: FollowGraphEvents? = nil,
        duringFollow: @escaping @Sendable () -> Void = {},
        gate: FollowGate? = nil
    ) -> ProfileRelationshipsRepository {
        let bff = MockBFF()
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowing") { (request: SocialGraph_V1_ListFollowingRequest) in
            var response = SocialGraph_V1_ListFollowingResponse()
            let ids = request.followerID == "prof-a" ? ["prof-x", "prof-b"] : []
            response.following = ids.map { id in
                var edge = SocialGraph_V1_EdgeSummary()
                edge.profileID = id
                return edge
            }
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowers") { (_: SocialGraph_V1_ListFollowersRequest) in
            var response = SocialGraph_V1_ListFollowersResponse()
            response.followers = ["prof-p", "prof-q"].map { id in
                var edge = SocialGraph_V1_EdgeSummary()
                edge.profileID = id
                return edge
            }
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Follow") { (request: SocialGraph_V1_FollowRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            duringFollow()
            if request.targetID == "prof-q" {
                return .failure(ConnectError(code: .permissionDenied, message: "blocked"))
            }
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            response.requested = request.targetID == "prof-p"
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/GetProfileById") { (request: Profile_V1_GetProfileByIdRequest) in
            var view = Profile_V1_ProfileView()
            view.profileID = request.profileID
            view.handle = request.profileID
            return .success(view)
        }
        gate?.bff = bff
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: gate ?? bff
        )
        return ProfileRelationshipsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: viewer,
            supportsFollowerRemoval: true,
            followEvents: followEvents
        )
    }

    private func row(
        _ id: String, in repository: ProfileRelationshipsRepository, direction: RelationshipDirection
    ) async throws -> ProfileRelation {
        let page = try await repository.relationships(
            for: ProfileID("prof-a"), direction: direction, pageToken: "", limit: 50
        )
        return try #require(page.relations.first { $0.id.rawValue == id }, "no row for \(id)")
    }

    @Test func aProfileSwitchForgetsTheFollowSet() async throws {
        let viewer = SwitchableViewer()
        let repository = makeRepository(viewer: viewer)
        #expect(try await row("prof-x", in: repository, direction: .following).viewerFollows,
                "A follows x")

        viewer.set(ProfileID("prof-b"))
        await repository.viewerDidChange(.member(AccountID("acct-1"), activeProfile: ProfileID("prof-b")))

        let after = try await row("prof-x", in: repository, direction: .following)
        #expect(!after.viewerFollows, "B's row said Following from A's follow set")
        #expect(try await row("prof-b", in: repository, direction: .following).isViewer)
    }

    @Test func aProfileSwitchForgetsRequestsAndRefusals() async throws {
        let viewer = SwitchableViewer()
        let repository = makeRepository(viewer: viewer)
        #expect(try await repository.follow(ProfileID("prof-p")) == .requested)
        await #expect(throws: RelationshipsError.cannotFollow) {
            _ = try await repository.follow(ProfileID("prof-q"))
        }
        #expect(try await row("prof-p", in: repository, direction: .followers).viewerRequested)
        #expect(try await !row("prof-q", in: repository, direction: .followers).canFollow)

        viewer.set(ProfileID("prof-b"))
        await repository.viewerDidChange(.member(AccountID("acct-1"), activeProfile: ProfileID("prof-b")))

        #expect(try await !row("prof-p", in: repository, direction: .followers).viewerRequested,
                "B's row said Requested for A's request")
        #expect(try await row("prof-q", in: repository, direction: .followers).canFollow,
                "B lost Follow to a refusal A got")
    }

    @Test func signingOutForgetsEverything() async throws {
        let viewer = SwitchableViewer()
        let repository = makeRepository(viewer: viewer)
        _ = try await repository.follow(ProfileID("prof-p"))
        #expect(try await row("prof-x", in: repository, direction: .following).viewerFollows)

        viewer.set(nil)
        await repository.viewerDidChange(.guest)

        #expect(try await !row("prof-x", in: repository, direction: .following).viewerFollows)
        #expect(try await !row("prof-p", in: repository, direction: .followers).viewerRequested)
    }

    // MARK: - Follow events carry the viewer (#978)

    private final class Heard: @unchecked Sendable {
        private let changes = Mutex<[FollowChange]>([])
        func append(_ change: FollowChange) { changes.withLock { $0.append(change) } }
        var all: [FollowChange] { changes.withLock { $0 } }
    }

    /// The announced follow names the profile it was made as.
    @Test func anAcceptedFollowIsAnnouncedAsTheViewerWhoMadeIt() async throws {
        let viewer = SwitchableViewer()
        let events = FollowGraphEvents(currentViewer: { ProfileID("prof-a") })
        let heard = Heard()
        let subscription = events.subscribe { heard.append($0) }
        let repository = makeRepository(viewer: viewer, followEvents: events)

        #expect(try await repository.follow(ProfileID("prof-y")) == .following)

        #expect(heard.all == [FollowChange(profileID: ProfileID("prof-y"), isFollowing: true, viewerID: ProfileID("prof-a"))])
        withExtendedLifetime(subscription) {}
    }

    /// A follow sent as A, accepted after the switch to B, never reaches B's
    /// surfaces: the channel drops a change made as a viewer who has left.
    @Test func aFollowAcceptedAfterASwitchReachesNobody() async throws {
        let viewer = SwitchableViewer()
        let active = Mutex<ProfileID?>(ProfileID("prof-a"))
        let events = FollowGraphEvents(currentViewer: { active.withLock { $0 } })
        let heard = Heard()
        let subscription = events.subscribe { heard.append($0) }
        // The switch lands while the follow is on its way.
        let repository = makeRepository(viewer: viewer, followEvents: events) {
            active.withLock { $0 = ProfileID("prof-b") }
            viewer.set(ProfileID("prof-b"))
        }

        #expect(try await repository.follow(ProfileID("prof-y")) == .following)

        #expect(heard.all.isEmpty, "B heard A's follow: \(heard.all)")
        withExtendedLifetime(subscription) {}
    }

    /// Holds the answer to a Follow until `release()`, so a test can switch
    /// the viewer while the follow is on its way.
    final class FollowGate: HTTPClientInterface, @unchecked Sendable {
        private struct State {
            var bff: MockBFF?
            var held: (@Sendable () -> Void)?
        }
        private let state = Mutex(State())

        var bff: MockBFF? {
            get { state.withLock { $0.bff } }
            set { state.withLock { $0.bff = newValue } }
        }

        var isHolding: Bool { state.withLock { $0.held != nil } }

        func release() {
            let held = state.withLock { state -> (@Sendable () -> Void)? in
                defer { state.held = nil }
                return state.held
            }
            held?()
        }

        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            guard let bff else { return Cancelable {} }
            guard request.url.path.hasSuffix("SocialGraphService/Follow") else {
                return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
            }
            return bff.unary(request: request, onMetrics: onMetrics) { [weak self] response in
                self?.state.withLock { $0.held = { onResponse(response) } }
            }
        }

        func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
            bff!.stream(request: request, responseCallbacks: responseCallbacks)
        }
    }

    /// The repository's own copy of the follow set: a follow A made, accepted
    /// after the switch to B and after B's set was read, is not filed in it.
    @Test func aFollowAcceptedAfterASwitchIsNotFiledUnderTheNewViewer() async throws {
        let viewer = SwitchableViewer()
        let gate = FollowGate()
        let repository = makeRepository(viewer: viewer, gate: gate)

        let follow = Task { try await repository.setFollowing(true, for: ProfileID("prof-p")) }
        var looks = 0
        while !gate.isHolding, looks < 6_000 {
            looks += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.isHolding, "the follow never reached the server")

        viewer.set(ProfileID("prof-b"))
        await repository.viewerDidChange(.member(AccountID("acct-1"), activeProfile: ProfileID("prof-b")))
        // B's set is read while A's follow is still on its way.
        #expect(try await !row("prof-p", in: repository, direction: .followers).viewerFollows)

        gate.release()
        try await follow.value

        #expect(try await !row("prof-p", in: repository, direction: .followers).viewerFollows,
                "A's late follow was filed in B's follow set")
    }
}
