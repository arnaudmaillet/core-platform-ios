import CoreContracts
import CoreModels
import Foundation

/// A ranked account recommendation, hydrated for display.
public struct SuggestedAccount: Equatable, Sendable, Identifiable {
    /// Why this account is being suggested — shown verbatim under the handle,
    /// because an unexplained recommendation reads as an advertisement.
    public enum Reason: Equatable, Sendable {
        case followsYou
        /// Accounts the viewer follows who also follow this one. `names` is
        /// capped at what the row can show, and may be empty: `SuggestProfiles`
        /// answers how many, not who. `total` is the full count.
        case followedBy(names: [String], total: Int)
        case suggestedForYou
    }

    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let reason: Reason

    public init(
        id: ProfileID,
        handle: String,
        displayName: String,
        avatarURL: URL?,
        reason: Reason
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.reason = reason
    }
}

/// What the Suggestions surface consumes. Kept separate from the source so a
/// stub can stand in for the social graph.
public protocol SuggestionsProviding: Sendable {
    /// The `limit` best suggestions, best first. The same graph answers the
    /// same order, so a longer list starts with the shorter one.
    func suggestions(limit: Int) async throws -> [SuggestedAccount]
    func follow(_ profileID: ProfileID) async throws
    func unfollow(_ profileID: ProfileID) async throws
}

public enum SuggestionsError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// Answers *who should I follow next* (Suggestions) from `social_graph.v1`,
/// and follows or unfollows from a row.
///
/// ⚠️ **THE SERVER RANKS, AND THE SERVER EXCLUDES (#644).** `SuggestProfiles`
/// returns friends of friends, ranked by how many of the viewer's follows
/// follow them, and leaves out what the client cannot see: private and hidden
/// profiles, blocks either way, and anyone who turned "appear in suggestions"
/// off (a teen never turns it on). The client used to rank on its own from
/// eight friends' follow lists — and suggested exactly those profiles.
/// Resolves a person's avatar, for surfaces that hold an id and need a face.
///
/// **Separate from the row's own data on purpose.** A conversation arrives from
/// `chat.v1` with a title and member ids and no pictures — the avatar lives in
/// `profile.v1` — so a list that waited for faces would wait on a second
/// service before drawing anything. Every caller here renders its monogram
/// first and asks for the picture afterwards.
public protocol PeerAvatarProviding: Sendable {
    /// The avatar for each id that has one. Ids absent from the result have no
    /// avatar, or could not be read; both mean "keep the initials".
    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL]
    /// The raw @handle (no "@") for each id whose profile could be read
    /// (#752). Same rule: absent means "show none".
    func handles(for ids: [ProfileID]) async -> [ProfileID: String]
}

public extension PeerAvatarProviding {
    /// No handles: a provider that only knows faces shows the name alone.
    func handles(for ids: [ProfileID]) async -> [ProfileID: String] { [:] }
}

