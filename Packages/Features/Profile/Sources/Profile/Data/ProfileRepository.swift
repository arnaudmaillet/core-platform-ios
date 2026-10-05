import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
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

/// How wide a block reaches.
///
/// The wire has no notion of this: `social_graph.v1.Block` takes a *profile*
/// id and nothing else, so `.account` is a client-side fan-out over the
/// account's profiles rather than one atomic command. Two consequences the UI
/// has to live with, both recorded in `dev/BACKEND_GAPS.md` §12:
/// - it is a **snapshot** — a profile created on that account afterwards is
///   not covered, where a server-side account block would be;
/// - it is **not transactional** — a partial failure blocks some and not
///   others, so the repository reports what it actually managed to block
///   rather than claiming the whole set.
public enum ProfileBlockScope: Equatable, Sendable {
    /// Just this profile.
    case profile
    /// This profile and every other profile on the same account.
    case account
}

/// The viewer's relationship to a profile, driving the header's action button.
public enum ProfileRelationship: Equatable, Sendable {
    /// The profile belongs to the signed-in viewer → "Edit Profile".
    case me
    /// Someone else's profile → Follow / Following toggle. `isBlocked` is the
    /// viewer's *outbound* block (`RelationStatus.blocking`), which the "..."
    /// menu reads to offer Block or Unblock. Being blocked BY the target
    /// (`blockedBy`) is deliberately not surfaced — platforms don't tell you.
    ///
    /// `isMutual` means they follow back (`RelationStatus.mutual`) — a FRIEND
    /// in the map's vocabulary. It implies `isFollowing`, and the two are kept
    /// apart rather than collapsed: the follow button only ever needed "does
    /// the viewer follow them", and squeezing mutual into that bool is why the
    /// distinction had to be recovered here before the map could offer a
    /// friends-or-following choice.
    case other(isFollowing: Bool, isMutual: Bool = false, isBlocked: Bool)
    /// Someone else's PRIVATE profile the viewer asked to follow; the request
    /// is pending (social_graph.v1 `REQUESTED`, backend #655) → "Requested",
    /// which withdraws it. Never blocked: a block drops pending requests.
    case requested
}

/// How widely a profile is exposed, mirroring `profile.v1.ProfileVisibility`.
///
/// The contract's flag is **whole-profile**: there is no per-surface privacy
/// anywhere in `profile.v1`, `social_graph.v1`, or `account.v1`, so this is the
/// only signal the client has about whether a profile's follower / following
/// lists should be shown to a stranger. `RelationshipListAccess` is where that
/// (approximate) inference is made and documented; see
/// `dev/BACKEND_GAPS.md` §13 for the contract this should become.
///
/// `unspecified` is treated as public everywhere — an unset enum on the wire
/// must not silently lock a profile down.
public enum ProfileVisibility: Equatable, Sendable {
    case unspecified
    case `public`
    case `private`

    /// Whether this value withholds anything. `unspecified` does not.
    public var isPrivate: Bool { self == .private }

    init(_ proto: Profile_V1_ProfileVisibility) {
        switch proto {
        case .private: self = .private
        case .public: self = .public
        default: self = .unspecified
        }
    }
}

