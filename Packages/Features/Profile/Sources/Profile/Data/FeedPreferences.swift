import CoreContracts
import CoreModels
import Foundation

/// How much sensitive content the active profile's feeds may show (#407,
/// backend #731), synced across devices on the profile.
public enum SensitiveContentLevel: Equatable, Sendable, CaseIterable {
    /// The default: posts marked sensitive (age-gated) stay out.
    case less
    /// Posts marked sensitive can show. Never for under-18s: the server
    /// clamps teens and guests to Less whatever is stored.
    case standard

    public var title: String {
        switch self {
        case .less: "Less"
        case .standard: "Standard"
        }
    }

    public var detail: String {
        switch self {
        case .less: "Posts marked as sensitive stay out of your feeds."
        case .standard: "Posts marked as sensitive can show. They're never shown to people under 18."
        }
    }

    init(_ proto: Profile_V1_SensitiveContent) {
        self = proto == .standard ? .standard : .less
    }

    var proto: Profile_V1_SensitiveContent {
        self == .standard ? .standard : .less
    }
}

/// Settings → What You See → Sensitive Content.
public protocol FeedPreferencesManaging: Sendable {
    func sensitiveContent() async throws -> SensitiveContentLevel
    func setSensitiveContent(_ level: SensitiveContentLevel) async throws
}

extension ProfileRepository: FeedPreferencesManaging {
    public func sensitiveContent() async throws -> SensitiveContentLevel {
        // Owner-only on the view: the active profile reading itself.
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return SensitiveContentLevel(view.feedSettings.sensitiveContent)
    }

    public func setSensitiveContent(_ level: SensitiveContentLevel) async throws {
        var request = Profile_V1_SetFeedSettingsRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setSensitiveContent").rawValue
        request.settings.sensitiveContent = level.proto
        let response = await profileClient.setFeedSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
