import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A snap page whose post turns unavailable (#447: taken down, deleted,
/// withheld) — learnt when its comments panel revalidates and hears
/// not-found — reads "This post isn't available" with nothing to act on:
/// no like (boost), no sound, no reactions, no save, repost or ⋯ (#1409).
/// The panel already loses its composer (#1404); the page draws its own
/// column above it, which stayed live.
@MainActor
struct SnapUnavailablePostTests {
    /// Answers every post, except `gone`'s, which the server no longer shows
    /// this viewer: their revalidation is not-found.
    private final class Posts: FeedProviding, @unchecked Sendable {
        let gone: Set<PostID>
        init(gone: Set<PostID>) { self.gone = gone }

        /// The feed here is SEEDED (`seedProjection`), and its own first load
        /// must not replace the seed. An empty page did, whenever it landed:
        /// on a starved runner it landed during a wait, the pager emptied,
        /// and the next page read found no cell (develop dd4d633f). A failed
        /// load keeps what is on screen (`loadFirstPageFromNetwork`).
        private struct SeededOnly: Error {}

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { throw SeededOnly() }
        func loadPage(afterToken token: String) async throws -> FeedPage { throw SeededOnly() }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            if gone.contains(id) { throw FeedError.notFound }
            return FeedEntry(
                post: Post(id: id, authorID: ProfileID("a"), caption: "caption", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
                author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil),
                likeCount: 3
            )
        }
    }

    /// The comments panels the feed mounts, by post.
    @MainActor
    private final class Panels {
        let posts: Posts
        private(set) var byPost: [PostID: PostDetailViewController] = [:]
        init(posts: Posts) { self.posts = posts }

        func make(_ id: PostID) -> UIViewController {
            let panel = PostDetailViewController(
                viewModel: PostDetailViewModel(postID: id, repository: posts),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            byPost[id] = panel
            return panel
        }
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: URL(string: "https://example.test/\(id).jpg"),
            mediaKind: .image, thumbnailURL: nil, audioText: nil, likeCount: 3
        )
    }

    private func makeWallet() -> WalletStore {
        let suite = "snap-unavailable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let wallet = WalletStore(defaults: defaults)
        wallet.credit(100)
        return wallet
    }

    private func makeFeed(
        _ models: [FeedItemDisplayModel], panels: Panels, wallet: WalletStore? = nil
    ) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: panels.posts),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) },
            wallet: wallet,
            bookmarks: PostBookmarkStore(
                defaults: UserDefaults(suiteName: "snap-unavailable-bookmarks-\(UUID().uuidString)")!,
                scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    private func pager(of feed: SnapFeedViewController) throws -> UICollectionView {
        try #require(feed.view.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    /// Settles the pager on page `index`, as a swipe that ended there would.
    private func settle(_ feed: SnapFeedViewController, on index: Int) throws {
        let collection = try pager(of: feed)
        collection.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * collection.bounds.height), animated: false)
        collection.layoutIfNeeded()
        feed.scrollViewDidEndDecelerating(collection)
        feed.view.layoutIfNeeded()
    }

    /// The page showing `index`'s post, among the cells on screen.
    private func cell(_ feed: SnapFeedViewController, at index: Int) throws -> SnapFeedCell {
        let collection = try pager(of: feed)
        collection.layoutIfNeeded()
        let id = PostID(["a", "b", "c", "d", "e"][index])
        let found = collection.visibleCells.compactMap { $0 as? SnapFeedCell }.first { $0.representedPostID == id }
        let where_ = "\(collection.visibleCells.count) visible at \(collection.contentOffset.y) of \(collection.contentSize.height)"
        return try #require(found, "no page for \(id.rawValue): \(where_)")
    }

    /// The page showing `id`, among the cells on screen.
    private func cell(_ feed: SnapFeedViewController, showing id: PostID) throws -> SnapFeedCell {
        let collection = try pager(of: feed)
        collection.layoutIfNeeded()
        let found = collection.visibleCells.compactMap { $0 as? SnapFeedCell }.first { $0.representedPostID == id }
        return try #require(found, "no page for \(id.rawValue)")
    }

    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func shown(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }
        return [view] + view.subviews.flatMap(shown(in:))
    }

    /// The page's post actions on screen: the like (boost) pill, the sound
    /// bubble, the reactions rail.
    private func postActions(on cell: SnapFeedCell) -> [UIView] {
        shown(in: cell.contentView).filter {
            $0 is SnapRailBoostButton || $0 is SnapSoundBubbleButton || $0 is SnapShortcutRailView
        }
    }

    /// The page's panel mounts (the warm a settled media page gets) and
    /// revalidates its post.
    private func mountPanel(_ feed: SnapFeedViewController, for id: PostID, panels: Panels) {
        if panels.byPost[id] == nil { feed.debugPrewarmComments(for: id) }
        panels.byPost[id]?.loadViewIfNeeded()
    }

    // MARK: - The settle's warm (#2136)

    /// A settled media page's comments sheet is warmed over the two turns
    /// after its settle, never in it: the settle is the scroll's last frame,
    /// and the whole warm there held whatever the finger did next.
    @Test func theSettleWarmsTheSheetOverTheNextTwoTurnsNotItsOwn() throws {
        let panels = Panels(posts: Posts(gone: []))
        let feed = makeFeed([media("a"), media("b")], panels: panels)
        RunLoopTurn.runPendingNow()
        try settle(feed, on: 1)
        let id = PostID("b")
        #expect(panels.byPost[id] == nil, "the panel was built in the settle's own turn")

        RunLoopTurn.runPendingNow()
        let panel = try #require(panels.byPost[id], "the first turn after the settle built no panel")
        #expect(!panel.isViewLoaded, "the panel's view was loaded in the same turn as its construction")

        RunLoopTurn.runPendingNow()
        #expect(panel.isViewLoaded, "the second turn did not load the panel")
    }

    /// The page moved on before the warm's turn: nothing is built for it.
    @Test func aWarmWhosePageMovedOnBuildsNothing() throws {
        let panels = Panels(posts: Posts(gone: []))
        let feed = makeFeed([media("a"), media("b"), media("c")], panels: panels)
        RunLoopTurn.runPendingNow()
        try settle(feed, on: 1)
        try settle(feed, on: 2)
        RunLoopTurn.runPendingNow()
        RunLoopTurn.runPendingNow()
        #expect(panels.byPost[PostID("b")] == nil, "a page left behind was warmed")
        #expect(panels.byPost[PostID("c")]?.isViewLoaded == true, "the page settled on was not warmed")
    }

    // MARK: - Acceptance

    /// AC1: the page whose post turns unavailable has no enabled like,
    /// boost or sound action — in place, on the page in front.
    @Test func aPageWhosePostTurnsUnavailableHasNoEnabledLikeBoostOrSound() async throws {
        let wallet = makeWallet()
        let panels = Panels(posts: Posts(gone: [PostID("a")]))
        let feed = makeFeed([media("a"), media("b")], panels: panels, wallet: wallet)
        try settle(feed, on: 0)
        let page = try cell(feed, at: 0)
        try #require(!postActions(on: page).isEmpty, "the premise: the page shows its like and its rail")
        try #require(feed.debugToolbarPostActions.count == 3 && feed.debugToolbarPostActions.allSatisfy { $0.isEnabled })

        mountPanel(feed, for: PostID("a"), panels: panels)
        #expect(await eventually { feed.unavailablePostIDs.contains(PostID("a")) })

        #expect(page.debugShowsUnavailableBlock, "the page does not say the post is unavailable")
        #expect(postActions(on: page).isEmpty, "still on the page: \(postActions(on: page))")
        #expect(feed.debugToolbarPostActions.allSatisfy { !$0.isEnabled }, "save, repost or ⋯ still live")
        // A like tapped now spends nothing.
        let before = wallet.balance
        feed.debugTapBoost(on: PostID("a"), spend: .likes(1))
        #expect(wallet.balance == before)
        #expect(wallet.boostTotal(forTarget: "a") == 0)
        withExtendedLifetime(feed) {}
    }

    /// Paged away, the unavailable post is gone (#2048): only the page in
    /// front keeps the block, and only until the viewer leaves it. The other
    /// pages keep their actions, and paging back does not find it.
    @Test func pagingAwayRemovesItAndLeavesTheOtherPagesAlone() async throws {
        let panels = Panels(posts: Posts(gone: [PostID("a")]))
        let feed = makeFeed(["a", "b", "c", "d", "e"].map(media), panels: panels)
        try settle(feed, on: 0)
        mountPanel(feed, for: PostID("a"), panels: panels)
        #expect(await eventually { feed.unavailablePostIDs.contains(PostID("a")) })
        #expect(try cell(feed, at: 0).debugShowsUnavailableBlock, "the page in front lost the block")

        try settle(feed, on: 1)
        let rest = ["b", "c", "d", "e"].map { PostID($0) }
        #expect(await eventually { feed.orderedIDs == rest }, "the page outlived the viewer leaving it")
        for (index, id) in rest.enumerated() {
            try settle(feed, on: index)
            let other = try cell(feed, showing: id)
            #expect(!other.debugShowsUnavailableBlock, "page \(index) caught it")
            #expect(!postActions(on: other).isEmpty, "page \(index) lost its actions")
            #expect(feed.debugToolbarPostActions.allSatisfy { $0.isEnabled }, "page \(index)'s toolbar is off")
        }
        try settle(feed, on: 0)
        #expect(feed.activePostID == PostID("b"), "paging back found it")
        withExtendedLifetime(feed) {}
    }

    /// A page learnt unavailable while off screen — a neighbour's panel
    /// revalidated it — never arrives (#2048): the viewer is not shown a post
    /// known to be unavailable. It leaves the pages at once.
    @Test func aPageLearntUnavailableOffScreenLeavesThePages() throws {
        let panels = Panels(posts: Posts(gone: []))
        let feed = makeFeed(["a", "b", "c"].map(media), panels: panels)
        try settle(feed, on: 0)
        feed.markPostUnavailable(PostID("b"))
        #expect(feed.orderedIDs == [PostID("a"), PostID("c")])
        try settle(feed, on: 1)
        let shown = try cell(feed, showing: PostID("c"))
        #expect(!shown.debugShowsUnavailableBlock)
        #expect(!postActions(on: shown).isEmpty)
        withExtendedLifetime(feed) {}
    }

    /// AC3, before the toast: a like still inside its undo window when the
    /// post turns unavailable goes back to the wallet. Staked straight
    /// through the wallet — the toast's one undo slot is shared by the whole
    /// process, and another suite's toast could send the burst.
    @Test func aLikeTappedJustBeforeTheChangeGoesBack() async throws {
        let wallet = makeWallet()
        let panels = Panels(posts: Posts(gone: [PostID("a")]))
        let feed = makeFeed([media("a"), media("b")], panels: panels, wallet: wallet)
        try settle(feed, on: 0)
        let start = wallet.balance

        feed.debugStake(.likes(5), on: PostID("a"))
        #expect(wallet.balance == start - 5, "staked")
        #expect(wallet.boostTotal(forTarget: "a") == 5)

        mountPanel(feed, for: PostID("a"), panels: panels)
        #expect(await eventually { feed.unavailablePostIDs.contains(PostID("a")) })
        #expect(wallet.balance == start, "refunded")
        #expect(wallet.boostTotal(forTarget: "a") == 0)
        withExtendedLifetime(feed) {}
    }

    /// AC3, after the toast: a burst already sent (its toast ended) goes to
    /// the server, which refuses a stake on a post the viewer may not read —
    /// and the outbox's answer puts the points back. A readable post's
    /// stake still lands.
    @Test func aLikeAlreadySentOnATakenDownPostComesBackThroughTheOutbox() async throws {
        let suite = "snap-unavailable-outbox-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        // ⚠️ ITS OWN SERVER WALLET: on the test host's standard defaults the
        // mock's wallet kept across runs and ran dry (`points: 0` after a
        // day of local lanes), and the readable post's stake was refused.
        let backend = MockBackend(persistence: defaults)
        let gone = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-5" }?.postID)
        let kept = try #require(backend.dataset.posts.first { $0.authorProfileID == "prof-6" }?.postID)
        backend.socialServices.takeDown(gone)
        let scope = StorageScope(owner: .member(account: MockAuthService.accountID, profile: MockSocialDataset.viewerProfileID))
        let wallet = WalletStore(defaults: defaults, scope: scope)
        let outbox = LikeOutbox(defaults: defaults, scope: scope)
        wallet.likeOutbox = outbox
        wallet.credit(100)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: BearerToken(), httpClient: backend.bff
        )
        let viewer = ViewerSession(authSession: Member()) { _ in [ProfileID(MockSocialDataset.viewerProfileID)] }
        let staking = WalletLikeStaking(walletClient: Wallet_V1_WalletServiceClient(client: client), viewer: viewer)
        let sender = LikeOutboxSender(outbox: outbox, wallet: wallet, staking: staking, retryDelays: [3600])
        let start = wallet.balance

        wallet.stake(.likes(3), on: gone)
        wallet.stake(.likes(2), on: kept)
        wallet.commitStakes(on: gone)
        wallet.commitStakes(on: kept)
        await sender.flush()

        #expect(wallet.boostTotal(forTarget: gone) == 0, "the refused stake stayed on the post")
        #expect(wallet.boostTotal(forTarget: kept) == 2)
        #expect(wallet.balance == start - 2, "only the readable post's like is spent")
        #expect(outbox.batches.isEmpty)
        withExtendedLifetime(sender) {}
    }
}

private struct Member: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private struct BearerToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}
