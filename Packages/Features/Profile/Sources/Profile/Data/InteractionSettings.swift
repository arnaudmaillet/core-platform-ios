import CoreContracts
import CoreModels
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

    /// `SetInteractionSettings` takes the whole set, so the others are read
    /// back and sent unchanged. An unset audience is sent as Everyone, the
    /// default (the server refuses UNSPECIFIED).
    public func setCommentAudience(_ audience: CommentAudience) async throws {
        let profileID = try await resolveViewerProfileID(forWrite: "setCommentAudience")
        let current = try await fetchProfileView(id: profileID).interactionSettings
        var settings = Profile_V1_InteractionSettings()
        settings.comments = audience.proto
        settings.mentions = current.mentions == .unspecified ? .everyone : current.mentions
        settings.messages = current.messages == .unspecified ? .everyone : current.messages
        settings.allowDownloads = current.allowDownloads
        settings.showLikeCounts = current.showLikeCounts
        // Remix, sound reuse and the limit are left out: absent keeps them.
        var request = Profile_V1_SetInteractionSettingsRequest()
        request.profileID = profileID.rawValue
        request.settings = settings
        let response = await profileClient.setInteractionSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
