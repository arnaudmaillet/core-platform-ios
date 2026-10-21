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

    /// The page's open card, on screen, from the pager's transform.
    private static func card(_ geometry: SnapSideList.Geometry, progress: CGFloat = 1) -> CGRect {
        let size = geometry.size
        return CGRect(origin: .zero, size: size).applying(
            CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(geometry.pagerTransform(progress: progress))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
        )
    }

    /// The bars as the two simulators wear them: an iPhone 18 Pro (402 × 874)
    /// and an iPhone SE, 2nd generation (375 × 667).
    static let devices: [(size: CGSize, bars: UIEdgeInsets)] = [
        (CGSize(width: 402, height: 874), UIEdgeInsets(top: 116, left: 0, bottom: 98, right: 0)),
        (CGSize(width: 375, height: 667), UIEdgeInsets(top: 64, left: 0, bottom: 49, right: 0)),
    ]

    /// ⚠️ BETWEEN THE BARS (#1509): open, the card and the list sit entirely
    /// between the top bar and the bottom toolbar, a gap from each; the
    /// card keeps one gap from the leading edge and one from the list, which
    /// keeps one from the trailing edge; closed, nothing moved.
    @Test(arguments: [0, 1])
    func theCardAndTheListShareTheScreen(_ device: Int) {
        let (size, bars) = Self.devices[device]
        let geometry = SnapSideList.Geometry(size: size, bars: bars, deviceCornerRadius: 55)
        let gap = SnapSideList.Geometry.gap
        #expect(geometry.pagerTransform(progress: 0) == .identity)

        let card = Self.card(geometry)
        let list = geometry.listFrame(progress: 1)
        #expect(card.minY >= bars.top + gap - 0.01, "the card runs under the top bar: \(card)")
        #expect(card.maxY <= size.height - bars.bottom - gap + 0.01, "the card runs under the toolbar: \(card)")
        #expect(abs(card.width / card.height - size.width / size.height) < 0.001, "the card does not keep the page's aspect")
        #expect(abs(card.minX - gap) < 0.01, "the card's leading gap: \(card)")
        #expect(abs(list.minX - card.maxX - gap) < 0.01, "the gap between card and list: \(card) \(list)")
        #expect(abs(size.width - list.maxX - gap) < 0.01, "the list's trailing gap: \(list)")
        #expect(abs(list.height - card.height) < 0.01 && abs(list.minY - card.minY) < 0.01, "the list is not the card's height")
        #expect(geometry.listFrame(progress: 0).minX == size.width, "closed, the list waits beyond the edge")
        // Never under a bar at any progress past 0 (the list's own frame
        // slides in from beyond the edge, at the open card's height).
        for progress in stride(from: 0.1, through: 1, by: 0.1) {
            let moving = geometry.listFrame(progress: progress)
            #expect(moving.minY >= bars.top && moving.maxY <= size.height - bars.bottom)
        }
    }

    /// The list is wider than the old ninth on an 18 Pro (about 70 pt), and
    /// never narrower than its minimum on an SE.
    @Test func theListTakesTheWidthTheCardLeaves() {
        let pro = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars)
        #expect(pro.listWidth > 60 && pro.listWidth < 100, "\(pro.listWidth)")
        let se = SnapSideList.Geometry(size: Self.devices[1].size, bars: Self.devices[1].bars)
        #expect(se.listWidth >= SnapSideList.Geometry.minimumListWidth)
    }

    /// ⚠️ THE CORNERS GO FROM THE DEVICE'S TO THE CARD'S (#1509), in screen
    /// space and continuously — never square.
    @Test func theCornersGoFromTheDevicesToTheCards() {
        let geometry = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars, deviceCornerRadius: 55)
        let card = SnapSideList.Geometry.cornerRadius
        #expect(card == SnapSideList.Geometry.tileCornerRadius + SnapSideList.Geometry.gap, "not concentric with the tiles")
        #expect(geometry.screenCornerRadius(progress: 0) == 55)
        #expect(abs(geometry.screenCornerRadius(progress: 0.5) - (55 + card) / 2) < 0.01)
        #expect(geometry.screenCornerRadius(progress: 1) == card)
    }

    /// ⚠️ THE OVERLAY MOVES DOWN WITH THE SLIDE (#1509) by the band the
    /// toolbar covers, and back up on close.
    @Test func theOverlayMovesDownByTheToolbarsBand() {
        let geometry = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars)
        #expect(geometry.overlayOffset(progress: 0) == 0)
        #expect(geometry.overlayOffset(progress: 0.5) == Self.devices[0].bars.bottom / 2)
        #expect(geometry.overlayOffset(progress: 1) == Self.devices[0].bars.bottom)
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
        #expect(pager.layer.cornerRadius > 0, "the open card is square")
        #expect(pager.transform.a < 1 && pager.transform.a == pager.transform.d, "not one uniform scale")
        #expect(feed.view.transform == .identity, "the screen itself moved")
        #expect(!sideList.listView.isHidden)
        #expect(!feed.isReadyForInteractiveDismissal, "a dismissal could begin while the list is open")
        #expect(pager.allowsBackwardPaging, "the pager does not page back while open")

        sideList.settle(open: false, animated: false)
        #expect(pager.transform == .identity)
        #expect(feed.collectionView.visibleCells.compactMap { ($0 as? SnapFeedCell)?.sideListOverlayOffset }.allSatisfy { $0 == 0 },
                "an overlay stayed down after the close")
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
