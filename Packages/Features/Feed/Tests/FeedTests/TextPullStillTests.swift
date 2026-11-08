import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE PULL TO GO BACK LIFTS NOTHING ON A TEXT PAGE (#2187, the owner): on a
/// text post opened with the native push, the pull up from the end (#2045)
/// and the pull down from the top (#2046) move neither the text nor its
/// comments — the indicator alone answers. A media page keeps its lift, and
/// both cost the same travel.
@MainActor
struct TextPullStillTests {
    /// Seeded only: the feed's own first load must not replace the seed.
    private final class Posts: FeedProviding, @unchecked Sendable {
        private struct SeededOnly: Error {}
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { throw SeededOnly() }
        func loadPage(afterToken token: String) async throws -> FeedPage { throw SeededOnly() }
        func loadPost(_ id: PostID) async throws -> FeedEntry { throw SeededOnly() }
    }

    private func model(_ id: String, media: Bool) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "words",
            mediaURL: media ? URL(string: "https://example.test/\(id).jpg") : nil,
            mediaKind: .image, thumbnailURL: nil, audioText: nil, likeCount: 3
        )
    }

    private func makeFeed(_ models: [FeedItemDisplayModel]) -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: Posts()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        feed.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        feed.seedProjection(models)
        feed.view.layoutIfNeeded()
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        return feed
    }

    private func pager(of feed: SnapFeedViewController) throws -> UICollectionView {
        try #require(feed.view.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private func settle(_ feed: SnapFeedViewController, on index: Int) throws {
        let pager = try pager(of: feed)
        pager.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * pager.bounds.height), animated: false)
        pager.layoutIfNeeded()
        feed.scrollViewDidEndDecelerating(pager)
        feed.view.layoutIfNeeded()
    }

    @Test(arguments: [ZoomDismissAxisCase.up, .down])
    func aTextPagePulledStaysStillAndOnlyTheIndicatorAnswers(_ axis: ZoomDismissAxisCase) throws {
        let feed = makeFeed([model("t", media: false), model("m", media: true)])
        try settle(feed, on: 0)
        let pager = try pager(of: feed)
        let rest = pager.contentOffset.y

        let lift = feed.pullToClose(travel: 200, along: axis.axis)
        #expect(lift > 0 && lift < 200, "no progress, or no resistance: \(lift)")
        #expect(pager.contentOffset.y == rest, "the text page moved by \(pager.contentOffset.y - rest)")
        let indicator = try #require(feed.debugPullIndicator, "the indicator did not answer")
        let pinned = indicator.center.y
        feed.pullToClose(travel: 400, along: axis.axis)
        #expect(pager.contentOffset.y == rest)
        #expect(abs(indicator.center.y - pinned) < 0.5, "the indicator moved with a lift that isn't there")

        feed.endPullToClose(commit: false)
        #expect(pager.contentOffset.y == rest, "a release short of the threshold moved the text page")
        #expect(feed.debugPullIndicator == nil)
        withExtendedLifetime(feed) {}
    }

    /// The same effort: a text pull reports the progress a media page's lift
    /// would have, so a release commits at the same travel on both.
    @Test func aTextPullCostsTheSameTravelAsAMediaPull() throws {
        let text = makeFeed([model("t", media: false), model("m", media: true)])
        try settle(text, on: 0)
        let media = makeFeed([model("m", media: true), model("t", media: false)])
        try settle(media, on: 0)

        for travel in [40, 120, 300] as [CGFloat] {
            let still = text.pullToClose(travel: travel, along: .upward)
            let lifted = media.pullToClose(travel: travel, along: .upward)
            #expect(abs(still - lifted) < 0.01, "at \(travel) pt: text \(still), media \(lifted)")
        }
        text.endPullToClose(commit: false)
        media.endPullToClose(commit: false)
        withExtendedLifetime((text, media)) {}
    }

    /// A media page keeps today's lift (#2045).
    @Test func aMediaPagePulledStillLifts() throws {
        let feed = makeFeed([model("m", media: true), model("t", media: false)])
        try settle(feed, on: 0)
        let pager = try pager(of: feed)
        let rest = pager.contentOffset.y
        let lift = feed.pullToClose(travel: 200, along: .upward)
        #expect(abs(pager.contentOffset.y - (rest + lift)) < 0.5, "the media page did not lift")
        feed.endPullToClose(commit: true)
        withExtendedLifetime(feed) {}
    }

    /// The pull reads the page's kind at its first step: a text page reached
    /// by paging is still, a media page reached by paging lifts.
    @Test func theKindIsReadFromThePageOnShow() throws {
        let feed = makeFeed([model("m", media: true), model("t", media: false)])
        try settle(feed, on: 1)
        let pager = try pager(of: feed)
        let rest = pager.contentOffset.y
        feed.pullToClose(travel: 200, along: .upward)
        #expect(pager.contentOffset.y == rest, "the text page on show moved")
        feed.endPullToClose(commit: false)

        try settle(feed, on: 0)
        let mediaRest = pager.contentOffset.y
        let lift = feed.pullToClose(travel: 200, along: .vertical)
        #expect(abs(pager.contentOffset.y - (mediaRest - lift)) < 0.5, "the media page on show did not lift")
        feed.endPullToClose(commit: false)
        withExtendedLifetime(feed) {}
    }
}

/// Both pull directions, by name in the test's arguments.
enum ZoomDismissAxisCase: String, CaseIterable, CustomTestStringConvertible {
    case up, down
    var axis: ZoomDismissAxis { self == .up ? .upward : .vertical }
    var testDescription: String { rawValue }
}
