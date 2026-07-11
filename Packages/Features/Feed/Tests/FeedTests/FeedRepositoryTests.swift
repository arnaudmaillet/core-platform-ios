import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct AuthenticatedSessionStub: AuthSessionProviding {
    var accountID = AccountID(MockAuthService.accountID)

    func currentState() async -> AuthState { .authenticated(accountID) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(accountID)); $0.finish() }
    }
    func logout() async {}
}

/// Drives the full read path — repository → generated clients → real
/// ProtocolClient → MockBFF — with production wire bytes, in-process.
struct FeedRepositoryTests {
    private func makeRepository(dataset: MockSocialDataset = MockSocialDataset()) -> (FeedRepository, MockBFF) {
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset).register(on: bff)
        MockEngagementService(store: store).register(on: bff)
        MockCounterService(store: store).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: AuthenticatedSessionStub(),
            snapshotStore: nil
        )
        return (repository, bff)
    }

    @Test func firstPageIsHydratedOrderedAndCold() async throws {
        let (repository, _) = makeRepository()

        let page = try await repository.loadFirstPage()

        #expect(page.entries.count == 20)
        #expect(page.isCold) // contract: first request hits cold storage
        #expect(page.nextPageToken != nil)
        // Timeline order (newest first) survives concurrent hydration.
        let dates = page.entries.map(\.post.publishedAt)
        #expect(dates == dates.sorted(by: >))
        // Hydration is real: entries carry author and media facts.
        let first = try #require(page.entries.first)
        #expect(!first.author.displayName.isEmpty)
        #expect(first.post.id == PostID("post-0000"))
    }

    @Test func loadPostHydratesSinglePostWithAuthorAndLikes() async throws {
        // Learn a real post id from the first page, then load it directly.
        let (repository, _) = makeRepository()
        let page = try await repository.loadFirstPage()
        let target = try #require(page.entries.first)

        let entry = try await repository.loadPost(target.post.id)

        #expect(entry.post.id == target.post.id)
        #expect(entry.author.id == target.author.id)
        #expect(!entry.author.displayName.isEmpty)
    }

    @Test func paginationWalksTheCursorWithoutDuplicatesUntilExhaustion() async throws {
        let (repository, _) = makeRepository(dataset: MockSocialDataset(postCount: 45))

        var seen: [PostID] = []
        var page = try await repository.loadFirstPage()
        seen += page.entries.map(\.post.id)
        while let token = page.nextPageToken {
            page = try await repository.loadPage(afterToken: token)
            seen += page.entries.map(\.post.id)
            #expect(!page.isCold) // only the first request is cold
        }

        #expect(seen.count == 45)
        #expect(Set(seen).count == 45)
        #expect(page.nextPageToken == nil)
    }

    @Test func authorHydrationIsDeduplicatedAndCachedAcrossPages() async throws {
        let (repository, bff) = makeRepository()

        _ = try await repository.loadFirstPage()
        let profileCallsAfterFirstPage = bff.recordedRequests.filter {
            $0.path == "/profile.v1.ProfileService/GetProfileById"
        }.count
        // 20 items but only 8 distinct authors in the dataset.
        #expect(profileCallsAfterFirstPage == 8)

        _ = try await repository.loadPage(afterToken: "20")
        let profileCallsAfterSecondPage = bff.recordedRequests.filter {
            $0.path == "/profile.v1.ProfileService/GetProfileById"
        }.count
        // Second page reuses the author cache: zero additional profile calls.
        #expect(profileCallsAfterSecondPage == profileCallsAfterFirstPage)
    }

    @Test func pagesHydrateLikeCountsWithOneBatchedCounterRead() async throws {
        let (repository, bff) = makeRepository()

        let page = try await repository.loadFirstPage()

        // Seeded store: every hydrated entry carries a nonzero count.
        #expect(page.entries.allSatisfy { $0.likeCount > 0 })
        let counterCalls = bff.recordedRequests.filter { $0.path == "/counter.v1.CounterService/BatchGetCounters" }
        #expect(counterCalls.count == 1) // batched, not per-post
    }

    @Test func likeRoundTripMutatesAuthoritativeCounts() async throws {
        let (repository, _) = makeRepository()
        _ = try await repository.loadFirstPage() // resolves the viewer profile
        let postID = PostID("post-0000")
        let before = try await repository.likeCounts(for: [postID])[postID] ?? 0

        try await repository.setLiked(true, for: postID)
        #expect(try await repository.likeCounts(for: [postID])[postID] == before + 1)

        // Idempotent per (post, viewer): a second upsert must not double-count.
        try await repository.setLiked(true, for: postID)
        #expect(try await repository.likeCounts(for: [postID])[postID] == before + 1)

        try await repository.setLiked(false, for: postID)
        #expect(try await repository.likeCounts(for: [postID])[postID] == before)
    }

    @Test func viewerProfileIsResolvedOnceViaAccountLookup() async throws {
        let (repository, bff) = makeRepository()

        _ = try await repository.loadFirstPage()
        _ = try await repository.loadPage(afterToken: "20")

        let lookups = bff.recordedRequests.filter {
            $0.path == "/profile.v1.ProfileService/ListProfilesByAccount"
        }
        #expect(lookups.count == 1)
    }

    // MARK: - Post cache / prewarm

    private func getPostCount(_ bff: MockBFF) -> Int {
        bff.recordedRequests.filter { $0.path == "/post.v1.PostService/GetPost" }.count
    }

    @Test func loadPostCachesSoASecondCallSkipsTheNetwork() async throws {
        let (repository, bff) = makeRepository()
        let id = PostID("post-0000")

        _ = try await repository.loadPost(id)
        _ = try await repository.loadPost(id)

        #expect(getPostCount(bff) == 1) // second call served from cache
    }

    @Test func concurrentLoadsOfTheSameIdShareOneFetch() async throws {
        let (repository, bff) = makeRepository()
        let id = PostID("post-0001")

        // Single-flight: three racing callers must collapse to one GetPost.
        async let a = repository.loadPost(id)
        async let b = repository.loadPost(id)
        async let c = repository.loadPost(id)
        _ = try await (a, b, c)

        #expect(getPostCount(bff) == 1)
    }

    @Test func prewarmMakesTheSubsequentLoadServeFromCache() async throws {
        let (repository, bff) = makeRepository()
        let ids = [PostID("post-0002"), PostID("post-0003")]

        await repository.prewarm(ids)
        #expect(getPostCount(bff) == 2) // one fetch per warmed id

        _ = try await repository.loadPost(ids[0])
        #expect(getPostCount(bff) == 2) // tap after warming hits the cache, no new fetch
    }
}
