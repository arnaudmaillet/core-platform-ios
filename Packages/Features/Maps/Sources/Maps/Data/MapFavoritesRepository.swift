import CoreContracts
import CoreModels
import Foundation

/// Sources the filter bar's people lists; implemented by
/// `MapFavoritesRepository`, faked in tests. All methods fail open by
/// contract: an empty list is normal (the bar simply hides the section)
/// and must never block the map.
public protocol MapFavoritesProviding: Sendable {
    /// Hydrates a curated id list (the pinned-favorites store) into
    /// displayable people, preserving order; unresolvable ids are dropped.
    func profiles(for ids: [ProfileID]) async -> [MapFavorite]
    /// The viewer's friends (mutual follows) — the sub-filter row under
    /// the Friends primary.
    func friends() async -> [MapFavorite]
    /// The profiles the viewer follows — the sub-filter row under the
    /// Following primary, and the favorites fallback before any curation.
    func following() async -> [MapFavorite]
}

/// Reads the viewer's people lists from `social_graph.v1` and hydrates names
/// via `profile.v1.GetProfileById`. Phase-1 semantics: favorites = the
/// followed profiles; friends = following ∩ followers (the implicit "mutual"
/// state — `social_graph.v1` has no mutual-list RPC).
///
/// Fleet caveat: both edge lists need the viewer's profile id, which the Maps
/// feature has no resolver for yet — requests go out with an empty
/// follower/followee id, so on the fleet everything resolves empty and the
/// sections stay hidden (consistent with the filter header being
/// fleet-ignored, see `MapFilter`). The mock ignores the ids and serves the
/// seeded graph.
public actor MapFavoritesRepository: MapFavoritesProviding {
    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface

    /// Rail cap: one-row carousels, not full graph lists.
    private static let limit = 12

    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface
    ) {
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
    }

    public func profiles(for ids: [ProfileID]) async -> [MapFavorite] {
        await hydrate(ids: ids.map(\.rawValue))
    }

    public func following() async -> [MapFavorite] {
        await hydrate(ids: followingIDs())
    }

    public func friends() async -> [MapFavorite] {
        // Both edge lists in flight together — the intersection needs both
        // anyway, so serializing them would just sum their latencies.
        async let followers = followerIDs()
        async let following = followingIDs()
        // Following order is preserved; the follower set just gates it.
        let mutuals = await following.filter(await followers.contains)
        return await hydrate(ids: mutuals)
    }

    // MARK: - Edges

    private func followingIDs() async -> [String] {
        var request = SocialGraph_V1_ListFollowingRequest()
        request.limit = Int32(Self.limit)
        let response = await socialGraphClient.listFollowing(request: request, headers: [:])
        guard case .success(let body) = response.result else { return [] }
        return body.following.map(\.profileID).filter { !$0.isEmpty }
    }

    private func followerIDs() async -> Set<String> {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.limit = Int32(Self.limit)
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        guard case .success(let body) = response.result else { return [] }
        return Set(body.followers.map(\.profileID))
    }

    // MARK: - Hydration

    /// All profile lookups in flight concurrently (a serial per-id chain sums
    /// N round trips — the original sub-filter-row lag). Input order is
    /// preserved; a profile that fails to hydrate is dropped, not a blocker.
    private func hydrate(ids: [String]) async -> [MapFavorite] {
        let capped = Array(ids.prefix(Self.limit))
        return await withTaskGroup(of: (Int, MapFavorite?).self) { group in
            for (index, id) in capped.enumerated() {
                group.addTask { (index, await self.fetchProfile(id)) }
            }
            var slots: [MapFavorite?] = Array(repeating: nil, count: capped.count)
            for await (index, favorite) in group { slots[index] = favorite }
            return slots.compactMap(\.self)
        }
    }

    private func fetchProfile(_ id: String) async -> MapFavorite? {
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = id
        let profile = await profileClient.getProfileByID(request: request, headers: [:])
        guard case .success(let view) = profile.result else { return nil }
        let title = view.displayName.isEmpty ? "@\(view.handle)" : view.displayName
        return MapFavorite(
            profileID: ProfileID(id),
            title: title,
            avatarURL: view.avatarURL.isEmpty ? nil : URL(string: view.avatarURL)
        )
    }
}