/// A labelled external link on a profile (`custom_links`) — a second site, a
/// storefront, a social handle. Order is meaningful: it's the display order.
public struct ProfileLink: Equatable, Sendable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
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
    /// The profile's ordered custom links (`custom_links`). Editable through the
    /// same `UpdateProfile` RPC as bio/name/website.
    public let customLinks: [ProfileLink]
    public let isVerified: Bool
    /// The profile's `profile.v1` visibility. Read by the follower / following
    /// lists to decide whether a stranger may see them — the closest thing the
    /// contracts offer to relationship-list privacy.
    public let visibility: ProfileVisibility
    public let followerCount: CountEstimate
    public let followingCount: CountEstimate
    /// Total likes received across the profile's posts (counter.v1 LIKE,
    /// profile-scoped) — the header's "Likes". No social-graph fallback exists
    /// for this metric. (Views were read beside it until 2026-09-30; nothing
    /// shows them any more.)
    public let reactionCount: CountEstimate

    public init(
        id: ProfileID,
        handle: String,
        displayName: String,
        bio: String,
        avatarURL: URL?,
        websiteURL: URL?,
        customLinks: [ProfileLink] = [],
        isVerified: Bool,
        // Defaulted: a profile the wire didn't describe is not a private one,
        // and every existing call site predates the field.
        visibility: ProfileVisibility = .unspecified,
        followerCount: CountEstimate,
        followingCount: CountEstimate,
        reactionCount: CountEstimate
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.avatarURL = avatarURL
        self.websiteURL = websiteURL
        self.customLinks = customLinks
        self.isVerified = isVerified
        self.visibility = visibility
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.reactionCount = reactionCount
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
    /// Block (`true`) or unblock (`false`) `profileID` as the viewer.
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws
    /// Blocks `profileID` and every other profile on the same account,
    /// returning the ids actually blocked (always including `profileID` on
    /// success). Best-effort by construction — see `ProfileBlockScope`.
    /// Throws only when nothing at all could be blocked.
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID]
    /// Edits the viewer's own mutable profile metadata via `UpdateProfile`,
    /// returning the refreshed profile. Fields not exposed here (avatar, banner,
    /// locale, visibility) are preserved; the handle is changed separately via
    /// `changeHandle`.
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile
    /// Changes the viewer's @handle via the dedicated `ChangeHandle` RPC (atomic
    /// swap on the fleet; a plain rename in mock), returning the refreshed profile.
    func changeHandle(_ newHandle: String) async throws -> UserProfile
}

/// A lightweight profile summary for the account's profile switcher — enough to
/// list a profile (name, @handle, avatar) without a full `UserProfile` fetch.
public struct AccountProfile: Equatable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// A profile the active profile has blocked, as Settings lists it.
public struct BlockedProfile: Hashable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let blockedAt: Date?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?, blockedAt: Date?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.blockedAt = blockedAt
    }
}

/// Settings → Safety and Interactions → Blocked Accounts (#389): who the
/// ACTIVE profile has blocked, and the way back.
public protocol BlockedAccountsManaging: Sendable {
    /// Newest block first.
    func blockedProfiles() async throws -> [BlockedProfile]
    func unblock(_ profileID: ProfileID) async throws
}

/// Public or private, for the ACTIVE profile (Settings → Privacy, #388).
/// Per profile, like the switcher: making @maya private leaves @maya.work
/// public.
public protocol ProfileVisibilityManaging: Sendable {
    func activeProfileIsPrivate() async throws -> Bool
    func setActiveProfilePrivate(_ isPrivate: Bool) async throws
}

/// Multi-profile support for the switcher: list the account's profiles, read the
/// active one, and switch it. "Active" is app-wide: the switch goes through the
/// shared `ViewerProviding`, so every repository that asks "who am I" (feed,
/// comments, chat, notifications, the post composer) follows it.
public protocol ProfileSwitching: Sendable {
    /// All profiles linked to the signed-in account.
    func accountProfiles() async throws -> [AccountProfile]
    /// The active profile id (the one the profile screen + avatar resolve to).
    func activeProfileID() async -> ProfileID?
    /// Switches the active profile; the profile screen + avatar refresh to it.
    func setActiveProfile(_ id: ProfileID) async
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
// `SocialGraphWriting` is satisfied by `ProfileProviding.setFollowing` — the
// same method, declared again in CoreModels so a feed row's "..." menu can
// unfollow without importing this package. `SocialGraphReading` is
// `relationship(for:)` folded to the one question a follow "+" asks.
public actor ProfileRepository: ProfileProviding, ProfileSwitching, ProfileVisibilityManaging, BlockedAccountsManaging, ProfileViewerResolving,
    SocialGraphWriting, SocialGraphReading {
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let counterClient: any Counter_V1_CounterServiceClientInterface
    let socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface
    private let authSession: any AuthSessionProviding
    /// Upper bound on edges sampled for the fallback count; beyond it the count
    /// is reported as `atLeast(limit)` rather than paginating the whole graph.
    private let edgeSampleLimit: Int32
    /// Where an accepted follow or unfollow is announced — see
    /// `FollowGraphEvents`. Nil announces nothing.
    let followEvents: FollowGraphEvents?
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "profile")

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding

