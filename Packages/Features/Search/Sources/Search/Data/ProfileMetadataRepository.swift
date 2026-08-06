import CoreContracts
import CoreModels
import Foundation

/// What a person row shows beyond the name the search response gave it.
public struct ProfileRowMetadata: Equatable, Sendable {
    public let avatarURL: URL?
    /// Whether the viewer follows them. `.mutual` counts: it is still a follow
    /// from the viewer's side, which is what the row is saying.
    public let isFollowed: Bool
    /// `nil` when the read-model had nothing — the row says nothing rather
    /// than claiming zero followers.
    public let followerCount: Int?

    public init(avatarURL: URL?, isFollowed: Bool, followerCount: Int?) {
        self.avatarURL = avatarURL
        self.isFollowed = isFollowed
        self.followerCount = followerCount
    }
}

/// Resolves people to their pictures and their social context.
///
/// **Why this exists at all.** Only one of the search screen's three person
/// lists gets an avatar for free: Suggestions is built from the timeline,
/// which hydrates authors through `profile.v1` and so already carries a URL.
/// The other two do not, for two different reasons:
///
/// - `search.v1.ProfileHit` carries `avatar_key` — a STORAGE KEY, not a URL —
///   and nothing in the app resolves keys. Results would render initials
///   forever no matter how the UI was written.
/// - `search.v1.Suggest` answers with completion text and an id. There is no
///   avatar in the response at all.
///
/// So the picture has to be fetched. `profile.v1.GetProfileById` is the only
/// read that returns one, and it is per-person — which is the cost this type
/// exists to bound.
public protocol ProfileMetadataProviding: Sendable {
    /// Best-effort. A person who cannot be read is simply absent from the
    /// result — the row keeps its initials and says nothing about them, which
    /// is what those fallbacks are for.
    func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata]
}

/// Reads a person's picture and social context, once per person per session.
///
/// Two reads, because no single one answers both: `profile.v1.GetProfileById`
/// carries the avatar and no counts at all, and
/// `social_graph.v1.GetRelationStatus` carries the follow status *and*
/// `target_followers_count`. They are issued together per person so a row
/// completes in one round of latency rather than two.
///
/// ⚠️ **This is an N+1 fan-out and it is deliberate.** Neither service exposes
/// a batch read anywhere in the contracts — so a list of ten people is twenty
/// calls. What makes it affordable rather than reckless:
///
/// - **The cache is permanent for the session** and remembers the *absence* of
///   a picture too, so a person with none is asked about exactly once rather
///   than on every keystroke that re-lists them.
/// - **In-flight requests are shared**, so the typeahead re-rendering three
///   times while a fetch is out spends one call, not three.
/// - **Callers pass only what is on screen.** Nothing prefetches.
///
/// The batched read is the right fix and it is a backend ask, not a client
/// one — see `dev/BACKEND_GAPS.md`, which already records the same shape for
/// the feed's hydration (a 20-item page costing 21+ round trips).
public actor ProfileMetadataRepository: ProfileMetadataProviding {
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let viewerID: @Sendable () async -> ProfileID?

    /// People already asked about — including the ones who turned out to have
    /// no picture, which is what stops the retry loop on them.
    private var resolved: [ProfileID: ProfileRowMetadata] = [:]
    /// Shared work, so concurrent callers for the same person queue behind one
    /// request instead of racing it.
    private var inFlight: [ProfileID: Task<ProfileRowMetadata, Never>] = [:]

    public init(
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        viewerID: @escaping @Sendable () async -> ProfileID?
    ) {
        self.profileClient = profileClient
        self.socialGraphClient = socialGraphClient
        self.viewerID = viewerID
    }

    public func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata] {
        let wanted = Set(ids)
        // Everything already known, answered without touching the network.
        var found: [ProfileID: ProfileRowMetadata] = [:]
        var missing: [ProfileID] = []
        for id in wanted {
            if let cached = resolved[id] { found[id] = cached } else { missing.append(id) }
        }
        guard !missing.isEmpty else { return found }

        let tasks = missing.map { id in (id, task(for: id)) }
        for (id, task) in tasks {
            found[id] = await task.value
        }
        return found
    }

    private func task(for id: ProfileID) -> Task<ProfileRowMetadata, Never> {
        if let existing = inFlight[id] { return existing }
        let task = Task<ProfileRowMetadata, Never> { [profileClient, socialGraphClient, viewerID] in
            // Concurrently: one round of latency per person, not two.
            async let avatar = Self.avatarURL(of: id, profileClient: profileClient)
            async let relation = Self.relation(
                to: id, socialGraphClient: socialGraphClient, viewerID: viewerID
            )
            let (url, status) = await (avatar, relation)
            return ProfileRowMetadata(
                avatarURL: url, isFollowed: status.isFollowed, followerCount: status.followers
            )
        }
        inFlight[id] = task
        Task { await self.finish(id, metadata: await task.value) }
        return task
    }

    private static func avatarURL(
        of id: ProfileID, profileClient: any Profile_V1_ProfileServiceClientInterface
    ) async -> URL? {
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = id.rawValue
        let response = await profileClient.getProfileByID(request: request, headers: [:])
        guard case .success(let view) = response.result else { return nil }
        return URL(string: view.avatarURL)
    }

    private static func relation(
        to id: ProfileID,
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        viewerID: @Sendable () async -> ProfileID?
    ) async -> (isFollowed: Bool, followers: Int?) {
        guard let viewer = await viewerID() else { return (false, nil) }
        var request = SocialGraph_V1_GetRelationStatusRequest()
        request.actorID = viewer.rawValue
        request.targetID = id.rawValue
        let response = await socialGraphClient.getRelationStatus(request: request, headers: [:])
        guard case .success(let view) = response.result else { return (false, nil) }
        // `.followedBy` is THEM following the viewer, which is not what the row
        // claims — only the viewer's own outbound edge counts as "Following".
        let isFollowed = view.status == .following || view.status == .mutual
        // Zero is read as "the read-model has nothing", not as a person with no
        // followers: `counter.v1` does not project follower counts at all
        // (`dev/BACKEND_GAPS.md` §7), so a real zero and an unanswered one are
        // indistinguishable here and the quieter reading is the safe one.
        return (isFollowed, view.targetFollowersCount > 0 ? Int(view.targetFollowersCount) : nil)
    }

    private func finish(_ id: ProfileID, metadata: ProfileRowMetadata) {
        // A failed read is cached as "nothing known" on purpose: retrying it on
        // every re-render would turn one unreachable person into a request per
        // keystroke. The row keeps its initials and says nothing about them.
        resolved[id] = metadata
        inFlight[id] = nil
    }
}
