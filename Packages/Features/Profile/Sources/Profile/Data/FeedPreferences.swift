import CoreContracts
import CoreModels
import CoreNetworking
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

/// Settings → What You See: Sensitive Content (#407) and Personalised For
/// You (#413). Both live in one `profile.v1.FeedSettings`, which
/// `SetFeedSettings` replaces whole, so each write carries the other's
/// current value.
public protocol FeedPreferencesManaging: Sendable {
    func sensitiveContent() async throws -> SensitiveContentLevel
    func setSensitiveContent(_ level: SensitiveContentLevel) async throws
    /// Whether For You is ranked by the profile's interest tags. Off is
    /// `non_personalized`: tags are ignored and none are learnt (DSA Art.
    /// 38); turning it off also erases the learnt ones.
    func personalizedFeed() async throws -> Bool
    func setPersonalizedFeed(_ isOn: Bool) async throws
}

extension ProfileRepository: FeedPreferencesManaging {
    public func sensitiveContent() async throws -> SensitiveContentLevel {
        SensitiveContentLevel(try await currentFeedSettings().sensitiveContent)
    }

    public func setSensitiveContent(_ level: SensitiveContentLevel) async throws {
        try await writeFeedSettings(as: "setSensitiveContent") { $0.sensitiveContent = level.proto }
    }

    public func personalizedFeed() async throws -> Bool {
        !(try await currentFeedSettings().nonPersonalized)
    }

    public func setPersonalizedFeed(_ isOn: Bool) async throws {
        try await writeFeedSettings(as: "setPersonalizedFeed") { $0.nonPersonalized = !isOn }
    }

    /// Owner-only on the view: the active profile reading itself.
    private func currentFeedSettings() async throws -> Profile_V1_FeedSettings {
        try await fetchProfileView(id: try await resolveViewerProfileID()).feedSettings
    }

    /// Reads the stored settings, changes one field, and writes the whole set
    /// back — a write that sent only its own field would reset the other.
    private func writeFeedSettings(as write: String, _ change: (inout Profile_V1_FeedSettings) -> Void) async throws {
        let profileID = try await resolveViewerProfileID(forWrite: write)
        var settings = try await fetchProfileView(id: profileID).feedSettings
        change(&settings)
        var request = Profile_V1_SetFeedSettingsRequest()
        request.profileID = profileID.rawValue
        request.settings = settings
        let response = await profileClient.setFeedSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}
