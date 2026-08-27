import CoreModels
import CoreNavigation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// What the post on screen travels as, asked of the screen that is showing it.
///
/// This is the ONE question the whole dismissal seam is built on: two grabs and
/// one delegate slot all decide what they do by asking it, so a wrong answer
/// here is not a wrong animation, it is no animation — either both drivers
/// stand down, or the one that claims the drag cannot animate what it claimed.
///
/// It has to be asked of the ACTIVE PAGE rather than of what the screen opened
/// with, because this screen is a pager: the viewer routinely closes a post
/// that is not the one they tapped.
@MainActor
struct SnapDismissalKindTests {
    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id),
            authorID: ProfileID("a"),
            authorName: "A",
            metaText: "",
            avatarURL: nil,
            caption: "caption",
            mediaURL: media,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil,
            likeCount: 0
        )
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func text(_ id: String) -> FeedItemDisplayModel {
        model(id, media: nil)
    }

    private func feed(_ models: [FeedItemDisplayModel]) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: MuteFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        // ⚠️ ON SCREEN, or the active page is `nil` whatever the offset says:
        // the dispatcher reports no active item while the surface is down, and
        // a test that skipped this would read every answer off page zero and
        // call the paging cases green for the wrong reason.
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    /// Pages the feed the way a settled swipe does: move the offset, then tell
    /// the screen the scroll came to rest. The active page is recomputed there
    /// and nowhere else, so a test that only moved the offset would be asking
    /// about the page the viewer left.
    private func page(_ feed: SnapFeedViewController, to index: Int) {
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }
        collection.setContentOffset(
            CGPoint(x: 0, y: collection.bounds.height * CGFloat(index)), animated: false
        )
        feed.scrollViewDidEndDecelerating(collection)
    }

    /// A post with media has something for a hero to carry.
    @Test func aPostWithMediaFlies() {
        #expect(feed([media("m")]).zoomDismissalKind == .hero)
    }

    /// ⚠️ AND A TEXT POST TRAVELS AS A CARD — it has no media, so there is
    /// nothing a flight could carry between the two screens.
    @Test func aPostWithNoMediaTravelsAsACard() {
        #expect(feed([text("t")]).zoomDismissalKind == .card)
    }

    /// ⚠️ THE ANSWER FOLLOWS THE PAGE, NOT THE OPENING.
    ///
    /// The defect this pins is the reported one: open a media post, scroll down
    /// onto a text post, and close. Answering from the opening tap sends a hero
    /// after media that is not on screen.
    @Test func pagingOntoATextPostChangesTheAnswer() {
        let feed = feed([media("m"), text("t")])
        #expect(feed.zoomDismissalKind == .hero)

        page(feed, to: 1)

        #expect(feed.zoomDismissalKind == .card)
    }

    /// And the mirror, which is the same bug from the other side: opening a
    /// text post as a window and paging onto media must give the hero back.
    @Test func pagingOntoAMediaPostGivesTheFlightBack() {
        let feed = feed([text("t"), media("m")])
        #expect(feed.zoomDismissalKind == .card)

        page(feed, to: 1)

        #expect(feed.zoomDismissalKind == .hero)
    }

    /// ⚠️ AN UNANSWERABLE SCREEN SAYS `.hero`, WHICH IS WHAT EVERY CALLER MEANT
    /// BEFORE THE QUESTION EXISTED.
    ///
    /// A feed with nothing loaded yet is asked this on any pop that beats its
    /// first page in — and the fallback has to be the historical answer, or a
    /// perfectly ordinary flight is silently downgraded during the window where
    /// the screen knows least.
    @Test func aFeedWithNothingToShowFallsBackToFlying() {
        #expect(feed([]).zoomDismissalKind == .hero)
    }

    /// The answer is a pure question — asking it must not activate a page,
    /// start a player, or otherwise move the screen. Both grabs ask it on every
    /// touch that reaches them.
    @Test func askingChangesNothing() {
        let feed = feed([media("m"), text("t")])
        page(feed, to: 1)
        let active = feed.activePostID

        for _ in 0..<5 { _ = feed.zoomDismissalKind }

        #expect(feed.activePostID == active)
        #expect(feed.zoomDismissalKind == .card)
    }
}

/// Vends nothing: these are about the question the feed answers, not about what
/// it loads through the repository.
private final class MuteFeedProvider: FeedProviding, @unchecked Sendable {
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
