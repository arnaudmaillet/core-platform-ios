import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct SessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private final class OnePostProvider: FeedProviding, @unchecked Sendable {
    let entry: FeedEntry
    init(_ entry: FeedEntry) { self.entry = entry }
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { nil }
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { entry }
}

private struct ReviewError: Error {}

/// Comments on a post, one of them held, and a reviewer that records what it
/// was asked and answers as told.
private actor HeldCommentsFake: CommentsProviding, HeldCommentReviewing {
    private var entries: [CommentEntry]
    private let viewer: ProfileID
    private var failsReview: Bool
    private(set) var reviews: [(id: String, approve: Bool)] = []

    init(entries: [CommentEntry], viewer: ProfileID, failsReview: Bool = false) {
        self.entries = entries
        self.viewer = viewer
        self.failsReview = failsReview
    }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
    func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
        throw ReviewError()
    }
    func viewerIdentity() async -> ViewerIdentity? {
        ViewerIdentity(name: "Me", avatarURL: nil, profileID: viewer, handle: "me")
    }

    func reviewHeldComment(_ commentID: String, approve: Bool) async throws {
        reviews.append((commentID, approve))
        if failsReview { throw ReviewError() }
        entries = approve
            ? entries.map { $0.id == commentID ? $0.released() : $0 }
            : entries.filter { $0.id != commentID }
    }
}

private func comment(_ id: String, held: Bool = false) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-3"), authorName: "Sam Lee", authorHandle: "sam",
        body: "Hello", createdAt: Date(timeIntervalSince1970: 1_000), isHeld: held
    )
}

private func post(by author: String) -> FeedEntry {
    FeedEntry(
        post: Post(id: PostID("post-1"), authorID: ProfileID(author), caption: "hi", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
        author: AuthorSummary(id: ProfileID(author), handle: "me", displayName: "Me", avatarURL: nil),
        likeCount: 0
    )
}

/// The post owner reviews comments held by their temporary interaction
/// limit (#416): approve shows it to everyone, decline removes it.
@MainActor
struct HeldCommentsTests {
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func makeViewModel(
        author: String, viewer: String, failsReview: Bool = false
    ) -> (PostDetailViewModel, HeldCommentsFake, () -> [CommentDisplayModel]) {
        let fake = HeldCommentsFake(
            entries: [comment("c-held", held: true), comment("c-open")],
            viewer: ProfileID(viewer), failsReview: failsReview
        )
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: OnePostProvider(post(by: author)), commentsProvider: fake
        )
        var latest: [CommentDisplayModel] = []
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { latest = models } }
        viewModel.viewDidLoad()
        return (viewModel, fake, { latest })
    }

    @Test func theOwnerMayReviewOnlyTheHeldComment() async throws {
        let (viewModel, _, models) = makeViewModel(author: "prof-me", viewer: "prof-me")
        try #require(await settle { models().first { $0.id == "c-held" }?.canReview == true }, "never reviewable")
        #expect(models().first { $0.id == "c-held" }?.isHeld == true)
        #expect(models().first { $0.id == "c-open" }?.canReview == false)
        withExtendedLifetime(viewModel) {}
    }

    @Test func anyoneElseSeesItHeldButCannotReview() async throws {
        let (viewModel, fake, models) = makeViewModel(author: "prof-owner", viewer: "prof-me")
        try #require(await settle { models().count == 2 }, "comments never loaded")
        // Let the identity and the post land too.
        try? await Task.sleep(for: .milliseconds(100))
        let held = try #require(models().first { $0.id == "c-held" })
        #expect(held.isHeld)
        #expect(!held.canReview)
        viewModel.reviewHeldComment("c-held", approve: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fake.reviews.isEmpty)
    }

    @Test func approvingShowsItToEveryone() async throws {
        let (viewModel, fake, models) = makeViewModel(author: "prof-me", viewer: "prof-me")
        try #require(await settle { models().first { $0.id == "c-held" }?.canReview == true }, "never reviewable")
        viewModel.reviewHeldComment("c-held", approve: true)
        #expect(await settle { models().first { $0.id == "c-held" }?.isHeld == false })
        #expect(models().count == 2)
        let reviews = await fake.reviews
        #expect(reviews.map(\.id) == ["c-held"])
        #expect(reviews.map(\.approve) == [true])
    }

    @Test func decliningRemovesIt() async throws {
        let (viewModel, fake, models) = makeViewModel(author: "prof-me", viewer: "prof-me")
        try #require(await settle { models().first { $0.id == "c-held" }?.canReview == true }, "never reviewable")
        viewModel.reviewHeldComment("c-held", approve: false)
        #expect(await settle { models().map(\.id) == ["c-open"] })
        #expect(await fake.reviews.map(\.approve) == [false])
    }

    /// Not optimistic: a failed review leaves the comment held, reviewable
    /// again, and says so.
    @Test func aFailedReviewLeavesItHeld() async throws {
        let (viewModel, _, models) = makeViewModel(author: "prof-me", viewer: "prof-me", failsReview: true)
        try #require(await settle { models().first { $0.id == "c-held" }?.canReview == true }, "never reviewable")
        var failed: Bool?
        viewModel.onReviewFailed = { failed = $0 }
        viewModel.reviewHeldComment("c-held", approve: false)
        #expect(await settle { failed == false })
        let held = try #require(models().first { $0.id == "c-held" })
        #expect(held.isHeld)
        #expect(held.canReview)
    }

    @Test func theFailureNoticeNamesTheAction() {
        #expect(PostDetailViewController.reviewFailureNotice(approve: true).title == "Couldn't Approve Comment")
        #expect(PostDetailViewController.reviewFailureNotice(approve: false).message.contains("still held"))
    }

    @Test func onlyAHeldCommentCanBeReviewed() {
        #expect(!CommentDisplayModel(entry: comment("c"), canReview: true).canReview)
        #expect(CommentDisplayModel(entry: comment("c", held: true), canReview: true).canReview)
    }
}

/// The repository against the mock BFF: held comments read as held, and the
/// owner's review reaches comment.v1.
struct HeldCommentsRepositoryTests {
    private func makeRepository() -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset, seedsHeldComments: true).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SessionStub()
        )
    }

    @Test func heldCommentsReadAsHeld() async throws {
        let comments = try await makeRepository().loadComments(for: PostID("post-me-00"))
        #expect(comments.filter(\.isHeld).map(\.id) == ["post-me-00-held-0", "post-me-00-held-1"])
    }

    @Test func approvingReleasesAndDecliningRemoves() async throws {
        let repository = makeRepository()
        try await repository.reviewHeldComment("post-me-00-held-0", approve: true)
        try await repository.reviewHeldComment("post-me-00-held-1", approve: false)
        let comments = try await repository.loadComments(for: PostID("post-me-00"))
        #expect(comments.first { $0.id == "post-me-00-held-0" }?.isHeld == false)
        #expect(!comments.contains { $0.id == "post-me-00-held-1" })
    }

    /// Reviewed already — here or on another device: nothing left to do,
    /// not an error.
    @Test func aSecondReviewIsNotAnError() async throws {
        let repository = makeRepository()
        try await repository.reviewHeldComment("post-me-01-held-0", approve: true)
        try await repository.reviewHeldComment("post-me-01-held-0", approve: false)
        let comments = try await repository.loadComments(for: PostID("post-me-01"))
        #expect(comments.first { $0.id == "post-me-01-held-0" }?.isHeld == false)
    }
}