    public init(
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        socialGraphClient: any SocialGraph_V1_SocialGraphServiceClientInterface,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        edgeSampleLimit: Int32 = 200,
        followEvents: FollowGraphEvents? = nil
    ) {
        self.followEvents = followEvents
        self.profileClient = profileClient
        self.counterClient = counterClient
        self.socialGraphClient = socialGraphClient
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this repository's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
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
        // A guest follows no one: they see Follow (which asks them to sign up),
        // not a header waiting on a relationship that can never resolve.
        if await viewer.current() == .guest {
            return .other(isFollowing: false, isMutual: false, isBlocked: false)
        }
        let viewer = try await resolveViewerProfileID()
        // The viewer's own profile (whether reached via the tab or by routing to
        // your own id) offers Edit, never Follow.
        guard viewer != profileID else { return .me }

        let status = try await relationStatus(from: viewer, to: profileID)
        if status == .requested { return .requested }
        // `.mutual` also means the viewer follows the target. `.blocking`
        // is exclusive with the follow states on the wire (blocking tears
        // the edges down), so a blocked profile reports isFollowing false —
        // which is also what the UI wants: Unblock, not Unfollow.
        let isFollowing = status == .following || status == .mutual
        return .other(
            isFollowing: isFollowing,
            isMutual: status == .mutual,
            isBlocked: status == .blocking
        )
    }

