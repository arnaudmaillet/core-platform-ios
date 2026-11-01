import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A text page's like stands in the screen's footer (#1924, the owner):
/// `[author] [♥ count] [☆] [↪]` — repost in the share sheet — and no pill floats over its composer, so a
/// short comment list rests on it. A media page keeps its pill, and its
/// footer no like.
@MainActor
struct SnapTextFooterLikeTests {
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

    private func text(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil,
            mediaKind: .image, thumbnailURL: nil, audioText: nil, likeCount: 3
        )
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

    private func footerLike(in feed: SnapFeedViewController) -> UIBarButtonItem? {
        feed.toolbarItems?.first { $0.identifier == SnapFooterToolbar.ID.like }
    }

    @Test func aTextPageWearsItsLikeInTheFooterAndNoPill() throws {
        let panels = Panels(posts: Posts(gone: []))
        let feed = makeFeed([text("a"), media("b")], panels: panels, wallet: makeWallet())
        try settle(feed, on: 0)

        let like = try #require(footerLike(in: feed), "no like in a text page's footer")
        #expect(like === feed.debugFooterLikeItem)
        let items = try #require(feed.toolbarItems)
        let likeIndex = try #require(items.firstIndex { $0 === like })
        let saveIndex = try #require(items.firstIndex { $0.identifier == SnapFooterToolbar.ID.save })
        #expect(likeIndex == 2, "the like is not right after the author and the space")
        #expect(likeIndex < saveIndex, "the like is not before save and repost")
        #expect((like.customView as? StretchedBarLabel)?.title == "3", "the count is not the post's")
        #expect(try cell(feed, at: 0).debugChrome.debugBoostButton.isHidden, "a pill still floats over the composer")
        // Repost is the share sheet's there, or an SE folds the run into •••.
        #expect(!items.contains { $0.identifier == SnapFooterToolbar.ID.repost }, "repost is still on the footer")
        #expect(feed.shareSheetActions(for: PostID("a")).contains { $0.title == "Repost" }, "no repost in the sheet")
        // Share is the slot's, right of the comment field (#1999): the
        // footer reads [author] [♥ count] [☆], and ends on the star.
        #expect(!items.contains { $0.identifier == SnapFooterToolbar.ID.share }, "Share is still on a text page's footer")
        #expect(items.last?.identifier == SnapFooterToolbar.ID.save, "the footer does not end on the star")

        // A media page: its pill, no footer like.
        try settle(feed, on: 1)
        #expect(footerLike(in: feed) == nil, "a media page's footer wears a like")
        #expect(feed.debugFooterLikeItem == nil)
        #expect(try !cell(feed, at: 1).debugChrome.debugBoostButton.isHidden, "a media page lost its pill")
        #expect(feed.toolbarItems?.contains { $0.identifier == SnapFooterToolbar.ID.save } == true)
        #expect(feed.toolbarItems?.contains { $0.identifier == SnapFooterToolbar.ID.repost } == true,
                "a media page's footer lost repost")
        #expect(!feed.shareSheetActions(for: PostID("b")).contains { $0.title == "Repost" })
        #expect(feed.toolbarItems?.contains { $0.identifier == SnapFooterToolbar.ID.share } == true,
                "a media page's footer lost Share")
        withExtendedLifetime(feed) {}
    }

    /// A tap on the footer's heart likes as the pill's does: the wallet
    /// spends, and the heart turns staked — a new item under the same
    /// identifier, for the bar to morph (R3).
    @Test func aTapOnTheFooterLikeStakesAsThePillDoes() async throws {
        let wallet = makeWallet()
        let panels = Panels(posts: Posts(gone: []))
        let feed = makeFeed([text("a"), media("b")], panels: panels, wallet: wallet)
        try settle(feed, on: 0)
        let before = try #require(footerLike(in: feed))
        let balance = wallet.balance

        feed.debugTapFooterLike()
        #expect(await eventually { wallet.boostTotal(forTarget: "a") > 0 }, "the tap spent nothing")
        #expect(wallet.balance < balance)
        let after = try #require(footerLike(in: feed))
        #expect(after !== before, "the staked heart is the same item")
        #expect(after.identifier == before.identifier)
        #expect(
            (after.customView as? StretchedBarLabel)?.image != (before.customView as? StretchedBarLabel)?.image,
            "the heart did not turn staked"
        )
        withExtendedLifetime(feed) {}
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

}
