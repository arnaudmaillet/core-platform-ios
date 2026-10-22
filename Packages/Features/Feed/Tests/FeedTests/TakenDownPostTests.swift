import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import LocalStore
import Testing
import MediaCore
import UIKit
@testable import Feed

private struct Unreachable: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

/// A post moderation takes down (#447, backend #688) reads "This post isn't
/// available" wherever it can surface after it was seen: the repository's
/// warm post cache used to keep serving it until the LRU let it go, so a
/// detail or a comment sheet opened on it showed the post.
@MainActor
struct TakenDownPostTests {
    private struct Member: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private struct Fixture {
        let backend: MockBackend
        let repository: FeedRepository
        let postID: PostID
    }

    private func makeFixture(localCache: FeedLocalCache? = nil) throws -> Fixture {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Member(),
            localCache: localCache
        )
        let postID = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-5" }?.postID)
        return Fixture(backend: backend, repository: repository, postID: PostID(postID))
    }

    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func revalidatingACachedTakenDownPostSaysNotFoundAndForgetsIt() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.repository.loadPost(fixture.postID)
        #expect(fixture.repository.peekPost(fixture.postID) != nil, "warm")

        fixture.backend.socialServices.takeDown(fixture.postID.rawValue)
        await #expect(throws: FeedError.notFound) { _ = try await fixture.repository.revalidatePost(fixture.postID) }
        #expect(fixture.repository.peekPost(fixture.postID) == nil, "out of the warm cache")
        await #expect(throws: FeedError.notFound) { _ = try await fixture.repository.loadPost(fixture.postID) }
    }

    /// The detail opens on the warm copy, then the server's answer replaces it.
    @Test func aDetailOpenedOnACachedTakenDownPostReadsUnavailable() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.repository.loadPost(fixture.postID)
        fixture.backend.socialServices.takeDown(fixture.postID.rawValue)

        let viewModel = PostDetailViewModel(postID: fixture.postID, repository: fixture.repository)
        var phases: [PostDetailViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { phases.last == .unavailable(message: PostDetailViewModel.unavailableMessage) })
        if case .content = phases.first {} else { Issue.record("expected the warm copy first, got \(String(describing: phases.first))") }
        withExtendedLifetime(viewModel) {}
    }

    private func labels(in view: UIView) -> [String] {
        ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.filter { !$0.isHidden }.flatMap(labels(in:))
    }

    /// The comments panel says so too: an answer,
    /// not an empty "No comments yet" over a post no one may read.
    @Test func aCommentSheetOnATakenDownPostSaysThePostIsNotAvailable() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.repository.loadPost(fixture.postID)
        fixture.backend.socialServices.takeDown(fixture.postID.rawValue)

        let viewModel = PostDetailViewModel(postID: fixture.postID, repository: fixture.repository)
        let sheet = PostDetailViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: Unreachable())
        )
        sheet.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        sheet.loadViewIfNeeded()
        #expect(await settle {
            sheet.view.layoutIfNeeded()
            return labels(in: sheet.view).contains(PostDetailViewModel.unavailableMessage)
        })
        #expect(!labels(in: sheet.view).contains { $0.localizedCaseInsensitiveContains("no comments") })
    }

    /// A warm post the server still shows comes back as its copy: one
    /// `GetPost` confirms it, and nothing changed means no second render.
    @Test func aWarmPostStillShownComesBackAsItsCopy() async throws {
        let fixture = try makeFixture()
        let warm = try await fixture.repository.loadPost(fixture.postID)
        #expect(try await fixture.repository.revalidatePost(fixture.postID) == warm)
    }

    /// The viewer's own just-published post is the client's (`remember`):
    /// the fleet may not serve it yet, so its `NOT_FOUND` keeps the copy.
    @Test func aRememberedPostTheFleetDoesNotServeYetKeepsItsCopy() async throws {
        let fixture = try makeFixture()
        let mine = FeedEntry(
            post: Post(id: PostID("just-written"), authorID: ProfileID(MockSocialDataset.viewerProfileID), caption: "mine", attachments: [], publishedAt: Date()),
            author: AuthorSummary(id: ProfileID(MockSocialDataset.viewerProfileID), handle: "you", displayName: "You", avatarURL: nil),
            likeCount: 0
        )
        await fixture.repository.remember(mine)
        #expect(try await fixture.repository.revalidatePost(PostID("just-written")) == mine)
    }

    /// A feed page whose post the server no longer shows drops it, and its
    /// cached copy goes too.
    @Test func aPageThatDropsATakenDownPostForgetsItsCopy() async throws {
        let fixture = try makeFixture()
        let first = try await fixture.repository.loadFirstPage()
        // Someone else's: its author would still read their own.
        let ownAccount = fixture.backend.dataset.profileIDs(inAccount: MockAuthService.accountID)
        let shown = try #require(first.entries.first { !ownAccount.contains($0.author.id.rawValue) }?.post.id)
        _ = try await fixture.repository.loadPost(shown)
        fixture.backend.socialServices.takeDown(shown.rawValue)

        let again = try await fixture.repository.loadFirstPage()
        #expect(!again.entries.contains { $0.post.id == shown })
        #expect(fixture.repository.peekPost(shown) == nil)
    }

    /// The device's copy goes too: the next cold start's first page, and the
    /// posts a cold start rebuilds from, no longer hold it.
    @Test func aTakenDownPostLeavesTheDeviceCache() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "TakenDownPostTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LocalStore(directory: folder, viewer: { .member(account: MockAuthService.accountID, profile: nil) })
        let cache = FeedLocalCache(store: store)
        let fixture = try makeFixture(localCache: cache)
        let first = try await fixture.repository.loadFirstPage()
        let ownAccount = fixture.backend.dataset.profileIDs(inAccount: MockAuthService.accountID)
        let shown = try #require(first.entries.first { !ownAccount.contains($0.author.id.rawValue) }?.post.id)
        #expect(cache.firstPage(of: .following)?.entries.contains { $0.post.id == shown } == true, "stored")

        fixture.backend.socialServices.takeDown(shown.rawValue)
        await #expect(throws: FeedError.notFound) { _ = try await fixture.repository.revalidatePost(shown) }
        #expect(cache.firstPage(of: .following)?.entries.contains { $0.post.id == shown } == false)
        #expect(!cache.storedPosts(limit: 300).contains { $0.entry.post.id == shown })
    }
}
