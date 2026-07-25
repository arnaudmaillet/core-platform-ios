import Connect
import CoreContracts
import Foundation

/// Fake of social_graph.v1 over the shared dataset. Enough to make the profile
/// surface work offline: a relation status (so Follow/Message buttons appear),
/// follow/unfollow commands, and follower/following edges (so counts render as
/// numbers rather than "—").
public final class MockSocialGraphService: @unchecked Sendable {
    private let dataset: MockSocialDataset

    public init(dataset: MockSocialDataset) {
        self.dataset = dataset
    }

    public func register(on bff: MockBFF) {
        // Relation status reads the dataset's own graph rather than a blanket
        // `.none`: the inbox's request partition and the profile header both
        // hang off it, so a viewer who demonstrably follows prof-0..3 must not
        // be told otherwise. prof-4..7 stay unfollowed, which keeps the
        // profile screen's "Follow" button exercised.
        bff.register(path: "/social_graph.v1.SocialGraphService/GetRelationStatus") { [self] (request: SocialGraph_V1_GetRelationStatusRequest) in
            var view = SocialGraph_V1_RelationStatusView()
            view.actorID = request.actorID
            view.targetID = request.targetID
            view.status = relationStatus(from: request.actorID, to: request.targetID)
            return .success(view)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Follow") { (_: SocialGraph_V1_FollowRequest) in
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unfollow") { (_: SocialGraph_V1_UnfollowRequest) in
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        // Both edge lists derive from the dataset's shared viewer graph, so
        // they, the map's Friends/Following filters, and a client-side
        // following ∩ followers mutual derivation all agree on one truth.
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowers") { [self] (request: SocialGraph_V1_ListFollowersRequest) in
            var response = SocialGraph_V1_ListFollowersResponse()
            response.followers = edges(for: followers(of: subject(request.followeeID)))
            return .success(response)
        }
        // Honors `follower_id`: friend-of-friend suggestions walk a SECOND hop
        // through other authors' follow lists, which a viewer-only answer
        // would collapse to nothing.
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowing") { [self] (request: SocialGraph_V1_ListFollowingRequest) in
            var response = SocialGraph_V1_ListFollowingResponse()
            response.following = edges(for: dataset.followingByProfileID[subject(request.followerID)] ?? [])
            return .success(response)
        }
    }

    /// Whose edges an request is asking for. An EMPTY id means "unspecified",
    /// which resolves to the viewer.
    ///
    /// This is load-bearing, not lenient parsing: `MapFavoritesRepository` has
    /// no viewer resolver yet and deliberately sends empty ids, documenting
    /// that the mock serves the seeded graph for them (on the fleet those
    /// sections stay hidden). Honouring a *specified* id — which the inbox's
    /// friend-of-friend suggestions need for their second hop — must not take
    /// that away.
    private func subject(_ profileID: String) -> String {
        profileID.isEmpty ? MockSocialDataset.viewerProfileID : profileID
    }

    private func relationStatus(from actorID: String, to targetID: String) -> SocialGraph_V1_RelationStatus {
        let follows = dataset.followingByProfileID[actorID]?.contains(targetID) ?? false
        let followedBy = dataset.followingByProfileID[targetID]?.contains(actorID) ?? false
        switch (follows, followedBy) {
        case (true, true): return .mutual
        case (true, false): return .following
        case (false, true): return .followedBy
        case (false, false): return .none
        }
    }

    /// Who follows `profileID`, inverted from the same follow graph — the
    /// viewer's answer stays `followerProfileIDs` by construction.
    private func followers(of profileID: String) -> Set<String> {
        Set(dataset.followingByProfileID.filter { $0.value.contains(profileID) }.map(\.key))
    }

    /// Edges for the given profile ids, in stable author order.
    private func edges(for ids: Set<String>) -> [SocialGraph_V1_EdgeSummary] {
        dataset.authors.filter { ids.contains($0.profileID) }.map { author in
            var edge = SocialGraph_V1_EdgeSummary()
            edge.profileID = author.profileID
            return edge
        }
    }
}
