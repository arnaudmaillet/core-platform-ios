import CoreModels
import CoreNavigation
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

// A swipe up past the true last post closes the feed (#628) — and only there.

/// Hydrates every id as a photo post.
private final class Photos: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: id.rawValue,
                attachments: [MediaAttachment(
                    url: URL(string: "mock://photo/\(id.rawValue)"),
                    thumbnailURL: URL(string: "mock://poster/\(id.rawValue)"),
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1080
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}

private func ids(_ raw: String...) -> [PostID] { raw.map { PostID($0) } }

@MainActor
struct SnapFeedEndOfSourceTests {
    // MARK: - The provider says when it knows

    /// A complete set's first page is its last; a window's is not known to be.
    @Test func onlyACompleteSetEndsWithItsWindow() async throws {
        let complete = FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c"), isCompleteSet: true)
        #expect(try await complete.loadFirstPage().isEndOfSource)

        let window = FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c"))
        let page = try await window.loadFirstPage()
        #expect(page.nextPageToken == nil, "no cursor to follow")
        #expect(!page.isEndOfSource, "but its last post may be the middle of a longer grid")
    }

    /// With a continuation, the end is the source saying "nothing follows" —
    /// and a re-aimed window is somebody's window, not a whole set.
    @Test func aContinuationsNilIsTheEnd() async throws {
        var asked = 0
        let provider = FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b")) { _ in
            asked += 1
            return nil
        }
        let first = try await provider.loadFirstPage()
        #expect(!first.isEndOfSource)
        let end = try await provider.loadPage(afterToken: try #require(first.nextPageToken))
        #expect(end.isEndOfSource)
        #expect(asked == 1)

        let repointed = FixedPostsFeedProvider(base: Photos(), ids: ids("a"), isCompleteSet: true)
        await repointed.repoint(to: ids("z"))
        #expect(try await !repointed.loadFirstPage().isEndOfSource)
    }

    // MARK: - The view model

    @Test func aCompleteSetIsExhaustedOnceLoaded() async throws {
        let viewModel = FeedViewModel(
            repository: FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b"), isCompleteSet: true)
        )
        viewModel.viewDidLoad()
        try #require(await settle { viewModel.isSourceExhausted })
    }

    /// ⚠️ A FAILED PAGE IS NOT THE END (the owner's call): the continuation had
    /// nothing right now, the cursor is kept, and the feed is not exhausted.
    @Test func aFailedPageIsNotTheEnd() async throws {
        var asked = 0
        let provider = FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b")) { _ in
            asked += 1
            return []
        }
        let viewModel = FeedViewModel(repository: provider)
        viewModel.viewDidLoad()
        await settle(looks: 200) { false }
        viewModel.willDisplayItem(at: 1)
        try #require(await settle { asked >= 1 }, "guard: the next page was never asked for")
        await settle(looks: 100) { false }
        #expect(!viewModel.isSourceExhausted)
    }

    // MARK: - The feed claims the upward grab only at the true end

    private func feed(_ provider: FixedPostsFeedProvider) async throws -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        // The first layout with a width is what starts the load.
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        try #require(await settle { controller.debugPageCount > 0 }, "the feed never loaded")
        controller.view.layoutIfNeeded()
        return controller
    }

    private func page(_ feed: SnapFeedViewController, to index: Int) {
        guard let collection = feed.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return }
        collection.setContentOffset(CGPoint(x: 0, y: collection.bounds.height * CGFloat(index)), animated: false)
        feed.scrollViewDidEndDecelerating(collection)
    }

    private func centre(of feed: SnapFeedViewController) -> CGPoint {
        CGPoint(x: feed.view.bounds.midX - 60, y: feed.view.bounds.midY)
    }

    /// Last page + exhausted: the upward grab may claim the touch — wherever
    /// the downward one may, since the tenants under the finger (the rail,
    /// the composer, a stream at its end) are the same and mirrored.
    ///
    /// ⚠️ ASKED AGAINST THE DOWNWARD GATE AT THE SAME POINT, not as a bare
    /// "yes": what lies under an arbitrary point (and whether a keyboard
    /// notification from another suite in the process is still in force) is
    /// shared state in a full run, and both gates read it alike. The property
    /// is that being at the end is all the upward gate adds.
    @Test func theLastPostOfACompleteSetClaimsTheUpwardGrab() async throws {
        let feed = try await feed(FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c"), isCompleteSet: true))
        page(feed, to: 2)
        let point = centre(of: feed)

        #expect(feed.isAtEndOfSource)
        #expect(feed.zoomUpwardDismissalPermitted(at: point, in: feed.view)
                == feed.zoomVerticalDismissalPermitted(at: point, in: feed.view),
                "at the end, the upward grab answers as the downward one does")
    }

    /// Not the last page: upward is the next post, as ever.
    @Test func anEarlierPostKeepsUpwardForPaging() async throws {
        let feed = try await feed(FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c"), isCompleteSet: true))
        page(feed, to: 1)

        #expect(!feed.isAtEndOfSource)
        #expect(!feed.zoomUpwardDismissalPermitted(at: centre(of: feed), in: feed.view))
    }

    /// ⚠️ A WINDOW'S LAST POST CLAIMS TOO (#761): every full-screen feed —
    /// For You's window, a profile's gallery — closes past its last post, not
    /// only a source that said it was finished.
    @Test func theLastPostOfAWindowClaimsToo() async throws {
        let feed = try await feed(FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c")))
        page(feed, to: 2)
        let point = centre(of: feed)

        #expect(feed.isAtEndOfSource)
        #expect(feed.zoomUpwardDismissalPermitted(at: point, in: feed.view)
                == feed.zoomVerticalDismissalPermitted(at: point, in: feed.view))
    }

    /// While the next page is on its way, the last post loaded is not the end.
    @Test func aPageOnItsWayIsNotTheEnd() async throws {
        let feed = try await feed(FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b", "c")) { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        page(feed, to: 2)
        try #require(await settle { feed.debugIsLoadingNextPage }, "guard: no page was asked for")
        #expect(!feed.isAtEndOfSource)
        #expect(!feed.zoomUpwardDismissalPermitted(at: centre(of: feed), in: feed.view))
    }

    /// The pager's half of the split: an upward touch is declined exactly
    /// where the grab may take it, so one side claims it.
    @Test func thePagerDeclinesOnlyAPredominantlyUpwardTouch() {
        #expect(SnapFeedCollectionView.isUpwardTouch(velocity: CGPoint(x: 20, y: -400)))
        #expect(!SnapFeedCollectionView.isUpwardTouch(velocity: CGPoint(x: 20, y: 400)), "downward")
        #expect(!SnapFeedCollectionView.isUpwardTouch(velocity: CGPoint(x: 400, y: -200)), "sideways")
    }

    /// Looks, not wall-clock time.
    @discardableResult
    // MARK: - The map's two other routes (#674)

    /// A marker that does not fly opens through `pushSnapFeed` (Reduce Motion)
    /// or `revealSnapFeed` (a text- or icon-faced marker, a city or country
    /// with its place page beneath). Asked for a complete set, both build a
    /// feed that knows its last post is the end; asked plainly — For You,
    /// search, profile — they still don't.
    @Test func theMapsPushAndRevealBuildACompleteSet() async throws {
        let (push, pushStack) = try await routed { builder, presenter in
            builder.pushSnapFeed(postIDs: ids("a", "b", "c"), from: presenter, sourceIsComplete: true)
        }
        page(push, to: 2)
        #expect(await settle { push.isAtEndOfSource }, "the map's plain push lost the upward grab")

        let (reveal, revealStack) = try await routed { builder, presenter in
            builder.revealSnapFeed(
                postIDs: ids("a", "b", "c"), from: presenter, origin: Self.revealOrigin,
                beneath: nil, sourceIsComplete: true
            )
        }
        page(reveal, to: 2)
        #expect(await settle { reveal.isAtEndOfSource }, "the map's reveal lost the upward grab")
        withExtendedLifetime((pushStack, revealStack)) {}
    }

    /// ⚠️ A FEED OPENED ON ITS LAST LOADED TILE ASKS FOR MORE ONCE THE FIRST
    /// PAGE SAYS MORE FOLLOWS (#761): the cell displayed before the cursor
    /// arrived, and the near-end check runs again — so the grab does not close
    /// a profile whose gallery has more pages.
    @Test func aCursorArrivingLateStillPagesFromTheDisplayedTile() async throws {
        var asked = 0
        let provider = FixedPostsFeedProvider(base: Photos(), ids: ids("a", "b")) { _ in
            asked += 1
            return []
        }
        let viewModel = FeedViewModel(repository: provider)
        viewModel.willDisplayItem(at: 1)
        viewModel.viewDidLoad()
        #expect(await settle { asked >= 1 }, "the late cursor never paged from the displayed tile")
    }

    /// A plain push or reveal (For You, search, profile) ends with its last
    /// post too (#761).
    @Test func aPlainPushOrRevealEndsWithItsLastPost() async throws {
        let (push, pushStack) = try await routed { builder, presenter in
            builder.pushSnapFeed(postIDs: ids("a", "b", "c"), from: presenter)
        }
        page(push, to: 2)
        #expect(await settle { push.isAtEndOfSource })

        let (reveal, revealStack) = try await routed { builder, presenter in
            builder.revealSnapFeed(
                postIDs: ids("a", "b", "c"), from: presenter, origin: Self.revealOrigin, beneath: nil
            )
        }
        page(reveal, to: 2)
        #expect(await settle { reveal.isAtEndOfSource })
        withExtendedLifetime((pushStack, revealStack)) {}
    }

    private static var revealOrigin: TextRevealOrigin {
        TextRevealOrigin(rowFrame: { _ in CGRect(x: 16, y: 300, width: 370, height: 120) }, captionEnd: nil)
    }

    /// Opens a feed the way `open` does from a presenter on a stack in a
    /// window, and returns it loaded — with what must stay alive around it.
    private func routed(
        _ open: (FeedFeatureBuilder, UIViewController) -> Void
    ) async throws -> (SnapFeedViewController, [Any]) {
        let builder = FeedFeatureBuilder(repository: Photos(), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        let presenter = UIViewController()
        let nav = UINavigationController(rootViewController: presenter)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()
        open(builder, presenter)
        let feed = try #require(nav.viewControllers.last as? SnapFeedViewController, "nothing was pushed")
        feed.loadViewIfNeeded()
        feed.view.frame = window.bounds
        feed.view.layoutIfNeeded()
        // ⚠️ EVERY PAGE, not the first: the tests page to the last one, and on
        // a starved runner the first page can be all there is when they do.
        try #require(await settle { feed.debugPageCount >= 3 }, "the feed never loaded its three posts")
        feed.view.layoutIfNeeded()
        return (feed, [builder, window])
    }

    private func settle(looks: Int = 2_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
