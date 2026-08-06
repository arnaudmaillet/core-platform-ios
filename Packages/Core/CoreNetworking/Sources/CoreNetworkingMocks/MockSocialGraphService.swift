import Connect
import CoreContracts
import Foundation

/// Fake of social_graph.v1 over the shared dataset. Enough to make the profile
/// surface work offline: a relation status (so Follow/Message buttons appear),
/// follow/unfollow commands, and follower/following edges (so counts render as
/// numbers rather than "—").
public final class MockSocialGraphService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// Blocks the viewer has placed this session, keyed actor → targets. The
    /// dataset seeds none (a profile screen must open on the ordinary Follow
    /// path), so this exists purely so a block placed from the "..." menu is
    /// visible to the next `GetRelationStatus` — the state the overflow menu
    /// reads to offer Unblock instead of Block.
    private let lock = NSLock()
    private var blocksByActorID: [String: Set<String>] = [:]
    /// Follow edges added and torn down this session, overlaying the dataset's
    /// immutable graph.
    ///
    /// Follow/unfollow used to be accepted and forgotten, which was enough
    /// while the only reader was a button that flipped its own label. The
    /// relationship lists read the graph back — a follow toggled in a row must
    /// survive to the next page, and the followers list's **Remove** is
    /// nothing *but* a graph edit whose whole proof is the row not returning.
    /// The fleet has no `RemoveFollower` RPC (`dev/BACKEND_GAPS.md` §13), so
    /// the mock is the only deployment where that flow can be exercised.
    private var addedEdges: Set<Edge> = []
    private var removedEdges: Set<Edge> = []

    private struct Edge: Hashable {
        let follower: String
        let followee: String
    }

    /// Page size cap for the edge lists, matching the other mocks' ceiling.
    private let pageSizeCap: Int32

    public init(dataset: MockSocialDataset, pageSizeCap: Int32 = 50) {
        self.dataset = dataset
        self.pageSizeCap = pageSizeCap
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
            // The counts the view carries, which used to be left at zero.
            // `counter.v1` does not project follower counts at all
            // (`dev/BACKEND_GAPS.md` §7), so this view is the only place they
            // are answered — and a search row that reads "0 followers" for
            // everybody is worse than one that says nothing.
            view.targetFollowersCount = Int64(followers(of: request.targetID).count)
            view.targetFollowingCount = Int64(following(of: request.targetID).count)
            return .success(view)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Follow") { [self] (request: SocialGraph_V1_FollowRequest) in
            setEdge(true, follower: request.actorID, followee: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        // Unfollow persists, unlike Follow: it is how the followers list's
        // Remove is spelled (the viewer issuing the follower's own unfollow),
        // and the row must not come back on the next page load.
        bff.register(path: "/social_graph.v1.SocialGraphService/Unfollow") { [self] (request: SocialGraph_V1_UnfollowRequest) in
            setEdge(false, follower: request.actorID, followee: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        // Block/Unblock DO persist, unlike follow/unfollow: the profile's
        // overflow menu reads the resulting relation status back to decide
        // which of Block / Unblock it offers, so a mock that forgot the block
        // would keep offering Block on a profile the viewer just blocked.
        bff.register(path: "/social_graph.v1.SocialGraphService/Block") { [self] (request: SocialGraph_V1_BlockRequest) in
            setBlocked(true, actorID: request.actorID, targetID: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unblock") { [self] (request: SocialGraph_V1_UnblockRequest) in
            setBlocked(false, actorID: request.actorID, targetID: request.targetID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        // Both edge lists derive from the dataset's shared viewer graph, so
        // they, the map's Friends/Following filters, and a client-side
        // following ∩ followers mutual derivation all agree on one truth.
        //
        // Both honor `limit` + `page_token`: the follower / following screen
        // pages, and a mock that served the whole graph at once would leave
        // its cursor handling — and its paging spinner — unexercised.
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowers") { [self] (request: SocialGraph_V1_ListFollowersRequest) in
            let all = edges(for: followers(of: subject(request.followeeID)))
            return page(all, limit: request.limit, token: request.pageToken).map { slice, next in
                var response = SocialGraph_V1_ListFollowersResponse()
                response.followers = slice
                response.nextPageToken = next
                return response
            }
        }
        // Honors `follower_id`: friend-of-friend suggestions walk a SECOND hop
        // through other authors' follow lists, which a viewer-only answer
        // would collapse to nothing.
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowing") { [self] (request: SocialGraph_V1_ListFollowingRequest) in
            let all = edges(for: following(of: subject(request.followerID)))
            return page(all, limit: request.limit, token: request.pageToken).map { slice, next in
                var response = SocialGraph_V1_ListFollowingResponse()
                response.following = slice
                response.nextPageToken = next
                return response
            }
        }
    }

    /// Cursor pagination over a stable list, matching the other mocks: the page
    /// token is the offset, and an empty `next` means the list ended.
    private func page(
        _ all: [SocialGraph_V1_EdgeSummary], limit: Int32, token: String
    ) -> Result<([SocialGraph_V1_EdgeSummary], String), ConnectError> {
        let start = Int(token) ?? 0
        let size = Int(min(max(limit, 1), pageSizeCap))
        guard start >= 0, start <= all.count else {
            return .failure(ConnectError(code: .invalidArgument, message: "bad page token"))
        }
        let end = min(start + size, all.count)
        return .success((Array(all[start..<end]), end < all.count ? String(end) : ""))
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

    private func setBlocked(_ blocked: Bool, actorID: String, targetID: String) {
        lock.withLock {
            if blocked {
                blocksByActorID[actorID, default: []].insert(targetID)
            } else {
                blocksByActorID[actorID]?.remove(targetID)
            }
        }
    }

    private func isBlocking(actorID: String, targetID: String) -> Bool {
        lock.withLock { blocksByActorID[actorID]?.contains(targetID) ?? false }
    }

    private func setEdge(_ exists: Bool, follower: String, followee: String) {
        let edge = Edge(follower: follower, followee: followee)
        lock.withLock {
            if exists {
                addedEdges.insert(edge)
                removedEdges.remove(edge)
            } else {
                removedEdges.insert(edge)
                addedEdges.remove(edge)
            }
        }
    }

    /// Whether `follower` follows `followee` right now — the seeded graph as
    /// amended by this session's follows and unfollows. Every read below goes
    /// through here, so the relation status, both edge lists, and the map's
    /// filters can never disagree about an edge the viewer just changed.
    private func follows(_ follower: String, _ followee: String) -> Bool {
        let edge = Edge(follower: follower, followee: followee)
        let (added, removed) = lock.withLock { (addedEdges.contains(edge), removedEdges.contains(edge)) }
        if removed { return false }
        if added { return true }
        return dataset.followingByProfileID[follower]?.contains(followee) ?? false
    }

    private func relationStatus(from actorID: String, to targetID: String) -> SocialGraph_V1_RelationStatus {
        // Blocking outranks the follow states, matching the contract: a block
        // tears the edges down, so the wire never reports both.
        if isBlocking(actorID: actorID, targetID: targetID) { return .blocking }
        if isBlocking(actorID: targetID, targetID: actorID) { return .blockedBy }
        let isFollowing = follows(actorID, targetID)
        let isFollowedBy = follows(targetID, actorID)
        switch (isFollowing, isFollowedBy) {
        case (true, true): return .mutual
        case (true, false): return .following
        case (false, true): return .followedBy
        case (false, false): return .none
        }
    }

    /// Who follows `profileID`, inverted from the same follow graph — the
    /// viewer's answer stays `followerProfileIDs` by construction. Candidates
    /// come from the seeded graph plus anyone this session added an edge for,
    /// and each is re-checked through `follows` so a removal takes effect.
    private func followers(of profileID: String) -> Set<String> {
        var candidates = Set(dataset.followingByProfileID.keys)
        candidates.formUnion(lock.withLock { addedEdges.map(\.follower) })
        return candidates.filter { follows($0, profileID) }
    }

    /// Who `profileID` follows, under the same session overlay.
    private func following(of profileID: String) -> Set<String> {
        var candidates = dataset.followingByProfileID[profileID] ?? []
        candidates.formUnion(lock.withLock {
            addedEdges.filter { $0.follower == profileID }.map(\.followee)
        })
        return candidates.filter { follows(profileID, $0) }
    }

    /// Edges for the given profile ids, in stable author order.
    ///
    /// The viewer leads when present. They were previously dropped altogether —
    /// `dataset.authors` doesn't contain them — which was invisible while these
    /// lists only fed counts and set intersections, but shows up the moment the
    /// edges are rendered as rows: the viewer follows twelve authors, so their
    /// own face belongs in those authors' follower lists, and the screen has a
    /// dedicated no-action state for exactly that row.
    private func edges(for ids: Set<String>) -> [SocialGraph_V1_EdgeSummary] {
        func edge(_ profileID: String) -> SocialGraph_V1_EdgeSummary {
            var edge = SocialGraph_V1_EdgeSummary()
            edge.profileID = profileID
            return edge
        }
        let viewer = ids.contains(MockSocialDataset.viewerProfileID)
            ? [edge(MockSocialDataset.viewerProfileID)]
            : []
        return viewer + dataset.authors
            .filter { ids.contains($0.profileID) }
            .map { edge($0.profileID) }
    }
}
