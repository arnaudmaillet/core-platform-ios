import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// What of a profile the viewer has muted (#403, backend #722). Softer than a
/// block: they aren't told, and follows are untouched.
public enum MuteScope: Equatable, Sendable, CaseIterable {
    case posts, stories, messages

    public var title: String {
        switch self {
        case .posts: "Posts"
        case .stories: "Stories"
        case .messages: "Messages"
        }
    }
}

public struct MuteScopes: Equatable, Hashable, Sendable {
    public var posts: Bool
    public var stories: Bool
    public var messages: Bool

    public static let none = MuteScopes()

    public init(posts: Bool = false, stories: Bool = false, messages: Bool = false) {
        self.posts = posts
        self.stories = stories
        self.messages = messages
    }

    public var isEmpty: Bool { !posts && !stories && !messages }

    public func contains(_ scope: MuteScope) -> Bool {
        switch scope {
        case .posts: posts
        case .stories: stories
        case .messages: messages
        }
    }

    /// These scopes with `scope` switched.
    public func toggling(_ scope: MuteScope) -> MuteScopes {
        var copy = self
        switch scope {
        case .posts: copy.posts.toggle()
        case .stories: copy.stories.toggle()
        case .messages: copy.messages.toggle()
        }
        return copy
    }

    /// "Posts, Messages".
    public var summary: String {
        MuteScope.allCases.filter(contains).map(\.title).joined(separator: ", ")
    }

    init(_ proto: SocialGraph_V1_MuteScopes) {
        self.init(posts: proto.posts, stories: proto.stories, messages: proto.messages)
    }

    var proto: SocialGraph_V1_MuteScopes {
        var proto = SocialGraph_V1_MuteScopes()
        proto.posts = posts
        proto.stories = stories
        proto.messages = messages
        return proto
    }
}

/// A profile the active profile has muted, as Settings lists it.
public struct MutedProfile: Hashable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let scopes: MuteScopes
    public let mutedAt: Date?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?, scopes: MuteScopes, mutedAt: Date?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.scopes = scopes
        self.mutedAt = mutedAt
    }
}

/// Mute from the profile's "..." menu; the muted list in Settings → Safety.
public protocol ProfileMuting: Sendable {
    func muteScopes(for profileID: ProfileID) async throws -> MuteScopes
    /// Replaces the scopes; none unmutes.
    func setMuteScopes(_ scopes: MuteScopes, for profileID: ProfileID) async throws
    func mutedProfiles() async throws -> [MutedProfile]
}

extension ProfileRepository: ProfileMuting {
    public func muteScopes(for profileID: ProfileID) async throws -> MuteScopes {
        let viewer = try await resolveViewerProfileID()
        guard viewer != profileID else { return .none }
        var request = SocialGraph_V1_GetRelationStatusRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.getRelationStatus(request: request, headers: [:])
        switch response.result {
        case .success(let view): return MuteScopes(view.muted)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func setMuteScopes(_ scopes: MuteScopes, for profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "setMuteScopes")
        guard viewer != profileID else { return }
        if scopes.isEmpty {
            var request = SocialGraph_V1_UnmuteRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            try Self.ensureAccepted(await socialGraphClient.unmute(request: request, headers: [:]))
        } else {
            var request = SocialGraph_V1_MuteRequest()
            request.actorID = viewer.rawValue
            request.targetID = profileID.rawValue
            request.scopes = scopes.proto
            try Self.ensureAccepted(await socialGraphClient.mute(request: request, headers: [:]))
        }
    }

    public func mutedProfiles() async throws -> [MutedProfile] {
        let viewer = try await resolveViewerProfileID()
        // Bounded, like the block list.
        let summaries = try await TokenPager.collect(maxPages: 20) { pageToken in
            var request = SocialGraph_V1_ListMutesRequest()
            request.profileID = viewer.rawValue
            request.limit = 100
            request.pageToken = pageToken
            let response = await socialGraphClient.listMutes(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                return (body.mutes, body.nextPageToken)
            case .failure(let error):
                throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
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
                return MutedProfile(
                    id: ProfileID(summary.profileID),
                    handle: view?.handle ?? summary.profileID,
                    displayName: view?.displayName ?? "",
                    avatarURL: view.flatMap { URL(string: $0.avatarURL) },
                    scopes: MuteScopes(summary.scopes),
                    mutedAt: summary.hasMutedAt ? summary.mutedAt.date : nil
                )
            }
            // The wire pages in profile-id order; newest mute first reads better.
            .sorted { ($0.mutedAt ?? .distantPast) > ($1.mutedAt ?? .distantPast) }
    }
}