    /// Read off the wire status directly rather than off `relationship(for:)`:
    /// a follow affordance needs the INBOUND half too (`.followedBy` — following
    /// them back makes a friend), which the profile header's relationship never
    /// needed and does not carry.
    public func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        // A guest follows no one — and is followed by no one.
        if await viewer.current() == .guest { return .notFollowing }
        let viewer = try await resolveViewerProfileID()
        guard viewer != profileID else { return .viewer }
        return switch try await relationStatus(from: viewer, to: profileID) {
        case .blocking: .blocked
        case .mutual: .mutual
        case .following: .following
        case .followedBy: .followedBy
        case .requested: .requested
        // `.blockedBy` is not surfaced (platforms don't tell you), and an
        // unknown status is no edge at all.
        default: .notFollowing
        }
    }

    private func relationStatus(
        from viewer: ProfileID, to profileID: ProfileID
    ) async throws -> SocialGraph_V1_RelationStatus {
        var request = SocialGraph_V1_GetRelationStatusRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.getRelationStatus(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            return view.status
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "setFollowing")
        guard viewer != profileID else { return } // no-op: can't follow yourself

        if following {
            var request = SocialGraph_V1_FollowRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            let response = await socialGraphClient.follow(request: request, headers: [:])
            try Self.ensureAccepted(response)
            // A private profile was asked, not followed: no edge to announce.
            // The profile screen reads the outcome through `follow(_:)`.
            if response.message?.requested == true { return }
        } else {
            var request = SocialGraph_V1_UnfollowRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unfollow(request: request, headers: [:]))
        }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: following))
    }

    public func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "setBlocked")
        guard viewer != profileID else { return } // no-op: can't block yourself

        if blocked {
            var request = SocialGraph_V1_BlockRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.block(request: request, headers: [:]))
        } else {
            var request = SocialGraph_V1_UnblockRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unblock(request: request, headers: [:]))
        }
    }

    /// Fans a block out across the account behind `profileID`.
    ///
    /// Degrades in one direction only — toward blocking *less*, never toward
    /// claiming more than it did. If the account can't be resolved, or the
    /// account's profile list is unreadable (it may well be: enumerating
    /// another account's profiles is a privacy-sensitive read the fleet is
    /// entitled to refuse), this falls back to blocking the one profile the
    /// viewer actually asked about, and says so by returning just that id.
    public func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] {
        let viewer = try await resolveViewerProfileID(forWrite: "blockAccount")
        let targets = await accountSiblings(of: profileID, viewer: viewer)

        // Concurrent, and INDEPENDENT: one rejected block must not strand the
        // rest — the whole point of the scope is to catch every alias.
        var blocked: [ProfileID] = []
        await withTaskGroup(of: ProfileID?.self) { group in
            for target in targets {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    do {
                        try await self.setBlocked(true, for: target)
                        return target
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let result { blocked.append(result) }
            }
        }

        guard !blocked.isEmpty else {
            throw ProfileError.transport(message: "no profile could be blocked")
        }
        // Stable order for callers that show the list; the set itself is what
        // matters, but a shuffling result reads as nondeterminism.
        return blocked.sorted { $0.rawValue < $1.rawValue }
    }

    /// Every profile the block should cover: the target plus its account
    /// siblings, minus the viewer's own (blocking yourself is a no-op the
    /// command layer would reject anyway).
    private func accountSiblings(of profileID: ProfileID, viewer: ProfileID) async -> [ProfileID] {
        var ids: Set<ProfileID> = [profileID]
        if let accountID = try? await fetchProfileView(id: profileID).accountID, !accountID.isEmpty {
            var request = Profile_V1_ListProfilesByAccountRequest()
            request.accountID = accountID
            let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
            if let body = response.message {
                ids.formUnion(body.profiles.map { ProfileID($0.profileID) })
            } else {
                logger.info("account profiles unreadable for \(profileID.rawValue, privacy: .public); blocking that profile only")
            }
        }
        ids.remove(viewer)
        return Array(ids)
    }

    /// Throws unless the command round-tripped and the server accepted it.
    static func ensureAccepted(_ response: ResponseMessage<SocialGraph_V1_CommandResponse>) throws {
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
        // A follow of a private profile answers with a pending request.
        guard response.message?.success == true || response.message?.requested == true else {
            throw ProfileError.transport(message: "command rejected")
        }
    }

    // MARK: - Edit

    public func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        let id = try await resolveViewerProfileID()
        // The contract has no field mask; start from the current view so fields
        // the form doesn't edit (locale) are preserved, not cleared. Links ARE
        // edited now, so they come from the caller rather than the current view.
        let current = try await fetchProfileView(id: id)

        var request = Profile_V1_UpdateProfileRequest()
        request.profileID = id.rawValue
        request.displayName = displayName
        request.bio = bio
        request.websiteURL = website
        request.locale = current.locale
        request.customLinks = links.map { link in
            var proto = Profile_V1_ProfileLinkProto()
            proto.label = link.label
            proto.url = link.url
            return proto
        }

        let response = await profileClient.updateProfile(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
        guard response.message?.success == true else {
            throw ProfileError.transport(message: "profile update rejected")
        }

        return try await loadProfile(id: id)
    }

    public func changeHandle(_ newHandle: String) async throws -> UserProfile {
        let id = try await resolveViewerProfileID()
        var request = Profile_V1_ChangeHandleRequest()
        request.profileID = id.rawValue
        request.newHandle = newHandle

        let response = await profileClient.changeHandle(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
        guard response.message?.success == true else {
            throw ProfileError.transport(message: "handle change rejected")
        }

        return try await loadProfile(id: id)
    }

    /// Fetches the profile view and its social counters concurrently.
    private func loadProfile(id: ProfileID) async throws -> UserProfile {
        async let viewResult = fetchProfileView(id: id)
        async let countsResult = fetchSocialCounts(for: id)
        let view = try await viewResult
        let counts = await countsResult
        return Self.makeProfile(from: view, counts: counts)
    }

    // MARK: - Profile view

    func fetchProfileView(id: ProfileID) async throws -> Profile_V1_ProfileView {
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

    /// `write` names the caller when it is a write, so a guest reaching it is
    /// reported (`GateAudit`): the member gate should have stopped them first.
    func resolveViewerProfileID(forWrite write: String? = nil) async throws -> ProfileID {
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            if let write { GateAudit.ungatedWrite(write) }
            throw ProfileError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw ProfileError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw ProfileError.transport(message: error.message)
        }
    }

    // MARK: - ProfileSwitching

    public func accountProfiles() async throws -> [AccountProfile] {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ProfileError.notAuthenticated
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.profiles.map { profile in
                AccountProfile(
                    id: ProfileID(profile.profileID),
                    handle: profile.handle,
                    displayName: profile.displayName,
                    avatarURL: URL(string: profile.avatarURL)
                )
            }
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func activeProfileID() async -> ProfileID? {
        try? await resolveViewerProfileID()
    }

    // MARK: - ProfileViewerResolving

    /// Same answer as `activeProfileID`, under the name the share-targets
    /// repository depends on — so that repository never re-derives (or
    /// re-caches) an identity this actor already owns, and a profile switch
    /// reaches it for free.
    public func viewerProfileID() async -> ProfileID? {
        try? await resolveViewerProfileID()
    }

    public func setActiveProfile(_ id: ProfileID) async {
        // The shared viewer is the whole switch: `currentUserProfile` (profile
        // screen), `viewerAvatarImage` (map avatar) and every other repository
        // resolve through it, so they all read the chosen profile next.
        await viewer.setActiveProfile(id)
    }

    // MARK: - BlockedAccountsManaging

    public func blockedProfiles() async throws -> [BlockedProfile] {
        let viewer = try await resolveViewerProfileID()
        var summaries: [SocialGraph_V1_BlockSummary] = []
        var pageToken = ""
        // Bounded: a block list is short, and a server that kept handing back
        // a page token must not spin this loop forever.
        for _ in 0..<20 {
            var request = SocialGraph_V1_ListBlocksRequest()
            request.blockerID = viewer.rawValue
            request.limit = 100
            request.pageToken = pageToken
            let response = await socialGraphClient.listBlocks(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                summaries += body.blocks
                pageToken = body.nextPageToken
            case .failure(let error):
                throw ProfileError.transport(message: error.message ?? "code \(error.code)")
            }
            if pageToken.isEmpty { break }
        }
        // One read per blocked profile (the contract has no batch read). A
        // profile that no longer resolves still lists, by id, so it can be
        // unblocked.
        let views = await withTaskGroup(of: (String, Profile_V1_ProfileView?).self) { group in
            for summary in summaries {
                group.addTask { [self] in
                    (summary.blockeeID, try? await fetchProfileView(id: ProfileID(summary.blockeeID)))
                }
            }
            var byID: [String: Profile_V1_ProfileView] = [:]
            for await (id, view) in group { byID[id] = view }
            return byID
        }
        return summaries
            .map { summary in
                let view = views[summary.blockeeID]
                return BlockedProfile(
                    id: ProfileID(summary.blockeeID),
                    handle: view?.handle ?? summary.blockeeID,
                    displayName: view?.displayName ?? "",
                    avatarURL: view.flatMap { URL(string: $0.avatarURL) },
                    blockedAt: summary.hasBlockedAt
                        ? Date(timeIntervalSince1970: TimeInterval(summary.blockedAt.seconds) + TimeInterval(summary.blockedAt.nanos) / 1e9)
                        : nil
                )
            }
            .sorted { ($0.blockedAt ?? .distantPast) > ($1.blockedAt ?? .distantPast) }
    }

    public func unblock(_ profileID: ProfileID) async throws {
        try await setBlocked(false, for: profileID)
    }

    // MARK: - ProfileVisibilityManaging

    public func activeProfileIsPrivate() async throws -> Bool {
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return view.visibility == .private
    }

    public func setActiveProfilePrivate(_ isPrivate: Bool) async throws {
        var request = Profile_V1_SetVisibilityRequest()
        request.profileID = try await resolveViewerProfileID().rawValue
        request.visibility = isPrivate ? .private : .public
        let response = await profileClient.setVisibility(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    // MARK: - Social counters

    /// The three header metrics, resolved together.
    struct SocialCounts {
        let followers: CountEstimate
        let following: CountEstimate
        let reactions: CountEstimate
    }

    /// Best-effort: an outage in *both* sources degrades to `.unavailable`
    /// (rendered "—") rather than failing the whole profile load. The counter
    /// read is one round-trip; the social-graph fallbacks fire only for metrics
    /// the counter didn't already answer, and run concurrently. Likes live
    /// *only* in counter.v1 — there is no edge set to sample — so an empty
    /// read degrades straight to `.unavailable`.
    private func fetchSocialCounts(for id: ProfileID) async -> SocialCounts {
        let counter = await counterEstimates(for: id)
        async let followers = resolve(counter.followers, fallback: { await self.followerFallback(for: id) })
        async let following = resolve(counter.following, fallback: { await self.followingFallback(for: id) })
        return await SocialCounts(
            followers: followers,
            following: following,
            reactions: counter.reactions ?? .unavailable
        )
    }

    /// Prefer the counter estimate; otherwise run the (async) social-graph fallback.
    private func resolve(_ primary: CountEstimate?, fallback: () async -> CountEstimate) async -> CountEstimate {
        if let primary { return primary }
        return await fallback()
    }

    /// Reads counter.v1. Returns `nil` per metric when the read-model has no
    /// value for it (the signal to fall back), not `.unavailable`.
    private func counterEstimates(
        for id: ProfileID
    ) async -> (followers: CountEstimate?, following: CountEstimate?, reactions: CountEstimate?) {
        var entity = Counter_V1_EntityRef()
        entity.entityType = .profile
        entity.id = id.rawValue

        var request = Counter_V1_BatchGetCountersRequest()
        request.entities = [entity]
        request.metrics = [.follower, .following, .like]

        let response = await counterClient.batchGetCounters(request: request, headers: [:])
        guard let snapshot = response.message?.snapshots.first else {
            return (nil, nil, nil)
        }
        func estimate(_ metric: Counter_V1_CounterMetric) -> CountEstimate? {
            snapshot.values.first { $0.metric == metric }.map { CountEstimate.exact($0.value) }
        }
        return (estimate(.follower), estimate(.following), estimate(.like))
    }

    private func followerFallback(for id: ProfileID) async -> CountEstimate {
        var request = SocialGraph_V1_ListFollowersRequest()
        request.followeeID = id.rawValue
        request.limit = edgeSampleLimit
        let response = await socialGraphClient.listFollowers(request: request, headers: [:])
        // A list hidden from this viewer (list privacy, backend #720) is an
        // empty page that counts nothing: "—", not "0".
        guard let body = response.message, !body.hidden else {
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
        guard let body = response.message, !body.hidden else {
            logger.info("following count unavailable for \(id.rawValue, privacy: .public)")
            return .unavailable
        }
        return .fromSample(count: body.following.count, hasMore: !body.nextPageToken.isEmpty)
    }

    private static func makeProfile(
        from view: Profile_V1_ProfileView,
        counts: SocialCounts
    ) -> UserProfile {
        UserProfile(
            id: ProfileID(view.profileID),
            handle: view.handle,
            displayName: view.displayName,
            bio: view.bio,
            avatarURL: URL(string: view.avatarURL),
            websiteURL: URL(string: view.websiteURL),
            customLinks: view.customLinks.map { ProfileLink(label: $0.label, url: $0.url) },
            isVerified: view.verified,
            visibility: ProfileVisibility(view.visibility),
            followerCount: counts.followers,
            followingCount: counts.following,
            reactionCount: counts.reactions
        )
    }
}
