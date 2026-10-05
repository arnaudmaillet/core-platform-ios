import CoreContracts
import Foundation

/// Who else may see one of the active profile's relationship lists (#403,
/// backend #720). The owner always sees both.
public enum ListAudience: Equatable, Sendable, CaseIterable {
    case everyone
    case followers
    case mutuals
    case onlyMe

    public var title: String {
        switch self {
        case .everyone: "Everyone"
        case .followers: "Followers"
        case .mutuals: "Friends"
        case .onlyMe: "Only Me"
        }
    }

    public var detail: String {
        switch self {
        case .everyone: "Anyone who can see this profile."
        case .followers: "People who follow this profile."
        case .mutuals: "People this profile follows who follow it back."
        case .onlyMe: "No one else."
        }
    }

    /// Unspecified reads as the default, Everyone.
    init(_ proto: SocialGraph_V1_ListAudience) {
        switch proto {
        case .followers: self = .followers
        case .mutuals: self = .mutuals
        case .onlyMe: self = .onlyMe
        case .everyone, .unspecified, .UNRECOGNIZED: self = .everyone
        }
    }

    var proto: SocialGraph_V1_ListAudience {
        switch self {
        case .everyone: .everyone
        case .followers: .followers
        case .mutuals: .mutuals
        case .onlyMe: .onlyMe
        }
    }
}

/// The audiences of the followers and following lists.
public struct ListPrivacy: Equatable, Sendable {
    public var followers: ListAudience
    public var following: ListAudience

    public init(followers: ListAudience = .everyone, following: ListAudience = .everyone) {
        self.followers = followers
        self.following = following
    }

    init(_ proto: SocialGraph_V1_ListPrivacy) {
        self.init(followers: ListAudience(proto.followers), following: ListAudience(proto.following))
    }
}

/// Settings → Privacy → Followers and Following Lists, enforced by the server:
/// another person's app asks the fleet, which applies these.
public protocol ListPrivacyManaging: Sendable {
    func listPrivacy() async throws -> ListPrivacy
    /// Changes only what is passed; returns what the server now holds.
    func setListPrivacy(followers: ListAudience?, following: ListAudience?) async throws -> ListPrivacy
}

extension ProfileRepository: ListPrivacyManaging {
    public func listPrivacy() async throws -> ListPrivacy {
        var request = SocialGraph_V1_GetListPrivacyRequest()
        request.profileID = try await resolveViewerProfileID().rawValue
        let response = await socialGraphClient.getListPrivacy(request: request, headers: [:])
        switch response.result {
        case .success(let privacy): return ListPrivacy(privacy)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func setListPrivacy(followers: ListAudience?, following: ListAudience?) async throws -> ListPrivacy {
        var request = SocialGraph_V1_SetListPrivacyRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setListPrivacy").rawValue
        // Unspecified keeps that list's current audience.
        request.followers = followers?.proto ?? .unspecified
        request.following = following?.proto ?? .unspecified
        let response = await socialGraphClient.setListPrivacy(request: request, headers: [:])
        switch response.result {
        case .success(let privacy): return ListPrivacy(privacy)
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
