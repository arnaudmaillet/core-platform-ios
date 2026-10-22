import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

private struct Unreachable: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

/// A post the server shows the viewer no more (#447: taken down, deleted,
/// someone else's draft, withheld by a block or an audience) reads "This post
/// isn't available" — and offers nothing to act on it with (#1404): no
/// composer, no like, no boost, no repost. Only the way back stays, and it is
/// the host's. A post that turns unavailable while shown loses them in place.
@MainActor
struct UnavailablePostActionsTests {
    /// Answers `revalidatePost` with `answer` — held until `release()` when
    /// built holding, so a test can look at the screen before the answer.
    private final class Provider: FeedProviding, @unchecked Sendable {
        private let lock = NSLock()
        private let answer: Result<FeedEntry, FeedError>
        private let peekable: FeedEntry?
        private var holding: Bool

        init(_ answer: Result<FeedEntry, FeedError>, peekable: FeedEntry? = nil, holding: Bool = false) {
            self.answer = answer
            self.peekable = peekable
            self.holding = holding
        }

        func release() { lock.withLock { holding = false } }

        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { peekable }
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { try answer.get() }
        func revalidatePost(_ id: PostID) async throws -> FeedEntry {
            for _ in 0..<6_000 where lock.withLock({ holding }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            return try answer.get()
        }
    }

