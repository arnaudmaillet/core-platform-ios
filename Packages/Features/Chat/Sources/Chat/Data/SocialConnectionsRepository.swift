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
        /// capped at what the row can show; `total` is the full count.
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

/// What the Suggestions surface consumes. Kept separate from the ranking so a
/// real recommendation service becomes one new conformer.
public protocol SuggestionsProviding: Sendable {
    func suggestions(limit: Int) async throws -> [SuggestedAccount]
    func follow(_ profileID: ProfileID) async throws
    func unfollow(_ profileID: ProfileID) async throws
}

extension SuggestionsProviding {
    /// One page of suggestions, `offset` accounts in.
    ///
    /// Ranking-then-dropping rather than a cursor, because there is no cursor
    /// to have: `social_graph.v1` exposes follow edges and nothing else, so the
    /// ordering is produced client-side by `SuggestionRanker` — which is
    /// deterministic and tie-broken on profile id precisely so that it is
    /// stable across calls. A prefix of page *n+1* is therefore exactly page
    /// *n*, and dropping it is a correct page boundary rather than an
    /// approximation.
    ///
    /// The re-rank is cheap after the first page: `SocialConnectionsRepository`
    /// caches the viewer's follow edges and every profile it has hydrated, so a
    /// later page costs the ranking pass plus the profiles it newly reveals.
    /// A real `ListSuggestions` RPC would replace this whole extension.
    public func suggestions(limit: Int, offset: Int) async throws -> [SuggestedAccount] {
        guard offset > 0 else { return try await suggestions(limit: limit) }
        let ranked = try await suggestions(limit: offset + limit)
        // Fewer than `offset` in hand means the graph ran out behind us; the
        // caller reads the empty page as "no more".
        guard ranked.count > offset else { return [] }
        return Array(ranked.dropFirst(offset))
    }
}

public enum SuggestionsError: Error, Equatable, Sendable {
    case transport(message: String)
}

/// Reads the viewer's follow graph from `social_graph.v1` and answers both
/// social questions the inbox asks: *do I follow this peer* (for the request
/// partition) and *who should I follow next* (for Suggestions).
///
/// One repository for both because they read the same two edge lists — asking
/// separately would double the traffic to answer from identical data.
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
}

public actor SocialConnectionsRepository: SuggestionsProviding, PeerRelationProviding, PeerAvatarProviding {
    /// How many of the viewer's follows are expanded for friend-of-friend
    /// candidates. Each costs one `ListFollowing`, so the fan-out is bounded
    /// rather than proportional to how social the viewer is.
    private static let connectorExpansionLimit = 8
    /// How many connector names a suggestion row spells out before collapsing
    /// into "+ n".
    private static let namedConnectorLimit = 1

    private let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let viewer: any ViewerIdentityProviding
    private let pageSize: Int32

    /// The viewer's own follow set, cached for the session: it answers the
    /// request partition on every inbox reload and seeds every ranking.
    private var followingCache: Set<ProfileID>?
    private var profileCache: [ProfileID: Profile_V1_ProfileView] = [:]

    /// `pageSize` carries no default: a default argument on an actor
    /// initializer can't be evaluated from the main-actor-isolated composition
    /// root, so every call site states the page size it wants.
    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        viewer: any ViewerIdentityProviding,
        pageSize: Int32
    ) {
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
        self.viewer = viewer
        self.pageSize = pageSize
    }

    // MARK: - PeerRelationProviding

    /// Answered from the viewer's own follow list rather than one
    /// `GetRelationStatus` per peer: a single request covers an inbox of any
    /// size, and the same cached set is what the ranker needs anyway.
    public func followedPeers(among peers: [ProfileID]) async throws -> Set<ProfileID> {
        let following = try await viewerFollowing()
        return Set(peers).intersection(following)
    }

    // MARK: - SuggestionsProviding

    public func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        let viewerID = try await viewer.viewerProfileID()
        async let followingTask = viewerFollowing()
        async let followersTask = followers(of: viewerID)
        let following = try await followingTask
        let followers = try await followersTask

        // Bounded fan-out: expand only the first few follows into their own
        // follow lists, in stable order so the suggestion set is reproducible.
        let connectors = Array(following.sorted { $0.rawValue < $1.rawValue }
            .prefix(Self.connectorExpansionLimit))
        var followingOfFollowing: [ProfileID: Set<ProfileID>] = [:]
        await withTaskGroup(of: (ProfileID, Set<ProfileID>).self) { group in
            for connector in connectors {
                group.addTask { [self] in
                    (connector, (try? await self.following(of: connector)) ?? [])
                }
            }
            for await (connector, edges) in group {
                followingOfFollowing[connector] = edges
            }
        }

        let ranked = SuggestionRanker.rank(
            SuggestionRanker.Input(
                viewer: viewerID,
                followers: followers,
                following: following,
                followingOfFollowing: followingOfFollowing
            ),
            limit: limit
        )
        await hydrateProfiles(for: ranked.flatMap { [$0.id] + $0.connectors })
        return ranked.compactMap(makeSuggestion)
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
        followingCache?.insert(profileID)
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
        followingCache?.remove(profileID)
    }

    // MARK: - Edges

    private func viewerFollowing() async throws -> Set<ProfileID> {
        if let followingCache { return followingCache }
        let edges = try await following(of: try await viewer.viewerProfileID())
        followingCache = edges
        return edges
    }

    private func following(of profileID: ProfileID) async throws -> Set<ProfileID> {
        var request = SocialGraph_V1_ListFollowingRequest()
        request.followerID = profileID.rawValue
        request.limit = pageSize
        let response = await socialGraphClient.listFollowing(request: request, headers: [:])
        switch response.result {
        case .success(let body): return Set(body.following.map { ProfileID($0.profileID) })
        case .failure(let error): throw SuggestionsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

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

    /// Reads through the same `profileCache` the suggestions ranker fills, so a
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
    private func makeSuggestion(from candidate: SuggestionRanker.Candidate) -> SuggestedAccount? {
        guard let view = profileCache[candidate.id] else { return nil }
        return SuggestedAccount(
            id: candidate.id,
            handle: view.handle,
            displayName: view.displayName.isEmpty ? view.handle : view.displayName,
            avatarURL: URL(string: view.avatarURL),
            reason: reason(for: candidate)
        )
    }

    private func reason(for candidate: SuggestionRanker.Candidate) -> SuggestedAccount.Reason {
        if candidate.followsViewer { return .followsYou }
        let names = candidate.connectors
            .compactMap { profileCache[$0] }
            .map { $0.displayName.isEmpty ? $0.handle : $0.displayName }
        guard !names.isEmpty else { return .suggestedForYou }
        return .followedBy(names: Array(names.prefix(Self.namedConnectorLimit)), total: candidate.connectors.count)
    }
}
