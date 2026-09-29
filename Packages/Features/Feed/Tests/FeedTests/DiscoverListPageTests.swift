import CoreModels
import CoreNavigation
import CoreStorage
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's Discover as a list with mosaic chunks: the tab order, what the
/// page is handed, how its stretches become sections, cards and tiles, and the
/// per-post answers the hero asks of a page that draws both.
@MainActor
struct DiscoverListPageTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: SilentFetcher()) }

    /// Every third post text, the rest photos — the feed's usual mix.
    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = index % 3 == 2
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: isText ? .text : .photo,
                isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1.5,
                caption: "post \(index)",
                publishedAtMS: Int64(10_000 - index)
            )
        }
    }

    private func page(_ posts: [GalleryPost], complete: Bool = true) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: .discover)
        // TALL, so the first run of cards AND the first chunk are realized:
        // three media cards alone can outgrow a phone's height, and the hero
        // questions below read realized cells.
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(complete)
        page.render(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    // MARK: - The single page

    /// The snapshot hands each surface its OWN corpus: Discover everyone, the
    /// mosaic Discover's media, the pushed lists the people followed.
    @Test func eachSurfaceIsHandedItsOwnCorpus() async {
        let all = corpus(9)
        let model = ForYouViewModel(repository: DiscoverStubProvider(posts: all))
        var latest: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { latest = $0 }
        model.viewDidLoad()
        for _ in 0..<40 where model.discoverPosts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(latest?.discover == .content(all))
        #expect(latest?.media == .content(all.filter { $0.kind != .text }))
    }

    /// Discover is everyone: an author unfollowed from the screen leaves
    /// Following and stays in Discover's state — list and mosaic both — and
    /// an empty Discover speaks Discover's words.
    @Test func discoverIsEveryoneFollowingIsTheFollowed() async {
        let posts = corpus(6).enumerated().map { index, post in
            GalleryPost(
                id: post.id, kind: post.kind, isRepost: false, pages: post.pages,
                caption: post.caption, publishedAtMS: post.publishedAtMS,
                authorID: ProfileID(index.isMultiple(of: 2) ? "followed" : "stranger")
            )
        }
        let model = ForYouViewModel(repository: DiscoverStubProvider(posts: posts))
        var latest: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { latest = $0 }
        model.viewDidLoad()
        for _ in 0..<40 where model.discoverPosts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.removeAuthor(ProfileID("stranger"))

        #expect(latest?.discover == .content(posts))
        #expect(model.followingPosts.allSatisfy { $0.authorID == ProfileID("followed") })
        #expect(model.discoverPosts.contains { $0.authorID == ProfileID("stranger") })

        let empty = ForYouViewModel.discoverEmptyState(source: .trending)
        #expect(empty.title.contains("discover"))
    }

    // MARK: - Stretches, sections, cells

    /// The page shows exactly the planner's list, flattened in display order.
    @Test func thePageIsThePlannersList() {
        let posts = corpus(60)
        let page = page(posts)
        var planner = MosaicChunkPlanner()
        let expected = planner.segments(for: posts, isComplete: true)
        #expect(page.segments == expected)
        #expect(page.posts.map(\.id) == expected.flatMap(\.posts).map(\.id))
        // Three cards, then the first chunk.
        #expect(page.segments.first?.posts.count == MosaicChunkPlanner.firstGap)
        #expect(page.segments.dropFirst().first?.chunk != nil)
        #expect(!page.drawsAsTile(page.posts[0].id))
        #expect(page.drawsAsTile(page.posts[MosaicChunkPlanner.firstGap].id))
    }

    /// One collection-view section per stretch, one item per post.
    @Test func eachStretchIsASection() {
        let page = page(corpus(60))
        let view = collectionView(of: page)
        #expect(view.numberOfSections == page.segments.count)
        for (section, segment) in page.segments.enumerated() {
            #expect(view.numberOfItems(inSection: section) == segment.posts.count)
        }
    }

    /// A run's posts are CARDS, a chunk's are TILES — asked of the realized
    /// cells, which is what every hero question resolves through.
    @Test func runsAreCardsAndChunksAreTiles() {
        let page = page(corpus(60))
        let view = collectionView(of: page)
        view.layoutIfNeeded()
        let card = view.cellForItem(at: IndexPath(item: 0, section: 0))
        let tile = view.cellForItem(at: IndexPath(item: 0, section: 1))
        #expect(card is PostGridListRowCell)
        #expect(tile is PostGridTileCell)
    }

    /// The chunk's foot is one line: every tile resting on it ends at the same
    /// y, and together they span the list's width — measured on the LAID-OUT
    /// attributes, the numbers the screen actually draws.
    @Test func aChunksTilesEndOnOneLine() {
        let page = page(corpus(60))
        let view = collectionView(of: page)
        view.layoutIfNeeded()
        guard let chunkSection = page.segments.firstIndex(where: { $0.chunk != nil }) else {
            Issue.record("no chunk to measure")
            return
        }
        let frames = (0..<view.numberOfItems(inSection: chunkSection)).compactMap {
            view.layoutAttributesForItem(at: IndexPath(item: $0, section: chunkSection))?.frame
        }
        let foot = frames.map(\.maxY).max() ?? 0
        let resting = frames.filter { abs($0.maxY - foot) < 0.01 }.sorted { $0.minX < $1.minX }
        let margin = PostGridListLayout.sideMargin
        #expect(abs((resting.first?.minX ?? 0) - margin) < 0.01, "the foot starts at the margin")
        #expect(abs((resting.last?.maxX ?? 0) - (393 - margin)) < 0.01, "the foot ends at the margin")
        for (left, right) in zip(resting, resting.dropFirst()) {
            #expect(abs(right.minX - left.maxX - DiscoverListLayout.gutter) < 0.01,
                    "a hole in the chunk's foot")
        }
    }

    /// A page landing is an INSERT: a delivery that extends the list must keep
    /// the collection view consistent with the model at every step (an
    /// inconsistent batch update throws, which is the failure this pins).
    @Test func pagesLandAsInserts() {
        let posts = corpus(90)
        let page = page(Array(posts[..<25]), complete: false)
        let view = collectionView(of: page)
        for (loaded, complete) in [(50, false), (75, false), (90, true)] {
            page.setCorpusComplete(complete)
            page.render(.content(Array(posts[..<loaded])))
            page.layoutIfNeeded()
            #expect(view.numberOfSections == page.segments.count)
            #expect((0..<view.numberOfSections).reduce(0) { $0 + view.numberOfItems(inSection: $1) }
                    == page.posts.count)
        }
        #expect(page.posts.count == posts.count, "the complete corpus is all shown")
    }

    /// The last page changing only COMPLETENESS still re-plans the tail: a
    /// chunk held back for more media is decided, and what it held appears.
    @Test func completenessAloneReleasesTheTail() {
        // Text-heavy, so the tail's chunk cannot fill from what is loaded.
        let posts = (0..<14).map { index in
            GalleryPost(
                id: PostID("t\(index)"), kind: index < 6 ? .photo : .text, isRepost: false,
                thumbnailURL: index < 6 ? URL(string: "https://example.com/\(index).jpg") : nil,
                caption: "t", publishedAtMS: 0
            )
        }
        let page = page(posts, complete: false)
        let held = page.posts.count
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        #expect(held < posts.count, "the undecided chunk held the tail back")
        #expect(page.posts.count == posts.count, "decided, and everything behind it shown")
    }

    // MARK: - "View all"

    @Test func viewAllAsksForTheGallery() {
        let page = page(corpus(60))
        var asked = 0
        page.onViewAllTapped = { asked += 1 }
        let view = collectionView(of: page)
        view.layoutIfNeeded()
        let footer = view.visibleSupplementaryViews(ofKind: DiscoverListLayout.viewAllElementKind)
            .compactMap { $0 as? DiscoverViewAllFooterView }.first
        #expect(footer != nil, "a chunk on screen wears its View all")
        footer?.sendTap()
        #expect(asked == 1)
    }

    /// "View all ›" sits right-aligned and close under its chunk (2026-09-29):
    /// the footer flush with the chunk's foot and as wide as the chunk, the
    /// chevron ending on the chunk's right edge, the title just under the
    /// tiles — and the control still the footer's full 44pt tall.
    @Test func viewAllSitsRightAlignedJustUnderItsChunk() throws {
        let page = page(corpus(60))
        let view = collectionView(of: page)
        view.layoutIfNeeded()
        let footer = try #require(
            view.visibleSupplementaryViews(ofKind: DiscoverListLayout.viewAllElementKind)
                .compactMap { $0 as? DiscoverViewAllFooterView }.first
        )
        footer.layoutIfNeeded()
        let section = try #require(
            view.indexPathsForVisibleSupplementaryElements(ofKind: DiscoverListLayout.viewAllElementKind)
                .first { view.supplementaryView(forElementKind: DiscoverListLayout.viewAllElementKind, at: $0) === footer }
        ).section
        let tiles = (0..<view.numberOfItems(inSection: section)).compactMap {
            view.layoutAttributesForItem(at: IndexPath(item: $0, section: section))?.frame
        }
        let chunk = try #require(tiles.dropFirst().reduce(tiles.first) { $0?.union($1) })

        #expect(abs(footer.frame.minY - chunk.maxY) < 0.5, "the footer starts at the chunk's foot: \(footer.frame) under \(chunk)")
        #expect(abs(footer.frame.minX - chunk.minX) < 0.5 && abs(footer.frame.maxX - chunk.maxX) < 0.5, "as wide as the chunk")
        let control = footer.debugControlFrame
        #expect(control.maxX == footer.bounds.maxX, "the chevron ends on the chunk's right edge")
        #expect(control.minX > footer.bounds.midX, "right-aligned, not centred: \(control)")
        #expect(control.height >= 44, "the hit target stays a control's")
        let title = try #require(footer.debugTitleFrame)
        #expect(title.minY <= DiscoverViewAllFooterView.titleTopInset + 2, "the title sits at the top: \(title)")
    }

    // MARK: - The hero's questions, per post

    @Test func heroQuestionsAreAnsweredPerPost() throws {
        let page = page(corpus(60))
        let view = collectionView(of: page)
        view.layoutIfNeeded()
        let cards = try #require(page.segments.first?.posts)
        let tiles = try #require(page.segments.first(where: { $0.chunk != nil })?.posts)
        let textCard = try #require(cards.first { $0.kind == .text })
        let mediaCard = try #require(cards.first { $0.kind != .text })
        let tile = try #require(tiles.first)

        // A text card has no media to land on; a tile is a rect whatever it is.
        #expect(page.canLandHero(on: textCard) == false)
        #expect(page.canLandHero(on: mediaCard))
        #expect(page.canLandHero(on: tile))
        // A landing on a card conceals its preview; on a tile it conceals
        // nothing — a hole in a chunk is a hole in the mosaic.
        #expect(page.landingConcealsMedia(for: mediaCard.id))
        #expect(page.landingConcealsMedia(for: tile.id) == false)
        // The card the flight wears matches what was tapped.
        #expect(page.heroAppearance(for: tile.id)?.style == .tile)
        #expect(page.heroAppearance(for: mediaCard.id)?.style == .listMedia)
        #expect(page.heroAppearance(for: textCard.id) == nil)
        // And the list never re-orders to meet a close.
        #expect(page.landsByAdoption == false)
        #expect(page.adoptPost(tile.id, intoSlotOf: mediaCard.id) == false)
    }

    /// ⚠️ The regression: a chunk's MEDIA tile, paged onto a text post and
    /// closed, landed through a window holding a whole post CARD — author,
    /// caption, actions — squeezed into the tile's rect. The close lands as
    /// the tile, at the tile's size; a card still lands as a card.
    @Test func aChunkTilesCloseLandsAsTheTileNotAPostCard() throws {
        let page = page(corpus(60))
        collectionView(of: page).layoutIfNeeded()
        let cards = try #require(page.segments.first?.posts)
        let tiles = try #require(page.segments.first(where: { $0.chunk != nil })?.posts)
        let tile = try #require(tiles.first)
        let card = try #require(cards.first { $0.kind != .text })

        let landing = try #require(page.makeDismissStandIn(for: tile.id))
        #expect(landing is PostGridTileStandInView, "a tile's close landed as \(type(of: landing))")
        let slot = try #require(page.rowFrame(for: tile.id, in: page))
        #expect(abs(landing.bounds.width - slot.width) < 0.5 && abs(landing.bounds.height - slot.height) < 0.5)
        #expect(!(page.makeDismissStandIn(for: card.id) is PostGridTileStandInView), "a card lost its card")
    }
}

