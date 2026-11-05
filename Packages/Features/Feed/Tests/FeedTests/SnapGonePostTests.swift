import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A post the server stops showing, on the feed it is shown in (#2048): the
/// page in front turns unavailable IN PLACE and leaves once the viewer pages
/// away; any other post replacing the one on show is a page change; a page
/// with no model is never read as a text page.
@MainActor
@Suite(.serialized)
struct SnapGonePostTests {
    /// Media posts by id; `gone` ones answer not-found, `window` is what a
    /// plain (unhydrated) first page serves.
    private final class Server: FeedProviding, @unchecked Sendable {
        var gone: Set<PostID> = []
        var window: [PostID] = []

        func entry(_ id: PostID) -> FeedEntry {
            FeedEntry(
                post: Post(
                    id: id, authorID: ProfileID("author-\(id.rawValue)"), caption: "caption \(id.rawValue)",
                    attachments: [MediaAttachment(
                        url: URL(string: "https://cdn.example/\(id.rawValue).jpg"), thumbnailURL: nil,
                        mimeType: "image/jpeg", pixelWidth: 720, pixelHeight: 1280
                    )],
                    publishedAt: Date(timeIntervalSince1970: 0)
                ),
                author: AuthorSummary(
                    id: ProfileID("author-\(id.rawValue)"), handle: id.rawValue, displayName: id.rawValue, avatarURL: nil
                ),
                likeCount: 1
            )
        }

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage {
            FeedPage(entries: window.map(entry), nextPageToken: nil, isCold: false, isEndOfSource: true)
        }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false, isEndOfSource: true)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            if gone.contains(id) { throw FeedError.notFound }
            return entry(id)
        }
    }

    private func makeFeed(_ viewModel: FeedViewModel) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
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

    private func page(_ feed: SnapFeedViewController, showing id: PostID) throws -> SnapFeedCell {
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

    private func ids(_ raw: String...) -> [PostID] { raw.map { PostID($0) } }

    /// A window read again without the post on show, because the server
    /// withholds it: the page stays where it is, as the block, with its
    /// author — no other post's caption, no clip of its own. Paged away, it is
    /// gone; paging back finds the post that followed it.
    @Test func thePostInFrontStaysUnavailableUntilTheViewerLeavesIt() async throws {
        let server = Server()
        let unavailable = UnavailablePosts()
        let viewModel = FeedViewModel(
            repository: FixedPostsFeedProvider(base: server, ids: ids("a", "b", "c")),
            unavailablePosts: unavailable
        )
        let feed = makeFeed(viewModel)
        #expect(await eventually { feed.orderedIDs == ids("a", "b", "c") }, "the window never loaded")
        try settle(feed, on: 0)
        #expect(feed.activePostID == PostID("a"))

        server.gone = [PostID("a")]
        viewModel.refresh()
        #expect(await eventually { feed.unavailablePostIDs.contains(PostID("a")) }, "the page never turned unavailable")
        #expect(feed.orderedIDs == ids("a", "b", "c"), "the post on show was pulled from under the viewer")
        #expect(feed.activePostID == PostID("a"))
        #expect(unavailable.contains(PostID("a")))
        #expect(try page(feed, showing: PostID("a")).debugShowsUnavailableBlock)

        try settle(feed, on: 1)
        #expect(await eventually { feed.orderedIDs == ids("b", "c") }, "the page outlived the viewer leaving it")
        #expect(feed.activePostID == PostID("b"), "the post on show moved with the removal")
        try settle(feed, on: 0)
        #expect(feed.activePostID == PostID("b"), "paging back found it")
        withExtendedLifetime(feed) {}
    }

    /// Another post taking the index on show — a refresh that no longer
    /// serves it — is a page change: the new post is activated, and its page
    /// is the one on screen, not the departed post's.
    @Test func aNewPostAtTheIndexOnShowIsAPageChange() async throws {
        let server = Server()
        server.window = ids("a", "b", "c")
        let viewModel = FeedViewModel(repository: server)
        let feed = makeFeed(viewModel)
        #expect(await eventually { feed.orderedIDs == ids("a", "b", "c") }, "the feed never loaded")
        try settle(feed, on: 0)
        #expect(feed.debugActivations.last == PostID("a"))

        server.window = ids("x", "b", "c")
        viewModel.refresh()
        #expect(await eventually { feed.orderedIDs == ids("x", "b", "c") })
        #expect(feed.activePostID == PostID("x"))
        // Activated as its page is displayed, the layout after the render.
        #expect(
            await eventually { feed.view.layoutIfNeeded(); return feed.debugActivations.last == PostID("x") },
            "the post that took the index was never activated"
        )
        #expect(feed.unavailablePostIDs.isEmpty, "a post that merely left was read as unavailable")
        _ = try page(feed, showing: PostID("x"))
        withExtendedLifetime(feed) {}
    }

    /// A post learnt unavailable ahead of the viewer — a neighbour's panel
    /// revalidated it — leaves the pages at once; the page on show keeps it.
    @Test func aPostLearntUnavailableAheadLeavesThePages() async throws {
        let server = Server()
        server.window = ids("a", "b", "c")
        let unavailable = UnavailablePosts()
        let viewModel = FeedViewModel(repository: server, unavailablePosts: unavailable)
        let feed = makeFeed(viewModel)
        #expect(await eventually { feed.orderedIDs == ids("a", "b", "c") }, "the feed never loaded")
        try settle(feed, on: 0)

        feed.markPostUnavailable(PostID("b"))
        #expect(feed.orderedIDs == ids("a", "c"))
        #expect(unavailable.contains(PostID("b")), "the other surfaces were not told")
        // The one on show stays, as the block, until it is left.
        feed.markPostUnavailable(PostID("a"))
        #expect(feed.orderedIDs == ids("a", "c"))
        try settle(feed, on: 1)
        #expect(await eventually { feed.orderedIDs == ids("c") })
        withExtendedLifetime(feed) {}
    }

    /// A page with no model is never a text page: unknown is not text.
    @Test func aMissingModelIsNeverAText() throws {
        let server = Server()
        let feed = makeFeed(FeedViewModel(repository: server))
        #expect(!feed.isTextPage(PostID("nowhere")))
        #expect(!feed.isTextPage(nil))
        withExtendedLifetime(feed) {}
    }

    /// The spelling that reads a missing model as text stays out of the snap
    /// feed: `modelsByID[…]?.mediaURL == nil` is true when there is no model.
    @Test func noCheckReadsAMissingModelAsText() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Feed/Snap/SnapFeedViewController.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        let offending = lines.enumerated().filter { _, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && code.contains("?.mediaURL == nil")
        }
        #expect(offending.isEmpty, "unknown read as text at lines \(offending.map { $0.offset + 1 }) — use `isTextPage`")
    }
}
