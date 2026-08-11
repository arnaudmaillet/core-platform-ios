import Connect
import CoreContracts
import CoreModels
import Foundation
import Testing
@testable import Profile

/// The Friends tab has no RPC behind it — `social_graph.v1` can list followers
/// and list following and nothing else, so `ProfileRelationshipsRepository`
/// derives mutuals by paging one side and testing it against the other.
///
/// These tests drive the REAL repository against fake transport, because the
/// intersection is the part that can be wrong: which side is paged, how many
/// pages it will walk to fill one, and what happens when a following page
/// contains no mutuals at all. A stub at the `ProfileRelationshipsProviding`
/// seam would sit above all of it and prove nothing.
@Suite("Friends intersection")
struct ProfileFriendsIntersectionTests {
    @Test("Friends are the following list filtered to people who follow back")
    func friendsAreMutuals() async throws {
        // Follows 1…6, followed by 4…9 → mutuals are 4, 5, 6.
        let graph = FakeSocialGraphClient(
            following: (1...6).map { "prof-\($0)" },
            followers: (4...9).map { "prof-\($0)" }
        )
        let repository = makeRepository(graph: graph)

        let page = try await repository.relationships(
            for: ProfileID("subject"), direction: .friends, pageToken: "", limit: 20
        )

        #expect(page.relations.map(\.id.rawValue) == ["prof-4", "prof-5", "prof-6"])
    }

    @Test("Someone the subject follows who doesn't follow back is not a friend")
    func oneWayFollowIsNotAFriend() async throws {
        let graph = FakeSocialGraphClient(following: ["prof-1"], followers: [])
        let repository = makeRepository(graph: graph)

        let page = try await repository.relationships(
            for: ProfileID("subject"), direction: .friends, pageToken: "", limit: 20
        )

        #expect(page.relations.isEmpty)
    }

    @Test("Someone who follows the subject without being followed back is not a friend")
    func inboundOnlyIsNotAFriend() async throws {
        let graph = FakeSocialGraphClient(following: [], followers: ["prof-1"])
        let repository = makeRepository(graph: graph)

        let page = try await repository.relationships(
            for: ProfileID("subject"), direction: .friends, pageToken: "", limit: 20
        )

        #expect(page.relations.isEmpty)
    }

    /// The reason `friendEdges` loops instead of returning what one following
    /// page happened to contain. With mutuals only at the far end of the
    /// following list, a single page would come back empty and the screen would
    /// render "No Friends Yet" over a graph that has three.
    @Test("Keeps pulling following pages until the page is full")
    func fillsAPageAcrossManyFollowingPages() async throws {
        // 30 followed, but only the last three follow back — at 5 per page
        // that is five fruitless pages before the first mutual appears.
        let graph = FakeSocialGraphClient(
            following: (1...30).map { "prof-\($0)" },
            followers: ["prof-28", "prof-29", "prof-30"],
            pageSize: 5
        )
        let repository = makeRepository(graph: graph)

        let page = try await repository.relationships(
            for: ProfileID("subject"), direction: .friends, pageToken: "", limit: 3
        )

        #expect(page.relations.map(\.id.rawValue) == ["prof-28", "prof-29", "prof-30"])
    }

    /// The follower set is what membership is tested against, so it must be
    /// assembled across ALL its pages — a single-page read would silently
    /// shrink the intersection to whoever happened to land in the first page.
    @Test("Pages the whole follower set before intersecting")
    func followerSetIsPagedInFull() async throws {
        let graph = FakeSocialGraphClient(
            following: ["prof-1", "prof-20"],
            followers: (1...20).map { "prof-\($0)" },
            pageSize: 5
        )
        let repository = makeRepository(graph: graph)

        let page = try await repository.relationships(
            for: ProfileID("subject"), direction: .friends, pageToken: "", limit: 20
        )

        // prof-20 sits in the fourth page of followers; if only the first were
        // read it would be missing here.
        #expect(page.relations.map(\.id.rawValue) == ["prof-1", "prof-20"])
    }

    private func makeRepository(graph: FakeSocialGraphClient) -> ProfileRelationshipsRepository {
        ProfileRelationshipsRepository(
            socialGraphClient: graph,
            profileClient: StubProfileServiceClient(),
            viewer: FakeViewer(),
            supportsFollowerRemoval: false
        )
    }
}

// MARK: - Fakes

/// Serves two static edge lists with real pagination. Only the two list calls
/// are meaningful; the rest of the interface exists to satisfy the protocol and
/// is never reached by this suite.
private final class FakeSocialGraphClient: SocialGraph_V1_SocialGraphServiceClientInterface, @unchecked Sendable {
    private let following: [String]
    private let followers: [String]
    private let pageSize: Int

    init(following: [String] = [], followers: [String] = [], pageSize: Int = 100) {
        self.following = following
        self.followers = followers
        self.pageSize = pageSize
    }

    /// Numeric page tokens — the offset of the next slice, empty when done.
    private func slice(_ all: [String], pageToken: String, limit: Int32) -> ([String], String) {
        let start = Int(pageToken) ?? 0
        let size = min(pageSize, Int(limit))
        let end = min(start + size, all.count)
        guard start < end else { return ([], "") }
        return (Array(all[start..<end]), end < all.count ? String(end) : "")
    }

    func listFollowers(
        request: SocialGraph_V1_ListFollowersRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_ListFollowersResponse> {
        let (ids, next) = slice(followers, pageToken: request.pageToken, limit: request.limit)
        var response = SocialGraph_V1_ListFollowersResponse()
        response.followers = ids.map { id in
            var edge = SocialGraph_V1_EdgeSummary()
            edge.profileID = id
            return edge
        }
        response.nextPageToken = next
        return ResponseMessage(result: .success(response))
    }

    func listFollowing(
        request: SocialGraph_V1_ListFollowingRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_ListFollowingResponse> {
        let (ids, next) = slice(following, pageToken: request.pageToken, limit: request.limit)
        var response = SocialGraph_V1_ListFollowingResponse()
        response.following = ids.map { id in
            var edge = SocialGraph_V1_EdgeSummary()
            edge.profileID = id
            return edge
        }
        response.nextPageToken = next
        return ResponseMessage(result: .success(response))
    }

    func getRelationStatus(
        request: SocialGraph_V1_GetRelationStatusRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_RelationStatusView> {
        ResponseMessage(result: .success(SocialGraph_V1_RelationStatusView()))
    }

    func follow(
        request: SocialGraph_V1_FollowRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_CommandResponse> {
        ResponseMessage(result: .success(SocialGraph_V1_CommandResponse()))
    }

    func unfollow(
        request: SocialGraph_V1_UnfollowRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_CommandResponse> {
        ResponseMessage(result: .success(SocialGraph_V1_CommandResponse()))
    }

    func block(
        request: SocialGraph_V1_BlockRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_CommandResponse> {
        ResponseMessage(result: .success(SocialGraph_V1_CommandResponse()))
    }

    func unblock(
        request: SocialGraph_V1_UnblockRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_CommandResponse> {
        ResponseMessage(result: .success(SocialGraph_V1_CommandResponse()))
    }

    func listBlocks(
        request: SocialGraph_V1_ListBlocksRequest, headers: Connect.Headers
    ) async -> ResponseMessage<SocialGraph_V1_ListBlocksResponse> {
        ResponseMessage(result: .success(SocialGraph_V1_ListBlocksResponse()))
    }
}

private struct FakeViewer: ProfileViewerResolving {
    func viewerProfileID() async -> ProfileID? { ProfileID("viewer") }
}
