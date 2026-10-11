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
    private func makeRepository(viewer: SwitchableViewer) -> ProfileRelationshipsRepository {
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
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRelationshipsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: viewer,
            supportsFollowerRemoval: true
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
}
