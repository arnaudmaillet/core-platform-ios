import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

/// A post the server shows to no one but its author (#447, backend
/// #686/#688/#691: a draft, a deleted or taken-down post, one withheld by a
/// block or a private author's audience) is an answer: "This post isn't
/// available", without Try Again — not "Couldn't load this post".
@MainActor
struct UnavailablePostTests {
    private final class Provider: FeedProviding, @unchecked Sendable {
        let answer: Result<FeedEntry, FeedError>
        let peekable: FeedEntry?
        init(_ answer: Result<FeedEntry, FeedError>, peekable: FeedEntry? = nil) {
            self.answer = answer
            self.peekable = peekable
        }
        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { peekable }
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { try answer.get() }
    }

    private struct Member: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func entry() -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID("post-1"), authorID: ProfileID("prof-9"), caption: "hello", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("prof-9"), handle: "ava", displayName: "Ava Moreau", avatarURL: nil),
            likeCount: 1
        )
    }

    @Test func aPostShownToNoOneReadsUnavailable() async {
        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: Provider(.failure(.notFound)))
        var last: PostDetailViewModel.Phase?
        viewModel.onPhaseChange = { last = $0 }
        viewModel.viewDidLoad()
        #expect(await settle { last == .unavailable(message: "This post isn\u{2019}t available") })
    }

    /// Opened on the cached post, the server's answer replaces it.
    @Test func theAnswerReplacesACachedPost() async {
        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: Provider(.failure(.notFound), peekable: entry()))
        var phases: [PostDetailViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { phases.last == .unavailable(message: PostDetailViewModel.unavailableMessage) })
        if case .content = phases.first {} else { Issue.record("expected the cached post first, got \(String(describing: phases.first))") }
    }

    /// Over the mock: a post whose author blocked the viewer reads as not
    /// found, which the repository says as `.notFound`.
    @Test func theRepositorySaysNotFoundForAWithheldPost() async throws {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        var block = SocialGraph_V1_BlockRequest()
        block.actorID = "prof-4"
        block.targetID = MockSocialDataset.viewerProfileID
        _ = await SocialGraph_V1_SocialGraphServiceClient(client: client).block(request: block, headers: [:])
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Member(),
            localCache: nil
        )
        let withheld = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-4" }?.postID)
        let visible = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-5" }?.postID)

        await #expect(throws: FeedError.notFound) { _ = try await repository.loadPost(PostID(withheld)) }
        #expect(try await repository.loadPost(PostID(visible)).post.id == PostID(visible))
    }
}
