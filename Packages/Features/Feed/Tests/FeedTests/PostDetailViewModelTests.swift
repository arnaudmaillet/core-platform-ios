import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Feed

private final class DetailFeedProvider: FeedProviding, @unchecked Sendable {
    var post: Result<FeedEntry, FeedError>
    init(_ post: Result<FeedEntry, FeedError>) { self.post = post }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { try post.get() }
}

private final class SpyEngagement: EngagementProviding, @unchecked Sendable {
    var setLikedError: Error?
    private let lock = NSLock()
    private(set) var calls: [(liked: Bool, id: PostID)] = []
    func setLiked(_ liked: Bool, for postID: PostID) async throws {
        lock.withLock { calls.append((liked, postID)) }
        if let setLikedError { throw setLikedError }
    }
    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] { [:] }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private struct LikeError: Error {}

private func entry(post: String = "post-1", author: String = "prof-9", likes: Int64 = 10) -> FeedEntry {
    FeedEntry(
        post: Post(id: PostID(post), authorID: ProfileID(author), caption: "hello", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
        author: AuthorSummary(id: ProfileID(author), handle: "ava", displayName: "Ava Moreau", avatarURL: nil),
        likeCount: likes
    )
}

@MainActor
struct PostDetailViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func loadsPostIntoContent() async {
        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: DetailFeedProvider(.success(entry())))
        var lastPhase: PostDetailViewModel.Phase?
        viewModel.onPhaseChange = { lastPhase = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .content(let model) = lastPhase else {
            Issue.record("expected content, got \(String(describing: lastPhase))")
            return
        }
        #expect(model.authorName == "Ava Moreau")
        #expect(model.handle == "@ava")
        #expect(model.caption == "hello")
    }

    @Test func failsWhenPostUnavailable() async {
        let viewModel = PostDetailViewModel(postID: PostID("x"), repository: DetailFeedProvider(.failure(.transport(message: "nope"))))
        var lastPhase: PostDetailViewModel.Phase?
        viewModel.onPhaseChange = { lastPhase = $0 }

        viewModel.viewDidLoad()
        await settle()

        guard case .failed = lastPhase else {
            Issue.record("expected failed, got \(String(describing: lastPhase))")
            return
        }
    }

    @Test func toggleLikeIsOptimisticAndCallsEngagement() async {
        let engagement = SpyEngagement()
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"),
            repository: DetailFeedProvider(.success(entry(likes: 10))),
            engagementProvider: engagement
        )
        var lastEngagement: PostDetailViewModel.EngagementState?
        viewModel.onEngagementChange = { lastEngagement = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleLike()
        #expect(lastEngagement == .init(likeCount: 11, isLiked: true))

        await settle()
        #expect(engagement.calls.map(\.liked) == [true])
    }

    @Test func failedLikeRollsBack() async {
        let engagement = SpyEngagement()
        engagement.setLikedError = LikeError()
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"),
            repository: DetailFeedProvider(.success(entry(likes: 10))),
            engagementProvider: engagement
        )
        var lastEngagement: PostDetailViewModel.EngagementState?
        viewModel.onEngagementChange = { lastEngagement = $0 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleLike()
        await settle()

        #expect(lastEngagement == .init(likeCount: 10, isLiked: false))
    }

    @Test func tappingAuthorRoutesToProfile() async {
        let router = SpyRouter()
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"),
            repository: DetailFeedProvider(.success(entry(author: "prof-9"))),
            router: router
        )
        viewModel.viewDidLoad()
        await settle()

        // The loaded entry's identity slice rides along, pre-seeding the
        // profile screen's navigation chrome.
        viewModel.didTapAuthor()
        #expect(router.routes == [
            .profile(ProfileID("prof-9"), stub: ProfileIdentityStub(handle: "ava", displayName: "Ava Moreau"))
        ])
    }
}
