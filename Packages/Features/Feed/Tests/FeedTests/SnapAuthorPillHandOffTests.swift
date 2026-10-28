import CoreModels
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// Hydrates every id as a photo post by its own author ("author-<id>").
private final class AuthoredPhotos: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        let author = ProfileID("author-\(id.rawValue)")
        return FeedEntry(
            post: Post(
                id: id, authorID: author, caption: id.rawValue,
                attachments: [MediaAttachment(
                    url: URL(string: "mock://photo/\(id.rawValue)"),
                    thumbnailURL: URL(string: "mock://poster/\(id.rawValue)"),
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1080
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: author, handle: id.rawValue, displayName: "Author \(id.rawValue)", avatarURL: nil),
            likeCount: 0
        )
    }
}

/// THE PILL CHANGES OWNER WITH THE PICTURE (#1791): one rule — the page that
/// covers most of the screen (`playbackOwner`) — so the author and the clip
/// change hands on the same frame, crossing half a page in either direction.
@MainActor
struct SnapAuthorPillHandOffTests {
    private func makeFeed() async throws -> SnapFeedViewController {
        let provider = FixedPostsFeedProvider(
            base: AuthoredPhotos(), ids: ["a", "b", "c"].map { PostID($0) }, isCompleteSet: true
        )
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
        try #require(await settle { controller.debugPageCount == 3 }, "the feed never loaded")
        controller.view.layoutIfNeeded()
        return controller
    }

    private func shownAuthor(_ feed: SnapFeedViewController) -> String? {
        let pill = feed.toolbarItems?.lazy.compactMap { $0.customView as? SnapAuthorIdentityView }.first
        return pill?.shownAuthor?.authorID.rawValue
    }

    /// Drags to `pages` (fractional) the way a finger does: the scroll
    /// callback, no settle.
    private func drag(_ feed: SnapFeedViewController, to pages: CGFloat) throws {
        let collection = try #require(feed.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.setContentOffset(CGPoint(x: 0, y: collection.bounds.height * pages), animated: false)
        feed.scrollViewDidScroll(collection)
    }

    @Test func thePillAndThePictureChangeOwnerAtTheSameOffset() async throws {
        let feed = try await makeFeed()
        try #require(await settle { shownAuthor(feed) == "author-a" }, "the first author never showed")

        for (pages, owner) in [(0.45, 0), (0.55, 1), (0.95, 1), (1.6, 2), (1.4, 1), (0.48, 0)] as [(CGFloat, Int)] {
            try drag(feed, to: pages)
            #expect(feed.playbackOwner == owner, "the picture at \(pages) pages")
            #expect(shownAuthor(feed) == ["author-a", "author-b", "author-c"][owner],
                    "the pill and the picture disagree at \(pages) pages")
        }
    }

    private func settle(looks: Int = 2_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
