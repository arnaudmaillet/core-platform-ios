import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import EntityStore
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// "Follow from Search → the profile header and the feed's '+' agree"
/// (#896), the Profile half. Search opens a person's profile; the follow
/// made there goes through `ProfileRepository.setFollowing`, which the graph
/// accepts and announces on the app's follow channel (`FollowGraphEvents`).
/// The feeds' "+" reads the store's relation, which hears that channel
/// (`EntityStore.follow`); the search rows hear it too
/// (`SearchFollowChannelTests`). The other way round — a "+" in a feed
/// writes through the same repository — the header hears the channel
/// (`ProfileViewModelTests.aFollowMadeElsewhereReachesTheProfile`).
@MainActor
struct ProfileFollowChannelTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func repository(events: FollowGraphEvents) -> ProfileRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session(),
            followEvents: events
        )
    }

    /// A public person the viewer does not follow yet.
    private func someoneToFollow(_ profiles: ProfileRepository) async throws -> ProfileID {
        for index in 1..<40 {
            let id = ProfileID("prof-\(index)")
            guard case .other(false, _, false)? = try? await profiles.relationship(for: id),
                  (try? await profiles.profile(id: id))?.visibility != .private else { continue }
            return id
        }
        throw CancellationError()
    }

    @Test func aFollowOnAProfileReachesTheFeedsPlus() async throws {
        let events = FollowGraphEvents()
        let profiles = repository(events: events)
        let target = try await someoneToFollow(profiles)
        let entities = EntityStore()
        let subscription = entities.follow(events)
        // The feed's "+" asked the graph earlier: not followed.
        entities.setRelation(.notFollowing, for: target)
        let heard = HeardChanges()
        let listener = events.subscribe { heard.append($0) }

        // Followed from the profile Search opened.
        try await profiles.setFollowing(true, for: target)

        #expect(heard.all == [FollowChange(profileID: target, isFollowing: true)], "announced once, after the graph accepted")
        #expect(entities.relation(to: target) == .following, "the feed's '+' is Following")

        try await profiles.setFollowing(false, for: target)
        #expect(entities.relation(to: target) == .notFollowing)
        withExtendedLifetime((subscription, listener)) {}
    }

    // MARK: - The own profile's "..." (Edit / Delete)

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A row configured before the relationship said "this is the viewer's
    /// own profile" drew no "..."; once it settles the rows are asked again,
    /// and Edit / Delete appear without the row being configured again.
    @Test func theOwnProfilesRowsGainTheirMenuWhenTheRelationshipSettles() throws {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list, tab: .format(.activity)
        )
        var isOwnProfile = false
        page.authorMenuActions = { _ in isOwnProfile ? [.edit {}, .delete {}] : [] }
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.setCorpusComplete(true)
        let posts = (0..<4).map { index in
            var post = GalleryPost(
                id: PostID("p\(index)"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: "Post \(index)", publishedAtMS: Int64(10_000 - index)
            )
            post.authorID = ProfileID("prof-demo")
            post.authorName = "Demo Viewer"
            post.authorHandle = "you"
            return post
        }
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        let path = try #require(page.debugIndexPath(for: PostID("p0")))
        let row = try #require(page.collectionView.cellForItem(at: path) as? PostGridListRowCell)
        #expect(!row.debugShowsAuthorMenu)

        // The relationship lands: the viewer's own profile.
        isOwnProfile = true
        page.refreshAuthorMenus()

        #expect(row.debugShowsAuthorMenu)
    }
}

/// Changes heard on the channel, from whatever thread published them.
private final class HeardChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [FollowChange] = []

    func append(_ change: FollowChange) { lock.withLock { changes.append(change) } }
    var all: [FollowChange] { lock.withLock { changes } }
}
