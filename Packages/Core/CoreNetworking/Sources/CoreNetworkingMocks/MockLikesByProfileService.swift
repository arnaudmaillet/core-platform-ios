import Connect
import CoreContracts
import Foundation

/// Fake of engagement.v1 `ListLikesByProfile` (#411): the posts a profile's
/// account staked on, newest first, paged by an offset token. Empty for
/// anyone but the profile's own account while its owner hides the Liked tab
/// (`TabSettings.show_likes`) — the server's rule.
public final class MockLikesByProfileService: @unchecked Sendable {
    private let store: MockCounterStore
    private let dataset: MockSocialDataset
    /// Whether the profile's owner shows its Liked tab.
    private let showsLikes: @Sendable (String) -> Bool

    public init(
        store: MockCounterStore,
        dataset: MockSocialDataset,
        showsLikes: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.store = store
        self.dataset = dataset
        self.showsLikes = showsLikes
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/engagement.v1.EngagementService/ListLikesByProfile") { [self] (request: Engagement_V1_ListLikesByProfileRequest, headers: Headers) -> Result<Engagement_V1_ListLikesByProfileResponse, ConnectError> in
            var response = Engagement_V1_ListLikesByProfileResponse()
            let account = dataset.accountID(for: request.profileID)
            let isOwner = MockEngagementService.account(from: headers) == account
            guard !account.isEmpty, isOwner || showsLikes(request.profileID) else { return .success(response) }
            let all = store.likedPosts(by: account)
            let limit = request.limit <= 0 ? 30 : min(Int(request.limit), 100)
            let start = min(max(Int(request.pageToken) ?? 0, 0), all.count)
            let end = min(start + limit, all.count)
            response.postIds = Array(all[start..<end])
            response.nextPageToken = end < all.count ? String(end) : ""
            return .success(response)
        }
    }
}
