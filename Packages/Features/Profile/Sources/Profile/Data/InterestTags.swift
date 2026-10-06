import Connect
import CoreContracts
import CoreModels
import Foundation

/// One interest the recommender learnt for the active profile (#413,
/// timeline #662): a hashtag, without its `#`, and how much it weighs today.
public struct InterestTag: Equatable, Hashable, Sendable {
    public let tag: String
    public let weight: Double

    public init(tag: String, weight: Double) {
        self.tag = tag
        self.weight = weight
    }

    init(_ proto: Timeline_V1_Interest) {
        self.init(tag: proto.tag, weight: proto.weight)
    }
}

/// Settings → What You See → Your Interests: the tags that rank For You,
/// which the owner can remove one by one or all at once. Every call answers
/// the tags that remain, heaviest first.
public protocol InterestTagsManaging: Sendable {
    func interests() async throws -> [InterestTag]
    /// Drops `tag` and keeps it out: later reactions no longer teach it.
    func removeInterest(_ tag: String) async throws -> [InterestTag]
    /// Forgets every tag, removed ones included: For You starts over.
    func resetInterests() async throws -> [InterestTag]
}

/// `timeline.v1` ListInterests / RemoveInterest / ResetInterests for the
/// active profile. Owner only: the edge checks the profile is the caller's.
public struct InterestTagsRepository: InterestTagsManaging {
    private let timelineClient: any Timeline_V1_TimelineServiceClientInterface
    private let profiles: ProfileRepository

    public init(timelineClient: any Timeline_V1_TimelineServiceClientInterface, profiles: ProfileRepository) {
        self.timelineClient = timelineClient
        self.profiles = profiles
    }

    public func interests() async throws -> [InterestTag] {
        var request = Timeline_V1_ListInterestsRequest()
        request.profileID = try await profiles.resolveViewerProfileID().rawValue
        return try Self.tags(await timelineClient.listInterests(request: request, headers: [:]))
    }

    public func removeInterest(_ tag: String) async throws -> [InterestTag] {
        var request = Timeline_V1_RemoveInterestRequest()
        request.profileID = try await profiles.resolveViewerProfileID(forWrite: "removeInterest").rawValue
        request.tag = tag
        return try Self.tags(await timelineClient.removeInterest(request: request, headers: [:]))
    }

    public func resetInterests() async throws -> [InterestTag] {
        var request = Timeline_V1_ResetInterestsRequest()
        request.profileID = try await profiles.resolveViewerProfileID(forWrite: "resetInterests").rawValue
        return try Self.tags(await timelineClient.resetInterests(request: request, headers: [:]))
    }

    private static func tags(_ response: ResponseMessage<Timeline_V1_InterestsResponse>) throws -> [InterestTag] {
        switch response.result {
        case .success(let body): return body.interests.map(InterestTag.init)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
