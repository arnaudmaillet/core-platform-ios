import AuthInterface
import Connect
import CoreContracts
import CoreModels
import Foundation
import OSLog

public enum ProfileError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case notFound
    case transport(message: String)
}

/// A follower/following count. Modelled as an estimate, not a bare number,
/// because the two sources disagree in shape:
///
/// - `counter.v1` is the O(1) read-model and returns an exact value — *when it
///   has projected one*. Today the fleet's counter-worker does not project
///   profile follower/following (see `dev/BACKEND_GAPS.md`), so this is often
///   absent.
/// - the `social_graph.v1` fallback derives the count from a bounded page of
///   edges: exact when the page is the whole set, `atLeast` when there are more.
///
/// `unavailable` (rendered "—") is distinct from `exact(0)` (rendered "0"): a
/// user with no followers is not the same as a counter we couldn't read.
public enum CountEstimate: Equatable, Sendable {
    case exact(Int64)
    case atLeast(Int64)
    case unavailable

    /// Derives an estimate from a sampled page of graph edges.
    static func fromSample(count: Int, hasMore: Bool) -> CountEstimate {
        hasMore ? .atLeast(Int64(count)) : .exact(Int64(count))
    }

    /// Nudges a known count by `delta` (never below zero) for optimistic
    /// follow/unfollow updates. An `unavailable` count stays "—".
    func adjusted(by delta: Int64) -> CountEstimate {
        switch self {
        case .exact(let value): .exact(max(0, value + delta))
        case .atLeast(let value): .atLeast(max(0, value + delta))
        case .unavailable: .unavailable
        }
    }
}

/// The viewer's relationship to a profile, driving the header's action button.
public enum ProfileRelationship: Equatable, Sendable {
    /// The profile belongs to the signed-in viewer → "Edit Profile".
    case me
    /// Someone else's profile → Follow / Following toggle.
    case other(isFollowing: Bool)
}

/// A fully-resolved public profile plus its social-graph counters, ready for
/// the presentation layer.
public struct UserProfile: Equatable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let bio: String
    public let avatarURL: URL?
    public let websiteURL: URL?
    public let isVerified: Bool
    public let followerCount: CountEstimate
    public let followingCount: CountEstimate

    public init(
        id: ProfileID,
        handle: String,
        displayName: String,
        bio: String,
        avatarURL: URL?,
        websiteURL: URL?,
        isVerified: Bool,
        followerCount: CountEstimate,
        followingCount: CountEstimate
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.avatarURL = avatarURL
        self.websiteURL = websiteURL
        self.isVerified = isVerified
        self.followerCount = followerCount
        self.followingCount = followingCount
    }
}

/// What the profile UI consumes; implemented by `ProfileRepository`, faked in
/// view-model tests.
public protocol ProfileProviding: Sendable {
    /// The signed-in viewer's own profile, resolved from the auth session.
    func currentUserProfile() async throws -> UserProfile
    /// Any profile by id — used when routing to another user's profile.
    func profile(id: ProfileID) async throws -> UserProfile
    /// The viewer's relationship to `profileID` (own profile vs. follow state).
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship
    /// Follow (`true`) or unfollow (`false`) `profileID` as the viewer.
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws
}

