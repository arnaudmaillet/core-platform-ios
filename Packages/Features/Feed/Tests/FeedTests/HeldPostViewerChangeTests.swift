import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import EntityStore
import Foundation
import MediaCore
import Testing
@testable import Feed

/// A post the app holds is served without the server (`heldEntry`: a place's
/// gallery, a map cluster), so what is held must be the viewer's (#2152). Over
/// the mock: after a sign-out or a profile switch, `galleryPosts` asks the
/// server again, and a post the next viewer may not read is left out.
@MainActor
struct HeldPostViewerChangeTests {
    /// The token the mock reads the viewer from: the demo member (any
    /// non-guest token) or a guest (`gt-…`).
    private final class Viewer: AuthTokenProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var token = "member-token"
        func become(_ token: String) { lock.withLock { self.token = token } }
        func validAccessToken() async throws -> String? { lock.withLock { self.token } }
    }

    private struct Member: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private let backend = MockBackend()
    private let viewer = Viewer()
    private let entities = EntityStore()

    private func makeRepository() -> FeedRepository {
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: viewer, httpClient: backend.bff
        )
        return FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Member(),
            localCache: nil
        )
    }

    private func builder(_ repository: FeedRepository) -> FeedFeatureBuilder {
        FeedFeatureBuilder(
            repository: repository, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), entities: entities
        )
    }

    private func firstPost(of profileID: String) throws -> PostID {
        PostID(try #require(backend.dataset.posts.first { $0.authorProfileID == profileID }?.postID))
    }

    /// What the app does on a viewer change: the repository and the store
    /// (the coordinator's `.viewerChanged`) forget what they read.
    private func change(_ repository: FeedRepository, to state: ViewerState) async {
        await repository.viewerDidChange(state)
        entities.viewerDidChange()
    }

    /// prof-1 is private and followed by the demo member.
    @Test func aSignOutLeavesTheMembersPostsOutOfTheGuestsGallery() async throws {
        #expect(backend.dataset.isRelationshipsPrivate("prof-1"))
        let repository = makeRepository()
        let feed = builder(repository)
        let id = try firstPost(of: "prof-1")
        // A list loaded it and wrote it to the store, as lists do.
        entities.upsert([try await repository.loadPost(id)])
        #expect(await feed.galleryPosts([id]).keys.contains(id))

        viewer.become("gt-guest")
        await change(repository, to: .guest)

        #expect(feed.heldGalleryPost(id) == nil, "held for the member, not the guest")
        #expect(await feed.galleryPosts([id]).isEmpty, "the guest's GetPost refuses it")
    }

    /// The seeded block (prof-4 blocks the viewer) stands for the next
    /// profile's.
    @Test func aProfileSwitchLeavesABlockedPostOutOfTheGallery() async throws {
        let repository = makeRepository()
        let feed = builder(repository)
        let id = try firstPost(of: "prof-4")
        entities.upsert([try await repository.loadPost(id)])

        var block = SocialGraph_V1_BlockRequest()
        block.actorID = "prof-4"
        block.targetID = MockSocialDataset.viewerProfileID
        _ = await SocialGraph_V1_SocialGraphServiceClient(client: backend.makeRPCClient()).block(request: block, headers: [:])
        await change(repository, to: .member(AccountID(MockAuthService.accountID), activeProfile: ProfileID("prof-2")))

        #expect(feed.heldGalleryPost(id) == nil)
        #expect(await feed.galleryPosts([id]).isEmpty)
    }

    /// A public post is still the guest's: read again, and held again.
    @Test func aPublicPostComesBackForTheNextViewer() async throws {
        let repository = makeRepository()
        let feed = builder(repository)
        let id = try firstPost(of: "prof-4")
        entities.upsert([try await repository.loadPost(id)])

        viewer.become("gt-guest")
        await change(repository, to: .guest)

        #expect(await feed.galleryPosts([id]).keys.contains(id))
    }
}
