import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// Who may comment on the active profile's posts (#397, backend #714). The
/// server refuses anyone else's comment (`CMT-1005`).
public enum CommentAudience: Equatable, Sendable, CaseIterable {
    case everyone, followers, mutuals, noOne

    public var title: String {
        switch self {
        case .everyone: "Everyone"
        case .followers: "Followers"
        case .mutuals: "Friends"
        case .noOne: "No One"
        }
    }

    init(_ proto: Profile_V1_InteractionAudience) {
        switch proto {
        case .followers: self = .followers
        case .mutuals: self = .mutuals
        case .noOne: self = .noOne
        case .everyone, .unspecified, .UNRECOGNIZED: self = .everyone
        }
    }

    var proto: Profile_V1_InteractionAudience {
        switch self {
        case .everyone: .everyone
        case .followers: .followers
        case .mutuals: .mutuals
        case .noOne: .noOne
        }
    }
}

/// The audiences `profile.v1` sets per interaction share one scale: who can
/// comment, mention and message read the same four choices.
public typealias InteractionAudience = CommentAudience

/// Settings → Privacy → Who Can Mention and Who Can Message (#397, backend
/// #656). Enforced by the server: a post mentioning someone outside their
/// audience is refused (PST-1009); a message from outside it arrives as a
/// request, and with No One it is refused (CHT-1011).
public enum InteractionKind: Equatable, Sendable {
    case mentions, messages
}

public protocol InteractionAudienceManaging: Sendable {
    func audience(for kind: InteractionKind) async throws -> InteractionAudience
    func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) async throws
}

extension ProfileRepository: InteractionAudienceManaging {
    public func audience(for kind: InteractionKind) async throws -> InteractionAudience {
        let settings = try await fetchProfileView(id: try await resolveViewerProfileID()).interactionSettings
        return InteractionAudience(kind == .mentions ? settings.mentions : settings.messages)
    }

    public func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) async throws {
        try await writeInteractionSettings(as: kind == .mentions ? "setMentionAudience" : "setMessageAudience") {
            switch kind {
            case .mentions: $0.mentions = audience.proto
            case .messages: $0.messages = audience.proto
            }
        }
    }
}

/// Settings → Privacy → Who Can Comment.
public protocol CommentAudienceManaging: Sendable {
    func commentAudience() async throws -> CommentAudience
    func setCommentAudience(_ audience: CommentAudience) async throws
}

extension ProfileRepository: CommentAudienceManaging {
    public func commentAudience() async throws -> CommentAudience {
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return CommentAudience(view.interactionSettings.comments)
    }

    public func setCommentAudience(_ audience: CommentAudience) async throws {
        try await writeInteractionSettings(as: "setCommentAudience") { $0.comments = audience.proto }
    }

    /// `SetInteractionSettings` takes the whole set, so the others are read
    /// back and sent unchanged. An unset audience is sent as Everyone, the
    /// default (the server refuses UNSPECIFIED).
    func writeInteractionSettings(
        as write: String, _ change: (inout Profile_V1_InteractionSettings) -> Void
    ) async throws {
        let profileID = try await resolveViewerProfileID(forWrite: write)
        let current = try await fetchProfileView(id: profileID).interactionSettings
        var settings = Profile_V1_InteractionSettings()
        settings.comments = current.comments == .unspecified ? .everyone : current.comments
        settings.mentions = current.mentions == .unspecified ? .everyone : current.mentions
        settings.messages = current.messages == .unspecified ? .everyone : current.messages
        settings.allowDownloads = current.allowDownloads
        settings.showLikeCounts = current.showLikeCounts
        change(&settings)
        // Remix, sound reuse and the limit are left out: absent keeps them.
        var request = Profile_V1_SetInteractionSettingsRequest()
        request.profileID = profileID.rawValue
        request.settings = settings
        let response = await profileClient.setInteractionSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}

/// How others may use the active profile's posts (#397, backend #809): see
/// how many likes they have, and download them. Enforced by the server: a
/// post's view tells each reader whether counts are hidden from them and
/// whether they may download it.
public struct PostSharing: Equatable, Sendable {
    public var showsLikeCounts: Bool
    public var allowsDownloads: Bool

    public init(showsLikeCounts: Bool, allowsDownloads: Bool) {
        self.showsLikeCounts = showsLikeCounts
        self.allowsDownloads = allowsDownloads
    }
}

/// Settings → Privacy → Show Like Counts and Allow Downloads.
public protocol PostSharingManaging: Sendable {
    func postSharing() async throws -> PostSharing
    func setPostSharing(_ sharing: PostSharing) async throws
}

extension ProfileRepository: PostSharingManaging {
    public func postSharing() async throws -> PostSharing {
        let settings = try await fetchProfileView(id: try await resolveViewerProfileID()).interactionSettings
        return PostSharing(showsLikeCounts: settings.showLikeCounts, allowsDownloads: settings.allowDownloads)
    }

    public func setPostSharing(_ sharing: PostSharing) async throws {
        try await writeInteractionSettings(as: "setPostSharing") {
            $0.showLikeCounts = sharing.showsLikeCounts
            $0.allowDownloads = sharing.allowsDownloads
        }
    }
}
