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

/// A member's bearer: the mock's like reads and `wallet.Stake` know the
/// caller by it (#676).
private struct MemberToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

/// Drives the full read path — repository → generated clients → real
/// ProtocolClient → MockBFF — with production wire bytes, in-process.
struct FeedRepositoryTests {
    private func makeRepository(dataset: MockSocialDataset = MockSocialDataset()) -> (FeedRepository, MockBFF) {
        let bff = MockBFF()
        let store = MockCounterStore(dataset: dataset)
        MockSocialServices(dataset: dataset).register(on: bff)
        MockEngagementService(store: store).register(on: bff)
        MockWalletService(store: store, dataset: dataset).register(on: bff)
        MockCounterService(store: store).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        let session = AuthenticatedSessionStub()
        let viewer = ViewerSession(authSession: session) { account in
            try await AccountProfilesReader.profileIDs(
                ofAccount: account.rawValue, using: Profile_V1_ProfileServiceClient(client: client)
            ).map { ProfileID($0) }
        }
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            likeStaking: WalletLikeStaking(walletClient: Wallet_V1_WalletServiceClient(client: client), viewer: viewer),
            authSession: session,
            viewer: viewer,
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
        // The corpus is led by the staged arrivals — the posts For You badges
        // as new. See `MockSocialDataset.justArrivedRecords`.
        #expect(first.post.id == PostID("post-new-00"))
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
        let dataset = MockSocialDataset(postCount: 45)
        let (repository, _) = makeRepository(dataset: dataset)
        // `postCount` sizes the seeded corpus; the staged arrivals ride on top
        // of it, so the total is asked for rather than restated.
        let total = dataset.posts.count

        var seen: [PostID] = []
        var page = try await repository.loadFirstPage()
        seen += page.entries.map(\.post.id)
        while let token = page.nextPageToken {
            page = try await repository.loadPage(afterToken: token)
            seen += page.entries.map(\.post.id)
            #expect(!page.isCold) // only the first request is cold
        }

        #expect(seen.count == total)
        #expect(Set(seen).count == total)
        #expect(page.nextPageToken == nil)
    }

    @Test func authorHydrationIsDeduplicatedAndCachedAcrossPages() async throws {
        let (repository, bff) = makeRepository()

        func profileCalls() -> [String] {
            bff.recordedRequests
                .filter { $0.path == "/profile.v1.ProfileService/GetProfileById" }
                .map(\.path)
        }

        let first = try await repository.loadFirstPage()
        let callsAfterFirst = profileCalls().count
        // One call per DISTINCT author on the page, never one per item —
        // expressed against the page itself so it holds at any dataset size.
        let authorsOnFirstPage = Set(first.entries.map(\.post.authorID))
        #expect(callsAfterFirst == authorsOnFirstPage.count)

        let second = try await repository.loadPage(afterToken: "20")
        let callsAfterSecond = profileCalls().count
        // The cache holds across pages: the only new calls are for authors the
        // first page never showed. Repeat authors cost nothing — which is what
        // carries the deduplication claim now that the roster is larger than a
        // page and the first page has no repeats of its own to prove it.
        let newAuthors = Set(second.entries.map(\.post.authorID)).subtracting(authorsOnFirstPage)
        #expect(callsAfterSecond - callsAfterFirst == newAuthors.count)
    }

    @Test func pagesHydrateLikeCountsWithOneBatchedRead() async throws {
        let (repository, bff) = makeRepository()

        let page = try await repository.loadFirstPage()

        // Seeded store: every hydrated entry carries a nonzero count.
        #expect(page.entries.allSatisfy { $0.likeCount > 0 })
        // engagement.v1 `BatchGetLikes` since #676: batched, not per-post.
        let likeReads = bff.recordedRequests.filter { $0.path == "/engagement.v1.EngagementService/BatchGetLikes" }
        #expect(likeReads.count == 1)
    }

    /// ⚠️ A LIKE IS A POINT (#676): each like stakes one through
    /// `wallet.Stake` and adds one to the count `BatchGetLikes` reads back.
    /// There is no unlike.
    @Test func eachLikeStakesAPointTheCountReadsBack() async throws {
        let (repository, bff) = makeRepository()
        _ = try await repository.loadFirstPage() // resolves the viewer profile
        let postID = try #require(MockSocialDataset().posts.first {
            MockSocialDataset().accountID(for: $0.authorProfileID) != MockAuthService.accountID
        }).postID.asPostID
        let before = try await repository.likeCounts(for: [postID])[postID] ?? 0

        try await repository.like(postID)
        #expect(try await repository.likeCounts(for: [postID])[postID] == before + 1)
        try await repository.like(postID)
        #expect(try await repository.likeCounts(for: [postID])[postID] == before + 2)
        #expect(bff.recordedRequests.contains { $0.path == "/wallet.v1.WalletService/Stake" })
        #expect(!bff.recordedRequests.contains { $0.path.contains("Reaction") })
    }

    /// One's own post is refused (`OWN_CONTENT`): the like throws, so the
    /// caller rolls back.
    @Test func likingOnesOwnPostIsRefused() async throws {
        let (repository, _) = makeRepository()
        _ = try await repository.loadFirstPage()
        let own = try #require(MockSocialDataset().posts.first {
            MockSocialDataset().accountID(for: $0.authorProfileID) == MockAuthService.accountID
        }).postID.asPostID
        await #expect(throws: LikeRefused(outcome: .ownContent)) { try await repository.like(own) }
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

private extension String {
    var asPostID: PostID { PostID(self) }
}