/// Reads the viewer's identity and social counters from profile.v1, counter.v1,
/// and (as a fallback) social_graph.v1.
///
/// Viewer resolution mirrors the feed's: the contracts expose only
/// `ListProfilesByAccount` + singular `GetProfileById`, so we resolve
/// account → first profile → full view.
///
/// Counts prefer `counter.v1` (O(1), the correct long-term read-model). Because
/// that projection is not yet live on the fleet, an empty counter falls back to
/// counting `social_graph.v1` edges so real counts still render today; the fast
/// path takes over automatically once the backend projects. See
/// `dev/BACKEND_GAPS.md` §7.
public actor ProfileRepository: ProfileProviding {
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let counterClient: any Counter_V1_CounterServiceClientInterface
    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let authSession: any AuthSessionProviding
    /// Upper bound on edges sampled for the fallback count; beyond it the count
    /// is reported as `atLeast(limit)` rather than paginating the whole graph.
    private let edgeSampleLimit: Int32
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "profile")

    private var viewerProfileID: ProfileID?

    public init(
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        authSession: any AuthSessionProviding,
        edgeSampleLimit: Int32 = 200
    ) {
        self.profileClient = profileClient
        self.counterClient = counterClient
        self.socialGraphClient = socialGraphClient
        self.authSession = authSession
        self.edgeSampleLimit = edgeSampleLimit
    }

    // MARK: - ProfileProviding

    public func currentUserProfile() async throws -> UserProfile {
        let id = try await resolveViewerProfileID()
        return try await loadProfile(id: id)
    }

    public func profile(id: ProfileID) async throws -> UserProfile {
        try await loadProfile(id: id)
    }

    // MARK: - Relationship

    public func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        let viewer = try await resolveViewerProfileID()
        // The viewer's own profile (whether reached via the tab or by routing to
        // your own id) offers Edit, never Follow.
        guard viewer != profileID else { return .me }

        var request = SocialGraph_V1_GetRelationStatusRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.getRelationStatus(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            // `.mutual` also means the viewer follows the target.
            let isFollowing = view.status == .following || view.status == .mutual
            return .other(isFollowing: isFollowing)
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID()
        guard viewer != profileID else { return } // no-op: can't follow yourself

        if following {
            var request = SocialGraph_V1_FollowRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.follow(request: request, headers: [:]))
        } else {
            var request = SocialGraph_V1_UnfollowRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unfollow(request: request, headers: [:]))
        }
    }

    /// Throws unless the command round-tripped and the server accepted it.
    private static func ensureAccepted(_ response: ResponseMessage<SocialGraph_V1_CommandResponse>) throws {
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
        guard response.message?.success == true else {
            throw ProfileError.transport(message: "command rejected")
        }
    }

    /// Fetches the profile view and its social counters concurrently.
    private func loadProfile(id: ProfileID) async throws -> UserProfile {
        async let viewResult = fetchProfileView(id: id)
        async let counts = fetchSocialCounts(for: id)
        let view = try await viewResult
        let (followers, following) = await counts
        return Self.makeProfile(from: view, followerCount: followers, followingCount: following)
    }

    // MARK: - Profile view

    private func fetchProfileView(id: ProfileID) async throws -> Profile_V1_ProfileView {
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = id.rawValue
        let response = await profileClient.getProfileByID(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            return view
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    private func resolveViewerProfileID() async throws -> ProfileID {
        if let viewerProfileID {
            return viewerProfileID
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ProfileError.notAuthenticated
        }

        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            guard let profile = body.profiles.first else {
                throw ProfileError.noProfileForAccount
            }
            let id = ProfileID(profile.profileID)
            viewerProfileID = id
            return id
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Social counters

    /// Best-effort: an outage in *both* sources degrades to `.unavailable`
    /// (rendered "—") rather than failing the whole profile load. The counter
    /// read is one round-trip; the social-graph fallbacks fire only for metrics
    /// the counter didn't already answer, and run concurrently.
    private func fetchSocialCounts(for id: ProfileID) async -> (followers: CountEstimate, following: CountEstimate) {
        let counter = await counterEstimates(for: id)
        async let followers = resolve(counter.followers, fallback: { await self.followerFallback(for: id) })
        async let following = resolve(counter.following, fallback: { await self.followingFallback(for: id) })
        return await (followers, following)
    }

    /// Prefer the counter estimate; otherwise run the (async) social-graph fallback.
    private func resolve(_ primary: CountEstimate?, fallback: () async -> CountEstimate) async -> CountEstimate {
        if let primary { return primary }
        return await fallback()
    }

    /// Reads counter.v1. Returns `nil` per metric when the read-model has no
    /// value for it (the signal to fall back), not `.unavailable`.
    private func counterEstimates(for id: ProfileID) async -> (followers: CountEstimate?, following: CountEstimate?) {
        var entity = Counter_V1_EntityRef()
        entity.entityType = .profile
        entity.id = id.rawValue

        var request = Counter_V1_BatchGetCountersRequest()
        request.entities = [entity]
        request.metrics = [.follower, .following]

        let response = await counterClient.batchGetCounters(request: request, headers: [:])
        guard let snapshot = response.message?.snapshots.first else {
            return (nil, nil)
        }
        let followers = snapshot.values.first { $0.metric == .follower }.map { CountEstimate.exact($0.value) }
        let following = snapshot.values.first { $0.metric == .following }.map { CountEstimate.exact($0.value) }
        return (followers, following)
    }

    private func followerFallback(for id: ProfileID) async -> CountEstimate {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.followeeID = id.rawValue
        request.limit = edgeSampleLimit
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        guard let body = response.message else {
            logger.info("follower count unavailable for \(id.rawValue, privacy: .public)")
            return .unavailable
        }
        return .fromSample(count: body.followers.count, hasMore: !body.nextPageToken.isEmpty)
    }

    private func followingFallback(for id: ProfileID) async -> CountEstimate {
        var request = SocialGraph_V1_ListFollowingRequest()
        request.followerID = id.rawValue
        request.limit = edgeSampleLimit
        let response = await socialGraphClient.listFollowing(request: request, headers: [:])
        guard let body = response.message else {
            logger.info("following count unavailable for \(id.rawValue, privacy: .public)")
            return .unavailable
        }
        return .fromSample(count: body.following.count, hasMore: !body.nextPageToken.isEmpty)
    }

    private static func makeProfile(
        from view: Profile_V1_ProfileView,
        followerCount: CountEstimate,
        followingCount: CountEstimate
    ) -> UserProfile {
        UserProfile(
            id: ProfileID(view.profileID),
            handle: view.handle,
            displayName: view.displayName,
            bio: view.bio,
            avatarURL: URL(string: view.avatarURL),
            websiteURL: URL(string: view.websiteURL),
            isVerified: view.verified,
            followerCount: followerCount,
            followingCount: followingCount
        )
    }
}