public actor SocialConnectionsRepository: SuggestionsProviding, PeerAvatarProviding {
    /// The most `SuggestProfiles` answers in one call.
    public static let suggestionLimit = 50

    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let viewer: any ViewerIdentityProviding
    private let pageSize: Int32

    /// Announces this repository's own accepted follows to the rest of the
    /// app (a profile's button, a feed's "+") — see `FollowGraphEvents`.
    private let followEvents: FollowGraphEvents?
    private var profileCache: [ProfileID: Profile_V1_ProfileView] = [:]

    /// `pageSize` carries no default: a default argument on an actor
    /// initializer can't be evaluated from the main-actor-isolated composition
    /// root, so every call site states the page size it wants.
    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        viewer: any ViewerIdentityProviding,
        pageSize: Int32,
        followEvents: FollowGraphEvents? = nil
    ) {
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
        self.viewer = viewer
        self.pageSize = pageSize
        self.followEvents = followEvents
    }

    // MARK: - SuggestionsProviding

    public func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_SuggestProfilesRequest()
        request.profileID = viewerID.rawValue
        request.limit = Int32(min(max(limit, 1), Self.suggestionLimit))
        async let suggestedTask = socialGraphClient.suggestProfiles(request: request, headers: [:])
        // Who already follows the viewer: one read, so a suggestion that
        // does can say so — the strongest reason the graph has.
        async let followersTask = try? followers(of: viewerID)
        let suggested: [SocialGraph_V1_SuggestedProfile]
        switch await suggestedTask.result {
        case .success(let body): suggested = body.profiles
        case .failure(let error): throw SuggestionsError.transport(message: error.message ?? "code \(error.code)")
        }
        let followers = await followersTask ?? []

        let ids = suggested.map { ProfileID($0.profileID) }
        await hydrateProfiles(for: ids)
        return suggested.compactMap { candidate in
            makeSuggestion(from: candidate, followsViewer: followers.contains(ProfileID(candidate.profileID)))
        }
    }

    public func follow(_ profileID: ProfileID) async throws {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_FollowRequest()
        request.actorID = viewerID.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.follow(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw SuggestionsError.transport(message: error.message ?? "code \(error.code)")
        }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: true))
    }

    public func unfollow(_ profileID: ProfileID) async throws {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_UnfollowRequest()
        request.actorID = viewerID.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.unfollow(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw SuggestionsError.transport(message: error.message ?? "code \(error.code)")
        }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: false))
    }

    // MARK: - Edges

    private func followers(of profileID: ProfileID) async throws -> Set<ProfileID> {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.followeeID = profileID.rawValue
        request.limit = pageSize
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        switch response.result {
        case .success(let body): return Set(body.followers.map { ProfileID($0.profileID) })
        case .failure(let error): throw SuggestionsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Avatars

    /// Reads through the same `profileCache` the suggestions fill, so a
    /// face already fetched for one surface is free for the next — the inbox
    /// and the Suggestions tab overlap heavily, and they are one tab apart.
    ///
    /// Absence is cached as well as presence: `hydrateProfiles` records every
    /// id it managed to read, so a profile with no avatar is asked for once,
    /// not once per cell reuse.
    public func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] {
        await hydrateProfiles(for: ids)
        return ids.reduce(into: [:]) { result, id in
            guard let view = profileCache[id],
                  let url = URL(string: view.avatarURL), !view.avatarURL.isEmpty
            else { return }
            result[id] = url
        }
    }

    /// From the same `GetProfileById` read as the avatar, and its cache.
    public func handles(for ids: [ProfileID]) async -> [ProfileID: String] {
        await hydrateProfiles(for: ids)
        return ids.reduce(into: [:]) { result, id in
            guard let view = profileCache[id], !view.handle.isEmpty else { return }
            result[id] = view.handle
        }
    }

    // MARK: - Hydration

    private func hydrateProfiles(for ids: [ProfileID]) async {
        let missing = Set(ids).filter { profileCache[$0] == nil && !$0.rawValue.isEmpty }
        guard !missing.isEmpty else { return }
        let client = profileClient
        let fetched = await withTaskGroup(of: (ProfileID, Profile_V1_ProfileView)?.self) { group in
            for id in missing {
                group.addTask {
                    var request = Profile_V1_GetProfileByIdRequest()
                    request.profileID = id.rawValue
                    guard let view = (await client.getProfileByID(request: request, headers: [:])).message else {
                        return nil
                    }
                    return (id, view)
                }
            }
            return await group.reduce(into: [(ProfileID, Profile_V1_ProfileView)]()) { partial, pair in
                if let pair { partial.append(pair) }
            }
        }
        for (id, view) in fetched { profileCache[id] = view }
    }

    /// A candidate becomes a row only once its own profile resolved — a
    /// suggestion with no name is not a suggestion.
    private func makeSuggestion(
        from candidate: SocialGraph_V1_SuggestedProfile, followsViewer: Bool
    ) -> SuggestedAccount? {
        let id = ProfileID(candidate.profileID)
        guard let view = profileCache[id] else { return nil }
        let reason: SuggestedAccount.Reason = if followsViewer {
            .followsYou
        } else if candidate.mutualCount > 0 {
            .followedBy(names: [], total: Int(candidate.mutualCount))
        } else {
            .suggestedForYou
        }
        return SuggestedAccount(
            id: id,
            handle: view.handle,
            displayName: view.displayName.isEmpty ? view.handle : view.displayName,
            avatarURL: URL(string: view.avatarURL),
            reason: reason
        )
    }
}
