import CoreModels
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

    // MARK: - The tabs

    /// Discover on the LEFT again, and the screen still opens on it.
    @Test func theTabsReadDiscoverThenFollowing() {
        #expect(ForYouPagerView.pageOrder == [.media, .activity])
        #expect(ForYouViewModel.tabs == ForYouPagerView.pageOrder)
        #expect(ForYouViewModel.defaultFormat == .media)
        #expect(ForYouPagerView.style(for: .media) == .discover)
        #expect(ForYouPagerView.style(for: .activity) == .list)
    }

    /// Discover is handed the WHOLE corpus — every kind — while the media-only
    /// state stays what the pushed gallery shows.
    @Test func discoverIsHandedEveryKindOfPost() {
        let all = corpus(9)
        let snapshot = ForYouViewModel.Snapshot(
            activity: .content(all),
            media: .content(all.filter { $0.kind != .text }),
            short: .content(all.filter { $0.kind == .text })
        )
        #expect(ForYouPagerView.pageState(for: .media, in: snapshot) == .content(all))
        #expect(ForYouPagerView.pageState(for: .activity, in: snapshot) == .content(all))
        #expect(snapshot.discover == snapshot.activity)
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
}

/// The pushed mosaic: it opens its tiles through the shared flight, with the
/// tapped tile first in the feed it seeds.
@MainActor
struct DiscoverGalleryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    @Test func aTileOpensThroughTheSharedFlight() {
        var opened: (origin: SnapFeedHeroOrigin, ids: [PostID])?
        let gallery = DiscoverGalleryViewController(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            openPost: { _, origin, ids in opened = (origin, ids) }
        )
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
        #expect(gallery.title == DiscoverGalleryViewController.title)
        #expect(gallery.debugOpenTile(at: 2))
        let shown = gallery.posts
        #expect(opened?.ids.first == shown[2].id, "the feed starts on the tapped tile")
        #expect(opened?.ids == Array(shown[2...].prefix(40)).map(\.id))
        #expect(opened?.origin.hasHero == true)
        #expect(opened?.origin.style == .tile)
    }
}
