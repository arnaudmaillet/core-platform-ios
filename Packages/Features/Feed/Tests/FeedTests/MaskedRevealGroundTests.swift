import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **THE FLIGHT IS COMPOSITED THROUGH THIS SCREEN, so this screen's floors
/// have to stay out of its way.**
///
/// A post opened from its COMMENT COUNT engages before the push and opens as a
/// masked hero: the real thread is drawn through a window that grows from the
/// media rect, over a card carrying the photograph. That only works while every
/// opaque layer between the two is transparent — the view, the collection view,
/// and the cell's own ground.
///
/// ⚠️ WHAT BROKE IT was a rule that has nothing to do with transitions: the
/// ground follows the settled page (light under a text page, black under a
/// media one), applied at EVERY settle. A flight triggers settles, so one frame
/// into the opening the ground went black and shut the card out — reported as
/// the media not transitioning at all and appearing only at the end, and filmed
/// as exactly one frame of photograph followed by black.
///
/// Both rules are right; the order between them was missing. These pin it.
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

    /// ⚠️ AND IT GOES TRANSPARENT FOR A MASKED OPENING, because the card is
    /// behind it.
    @Test func theGroundClearsWhenTheWindowOpens() throws {
        let feed = feed([model("a", media: URL(string: "https://example.test/a.jpg"))])
        let pager = try #require(collection(feed))

        feed.debugBeginMaskedReveal(for: PostID("a"))

        #expect(pager.backgroundColor != .black, "the ground is still opaque under the card")
        #expect(feed.view.backgroundColor != .black)
    }

    /// ⚠️ AND A SETTLE MID-FLIGHT MUST NOT PAINT IT BACK — the whole defect.
    ///
    /// The settle is not hypothetical: realizing the page fires `willDisplay`,
    /// which recomputes the active item, which reconciles the interface — and
    /// the ground is one of the things it derives.
    @Test func aSettleDuringTheOpeningLeavesTheGroundClear() throws {
        let feed = feed([model("a", media: URL(string: "https://example.test/a.jpg"))])
        let pager = try #require(collection(feed))
        feed.debugBeginMaskedReveal(for: PostID("a"))

        feed.scrollViewDidEndDecelerating(pager)
        feed.debugRealizeVisibleCells()

        #expect(pager.backgroundColor != .black,
                "a settle repainted the ground black over the flight card")
    }

    /// And the ground comes back when the flight lands — the rule resumes,
    /// rather than being permanently disabled by having been suspended once.
    @Test func theGroundReturnsWhenTheFlightLands() throws {
        let feed = feed([model("a", media: URL(string: "https://example.test/a.jpg"))])
        let pager = try #require(collection(feed))
        feed.debugBeginMaskedReveal(for: PostID("a"))

        feed.zoomTransitionDidEnd()

        #expect(pager.backgroundColor == .black)
        // …and a later settle keeps it that way, which is what "the rule
        // resumes" means.
        feed.scrollViewDidEndDecelerating(pager)
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
