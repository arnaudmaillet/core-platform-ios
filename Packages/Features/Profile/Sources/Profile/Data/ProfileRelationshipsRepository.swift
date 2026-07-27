import Connect
import CoreContracts
import CoreModels
import Foundation
import OSLog

/// Which edge list a screen is showing. `social_graph.v1` serves the two
/// directions through separate RPCs, so this is the axis everything below
/// (request, page cursor, empty copy) branches on.
public enum RelationshipDirection: Equatable, Sendable, CaseIterable {
    /// Profiles that follow the subject (`ListFollowers(followee_id:)`).
    case followers
    /// Profiles the subject follows (`ListFollowing(follower_id:)`).
    case following
}

/// One person in a follower / following list, hydrated for display.
///
/// `viewerFollows` is resolved from the *viewer's own* follow set rather than a
/// per-row `GetRelationStatus` — see `ProfileRelationshipsRepository` for why
/// that matters at list scale. `isViewer` marks the viewer's own row, which
/// carries no action button (you cannot follow yourself).
public struct ProfileRelation: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let isVerified: Bool
    public var viewerFollows: Bool
    public let isViewer: Bool

    public init(
        id: ProfileID,
        handle: String,
        displayName: String,
        avatarURL: URL?,
        isVerified: Bool,
        viewerFollows: Bool,
        isViewer: Bool
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.isVerified = isVerified
        self.viewerFollows = viewerFollows
        self.isViewer = isViewer
    }
}

/// One page of an edge list. An empty `nextPageToken` means the list ended —
/// the same cursor contract `social_graph.v1` uses on the wire.
public struct RelationshipPage: Equatable, Sendable {
    public let relations: [ProfileRelation]
    public let nextPageToken: String

    public init(relations: [ProfileRelation], nextPageToken: String) {
        self.relations = relations
        self.nextPageToken = nextPageToken
    }

    public var hasMore: Bool { !nextPageToken.isEmpty }
}

public enum RelationshipsError: Error, Equatable, Sendable {
    case transport(message: String)
    /// The viewer isn't allowed to see this list. Distinct from a transport
    /// failure: it is an *answer*, and the UI shows the private state rather
    /// than a retry affordance.
    case forbidden
}

/// Whether the viewer may see a profile's relationship lists.
///
/// **This is an inference, not a contract.** No API in `profile.v1`,
/// `social_graph.v1`, or `account.v1` describes relationship-list privacy: the
/// list RPCs carry no permission field, and the only privacy signal that exists
/// anywhere is `ProfileView.visibility`, which is whole-profile. So the client
/// derives the rule the platforms converge on — a private profile's social
/// graph is visible to the people inside it — from what it *can* read, and the
/// required contract is specified in `dev/BACKEND_GAPS.md` §13.
///
/// Deliberately conservative in one direction only: it can hide a list the
/// backend would have served, but it can never *show* one the backend refuses —
/// a fleet `PERMISSION_DENIED` maps to `.private` too (see
/// `ProfileRelationshipsRepository.page`), so enforcement landing server-side
/// changes nothing here.
public enum RelationshipListAccess: Equatable, Sendable {
    case visible
    case `private`

    /// - Parameters:
    ///   - subjectVisibility: the listed profile's `profile.v1` visibility.
    ///   - viewerFollowsSubject: whether the viewer is inside the subject's graph.
    ///   - isSelf: whether the viewer is the subject.
    public static func resolve(
        subjectVisibility: ProfileVisibility,
        viewerFollowsSubject: Bool,
        isSelf: Bool
    ) -> RelationshipListAccess {
        // Your own lists are always yours — including the state where a viewer
        // has just made their profile private.
        if isSelf { return .visible }
        guard subjectVisibility.isPrivate else { return .visible }
        // A private profile the viewer already follows behaves like a public
        // one: they are already inside the graph being listed.
        return viewerFollowsSubject ? .visible : .private
    }
}

/// What the relationships screen consumes; faked in view-model tests.
public protocol ProfileRelationshipsProviding: Sendable {
    /// One page of `direction`'s edges for `profileID`. Pass an empty
    /// `pageToken` for the first page.
    func relationships(
        for profileID: ProfileID,
        direction: RelationshipDirection,
        pageToken: String,
        limit: Int32
    ) async throws -> RelationshipPage

    /// Follow (`true`) or unfollow (`false`) a row's profile as the viewer.
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws

    /// Whether `removeFollower` has a backend behind it. False on the fleet
    /// today — `social_graph.v1` has no such RPC — and the UI omits the action
    /// entirely rather than offering a button that cannot work. See
    /// `dev/BACKEND_GAPS.md` §13.
    var supportsFollowerRemoval: Bool { get }

