import CoreContracts
import CoreModels
import CoreNetworking
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
    /// A private profile: a follow from the row ASKS (#1454).
    public let isPrivate: Bool

    public init(
        id: ProfileID,
        handle: String,
        displayName: String,
        avatarURL: URL?,
        reason: Reason,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.reason = reason
        self.isPrivate = isPrivate
    }
}

/// One page of suggestions, best first (#644).
public struct SuggestionsPage: Equatable, Sendable {
    public let accounts: [SuggestedAccount]
    /// Where the next page starts; nil on the last page.
    ///
    /// ⚠️ **FOLLOW THE TOKEN, NEVER THE COUNT.** The server filters each page
    /// after reading it, so a page can come back short — even empty — and
    /// still carry a token: more follow.
    public let nextPageToken: String?

    public init(accounts: [SuggestedAccount], nextPageToken: String?) {
        self.accounts = accounts
        self.nextPageToken = nextPageToken
    }
}

/// What the Suggestions surface consumes. Kept separate from the source so a
/// stub can stand in for the social graph.
public protocol SuggestionsProviding: Sendable {
    /// The `limit` best suggestions, best first: the first page.
    func suggestions(limit: Int) async throws -> [SuggestedAccount]
    /// A page of at most `limit` suggestions: the first when `pageToken` is
    /// nil, otherwise the one that token starts (#644).
    func suggestions(limit: Int, after pageToken: String?) async throws -> SuggestionsPage
    /// Follows, or — a private profile — asks to (#1454): which one the
    /// server answered.
    @discardableResult
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome
    func unfollow(_ profileID: ProfileID) async throws
    /// Withdraws a request still pending (#1454).
    func cancelFollowRequest(_ profileID: ProfileID) async throws
}

extension SuggestionsProviding {
    /// Sources that never ask (stubs): nothing to withdraw.
    public func cancelFollowRequest(_ profileID: ProfileID) async throws {}

    /// Providers that don't page: the first page is everything.
    public func suggestions(limit: Int, after pageToken: String?) async throws -> SuggestionsPage {
        guard pageToken == nil else { return SuggestionsPage(accounts: [], nextPageToken: nil) }
        return SuggestionsPage(accounts: try await suggestions(limit: limit), nextPageToken: nil)
    }
}

public enum SuggestionsError: Error, Equatable, Sendable {
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension SuggestionsError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
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
    /// Where every person this repository hydrates is reported — the inbox's
    /// rows, a thread's peer, Suggestions, inbox search (#1858).
    private let people: (any PeopleSightings)?
    /// Who followed the viewer when the first page of suggestions was read —
    /// reused by the pages after it.
    private var viewerFollowers: (viewer: ProfileID, ids: Set<ProfileID>)?

    /// `pageSize` carries no default: a default argument on an actor
    /// initializer can't be evaluated from the main-actor-isolated composition
    /// root, so every call site states the page size it wants.
    public init(
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        viewer: any ViewerIdentityProviding,
        pageSize: Int32,
        followEvents: FollowGraphEvents? = nil,
        people: (any PeopleSightings)? = nil
    ) {
        self.people = people
        self.socialGraphClient = socialGraphClient
        self.profileClient = profileClient
        self.viewer = viewer
        self.pageSize = pageSize
        self.followEvents = followEvents
    }

    // MARK: - SuggestionsProviding

    public func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        try await suggestions(limit: limit, after: nil).accounts
    }

    /// One `SuggestProfiles` page (#644, backend #834), its rows hydrated.
    ///
    /// ⚠️ A page can come back short, even empty, WITH a token: the server
    /// filters what it examined (private, hidden, opted out), and a row
    /// whose profile did not resolve is dropped here too. The token, not the
    /// count, says whether more follow. A profile can also show on two pages
    /// when its ranking moved between them: the caller de-duplicates by id
    /// across pages; this de-duplicates within one.
    public func suggestions(limit: Int, after pageToken: String?) async throws -> SuggestionsPage {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_SuggestProfilesRequest()
        request.profileID = viewerID.rawValue
        request.limit = Int32(min(max(limit, 1), Self.suggestionLimit))
        request.pageToken = pageToken ?? ""
        async let suggestedTask = socialGraphClient.suggestProfiles(request: request, headers: [:])
        // Who already follows the viewer, so a suggestion that does can say
        // so — the strongest reason the graph has. Read with the first page
        // and reused by the pages after it: one read per paging run.
        let held = pageToken == nil ? nil : viewerFollowers.flatMap { $0.viewer == viewerID ? $0.ids : nil }
        async let followersTask = held == nil ? (try? followers(of: viewerID)) : nil
        let body: SocialGraph_V1_SuggestProfilesResponse
        switch await suggestedTask.result {
        case .success(let answer): body = answer
        case .failure(let error): throw SuggestionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        let fetched = await followersTask
        if let fetched { viewerFollowers = (viewerID, fetched) }
        let followers = held ?? fetched ?? []

        var seen: Set<String> = []
        let suggested = body.profiles.filter { seen.insert($0.profileID).inserted }
        await hydrateProfiles(for: suggested.map { ProfileID($0.profileID) })
        let accounts = suggested.compactMap { candidate in
            makeSuggestion(from: candidate, followsViewer: followers.contains(ProfileID(candidate.profileID)))
        }
        return SuggestionsPage(accounts: accounts, nextPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken)
    }

    @discardableResult
    public func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_FollowRequest()
        request.actorID = viewerID.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.follow(request: request, headers: [:])
        // A private profile is ASKED, and an ask already pending is that
        // ask (SGR-1005): announced as a request, not a follow, so the
        // profile under this screen reads "Requested" (#1450).
        if response.error?.code == .alreadyExists || response.message?.requested == true {
            followEvents?.publish(FollowRequestChange(profileID: profileID, isPending: true, viewerID: viewerID))
            return .requested
        }
        if case .failure(let error) = response.result {
            throw SuggestionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: true, viewerID: viewerID))
        return .following
    }

    /// Withdraws the viewer's pending request (#1454). Nothing pending any
    /// more (SGR-1006, answered meanwhile) meets the withdrawal's goal.
    public func cancelFollowRequest(_ profileID: ProfileID) async throws {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_CancelFollowRequestRequest()
        request.actorID = viewerID.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.cancelFollowRequest(request: request, headers: [:])
        if case .failure(let error) = response.result, !(error.message ?? "").contains("SGR-1006") {
            throw SuggestionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        followEvents?.publish(FollowRequestChange(profileID: profileID, isPending: false, viewerID: viewerID))
    }

    public func unfollow(_ profileID: ProfileID) async throws {
        let viewerID = try await viewer.viewerProfileID()
        var request = SocialGraph_V1_UnfollowRequest()
        request.actorID = viewerID.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.unfollow(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw SuggestionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: false, viewerID: viewerID))
    }

    // MARK: - Edges

    private func followers(of profileID: ProfileID) async throws -> Set<ProfileID> {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.followeeID = profileID.rawValue
        request.limit = pageSize
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        switch response.result {
        case .success(let body): return Set(body.followers.map { ProfileID($0.profileID) })
        case .failure(let error): throw SuggestionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
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
        people?.saw(fetched.map { AuthorSummary(profileView: $0.1) })
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
            reason: reason,
            isPrivate: view.visibility == .private
        )
    }
}