/// The pushed mosaic: it opens its tiles through the shared flight, with the
/// tapped tile first in the feed it seeds.
@MainActor
struct DiscoverGalleryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func wallet() -> WalletStore {
        let suite = "discover-gallery-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WalletStore(defaults: defaults)
    }

    private static func gallery(
        wallet: WalletStore? = nil,
        openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)? = nil
    ) -> DiscoverGalleryViewController {
        DiscoverGalleryViewController(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            header: PushedScreenHeader(wallet: wallet, makeWalletSheet: nil, router: nil),
            openPost: openPost
        )
    }

    /// `[‹] ———— [points][search]`: no title, no tab bar, and the root's two
    /// trailing items in the root's order — search at the edge.
    @Test func theHeaderIsBackThenPointsAndSearch() {
        let gallery = Self.gallery(wallet: Self.wallet())
        gallery.loadViewIfNeeded()
        #expect(gallery.title == nil)
        #expect(gallery.navigationItem.title == nil)
        #expect(gallery.hidesBottomBarWhenPushed, "the tab bar leaves with the push, UIKit's way")
        #expect(gallery.navigationItem.rightBarButtonItems?.map(\.identifier) == [
            PushedScreenHeader.searchItemIdentifier, PushedScreenHeader.walletItemIdentifier
        ])
        #expect(gallery.navigationItem.rightBarButtonItems?.allSatisfy { !$0.sharesBackground } == true)
    }

    /// No wallet wired: search alone, rather than a balance that reads nothing.
    @Test func withoutAWalletOnlySearchIsOffered() {
        let gallery = Self.gallery()
        #expect(gallery.navigationItem.rightBarButtonItems?.map(\.identifier) == [
            PushedScreenHeader.searchItemIdentifier
        ])
    }

    @Test func aTileOpensThroughTheSharedFlight() {
        var opened: (origin: SnapFeedHeroOrigin, ids: [PostID])?
        let gallery = Self.gallery(openPost: { _, origin, ids in opened = (origin, ids) })
        let posts = (0..<30).map { index in
            GalleryPost(
                id: PostID("m\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                caption: "", publishedAtMS: 0
            )
        }
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        gallery.render(.content(posts))
        gallery.view.layoutIfNeeded()
        #expect(gallery.title == nil, "the pushed mosaic wears no title")
        #expect(gallery.debugOpenTile(at: 2))
        let shown = gallery.posts
        #expect(opened?.ids.first == shown[2].id, "the feed starts on the tapped tile")
        #expect(opened?.ids == Array(shown[2...].prefix(40)).map(\.id))
        #expect(opened?.origin.hasHero == true)
        #expect(opened?.origin.style == .tile)
    }

    /// Every tile carries its own window, so a tile opened by a flight and
    /// paged onto a text post closes back onto it — as the TILE: its picture,
    /// its corner, nothing aligned to a caption it does not have.
    @Test func aTileClosesFromAWordsPageThroughItsOwnWindow() throws {
        var opened: SnapFeedHeroOrigin?
        let gallery = Self.gallery(openPost: { _, origin, _ in opened = origin })
        let posts = (0..<30).map { index in
            GalleryPost(
                id: PostID("m\(index)"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                caption: "", publishedAtMS: 0
            )
        }
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        gallery.render(.content(posts))
        gallery.view.layoutIfNeeded()
        #expect(gallery.debugOpenTile(at: 2))
        let window = try #require(opened?.textReveal, "a tile opened with no way to close from words")
        #expect(window.alignsPageToSource == false)
        #expect(window.pageFit == .covering)
        #expect(window.cornerRadius == ChaoticSliceLayout.harmonisedCornerRadius)
        #expect(window.rowFrame(gallery.view) != nil)
        #expect(window.makeDismissStandIn(nil) is PostGridTileStandInView)
    }
}

private final class DiscoverStubProvider: ForYouProviding, @unchecked Sendable {
    private let posts: [GalleryPost]
    init(posts: [GalleryPost]) { self.posts = posts }
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: posts, nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
