import CoreContracts
import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The side list (#1425), on every vertical feed since #1473.
@MainActor
struct SnapSideListTests {
    // MARK: - Geometry

    /// Open, the card keeps one gap from the leading edge and one from the
    /// list, which keeps one from the trailing edge; closed, nothing moved.
    @Test func theCardAndTheListShareTheScreen() {
        let geometry = SnapSideList.Geometry(size: CGSize(width: 402, height: 874))
        let gap = SnapSideList.Geometry.gap
        #expect(geometry.listWidth == 45, "about a ninth of the screen")
        #expect(geometry.pagerTransform(progress: 0) == .identity)

        let card = CGRect(x: 0, y: 0, width: 402, height: 874).applying(
            CGAffineTransform(translationX: -201, y: -437)
                .concatenating(geometry.pagerTransform(progress: 1))
                .concatenating(CGAffineTransform(translationX: 201, y: 437))
        )
        let list = geometry.listFrame(progress: 1)
        #expect(abs(card.minX - gap) < 0.01, "the card's leading gap: \(card)")
        #expect(abs(list.minX - card.maxX - gap) < 0.01, "the gap between card and list: \(card) \(list)")
        #expect(abs(402 - list.maxX - gap) < 0.01, "the list's trailing gap: \(list)")
        #expect(abs(list.height - card.height) < 0.01 && abs(list.minY - card.minY) < 0.01, "the list is as tall as the card")
        #expect(geometry.listFrame(progress: 0).minX == 402, "closed, the list waits beyond the edge")
    }

    /// Past half way, or flung, it opens; short of it, it springs back.
    @Test func aReleaseSettlesByWhereItWouldCarryOnTo() {
        let geometry = SnapSideList.Geometry(size: CGSize(width: 402, height: 874))
        #expect(geometry.settlesOpen(progress: 0.6, velocityX: 0))
        #expect(!geometry.settlesOpen(progress: 0.3, velocityX: 0))
        #expect(geometry.settlesOpen(progress: 0.3, velocityX: -900), "a leftward flick opens")
        #expect(!geometry.settlesOpen(progress: 0.7, velocityX: 900), "a rightward flick closes")
    }

    // MARK: - The screen

    private static func photo(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "", mediaURL: URL(string: "https://example.test/\(id).jpg"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil
        )
    }

    private static func entry(_ id: String, media: Bool = true) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("author-\(id)"), caption: "caption \(id)",
                attachments: media ? [MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                )] : [],
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000), likeCountsHidden: false
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h-\(id)", displayName: "Name \(id)", avatarURL: nil),
            likeCount: 0
        )
    }

    private func feed(sideList: Bool) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SideListProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SideListReporter()
        )
        controller.installsSideList = sideList
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.seedProjection([Self.photo("p1")])
        controller.view.layoutIfNeeded()
        return controller
    }

    /// On by default (#1473): a vertical feed installs it with no flag.
    @Test func everyVerticalFeedInstallsItByDefault() {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SideListProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SideListReporter()
        )
        #expect(controller.installsSideList)
    }

    /// A screen that opts out installs nothing, and the dismissal answers as
    /// it always did.
    @Test func aScreenThatOptsOutInstallsNothing() {
        let feed = feed(sideList: false)
        #expect(feed.sideList == nil)
        #expect(!feed.view.subviews.contains { $0 is SnapSideListView })
        #expect(feed.isReadyForInteractiveDismissal)
    }

    /// Open: the pager is a card, the list is on screen, the dismissals stand
    /// aside and the pager pages back; closed, all of it undone.
    @Test func openingShrinksThePagerAndHoldsTheDismissals() throws {
        let feed = feed(sideList: true)
        let sideList = try #require(feed.sideList)
        let pager = try #require(feed.collectionView as? SnapFeedCollectionView)

        sideList.settle(open: true, animated: false)
        #expect(pager.transform != .identity, "the page did not shrink")
        #expect(pager.transform.a < 1 && pager.transform.a == pager.transform.d, "not one uniform scale")
        #expect(feed.view.transform == .identity, "the screen itself moved")
        #expect(!sideList.listView.isHidden)
        #expect(!feed.isReadyForInteractiveDismissal, "a dismissal could begin while the list is open")
        #expect(pager.allowsBackwardPaging, "the pager does not page back while open")

        sideList.settle(open: false, animated: false)
        #expect(pager.transform == .identity)
        #expect(sideList.listView.isHidden)
        #expect(feed.isReadyForInteractiveDismissal)
        #expect(!pager.allowsBackwardPaging)
    }

    /// The list offers current posts of the feed's kind, none already in it.
    @Test func theListOffersOtherPostsOfTheFeedsKind() async {
        let feed = feed(sideList: true)
        feed.sideListEntries = {
            [Self.entry("p1"), Self.entry("m1"), Self.entry("t1", media: false), Self.entry("m2"), Self.entry("m1")]
        }
        let ids = await feed.sideListCandidates().map(\.post.id.rawValue)
        #expect(Set(ids) == ["m1", "m2"], "not the other media posts, once each: \(ids)")
    }
}

/// Inserting after a post (#1425): the pager's next page, paging back
/// returns to the anchor.
@MainActor
struct FeedViewModelInsertTests {
    @Test func aPickedPostGoesRightAfterTheOneOnShow() async {
        let viewModel = FeedViewModel(repository: SideListProvider())
        var shown: [String] = []
        var renders = 0
        viewModel.onStateChange = { state in
            shown = state.items.map(\.id.rawValue)
            renders += 1
        }
        // The builder comes with the screen's load; the (empty) first page
        // lands before the seed.
        viewModel.viewDidLoad()
        for _ in 0..<6_000 where renders == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        viewModel.seed(["a", "b", "c"].map {
            FeedItemDisplayModel(
                id: PostID($0), authorID: ProfileID("x"), authorName: "X", metaText: "", avatarURL: nil,
                caption: "", mediaURL: nil, mediaKind: .image, thumbnailURL: nil, audioText: nil
            )
        })
        let inserted = await viewModel.insert(SideListProvider.entry("n"), after: PostID("a"))
        #expect(inserted)
        #expect(shown == ["a", "n", "b", "c"], "not right after the anchor: \(shown)")
        let again = await viewModel.insert(SideListProvider.entry("n"), after: PostID("c"))
        #expect(!again, "a post already in the feed went in twice")
        #expect(shown == ["a", "n", "b", "c"])
    }
}

private final class SideListReporter: ContentReporting, @unchecked Sendable {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

private final class SideListProvider: FeedProviding, @unchecked Sendable {
    static func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID(id), authorID: ProfileID("p"), caption: "", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { Self.entry(id.rawValue) }
}