    /// Drops `profileID` from the viewer's own follower list. Only meaningful
    /// when `supportsFollowerRemoval` is true.
    func removeFollower(_ profileID: ProfileID) async throws

    /// Discards any cached viewer state, so a pull-to-refresh re-reads the
    /// viewer's follow set instead of re-deriving rows from a stale one.
    func invalidateViewerCache() async
}

/// Reads follower / following edges from `social_graph.v1` and hydrates them
/// through `profile.v1`.
///
/// **Two fan-out decisions carry this screen.**
///
/// 1. *Hydration is unavoidable, so it is bounded.* `EdgeSummary` carries a
///    profile id and nothing else, and `profile.v1` exposes only singular
///    `GetProfileById` — so a page of N rows costs N profile reads, issued
///    concurrently and reassembled in edge order (a task group completes in
///    arrival order, which would scramble the graph's ranking). Page size is
///    therefore the cost knob, and it is small. A batch read would collapse
///    this to one request — see `dev/BACKEND_GAPS.md` §13.
///
/// 2. *Row follow state is derived, not asked for.* Each row needs "do I follow
///    this person", which `GetRelationStatus` answers one profile at a time —
///    doubling the per-page fan-out. Instead the viewer's own follow set is
///    read **once** (`ListFollowing(viewer)`), cached for the screen's
///    lifetime, and intersected. This is the same trade
///    `SocialConnectionsRepository.followedPeers` makes for the inbox, for the
///    same reason: one request covers a list of any length.
public actor ProfileRelationshipsRepository: ProfileRelationshipsProviding {
    /// How much of the viewer's own follow list is sampled to decide row
    /// states. Beyond this a row can render "Follow" for someone the viewer
    /// already follows — self-correcting on tap, and far cheaper than the
    /// per-row relationship reads it replaces.
    private static let viewerFollowSampleLimit: Int32 = 500

    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let viewer: any ProfileViewerResolving
    public let supportsFollowerRemoval: Bool
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "profile")

    /// The viewer's follow set, resolved once per screen. `nil` = not yet read.
    private var viewerFollowing: Set<String>?

    /// `supportsFollowerRemoval` is injected by the composition root rather
    /// than probed: whether the RPC exists is a property of the *deployment*
    /// (the mock implements it, the fleet does not yet), and discovering that
    /// by calling and failing would burn a request to learn a constant.
    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        viewer: any ProfileViewerResolving,
        supportsFollowerRemoval: Bool
    ) {
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
        self.viewer = viewer
        self.supportsFollowerRemoval = supportsFollowerRemoval
    }

    public func invalidateViewerCache() {
        viewerFollowing = nil
    }

    // MARK: - Pages

    public func relationships(
        for profileID: ProfileID,
        direction: RelationshipDirection,
        pageToken: String,
        limit: Int32
    ) async throws -> RelationshipPage {
        let viewerID = await viewer.viewerProfileID()
        // The edge page and the viewer's follow set are independent reads; the
        // second is cached, so this only actually races on the first page.
        async let edgesTask = edges(for: profileID, direction: direction, pageToken: pageToken, limit: limit)
        async let followingTask = resolveViewerFollowing(viewerID: viewerID)
        let edges = try await edgesTask
        let following = await followingTask

        let relations = await hydrate(edges.ids, viewerID: viewerID, viewerFollowing: following)
        return RelationshipPage(relations: relations, nextPageToken: edges.nextPageToken)
    }

    private func edges(
        for profileID: ProfileID,
        direction: RelationshipDirection,
        pageToken: String,
        limit: Int32
    ) async throws -> (ids: [String], nextPageToken: String) {
        switch direction {
        case .followers:
            var request = SocialGraph_V1_ListFollowersRequest()
            request.followeeID = profileID.rawValue
            request.limit = limit
            request.pageToken = pageToken
            let response = await socialGraphClient.listFollowers(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                return (body.followers.map(\.profileID), body.nextPageToken)
            case .failure(let error):
                throw Self.mapped(error)
            }

        case .following:
            var request = SocialGraph_V1_ListFollowingRequest()
            request.followerID = profileID.rawValue
            request.limit = limit
            request.pageToken = pageToken
            let response = await socialGraphClient.listFollowing(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                return (body.following.map(\.profileID), body.nextPageToken)
            case .failure(let error):
                throw Self.mapped(error)
            }
        }
    }

    /// A refusal is an answer, not an outage: the day the fleet enforces
    /// relationship-list privacy it will land here as `permissionDenied`, and
    /// the screen must show the private state rather than "pull to retry".
    private static func mapped(_ error: ConnectError) -> RelationshipsError {
        if error.code == .permissionDenied { return .forbidden }
        return .transport(message: error.message ?? "code \(error.code)")
    }

    // MARK: - Hydration

    /// Fetches each id's profile concurrently and puts the results back in
    /// **edge order** — the graph's own ranking, which a task group's arrival
    /// order would destroy. Ids whose profile can't be read are dropped: a row
    /// with no name is not a row.
    private func hydrate(
        _ ids: [String],
        viewerID: ProfileID?,
        viewerFollowing: Set<String>
    ) async -> [ProfileRelation] {
        guard !ids.isEmpty else { return [] }
        let client = profileClient

        var byID: [String: Profile_V1_ProfileView] = [:]
        await withTaskGroup(of: Profile_V1_ProfileView?.self) { group in
            for id in ids where !id.isEmpty {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id
                    return (await client.getProfileByID(request: request, headers: [:])).message
                }
            }
            for await view in group {
                if let view, !view.profileID.isEmpty { byID[view.profileID] = view }
            }
        }
        if byID.count < ids.count {
            logger.info("relationship page: \(ids.count - byID.count, privacy: .public) of \(ids.count, privacy: .public) profiles unreadable")
        }

        return ids.compactMap { id in
            guard let view = byID[id] else { return nil }
            return ProfileRelation(
                id: ProfileID(view.profileID),
                handle: view.handle,
                displayName: view.displayName.isEmpty ? view.handle : view.displayName,
                avatarURL: URL(string: view.avatarURL),
                isVerified: view.verified,
                viewerFollows: viewerFollowing.contains(view.profileID),
                isViewer: view.profileID == viewerID?.rawValue
            )
        }
    }

    /// The viewer's follow set, read once per screen. Best-effort: if it can't
    /// be read every row simply renders "Follow", which is recoverable (the
    /// server rejects or no-ops a duplicate follow) where failing the whole
    /// list would not be.
    private func resolveViewerFollowing(viewerID: ProfileID?) async -> Set<String> {
        if let viewerFollowing { return viewerFollowing }
        guard let viewerID else { return [] }

        var request = SocialGraph_V1_ListFollowingRequest()
        request.followerID = viewerID.rawValue
        request.limit = Self.viewerFollowSampleLimit
        let response = await socialGraphClient.listFollowing(request: request, headers: [:])
        guard let body = response.message else {
            logger.info("viewer follow set unavailable; rows default to Follow")
            return []
        }
        let following = Set(body.following.map(\.profileID))
        viewerFollowing = following
        return following
    }

    // MARK: - Mutations

    public func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        guard let viewerID = await viewer.viewerProfileID() else {
            throw RelationshipsError.transport(message: "no viewer profile")
        }
        guard viewerID != profileID else { return } // can't follow yourself

        if following {
            var request = SocialGraph_V1_FollowRequest()
            request.actorID = viewerID.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.follow(request: request, headers: [:]))
        } else {
            var request = SocialGraph_V1_UnfollowRequest()
            request.actorID = viewerID.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unfollow(request: request, headers: [:]))
        }
        // Keep the cached set honest, so a later page of the same screen
        // renders this row's new state rather than the one it was loaded with.
        if following {
            viewerFollowing?.insert(profileID.rawValue)
        } else {
            viewerFollowing?.remove(profileID.rawValue)
        }
    }

    /// Removing a follower is *their* unfollow, issued by the viewer — which is
    /// precisely why it needs its own RPC and cannot be spelled with the ones
    /// that exist: `Unfollow(actor:target:)` is authorized as the actor, and
    /// the client is not that actor here. Block-then-unblock would sever the
    /// edge as a side effect, but it also notifies nothing, drops the reverse
    /// edge, and writes a moderation event for what is not a moderation
    /// action — so it is not done.
    ///
    /// Against a deployment that does implement it (the mock), this issues the
    /// unfollow on the follower's behalf. Against one that doesn't, the UI
    /// never offers the action, so this is unreachable rather than broken.
    public func removeFollower(_ profileID: ProfileID) async throws {
        guard supportsFollowerRemoval else {
            throw RelationshipsError.transport(message: "removing followers isn't available")
        }
        guard let viewerID = await viewer.viewerProfileID() else {
            throw RelationshipsError.transport(message: "no viewer profile")
        }
        var request = SocialGraph_V1_UnfollowRequest()
        request.actorID = profileID.rawValue
        request.targetID = viewerID.rawValue
        try Self.ensureAccepted(await socialGraphClient.unfollow(request: request, headers: [:]))
    }

    private static func ensureAccepted(_ response: ResponseMessage<SocialGraph_V1_CommandResponse>) throws {
        if let error = response.error {
            throw RelationshipsError.transport(message: error.message ?? "code \(error.code)")
        }
        guard response.message?.success == true else {
            throw RelationshipsError.transport(message: "command rejected")
        }
    }
}
