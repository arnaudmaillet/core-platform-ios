import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import MediaCoreFixtures
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// The Snap page's likes spend through its `StakeSession` (#2532). The
/// session's own rules are
/// PostGrid's `StakeSessionTests`; these pin the page's wiring (ADR 0011).
///
/// Every test runs in one main-actor turn once its feed is up: no toast's
/// clock can fire in the middle of one.
@MainActor
@Suite(.serialized)
struct SnapStakeSessionTests {
    /// Answers every post. The feed is SEEDED, and its own first load must
    /// not replace the seed: it fails, and a failed load keeps what is shown.
    private final class Posts: FeedProviding, @unchecked Sendable {
        private struct SeededOnly: Error {}
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { throw SeededOnly() }
        func loadPage(afterToken token: String) async throws -> FeedPage { throw SeededOnly() }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            FeedEntry(
                post: Post(id: id, authorID: ProfileID("a"), caption: "caption", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
                author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil),
                likeCount: 3
            )
        }
    }

    private static func wallet() -> WalletStore {
        let suite = "snap-stake-session-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let wallet = WalletStore(defaults: defaults, scope: StorageScope())
        wallet.credit(100)
        return wallet
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: URL(string: "https://example.test/\(id).jpg"),
            mediaKind: .image, thumbnailURL: nil, audioText: nil, likeCount: 3
        )
    }

    private func text(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil,
            mediaKind: .image, thumbnailURL: nil, audioText: nil, likeCount: 3
        )
    }

    private func makeFeed(_ models: [FeedItemDisplayModel], wallet: WalletStore?) -> SnapFeedViewController {
        let posts = Posts()
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: posts, unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in
                PostDetailViewController(
                    viewModel: PostDetailViewModel(postID: id, repository: posts),
                    imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
                )
            },
            wallet: wallet,
            bookmarks: PostBookmarkStore(
                defaults: UserDefaults(suiteName: "snap-stake-session-bookmarks-\(UUID().uuidString)")!,
                scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
            ), savedSounds: SavedSoundStore(scope: StorageScope()), viewer: { nil }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    /// Settles the pager on page `index`, as a swipe that ended there would.
    private func settle(_ feed: SnapFeedViewController, on index: Int) throws {
        let collection = try #require(feed.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * collection.bounds.height), animated: false)
        collection.layoutIfNeeded()
        feed.scrollViewDidEndDecelerating(collection)
        feed.view.layoutIfNeeded()
    }

    /// The page's pill and the text page's footer like reach the screen's
    /// stakes (ADR 0011's forwarding): one burst on the post.
    @Test func thePillAndTheFooterLikeSpendThroughTheScreensStakes() throws {
        let wallet = Self.wallet()
        let feed = makeFeed([text("a"), media("b")], wallet: wallet)
        try settle(feed, on: 0)
        let stakes = try #require(feed.stakes)
        try #require(feed.snapCell(for: PostID("a")) != nil, "the premise: page a is on screen")

        feed.debugTapBoost(on: PostID("a"), spend: .likes(1))
        #expect(stakes.menuState(for: PostID("a")).undoable == 1, "the pill's tap missed the stakes")

        feed.debugTapFooterLike()
        #expect(stakes.menuState(for: PostID("a")).undoable == 2, "the footer's tap missed the stakes")
        #expect(wallet.boostTotal(forTarget: "a") == 2)
        withExtendedLifetime(feed) {}
    }

    /// Paging away no longer ends a burst (§ 3, rows 1 and 4): it stays
    /// undoable, through the menu, while its toast is up.
    @Test func pagingAwayKeepsTheBurstUndoableWhileItsToastIsUp() throws {
        let wallet = Self.wallet()
        let feed = makeFeed([media("a"), media("b")], wallet: wallet)
        try settle(feed, on: 0)
        let stakes = try #require(feed.stakes)
        feed.debugTapBoost(on: PostID("a"), spend: .likes(1))
        try #require(stakes.menuState(for: PostID("a")).undoable == 1)

        try settle(feed, on: 1)

        #expect(stakes.menuState(for: PostID("a")).undoable == 1, "paging away ended the burst")
        stakes.undo(on: PostID("a"))
        #expect(wallet.boostTotal(forTarget: "a") == 0)
        withExtendedLifetime(feed) {}
    }

    /// Without a wallet the page has no stakes, and its like spends nothing.
    @Test func aFeedWithoutAWalletHasNoStakes() throws {
        let feed = makeFeed([media("a")], wallet: nil)
        try settle(feed, on: 0)

        #expect(feed.stakes == nil)
        feed.debugTapBoost(on: PostID("a"), spend: .likes(1))
        withExtendedLifetime(feed) {}
    }
}
