import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The day on the feed's bar (#757) belongs to the page being read: only the
/// panel that holds the engagement drives it, and a tap on it reaches that
/// panel.
///
/// The panels' days are stood in for (`debugDayUnderTheTop`): what the
/// stream's own geometry reports is `UnifiedThreadChromeTests`'s concern;
/// this suite is about which panel the bar listens to.
@MainActor
struct SnapCommentsDayBarTests {
    private func model(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    /// Every text page's panel, held by post so a test can move its day.
    @MainActor
    private final class Panels {
        private(set) var byPost: [PostID: PostDetailViewController] = [:]
        func make(_ id: PostID) -> UIViewController {
            let panel = PostDetailViewController(
                viewModel: PostDetailViewModel(postID: id, repository: DayMuteProvider()),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                mode: .commentsOnly,
                threadChrome: true,
                groupsByDay: true
            )
            byPost[id] = panel
            return panel
        }

        /// What `id`'s panel reports from now on, as if its thread had
        /// scrolled there.
        func scroll(_ id: String, to day: Date?) throws {
            let panel = try #require(byPost[PostID(id)], "no panel for \(id)")
            panel.debugDayUnderTheTop = { day }
            panel.debugSyncDayUnderHeader()
        }
    }

    private func feed(_ ids: [String], panels: Panels) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: DayMuteProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(ids.map(model))
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    private func pager(of feed: SnapFeedViewController) throws -> UICollectionView {
        try #require(feed.view.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private static let today = Calendar.current.startOfDay(for: Date())
    private static let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

    /// ⚠️ A PREVIEW NEVER TOUCHES THE BAR, and a promotion hands it the new
    /// page's day. The page arriving mounts its panel while the page being
    /// left still owns the engagement: its mount cleared the pill mid-swipe,
    /// a cancelled swipe never restored it, and a promotion could leave the
    /// previous page's day on the bar.
    @Test func onlyTheEngagedPanelDrivesTheBarsDay() throws {
        let panels = Panels()
        let feed = feed(["a", "b"], panels: panels)
        #expect(feed.debugRestingCommentsID == PostID("a"), "the premise: a holds the engagement")
        try panels.scroll("a", to: Self.today)
        #expect(feed.commentsDay == Self.today, "the engaged panel's day is not on the bar")

        // b scrolls in as a preview, and its own thread moves.
        feed.debugMountRestingComments(for: PostID("b"))
        #expect(feed.debugPreviewRestingID == PostID("b"), "the premise: b is a preview")
        #expect(feed.commentsDay == Self.today, "the preview's mount cleared the bar")
        try panels.scroll("b", to: Self.yesterday)
        #expect(feed.commentsDay == Self.today, "the preview's day took the bar")

        // The swipe goes back home: still a's day.
        let collection = try pager(of: feed)
        collection.setContentOffset(.zero, animated: false)
        feed.scrollViewDidEndDecelerating(collection)
        #expect(feed.commentsDay == Self.today, "a cancelled swipe left the bar without a's day")

        // The swipe commits: b is promoted, and the bar says b's day.
        collection.setContentOffset(CGPoint(x: 0, y: collection.bounds.height), animated: false)
        feed.scrollViewDidEndDecelerating(collection)
        feed.debugLeaveCell(at: 0)
        #expect(feed.debugRestingCommentsID == PostID("b"), "the premise: b was promoted")
        #expect(feed.commentsDay == Self.yesterday,
                "the bar's day after the promotion: \(String(describing: feed.commentsDay))")
    }

    /// A tap on the bar's day scrolls the ENGAGED panel to that day.
    @Test func aTapOnTheDayScrollsTheEngagedThreadToIt() throws {
        let panels = Panels()
        let feed = feed(["a", "b"], panels: panels)
        try panels.scroll("a", to: Self.yesterday)
        let panel = try #require(panels.byPost[PostID("a")])
        var asked: [Date] = []
        panel.debugOnScrollToDay = { asked.append($0) }

        let pill = try #require(feed.debugCommentsDayPill, "no day on the bar")
        pill.sendActions(for: .primaryActionTriggered)

        #expect(asked == [Self.yesterday], "the tap reached: \(asked)")
    }
}

/// Vends nothing: these are about what the screen does with what it has.
private final class DayMuteProvider: FeedProviding, @unchecked Sendable {
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
