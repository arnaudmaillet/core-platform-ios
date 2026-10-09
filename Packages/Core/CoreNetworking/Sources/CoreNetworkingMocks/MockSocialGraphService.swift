import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of social_graph.v1 over the shared dataset. Enough to make the profile
/// surface work offline: a relation status (so Follow/Message buttons appear),
/// follow/unfollow commands, follower/following edges (so counts render as
/// numbers rather than "—"), and follow requests for private profiles
/// (backend #655: following a private profile asks, and only the owner's
/// approval makes the edge).
public final class MockSocialGraphService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// Blocks the viewer has placed this session, keyed actor → targets. The
    /// dataset seeds none (a profile screen must open on the ordinary Follow
    /// path), so this exists purely so a block placed from the "..." menu is
    /// visible to the next `GetRelationStatus` — the state the overflow menu
    /// reads to offer Unblock instead of Block.
    private let lock = NSLock()
    private var blocksByActorID: [String: Set<String>] = [:]
    /// When each block was placed ("actor|target"), for `ListBlocks`.
    private var blockDates: [String: Date] = [:]
    /// Follow edges added and torn down this session, overlaying the dataset's
    /// immutable graph.
    ///
    /// Follow/unfollow used to be accepted and forgotten, which was enough
    /// while the only reader was a button that flipped its own label. The
    /// relationship lists read the graph back — a follow toggled in a row must
    /// survive to the next page, and the followers list's **Remove**
    /// (`RemoveFollower`) is nothing *but* a graph edit whose whole proof is
    /// the row not returning.
    private var addedEdges: Set<Edge> = []
    private var removedEdges: Set<Edge> = []
    /// Pending follow requests, requester → private target, with when they
    /// were asked. A request is not an edge: no list, count or relation
    /// status other than `.requested` sees it.
    private var requests: [Edge: Date] = [:]
    /// Whether a profile is private right now; profile.v1 owns that flag.
    private let isPrivate: @Sendable (String) -> Bool
    /// Whether a profile turned "appear in suggestions" on; profile.v1 owns
    /// that flag too.
    private let isSuggestible: @Sendable (String) -> Bool
    /// Restrictions, owner → restricted, with when (backend #724).
    private var restrictions: [Edge: Date] = [:]
    /// Mutes, muter → muted, with their scopes and when (backend #722).
    private var mutes: [Edge: (scopes: SocialGraph_V1_MuteScopes, at: Date)] = [:]
    /// Who else may see each profile's followers / following lists
    /// (backend #720). Absent means Everyone.
    private var listPrivacy: [String: SocialGraph_V1_ListPrivacy] = [:]
    /// The viewer's account's profiles: their own lists are always theirs.
    private let viewerProfileIDs: Set<String>

    private struct Edge: Hashable {
        let follower: String
        let followee: String
    }

    /// Page size cap for the edge lists, matching the other mocks' ceiling.
    private let pageSizeCap: Int32

    /// `seedsFollowRequests` gives the viewer three pending requests from
    /// authors who don't follow them, so the requests inbox can be seen filled.
    public init(
        dataset: MockSocialDataset,
        pageSizeCap: Int32 = 50,
        isPrivate: @escaping @Sendable (String) -> Bool = { _ in false },
        isSuggestible: @escaping @Sendable (String) -> Bool = { _ in true },
        seedsFollowRequests: Bool = false
    ) {
        self.dataset = dataset
        self.pageSizeCap = pageSizeCap
        self.isPrivate = isPrivate
        self.isSuggestible = isSuggestible
        self.viewerProfileIDs = Set(dataset.profileIDs(inAccount: MockAuthService.accountID))
        // One public author the viewer doesn't follow keeps their following
        // list to themself, so a hidden list can be seen without setup.
        let viewerFollowsSeed = dataset.followingByProfileID[MockSocialDataset.viewerProfileID] ?? []
        if let hider = dataset.authors.map(\.profileID).first(where: { id in
            !dataset.isRelationshipsPrivate(id) && !viewerFollowsSeed.contains(id) && id != "prof-4"
        }) {
            var privacy = SocialGraph_V1_ListPrivacy()
            privacy.followers = .everyone
            privacy.following = .onlyMe
            listPrivacy[hider] = privacy
        }
        if seedsFollowRequests {
            let viewer = MockSocialDataset.viewerProfileID
            let strangers = dataset.authors.map(\.profileID).filter { id in
                !dataset.followerProfileIDs.contains(id)
                    && !(dataset.followingByProfileID[viewer]?.contains(id) ?? false)
            }
            for (index, requester) in strangers.prefix(3).enumerated() {
                let hoursAgo = [1.0, 26, 74][index]
                requests[Edge(follower: requester, followee: viewer)] = Date().addingTimeInterval(-hoursAgo * 3_600)
            }
        }
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
            // How the actor mutes the target, so the profile can offer Unmute.
            view.muted = lock.withLock { mutes[Edge(follower: request.actorID, followee: request.targetID)]?.scopes }
                ?? SocialGraph_V1_MuteScopes()
            view.restricted = lock.withLock { restrictions[Edge(follower: request.actorID, followee: request.targetID)] != nil }
            // The counts the view carries, which used to be left at zero.
            // `counter.v1` does not project follower counts at all
            // (`dev/BACKEND_GAPS.md` §7), so this view is the only place they
            // are answered — and a search row that reads "0 followers" for
            // everybody is worse than one that says nothing.
            view.targetFollowersCount = Int64(followers(of: request.targetID).count)
            view.targetFollowingCount = Int64(following(of: request.targetID).count)
            return .success(view)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/SuggestProfiles") { [self] (request: SocialGraph_V1_SuggestProfilesRequest) in
            var response = SocialGraph_V1_SuggestProfilesResponse()
            response.profiles = suggestions(for: subject(request.profileID), limit: request.limit)
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Follow") { [self] (request: SocialGraph_V1_FollowRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            response.actorID = request.actorID
            response.targetID = request.targetID
            let edge = Edge(follower: request.actorID, followee: request.targetID)
            // Someone who blocks the actor can't be followed (#726), as on
            // the fleet.
            if lock.withLock({ blocksByActorID[request.targetID]?.contains(request.actorID) == true }) {
                return .failure(ConnectError(code: .permissionDenied, message: "SGR-1003: blocked"))
            }
            // A private profile is asked, not followed — unless the edge
            // already exists. Following a now-public profile clears an old
            // request, as on the fleet.
            if isPrivate(request.targetID), !follows(request.actorID, request.targetID) {
                let pending = lock.withLock { requests[edge] != nil }
                if pending {
                    return .failure(ConnectError(code: .alreadyExists, message: "SGR-1005: follow request already pending"))
                }
                lock.withLock { requests[edge] = Date() }
                response.requested = true
                return .success(response)
            }
            lock.withLock { requests[edge] = nil }
            setEdge(true, follower: request.actorID, followee: request.targetID)
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowRequests") { [self] (request: SocialGraph_V1_ListFollowRequestsRequest) in
            let inbox = lock.withLock {
                requests.filter { $0.key.followee == request.ownerID }
                    .sorted { $0.value > $1.value }
                    .map { edge, date in
                        var summary = SocialGraph_V1_EdgeSummary()
                        summary.profileID = edge.follower
                        summary.followedAt = .init(date: date)
                        return summary
                    }
            }
            return page(inbox, limit: request.limit == 0 ? 20 : request.limit, token: request.pageToken).map { slice, next in
                var response = SocialGraph_V1_ListFollowRequestsResponse()
                response.requests = slice
                response.nextPageToken = next
                return response
            }
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ApproveFollowRequest") { [self] (request: SocialGraph_V1_AnswerFollowRequestRequest) in
            answer(request, approve: true)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/DeclineFollowRequest") { [self] (request: SocialGraph_V1_AnswerFollowRequestRequest) in
            answer(request, approve: false)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/CancelFollowRequest") { [self] (request: SocialGraph_V1_CancelFollowRequestRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            let edge = Edge(follower: request.actorID, followee: request.targetID)
            let removed = lock.withLock { requests.removeValue(forKey: edge) != nil }
            guard removed else {
                return .failure(ConnectError(code: .failedPrecondition, message: "SGR-1006: no follow request pending"))
            }
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
        bff.register(path: "/social_graph.v1.SocialGraphService/ListBlocks") { [self] (request: SocialGraph_V1_ListBlocksRequest) in
            listBlocks(request)
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
        bff.register(path: "/social_graph.v1.SocialGraphService/Restrict") { [self] (request: SocialGraph_V1_RestrictRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            guard request.actorID != request.targetID else {
                return .failure(ConnectError(code: .invalidArgument, message: "SGR-2001: cannot restrict oneself"))
            }
            lock.withLock {
                let edge = Edge(follower: request.actorID, followee: request.targetID)
                if restrictions[edge] == nil { restrictions[edge] = Date() }
            }
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unrestrict") { [self] (request: SocialGraph_V1_UnrestrictRequest) in
            lock.withLock { restrictions[Edge(follower: request.actorID, followee: request.targetID)] = nil }
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListRestricted") { [self] (request: SocialGraph_V1_ListRestrictedRequest) in
            // Profile-id order, as on the fleet; one page.
            var response = SocialGraph_V1_ListRestrictedResponse()
            response.restricted = lock.withLock {
                restrictions.filter { $0.key.follower == request.profileID }
                    .sorted { $0.key.followee < $1.key.followee }
                    .map { edge, date in
                        var summary = SocialGraph_V1_RestrictedSummary()
                        summary.profileID = edge.followee
                        summary.restrictedAt = .init(date: date)
                        return summary
                    }
            }
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Mute") { [self] (request: SocialGraph_V1_MuteRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            guard request.actorID != request.targetID else {
                return .failure(ConnectError(code: .invalidArgument, message: "SGR-2001: cannot mute oneself"))
            }
            let scopes = request.scopes
            guard scopes.posts || scopes.stories || scopes.messages else {
                return .failure(ConnectError(code: .invalidArgument, message: "SGR-9001: at least one scope is required"))
            }
            // Re-muting replaces the scopes.
            lock.withLock { mutes[Edge(follower: request.actorID, followee: request.targetID)] = (scopes, Date()) }
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/Unmute") { [self] (request: SocialGraph_V1_UnmuteRequest) in
            // Idempotent.
            lock.withLock { mutes[Edge(follower: request.actorID, followee: request.targetID)] = nil }
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListMutes") { [self] (request: SocialGraph_V1_ListMutesRequest) -> Result<SocialGraph_V1_ListMutesResponse, ConnectError> in
            // Profile-id order, as on the fleet.
            let all = lock.withLock {
                mutes.filter { $0.key.follower == request.profileID }
                    .sorted { $0.key.followee < $1.key.followee }
                    .map { edge, mute in
                        var summary = SocialGraph_V1_MuteSummary()
                        summary.profileID = edge.followee
                        summary.scopes = mute.scopes
                        summary.mutedAt = .init(date: mute.at)
                        return summary
                    }
            }
            let start = Int(request.pageToken) ?? 0
            let size = Int(min(max(request.limit == 0 ? 50 : request.limit, 1), pageSizeCap))
            guard start >= 0, start <= all.count else {
                return .failure(ConnectError(code: .invalidArgument, message: "bad page token"))
            }
            let end = min(start + size, all.count)
            var response = SocialGraph_V1_ListMutesResponse()
            response.mutes = Array(all[start..<end])
            response.nextPageToken = end < all.count ? String(end) : ""
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/RemoveFollower") { [self] (request: SocialGraph_V1_RemoveFollowerRequest) -> Result<SocialGraph_V1_CommandResponse, ConnectError> in
            guard follows(request.followerID, request.profileID) else {
                return .failure(ConnectError(code: .notFound, message: "SGR-1002: not a follower"))
            }
            // The follower's own unfollow, as on the fleet; they aren't told.
            setEdge(false, follower: request.followerID, followee: request.profileID)
            var response = SocialGraph_V1_CommandResponse()
            response.success = true
            response.actorID = request.profileID
            response.targetID = request.followerID
            return .success(response)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/GetListPrivacy") { [self] (request: SocialGraph_V1_GetListPrivacyRequest) in
            .success(storedListPrivacy(for: request.profileID))
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/SetListPrivacy") { [self] (request: SocialGraph_V1_SetListPrivacyRequest) in
            // Unspecified keeps that list's audience.
            let privacy = lock.withLock {
                var privacy = listPrivacy[request.profileID] ?? Self.everyone
                if request.followers != .unspecified { privacy.followers = request.followers }
                if request.following != .unspecified { privacy.following = request.following }
                listPrivacy[request.profileID] = privacy
                return privacy
            }
            return .success(privacy)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/ListFollowers") { [self] (request: SocialGraph_V1_ListFollowersRequest) in
            guard mayRead(\.followers, of: subject(request.followeeID)) else {
                var response = SocialGraph_V1_ListFollowersResponse()
                response.hidden = true
                return .success(response)
            }
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
            guard mayRead(\.following, of: subject(request.followerID)) else {
                var response = SocialGraph_V1_ListFollowingResponse()
                response.hidden = true
                return .success(response)
            }
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
    /// sections stay hidden). Honouring a *specified* id — which a profile's
    /// relationship lists and `SuggestProfiles` need — must not take that
    /// away.
    private func subject(_ profileID: String) -> String {
        profileID.isEmpty ? MockSocialDataset.viewerProfileID : profileID
    }

    private static let everyone: SocialGraph_V1_ListPrivacy = {
        var privacy = SocialGraph_V1_ListPrivacy()
        privacy.followers = .everyone
        privacy.following = .everyone
        return privacy
    }()

    private func storedListPrivacy(for profileID: String) -> SocialGraph_V1_ListPrivacy {
        lock.withLock { listPrivacy[profileID] } ?? Self.everyone
    }

    /// The list gate (backend #720), for the viewer as reader: the owner's
    /// account always reads; anyone else needs content access (no block, and
    /// following a private profile) and a place in the list's audience.
    private func mayRead(_ list: KeyPath<SocialGraph_V1_ListPrivacy, SocialGraph_V1_ListAudience>, of owner: String) -> Bool {
        if viewerProfileIDs.contains(owner) { return true }
        let reader = MockSocialDataset.viewerProfileID
        if isBlocking(actorID: owner, targetID: reader) || isBlocking(actorID: reader, targetID: owner) { return false }
        let readerFollows = follows(reader, owner)
        if isPrivate(owner), !readerFollows { return false }
        switch storedListPrivacy(for: owner)[keyPath: list] {
        case .everyone, .unspecified, .UNRECOGNIZED: return true
        case .followers: return readerFollows
        case .mutuals: return readerFollows && follows(owner, reader)
        case .onlyMe: return false
        }
    }

    /// Approve makes the edge; decline drops the request and tells no one.
    private func answer(
        _ request: SocialGraph_V1_AnswerFollowRequestRequest, approve: Bool
    ) -> Result<SocialGraph_V1_CommandResponse, ConnectError> {
        let edge = Edge(follower: request.requesterID, followee: request.ownerID)
        let removed = lock.withLock { requests.removeValue(forKey: edge) != nil }
        guard removed else {
            return .failure(ConnectError(code: .failedPrecondition, message: "SGR-1006: no follow request pending"))
        }
        if approve { setEdge(true, follower: request.requesterID, followee: request.ownerID) }
        var response = SocialGraph_V1_CommandResponse()
        response.success = true
        response.actorID = request.ownerID
        response.targetID = request.requesterID
        return .success(response)
    }

    private func setBlocked(_ blocked: Bool, actorID: String, targetID: String) {
        lock.withLock {
            if blocked {
                // A block drops pending requests both ways.
                requests[Edge(follower: actorID, followee: targetID)] = nil
                requests[Edge(follower: targetID, followee: actorID)] = nil
                blocksByActorID[actorID, default: []].insert(targetID)
                blockDates["\(actorID)|\(targetID)"] = Date()
            } else {
                blocksByActorID[actorID]?.remove(targetID)
                blockDates["\(actorID)|\(targetID)"] = nil
            }
        }
    }

    /// Newest first, one page: the viewer's block list is small, so the mock
    /// never hands out a page token.
    private func listBlocks(_ request: SocialGraph_V1_ListBlocksRequest) -> Result<SocialGraph_V1_ListBlocksResponse, ConnectError> {
        lock.withLock {
            var response = SocialGraph_V1_ListBlocksResponse()
            response.blocks = (blocksByActorID[request.blockerID] ?? [])
                .map { target in (target, blockDates["\(request.blockerID)|\(target)"] ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .map { target, date in
                    var summary = SocialGraph_V1_BlockSummary()
                    summary.blockeeID = target
                    summary.blockedAt = .init(date: date)
                    return summary
                }
            return .success(response)
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
    /// Whether `follower` follows `followee` now, for the other mocks'
    /// interaction checks (backend `CheckInteraction`).
    public func isFollowing(_ follower: String, _ followee: String) -> Bool {
        follows(follower, followee)
    }

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
        case (false, false):
            let pending = lock.withLock { requests[Edge(follower: actorID, followee: targetID)] != nil }
            return pending ? .requested : .none
        }
    }

    /// `SuggestProfiles` as the fleet answers it (backend #661): the profiles
    /// the profiles `profileID` follows follow, ranked by how many of them do,
    /// ties on id; without oneself, those already followed, a block either
    /// way, private profiles, and anyone with "appear in suggestions" off. At
    /// most 50; 0 means 20.
    private func suggestions(for profileID: String, limit: Int32) -> [SocialGraph_V1_SuggestedProfile] {
        let size = limit == 0 ? 20 : Int(min(max(limit, 1), 50))
        let followed = following(of: profileID)
        var counts: [String: UInt32] = [:]
        for source in followed {
            for candidate in following(of: source) { counts[candidate, default: 0] += 1 }
        }
        return counts
            .filter { candidate, _ in
                candidate != profileID
                    && !followed.contains(candidate)
                    && !isBlocking(actorID: profileID, targetID: candidate)
                    && !isBlocking(actorID: candidate, targetID: profileID)
                    && !isPrivate(candidate)
                    && isSuggestible(candidate)
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(size)
            .map { candidate, mutuals in
                var suggestion = SocialGraph_V1_SuggestedProfile()
                suggestion.profileID = candidate
                suggestion.mutualCount = mutuals
                return suggestion
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