    private final class SpyEngagement: EngagementProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var likes: [PostID] = []
        var calls: [PostID] { lock.withLock { likes } }
        func like(_ postID: PostID) async throws { lock.withLock { likes.append(postID) } }
        func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] { [:] }
    }

    private actor SpyComments: CommentsProviding {
        private(set) var added: [String] = []
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { [] }
        func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
            added.append(body)
            return CommentEntry(
                id: commentID, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
                body: body, createdAt: Date(timeIntervalSince1970: 0), parentID: parentID
            )
        }
    }

    private struct Member: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
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

    private func entry() -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID("post-1"), authorID: ProfileID("prof-9"), caption: "hello", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("prof-9"), handle: "ava", displayName: "Ava Moreau", avatarURL: nil),
            likeCount: 1
        )
    }

    private func makeScreen(_ viewModel: PostDetailViewModel) -> PostDetailViewController {
        let screen = PostDetailViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: Unreachable())
        )
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.loadViewIfNeeded()
        return screen
    }

    // MARK: - What the screen shows

    /// Views drawn on screen: neither hidden nor transparent, nor under an
    /// ancestor that is.
    private func shown(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }
        return [view] + view.subviews.flatMap(shown(in:))
    }

    private func labels(in view: UIView) -> [String] {
        shown(in: view).compactMap { ($0 as? UILabel)?.text }
    }

    /// The composer on screen, if any.
    private func composers(in view: UIView) -> [CommentsInputBar] {
        shown(in: view).compactMap { $0 as? CommentsInputBar }
    }

    /// Every control a finger could act with: shown, enabled and taking
    /// touches — the like, the boost, the rail slot, send, a menu button.
    private func actionableControls(in view: UIView) -> [UIControl] {
        shown(in: view).compactMap { $0 as? UIControl }.filter { $0.isEnabled && $0.isUserInteractionEnabled }
    }

    /// Anything a viewer could type into.
    private func editableText(in view: UIView) -> [UIView] {
        shown(in: view).filter { ($0 as? UITextView)?.isEditable == true || $0 is UITextField }
    }

    /// The screen offers nothing to act on the post with: no composer, no
    /// control, no field, no bar item of its own — the way back is the host's.
    private func offersNoPostAction(_ screen: PostDetailViewController) -> Bool {
        composers(in: screen.view).isEmpty
            && actionableControls(in: screen.view).isEmpty
            && editableText(in: screen.view).isEmpty
            && (screen.navigationItem.rightBarButtonItems ?? []).isEmpty
            && (screen.navigationItem.leftBarButtonItems ?? []).isEmpty
            && (screen.toolbarItems ?? []).isEmpty
    }

    private func readsUnavailable(_ screen: PostDetailViewController) -> Bool {
        screen.view.layoutIfNeeded()
        return labels(in: screen.view).contains(PostDetailViewModel.unavailableMessage)
    }

    // MARK: - Acceptance

    /// The comments panel opened on a post moderation took down — over the
    /// mock, `-mock-takedown`'s path — shows no composer and no enabled
    /// action.
    @Test func aCommentSheetOnAnUnavailablePostShowsNoComposerAndNoEnabledAction() async throws {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let repository = FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            engagementClient: Engagement_V1_EngagementServiceClient(client: client),
            authSession: Member(),
            localCache: nil
        )
        let postID = PostID(try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-5" }?.postID))
        backend.socialServices.takeDown(postID.rawValue)

        let viewModel = PostDetailViewModel(
            postID: postID, repository: repository,
            engagementProvider: SpyEngagement(), commentsProvider: SpyComments()
        )
        let sheet = makeScreen(viewModel)
        #expect(await settle { readsUnavailable(sheet) })
        #expect(offersNoPostAction(sheet), "composers \(composers(in: sheet.view)), controls \(actionableControls(in: sheet.view))")
        withExtendedLifetime(viewModel) {}
    }

    /// Opened on the warm copy, the panel shows its composer and its
    /// actions; the revalidation then answers not-found, and the SAME panel
    /// loses them where it stands.
    @Test func aPostThatTurnsUnavailableWhileShownLosesItsActionsInPlace() async {
        let provider = Provider(.failure(.notFound), peekable: entry(), holding: true)
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: provider,
            engagementProvider: SpyEngagement(), commentsProvider: SpyComments()
        )
        let screen = makeScreen(viewModel)
        // Shown: the warm copy, with its composer and something to act with.
        #expect(await settle {
            screen.view.layoutIfNeeded()
            return !composers(in: screen.view).isEmpty && !actionableControls(in: screen.view).isEmpty
        })
        #expect(!readsUnavailable(screen))

        provider.release()
        #expect(await settle { readsUnavailable(screen) })
        #expect(offersNoPostAction(screen), "composers \(composers(in: screen.view)), controls \(actionableControls(in: screen.view))")
        withExtendedLifetime(viewModel) {}
    }

    /// A boost that reaches the panel after the post turned unavailable — a
    /// guest's tap finishing its sign-up later (`MemberGates`) — spends
    /// nothing: there is no post left to boost.
    @Test func aBoostAfterThePostTurnedUnavailableSpendsNothing() async {
        let suite = "unavailable-post-actions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let wallet = WalletStore(defaults: defaults)
        wallet.credit(100)
        let before = wallet.balance

        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: Provider(.failure(.notFound)))
        let screen = PostDetailViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: Unreachable()),
            wallet: wallet
        )
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.loadViewIfNeeded()
        #expect(await settle { readsUnavailable(screen) })

        screen.debugBoost(.likes(5))
        #expect(wallet.balance == before)
        #expect(wallet.boostTotal(forTarget: "post-1") == 0)
        withExtendedLifetime(viewModel) {}
    }

    /// Behind the screen: a like or a comment on an unavailable post never
    /// leaves — the server would only refuse it.
    @Test func anUnavailablePostTakesNoLikeAndNoComment() async {
        let engagement = SpyEngagement()
        let comments = SpyComments()
        let viewModel = PostDetailViewModel(
            postID: PostID("post-1"), repository: Provider(.failure(.notFound), peekable: entry()),
            engagementProvider: engagement, commentsProvider: comments
        )
        var last: PostDetailViewModel.Phase?
        var composing: [Bool] = []
        viewModel.onPhaseChange = { last = $0 }
        viewModel.onComposingChange = { composing.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { last == .unavailable(message: PostDetailViewModel.unavailableMessage) })

        // Both are refused synchronously, before anything is sent: a like
        // shows itself at once (optimistic), and a comment marks the composer
        // busy at once — neither happened.
        viewModel.like()
        viewModel.submitComment("hello")
        #expect(viewModel.engagementState.isLiked == false)
        #expect(composing.isEmpty)
        #expect(engagement.calls.isEmpty)
        #expect(await comments.added.isEmpty)
        withExtendedLifetime(viewModel) {}
    }
}
