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
        bff.register(path: "/social_graph.v1.SocialGraphService/GetRelationStatus") { (request: SocialGraph_V1_GetRelationStatusRequest) in
            var view = SocialGraph_V1_RelationStatusView()
            view.actorID = request.actorID
            view.targetID = request.targetID
            view.status = .none // the viewer doesn't follow them yet → "Follow"
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
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowers") { [self] (_: SocialGraph_V1_ListFollowersRequest) in
            var response = SocialGraph_V1_ListFollowersResponse()
            response.followers = edges(count: 3)
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowing") { [self] (_: SocialGraph_V1_ListFollowingRequest) in
            var response = SocialGraph_V1_ListFollowingResponse()
            response.following = edges(count: 2)
            return .success(response)
        }
    }

    private func edges(count: Int) -> [SocialGraph_V1_EdgeSummary] {
        dataset.authors.prefix(count).map { author in
            var edge = SocialGraph_V1_EdgeSummary()
            edge.profileID = author.profileID
            return edge
        }
    }
}
