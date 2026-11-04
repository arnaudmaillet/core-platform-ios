import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// The screen's ground under a media page: black at rest. (The masked
/// comments opening these tests also pinned is gone with the first comments
/// space, #2087.)
@MainActor
struct MaskedRevealGroundTests {
    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func feed(_ models: [FeedItemDisplayModel]) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: QuietFeed()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { _ in
                let panel = UIViewController()
                panel.view.backgroundColor = .clear
                return panel
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.debugRealizeVisibleCells()
        return controller
    }

    private func collection(_ feed: SnapFeedViewController) -> UICollectionView? {
        feed.view.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// The premise, and the rule this one has to yield to: at rest under a
    /// media page the ground is black.
    @Test func theGroundIsBlackUnderAMediaPageAtRest() throws {
        let feed = feed([model("a", media: URL(string: "https://example.test/a.jpg"))])
        let pager = try #require(collection(feed))

        #expect(pager.backgroundColor == .black)
    }

}

private final class QuietFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
