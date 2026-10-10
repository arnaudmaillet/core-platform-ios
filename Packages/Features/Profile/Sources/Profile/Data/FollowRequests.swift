import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// What a Follow tap did: followed, or asked a private profile (#396,
/// backend #655).
public enum FollowOutcome: Equatable, Sendable {
    case following
    case requested
}

/// The requester's half of follow requests: following a private profile asks,
/// and the request can be withdrawn while it's pending.
public protocol FollowRequestSending: Sendable {
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome
    /// Withdraws a pending request; succeeds if none is pending any more.
    func cancelFollowRequest(to profileID: ProfileID) async throws
}

/// Someone asking to follow the active (private) profile.
public struct FollowRequest: Hashable, Sendable {
    public let id: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let requestedAt: Date?

    public init(id: ProfileID, handle: String, displayName: String, avatarURL: URL?, requestedAt: Date?) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.requestedAt = requestedAt
    }
}

/// The owner's half: the requests inbox (Settings → Privacy → Follow
/// Requests). Approving makes a real follow; declining tells no one.
public protocol FollowRequestsManaging: Sendable {
    /// Newest first.
    func followRequests() async throws -> [FollowRequest]
    /// How many are pending, without reading each requester's profile.
    func pendingFollowRequestCount() async throws -> Int
    func approveFollowRequest(from profileID: ProfileID) async throws
    func declineFollowRequest(from profileID: ProfileID) async throws
}

extension ProfileRepository: FollowRequestSending, FollowRequestsManaging {
    public func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
        let viewer = try await resolveViewerProfileID(forWrite: "follow")
        guard viewer != profileID else { return .following }
        var request = SocialGraph_V1_FollowRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.follow(request: request, headers: [:])
        try Self.ensureAccepted(response)
        if response.message?.requested == true { return .requested }
        followEvents?.publish(FollowChange(profileID: profileID, isFollowing: true))
        return .following
    }

    public func cancelFollowRequest(to profileID: ProfileID) async throws {
        let viewer = try await resolveViewerProfileID(forWrite: "cancelFollowRequest")
        var request = SocialGraph_V1_CancelFollowRequestRequest()
        request.actorID = viewer.rawValue
        request.targetID = profileID.rawValue
        let response = await socialGraphClient.cancelFollowRequest(request: request, headers: [:])
        // SGR-1006: nothing pending any more (answered meanwhile): the
        // withdrawal's goal is met either way.
        if let error = response.error, (error.message ?? "").contains("SGR-1006") { return }
        try Self.ensureAccepted(response)
    }

    public func pendingFollowRequestCount() async throws -> Int {
        try await followRequestSummaries().count
    }

    public func followRequests() async throws -> [FollowRequest] {
        let summaries = try await followRequestSummaries()
        // One read per requester (no batch read). A requester that no longer
        // resolves still lists, by id, so the request can be answered.
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
        return summaries.map { summary in
            let view = views[summary.profileID]
            return FollowRequest(
                id: ProfileID(summary.profileID),
                handle: view?.handle ?? summary.profileID,
                displayName: view?.displayName ?? "",
                avatarURL: view.flatMap { URL(string: $0.avatarURL) },
                requestedAt: summary.hasFollowedAt ? summary.followedAt.date : nil
            )
        }
    }

    private func followRequestSummaries() async throws -> [SocialGraph_V1_EdgeSummary] {
        let owner = try await resolveViewerProfileID()
        // Bounded, like the block list: a server that kept handing back a
        // page token must not spin this loop forever.
        return try await TokenPager.collect(maxPages: 20) { pageToken in
            var request = SocialGraph_V1_ListFollowRequestsRequest()
            request.ownerID = owner.rawValue
            request.limit = 50
            request.pageToken = pageToken
            let response = await socialGraphClient.listFollowRequests(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                return (body.requests, body.nextPageToken)
            case .failure(let error):
                throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
        }
    }

    public func approveFollowRequest(from profileID: ProfileID) async throws {
        try await answer(profileID, approve: true)
    }

    public func declineFollowRequest(from profileID: ProfileID) async throws {
        try await answer(profileID, approve: false)
    }

    private func answer(_ requester: ProfileID, approve: Bool) async throws {
        let owner = try await resolveViewerProfileID(forWrite: approve ? "approveFollowRequest" : "declineFollowRequest")
        var request = SocialGraph_V1_AnswerFollowRequestRequest()
        request.ownerID = owner.rawValue
        request.requesterID = requester.rawValue
        let response = approve
            ? await socialGraphClient.approveFollowRequest(request: request, headers: [:])
            : await socialGraphClient.declineFollowRequest(request: request, headers: [:])
        try Self.ensureAccepted(response)
    }
}
