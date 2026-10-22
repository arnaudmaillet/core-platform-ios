import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The composer's keyboard ceiling (`CommentsInputBar.tracksKeyboard`) belongs
/// to the panel of the page being READ, whichever route made it the engagement
/// (#969). With it off, the input row stays at rest under the keyboard.
///
/// A media page: its comments panel is warmed when the page settles and parks
/// in the engagement's slot with no engagement behind it, and the settle's
/// reconcile turns a parked panel's ceiling OFF. The tap that then engages that
/// same panel settles nothing, so the ceiling stayed off: the reported defect,
/// on the first engagement after every settle.
///
/// Text onto text: the page arriving mounts its panel as a PREVIEW while the
/// page being left still holds the slot, and a preview's ceiling is off. When
/// the page being left lets go only AFTER the settle (its last pixel leaves a
/// moment later), the preview is promoted from `didEndDisplaying`, with no
/// reconcile behind it — and kept the ceiling off.
@MainActor
struct SnapComposerKeyboardCeilingTests {
    private func text(_ id: String) -> FeedItemDisplayModel {
        model(id, media: nil)
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    @MainActor
    private final class Panels {
        private(set) var byPost: [PostID: PostDetailViewController] = [:]
        func make(_ id: PostID) -> UIViewController {
            let panel = PostDetailViewController(
                viewModel: PostDetailViewModel(postID: id, repository: CeilingMuteProvider()),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                threadChrome: true,
                groupsByDay: true
            )
            byPost[id] = panel
            return panel
        }

        func tracks(_ id: String) throws -> Bool {
            try #require(byPost[PostID(id)], "no panel for \(id)").debugComposerTracksKeyboard
        }
    }

    private func makeFeed(_ models: [FeedItemDisplayModel], panels: Panels) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: CeilingMuteProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) }
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

    /// ⚠️ THE REPORTED TRIGGER: a media page's warm panel, turned off at the
    /// settle, then engaged by a tap.
    @Test func aWarmPanelEngagedByATapRisesWithTheKeyboard() throws {
        let panels = Panels()
        let feed = makeFeed([media("a"), media("b")], panels: panels)
        if !feed.debugHasParkedCommentsWarm { feed.debugPrewarmComments(for: PostID("a")) }
        // The page settles with the warm parked: the reconcile turns it off.
        feed.scrollViewDidEndDecelerating(try pager(of: feed))
        #expect(feed.debugHasParkedCommentsWarm, "the premise: a warm is parked in the slot")
        #expect(try !panels.tracks("a"), "the premise: the settle turned the parked warm off")

        // The tap: the warm becomes the engagement, and nothing settles.
        feed.openComments(for: PostID("a"))

        #expect(feed.debugRestingCommentsID == PostID("a"), "the premise: a is engaged")
        #expect(panels.byPost.count == 1, "the premise: the engagement is the warm, not a new panel")
        #expect(try panels.tracks("a"), "the engaged page's composer stays put under the keyboard")
    }

    /// ⚠️ TEXT ONTO TEXT: the settle lands while the page being left still
    /// holds the slot, and the promotion comes after it, when its last pixel
    /// goes.
    @Test func aPreviewPromotedAfterTheSettleRisesWithTheKeyboard() throws {
        let panels = Panels()
        let feed = makeFeed([text("a"), text("b")], panels: panels)
        #expect(feed.debugRestingCommentsID == PostID("a"), "the premise: a holds the engagement")
        #expect(try panels.tracks("a"), "the page being read cannot rise with the keyboard")

        // b scrolls in as a preview: its ceiling is off while it travels.
        feed.debugMountRestingComments(for: PostID("b"))
        #expect(feed.debugPreviewRestingID == PostID("b"), "the premise: b is a preview")
        #expect(try !panels.tracks("b"), "a page still scrolling in had its composer pinned to the screen")

        // The swipe commits with a's last points still on screen, so the
        // settle leaves the slot to a.
        let collection = try pager(of: feed)
        collection.setContentOffset(CGPoint(x: 0, y: collection.bounds.height - 1), animated: false)
        feed.scrollViewDidEndDecelerating(collection)
        #expect(feed.debugPreviewRestingID == PostID("b"), "the premise: the settle did not promote b")

        // a's last pixel leaves: b is promoted, and is the page being read.
        collection.setContentOffset(CGPoint(x: 0, y: collection.bounds.height), animated: false)
        feed.debugLeaveCell(at: 0)
        #expect(feed.debugRestingCommentsID == PostID("b"), "the premise: b was promoted")
        #expect(try panels.tracks("b"), "the engaged page's composer stays put under the keyboard")
    }
}

/// Vends nothing: these are about which panel the keyboard lifts.
private final class CeilingMuteProvider: FeedProviding, @unchecked Sendable {
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
