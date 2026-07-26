import Connect
import CoreContracts
import CoreModels
import Foundation

/// Someone the viewer can send a profile to, as the share sheet's quick row
/// renders them.
public struct ProfileShareTarget: Equatable, Sendable {
    public let id: ProfileID
    public let displayName: String
    public let handle: String
    public let avatarURL: URL?

    public init(id: ProfileID, displayName: String, handle: String, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.avatarURL = avatarURL
    }
}

/// Supplies the share sheet's quick-send row.
public protocol ProfileShareTargeting: Sendable {
    /// Up to `limit` people, best candidates first. Best-effort: an empty
    /// result hides the row rather than failing the sheet.
    func shareTargets(limit: Int) async -> [ProfileShareTarget]
}

/// Ranks share targets out of the viewer's social graph.
///
/// **Mutuals first.** A mutual follow is the closest thing this client has to
/// "someone you actually talk to" — the same signal the map's Friends filter
/// and the inbox's suggestions both use — and it is derivable from two edge
/// lists the graph already serves. Remaining follows come after.
///
/// **Not "recent".** Recency would mean recent *conversations*, which live in
/// `chat.v1` behind the Chat feature; Profile emits routes to Chat and never
/// reads from it (the rule `messageTapped` documents). Wiring a chat
/// repository in here to rank a 12-item row would be the wrong trade — so the
/// row is honestly "people you're connected to", ordered by closeness.
public actor ProfileShareTargetsRepository: ProfileShareTargeting {
    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let viewer: any ProfileViewerResolving
    /// Edge sample per direction. Small on purpose: the row shows a dozen, and
    /// the ranking only needs enough of each list to intersect them.
    private static let edgeSampleLimit: Int32 = 100

    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        viewer: any ProfileViewerResolving
    ) {
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
        self.viewer = viewer
    }

    public func shareTargets(limit: Int) async -> [ProfileShareTarget] {
        guard limit > 0, let viewerID = await viewer.viewerProfileID() else { return [] }

        async let followingEdges = following(of: viewerID)
        async let followerEdges = followers(of: viewerID)
        let following = await followingEdges
        let followers = await followerEdges
        guard !following.isEmpty else { return [] }

        // Mutuals lead; the rest of the follow list follows. Both halves sort
        // by id so the row cannot reshuffle between openings of the sheet.
        let mutual = following.intersection(followers).sorted()
        let rest = following.subtracting(followers).sorted()
        let ranked = (mutual + rest).prefix(limit)

        // Hydrated concurrently, then put back in rank order — a task group
        // completes in arrival order, which would scramble the ranking.
        var byID: [String: ProfileShareTarget] = [:]
        await withTaskGroup(of: ProfileShareTarget?.self) { group in
            for id in ranked {
                group.addTask { [weak self] in await self?.target(for: id) }
            }
            for await target in group {
                if let target { byID[target.id.rawValue] = target }
            }
        }
        return ranked.compactMap { byID[$0] }
    }

    private func following(of viewerID: ProfileID) async -> Set<String> {
        var request = SocialGraph_V1_ListFollowingRequest()
        request.followerID = viewerID.rawValue
        request.limit = Self.edgeSampleLimit
        let response = await socialGraphClient.listFollowing(request: request, headers: [:])
        return Set(response.message?.following.map(\.profileID) ?? [])
    }

    private func followers(of viewerID: ProfileID) async -> Set<String> {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.followeeID = viewerID.rawValue
        request.limit = Self.edgeSampleLimit
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        return Set(response.message?.followers.map(\.profileID) ?? [])
    }

    private func target(for profileID: String) async -> ProfileShareTarget? {
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = profileID
        let response = await profileClient.getProfileByID(request: request, headers: [:])
        guard let view = response.message else { return nil }
        return ProfileShareTarget(
            id: ProfileID(view.profileID),
            displayName: view.displayName,
            handle: view.handle,
            avatarURL: URL(string: view.avatarURL)
        )
    }
}

/// Resolves who the viewer is, without this repository re-deriving it (and
/// re-caching it) alongside `ProfileRepository`'s own resolution. Conformed by
/// `ProfileRepository`, which already owns that lookup and its cache — so a
/// profile switch is reflected here for free.
public protocol ProfileViewerResolving: Sendable {
    func viewerProfileID() async -> ProfileID?
}
