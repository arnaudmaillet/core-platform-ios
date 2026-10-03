import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// On For You's chunks and the pushed Discover gallery, a tile large enough
/// wears its author and the start of its caption over the picture — the
/// Following card's foot — and flies it: the flight's card carries a copy as
/// its resting furniture (faded as it grows, #319's arrangement) and a close's
/// stand-in lands wearing it. Began as `-gallery-tile-info`; validated on 3
/// October 2026, so For You's surfaces always ask, and the flag is gone. A
/// grid that does not ask (a place's, a post set's) keeps every tile exactly
/// what it was.
@MainActor
struct GalleryTileInfoTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: SilentFetcher()) }

    /// The feed's mix: text posts, vertical media (pairs), other media
    /// (chunks and cards).
    private func corpus(_ count: Int, mediaOnly: Bool = false) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = !mediaOnly && index % 3 == 2
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: isText ? .text : .photo,
                isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: index % 2 == 0 ? 9.0 / 16.0 : 1.5,
                caption: "post \(index) — a caption long enough to need more than one line on a tile",
                publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 1_200, commentCount: 34
            )
        }
    }

    private func page(style: ForYouGridPage.Style, showsInfo: Bool) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: style)
        page.showsTileInfo = showsInfo
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 6000)
        page.setCorpusComplete(true)
        page.render(.content(corpus(60, mediaOnly: style == .grid)))
        page.layoutIfNeeded()
        collectionView(of: page).layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    /// Every realized mosaic tile on `page`.
    private func tiles(on page: ForYouGridPage) -> [(post: GalleryPost, cell: PostGridTileCell)] {
        page.posts.compactMap { post in
            (page.debugCell(for: post.id) as? PostGridTileCell).map { (post, $0) }
        }
    }

    // MARK: - On by default

    /// No flag: For You's Discover list and its pushed gallery both ask for
    /// the words, out of the box.
    @Test func forYousSurfacesWearTheWordsByDefault() {
        let screen = ForYouViewController(
            viewModel: ForYouViewModel(repository: EmptyProvider()),
            imagePipeline: pipeline(),
            makeSnapFeed: { _ in UIViewController() },
            prewarm: { _ in }
        )
        #expect(screen.debugShowsTileInfo)
        let gallery = DiscoverGalleryViewController(
            imagePipeline: pipeline(), videoPlayback: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: nil
        )
        #expect(gallery.debugShowsTileInfo)
    }

    /// A grid that does not ask — a place's, a post set's — keeps bare
    /// tiles: no words, every tile its corner count, no flight or close
    /// carrying any.
    @Test func aGridThatDoesNotAskKeepsBareTiles() throws {
        let page = page(style: .grid, showsInfo: false)
        let tiles = tiles(on: page)
        #expect(tiles.isEmpty == false, "precondition: realized tiles")
        for (post, cell) in tiles {
            #expect(cell.debugInfoOverlay == nil)
            #expect(cell.debugShowsCornerLikes)
            #expect(page.restingOverlay(for: post.id) == nil)
            let standIn = try #require(page.makeDismissStandIn(for: post.id) as? PostGridTileStandInView)
            #expect((standIn.subviews.first as? PostGridTileCell)?.debugInfoOverlay == nil)
        }
    }

    /// Each tile wears the variant ITS size earns — the rule, cell by cell —
    /// and the mosaic genuinely holds both kinds (some tiles carry words, some
    /// stay pictures).
    @Test func eachTileWearsWhatItsSizeEarns() {
        for style in [ForYouGridPage.Style.discover, .grid] {
            let page = page(style: style, showsInfo: true)
            let tiles = tiles(on: page)
            #expect(tiles.isEmpty == false)
            for (_, cell) in tiles {
                let expected = PostTileInfo.variant(for: cell.bounds.size)
                #expect(cell.infoVariant == expected, "\(cell.bounds.size)")
                #expect((cell.debugInfoOverlay != nil) == (expected != .none))
                #expect(cell.debugShowsCornerLikes == (expected == .none), "one heart per tile")
            }
            if style == .grid {
                #expect(tiles.contains { $0.cell.infoVariant != .none }, "no gallery tile is large enough")
                #expect(tiles.contains { $0.cell.infoVariant == .none }, "every gallery tile wears words")
            }
        }
    }

    /// The list's cards and the paired cards are not tiles: they keep their
    /// own furniture.
    @Test func pairedCardsAndCardsAreUntouched() throws {
        let page = page(style: .discover, showsInfo: true)
        let paired = try #require(page.segments.first(where: \.isPairs)?.posts.first)
        let overlay = try #require(page.restingOverlay(for: paired.id) as? ForYouCardCaptionOverlay)
        #expect(overlay.debugCaptionLineLimit == ForYouCardCaptionOverlay.mediaCaptionLines)
        #expect(overlay.debugUsesLayerShadows, "the Following card's own overlay, as it was")
        let card = try #require(page.segments.first(where: { $0.chunk == nil && !$0.isPairs })?.posts.first)
        #expect(page.restingOverlay(for: card.id) == nil)
    }

    // MARK: - The hero

    /// The flight's resting furniture is the tile's own words, at the tile's
    /// size and in the same places; a tile too small for words flies none and
    /// keeps its corner count.
    @Test func theFlightCarriesTheTilesOwnWords() throws {
        let page = page(style: .grid, showsInfo: true)
        let tiles = tiles(on: page)
        let worded = try #require(tiles.first { $0.cell.infoVariant != .none })
        let own = try #require(worded.cell.debugInfoOverlay)
        let copy = try #require(page.restingOverlay(for: worded.post.id) as? PostCardCaptionOverlay)
        #expect(copy.debugCaptionFrame == own.debugCaptionFrame)
        #expect(copy.debugAuthorFrame == own.debugAuthorFrame)
        #expect(copy.debugLikeFrame == own.debugLikeFrame)
        #expect(copy.debugCaptionLineLimit == own.debugCaptionLineLimit)

        if let bare = tiles.first(where: { $0.cell.infoVariant == .none }) {
            #expect(page.restingOverlay(for: bare.post.id) == nil)
        }
    }

    /// For You's own flight (`ForYouGridZoomSource`): the card wears the
    /// words in its RESTING CHROME — the channel the flight fades as the card
    /// grows into the page and back — and drops its corner count, so it flies
    /// one heart, the author line's, as the tile wears it.
    @Test func forYousFlightCardWearsTheWordsInItsFadingChrome() throws {
        let page = page(style: .discover, showsInfo: true)
        let worded = try #require(tiles(on: page).first { $0.cell.infoVariant != .none },
                                  "precondition: a chunk tile large enough for words")
        let source = ForYouGridZoomSource(
            page: page, tappedID: worded.post.id, activePostID: { worded.post.id }, depthView: nil
        )
        let card = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)
        let chrome = try #require(card.zoomRestingChrome)
        #expect(chrome.subviews.contains { $0 is PostCardCaptionOverlay }, "the words are not in the fading chrome")
        #expect(card.debugShowsCornerCount == false, "two hearts in the flight")

        // A tile with no words flies as it always did: its count, no overlay.
        if let bare = tiles(on: page).first(where: { $0.cell.infoVariant == .none }) {
            let plain = ForYouGridZoomSource(
                page: page, tappedID: bare.post.id, activePostID: { bare.post.id }, depthView: nil
            )
            let plainCard = try #require(plain.makeZoomFlightCard() as? PostGridFlightCard)
            #expect(plainCard.debugShowsCornerCount)
            #expect(plainCard.zoomRestingChrome?.subviews.contains { $0 is PostCardCaptionOverlay } == false)
        }
    }

    /// An overlay with no heart of its own leaves the card's count alone.
    @Test func onlyAnOverlayWithAHeartReplacesTheCount() {
        let post = corpus(1)[0]
        let card = PostGridFlightCard(post: post, cover: nil, style: .tile)
        #expect(card.debugShowsCornerCount)
        card.installRestingOverlay(PostCardCaptionOverlay(post: post, placement: .onMedia))
        #expect(card.debugShowsCornerCount)
        let withHeart = PostGridFlightCard(post: post, cover: nil, style: .tile)
        withHeart.installRestingOverlay(PostCardCaptionOverlay(post: post, placement: .onMedia, viewerStake: 0))
        #expect(withHeart.debugShowsCornerCount == false)
    }

    /// The pushed gallery's flight (the shared `presentSnapFeedHero`): the
    /// origin hands the tile's words to the card as its resting overlay, and
    /// the card built from it wears them in the fading chrome.
    @Test func theGallerysFlightCarriesTheWords() throws {
        var opened: SnapFeedHeroOrigin?
        let gallery = DiscoverGalleryViewController(
            imagePipeline: pipeline(), videoPlayback: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: { _, origin, _ in opened = origin }
        )
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        gallery.render(.content(corpus(30, mediaOnly: true)))
        gallery.view.layoutIfNeeded()

        // The first tile large enough for words.
        var index: Int?
        for candidate in gallery.posts.indices {
            guard let size = gallery.debugTileSize(at: candidate) else { continue }
            if PostTileInfo.variant(for: size) != .none { index = candidate; break }
        }
        let tapped = try #require(index, "no gallery tile on screen is large enough")
        #expect(gallery.debugOpenTile(at: tapped))
        let origin = try #require(opened)
        let overlay = try #require(origin.restingOverlay?() as? PostCardCaptionOverlay)
        #expect(overlay.likeReadout != nil, "the tile's heart rides with its words")

        let card = try #require(ExternalHeroZoomSource(origin: origin).makeZoomFlightCard() as? PostGridFlightCard)
        #expect(card.zoomRestingChrome?.subviews.contains { $0 is PostCardCaptionOverlay } == true)
        #expect(card.debugShowsCornerCount == false)
    }

    /// The close's stand-in — what a window lands as when the feed paged
    /// onto words — wears the slot's words, at the slot's size: the same
    /// frames as the tile it hands over to.
    @Test func theCloseStandInMatchesTheTile() throws {
        let page = page(style: .discover, showsInfo: true)
        let worded = try #require(tiles(on: page).first { $0.cell.infoVariant != .none })
        let own = try #require(worded.cell.debugInfoOverlay)
        let standIn = try #require(page.makeDismissStandIn(for: worded.post.id) as? PostGridTileStandInView)
        let tile = try #require(standIn.subviews.first as? PostGridTileCell)
        let overlay = try #require(tile.debugInfoOverlay)
        #expect(tile.infoVariant == worded.cell.infoVariant)
        #expect(overlay.debugCaptionFrame == own.debugCaptionFrame)
        #expect(overlay.debugAuthorFrame == own.debugAuthorFrame)
        #expect(overlay.debugLikeFrame == own.debugLikeFrame)
    }
}

/// Pages nothing — the default needs the screen, not its content.
private final class EmptyProvider: ForYouProviding, @unchecked Sendable {
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
}
