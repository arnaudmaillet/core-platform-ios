import CoreContracts
import CoreModels
import Foundation

// MARK: - Restrict

/// A profile the active profile has restricted, as Settings lists it.
public struct RestrictedProfile: Hashable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let restrictedAt: Date?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?, restrictedAt: Date?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.restrictedAt = restrictedAt
    }
}

/// Restrict (#416, backend #724): a restricted profile's comments on your
/// posts are seen only by them and you. They aren't told; follows stay.
public protocol ProfileRestricting: Sendable {
    func isRestricted(_ profileID: ProfileID) async throws -> Bool
    func setRestricted(_ restricted: Bool, for profileID: ProfileID) async throws
    /// Newest first.
    func restrictedProfiles() async throws -> [RestrictedProfile]
}

extension ProfileRepository: ProfileRestricting {
    public func isRestricted(_ profileID: ProfileID) async throws -> Bool {
        let viewer = try await resolveViewerProfileID()
        guard viewer != profileID else { return false }
        var request = SocialGraph_V1_GetRelationStatusRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.getRelationStatus(request: request, headers: [:])
        switch response.result {
        case .success(let view): return view.restricted
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func setRestricted(_ restricted: Bool, for profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "setRestricted")
        guard viewer != profileID else { return }
        if restricted {
            var request = SocialGraph_V1_RestrictRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.restrict(request: request, headers: [:]))
        } else {
            var request = SocialGraph_V1_UnrestrictRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unrestrict(request: request, headers: [:]))
        }
    }

    public func restrictedProfiles() async throws -> [RestrictedProfile] {
        let viewer = try await resolveViewerProfileID()
        var summaries: [SocialGraph_V1_RestrictedSummary] = []
        var pageToken = ""
        for _ in 0..<20 {
            var request = SocialGraph_V1_ListRestrictedRequest()
            request.profileID = viewer.rawValue
            request.limit = 100
            request.pageToken = pageToken
            let response = await socialGraphClient.listRestricted(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                summaries += body.restricted
                pageToken = body.nextPageToken
            case .failure(let error):
                throw ProfileError.transport(message: error.message ?? "code \(error.code)")
            }
            if pageToken.isEmpty { break }
        }
        let views = await withTaskGroup(of: (String, Profile_V1_ProfileView?).self) { group in
            for summary in summaries {
                group.addTask { [self] in
                    (summary.profileID, try? await fetchProfileView(id: ProfileID(summary.profileID)))
                }
            }
            var byID: [String: Profile_V1_ProfileView] = [:]
            for await (id, view) in group { byID[id] = view }
            return byID
        }
        return summaries
            .map { summary in
                let view = views[summary.profileID]
                return RestrictedProfile(
                    id: ProfileID(summary.profileID),
                    handle: view?.handle ?? summary.profileID,
                    displayName: view?.displayName ?? "",
                    avatarURL: view.flatMap { URL(string: $0.avatarURL) },
                    restrictedAt: summary.hasRestrictedAt ? summary.restrictedAt.date : nil
                )
            }
            .sorted { ($0.restrictedAt ?? .distantPast) > ($1.restrictedAt ?? .distantPast) }
    }
}

// MARK: - Temporary limits

/// Who a temporary limit holds back (#416, backend #736).
public enum InteractionLimitAudience: Equatable, Sendable, CaseIterable {
    /// Everyone who doesn't follow you.
    case nonFollowers
    /// Non-followers, and anyone who followed you less than a week ago.
    case recentFollowers

    public var title: String {
        switch self {
        case .nonFollowers: "People Who Don't Follow You"
        case .recentFollowers: "Non-Followers and Recent Followers"
        }
    }

    init?(_ proto: Profile_V1_LimitAudience) {
        switch proto {
        case .nonFollowers: self = .nonFollowers
        case .recentFollowers: self = .recentFollowers
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Profile_V1_LimitAudience {
        switch self {
        case .nonFollowers: .nonFollowers
        case .recentFollowers: .recentFollowers
        }
    }
}

/// A temporary limit: while it's on, comments and messages from its
/// audience are held for you to review instead of shown.
public struct InteractionLimit: Equatable, Sendable {
    /// At most four weeks ahead (backend #736).
    public static let maximumDays = 28
    public static let durations = [1, 3, 7, 14, 28]

    public var audience: InteractionLimitAudience
    public var until: Date

    public init(audience: InteractionLimitAudience, until: Date) {
        self.audience = audience
        self.until = until
    }
}

/// Settings → Safety → Limit Interactions; and the sound-reuse permission.
public protocol InteractionLimitsManaging: Sendable {
    /// Nil when no limit is on (or it has ended).
    func interactionLimit() async throws -> InteractionLimit?
    func setInteractionLimit(_ limit: InteractionLimit) async throws
    func clearInteractionLimit() async throws
    /// Whether others may reuse this profile's original sounds (#416,
    /// backend #735: enforced when a post is created).
    func allowsSoundReuse() async throws -> Bool
    func setAllowsSoundReuse(_ allowed: Bool) async throws
}

extension ProfileRepository: InteractionLimitsManaging {
    public func interactionLimit() async throws -> InteractionLimit? {
        let settings = try await fetchProfileView(id: try await resolveViewerProfileID()).interactionSettings
        guard settings.hasLimit, let audience = InteractionLimitAudience(settings.limit.audience) else { return nil }
        let until = Date(timeIntervalSince1970: TimeInterval(settings.limit.untilMs) / 1_000)
        return until > Date() ? InteractionLimit(audience: audience, until: until) : nil
    }

    public func setInteractionLimit(_ limit: InteractionLimit) async throws {
        var request = Profile_V1_SetInteractionLimitRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setInteractionLimit").rawValue
        request.audience = limit.audience.proto
        request.untilMs = Int64(limit.until.timeIntervalSince1970 * 1_000)
        let response = await profileClient.setInteractionLimit(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func clearInteractionLimit() async throws {
        var request = Profile_V1_ClearInteractionLimitRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "clearInteractionLimit").rawValue
        let response = await profileClient.clearInteractionLimit(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func allowsSoundReuse() async throws -> Bool {
        let settings = try await fetchProfileView(id: try await resolveViewerProfileID()).interactionSettings
        return settings.hasAllowSoundReuse ? settings.allowSoundReuse : true
    }

    /// `SetInteractionSettings` takes the audiences whole, so they're read
    /// back and sent unchanged; remix is left out, which keeps it.
    public func setAllowsSoundReuse(_ allowed: Bool) async throws {
        let profileID = try await resolveViewerProfileID(forWrite: "setAllowsSoundReuse")
        let current = try await fetchProfileView(id: profileID).interactionSettings
        var settings = Profile_V1_InteractionSettings()
        settings.comments = current.comments == .unspecified ? .everyone : current.comments
        settings.mentions = current.mentions == .unspecified ? .everyone : current.mentions
        settings.messages = current.messages == .unspecified ? .everyone : current.messages
        settings.allowDownloads = current.allowDownloads
        settings.showLikeCounts = current.showLikeCounts
        settings.allowSoundReuse = allowed
        var request = Profile_V1_SetInteractionSettingsRequest()
        request.profileID = profileID.rawValue
        request.settings = settings
        let response = await profileClient.setInteractionSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
