import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's page in the flat style (#2243): its ground, its rows with no
/// card, the hairlines it decides from each row's neighbours, and the
/// opening it describes per post — each against the cards style.
@MainActor
struct FlatPostListPageTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// Every third post text, the rest photos — the feed's usual mix.
    private func corpus(_ count: Int, allText: Bool = false) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = allText || index % 3 == 2
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

    private func page(
        _ posts: [GalleryPost], style: ForYouGridPage.Style = .discover, listStyle: PostListStyle
    ) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style, listStyle: listStyle
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    // MARK: - The ground

    /// The page's ground per style: the grey page under cards, the white one
    /// under flat rows.
    @Test func thePageGroundPerStyle() {
        #expect(page([], listStyle: .cards).pageGround == PostListStyle.cards.pageGround)
        #expect(page([], listStyle: .flat).pageGround == PostListStyle.flat.pageGround)
    }

    /// Only the vertical lists draw flat rows: a grid's tiles and History's
    /// rows have no card to drop.
    @Test func onlyTheVerticalListsDrawFlatRows() {
        #expect(page([], style: .discover, listStyle: .flat).rowListStyle == .flat)
        #expect(page([], style: .list, listStyle: .flat).rowListStyle == .flat)
        #expect(page([], style: .grid, listStyle: .flat).rowListStyle == .cards)
        #expect(page([], style: .rows, listStyle: .flat).rowListStyle == .cards)
        #expect(page([], style: .list, listStyle: .cards).rowListStyle == .cards)
    }

    // MARK: - The rows

    /// A text row drawn by a flat page wears no card; by a cards page, today's.
    @Test func aTextRowWearsTheStylesDress() throws {
        let flat = page(corpus(3, allText: true), style: .list, listStyle: .flat)
        let flatRow = try #require(collectionView(of: flat).cellForItem(at: IndexPath(item: 0, section: 0))
            as? PostGridListRowCell)
        #expect(flatRow.listStyle == .flat)
        #expect(flatRow.debugCardDress.cornerRadius == 0)

        let cards = page(corpus(3, allText: true), style: .list, listStyle: .cards)
        let cardRow = try #require(collectionView(of: cards).cellForItem(at: IndexPath(item: 0, section: 0))
            as? PostGridListRowCell)
        #expect(cardRow.listStyle == .cards)
        #expect(cardRow.debugCardDress.cornerRadius == PostGridListRowCell.cardCornerRadius)
    }

    // MARK: - The hairlines

    /// A run of rows: an inset line between two, none over the first nor
    /// under the last.
    @Test func aRunOfRowsHasInsetLinesBetweenAndNoneAtTheEnds() {
        let page = page(corpus(4, allText: true), style: .list, listStyle: .flat)
        #expect(page.flatSeparators(at: IndexPath(item: 0, section: 0)) == FlatRowSeparators(top: .none, bottom: .inset))
        #expect(page.flatSeparators(at: IndexPath(item: 2, section: 0)) == FlatRowSeparators(top: .none, bottom: .inset))
        #expect(page.flatSeparators(at: IndexPath(item: 3, section: 0)) == .none, "a line under the last post")
    }

    /// Discover: the run's last row draws a FULL line over the chunk under
    /// it, and the row after a chunk a full line under it.
    @Test func aChunkIsFramedByFullLines() throws {
        let page = page(corpus(60), listStyle: .flat)
        let firstRun = try #require(page.segments.first)
        #expect(page.segments.dropFirst().first?.chunk != nil, "precondition: a chunk follows the first run")
        let lastOfRun = IndexPath(item: firstRun.posts.count - 1, section: 0)
        #expect(page.flatSeparators(at: lastOfRun).bottom == .full)
        let afterChunk = try #require(page.segments.indices.dropFirst(2).first {
            page.segments[$0].chunk == nil && !page.segments[$0].isPairs && !page.segments[$0].posts.isEmpty
        })
        if page.segments[afterChunk - 1].chunk != nil || page.segments[afterChunk - 1].isPairs {
            #expect(page.flatSeparators(at: IndexPath(item: 0, section: afterChunk)).top == .full)
        }
    }

    /// The cards style draws no hairline at all.
    @Test func theCardsStyleDrawsNoLine() {
        let page = page(corpus(4, allText: true), style: .list, listStyle: .cards)
        #expect(page.flatSeparators(at: IndexPath(item: 0, section: 0)) == .none)
    }

    // MARK: - The opening

    /// Per style and per item: a flat row of words opens with the native
    /// push; a picture keeps its flight; the cards style keeps the window.
    @Test func theOpeningPerStyleAndPerItem() throws {
        let posts = corpus(3)
        let flat = page(posts, style: .list, listStyle: .flat)
        let text = try #require(posts.first { $0.kind == .text })
        let photo = try #require(posts.first { $0.kind != .text })
        #expect(flat.opensWithNativePush(text.id))
        #expect(!flat.opensWithNativePush(photo.id))
        let cards = page(posts, style: .list, listStyle: .cards)
        #expect(!cards.opensWithNativePush(text.id))
    }

    /// The origin the page describes for every other host (a profile, a
    /// place, a post set) carries the answer to `presentSnapFeedHero`.
    @Test func theHeroOriginCarriesTheNativePush() throws {
        let posts = corpus(3)
        let text = try #require(posts.first { $0.kind == .text })
        let photo = try #require(posts.first { $0.kind != .text })
        let flat = page(posts, style: .list, listStyle: .flat)
        let host = UIView()
        let textOrigin = flat.heroOrigin(opening: text, stream: posts, in: host, textReveal: nil, continuation: nil)
        let photoOrigin = flat.heroOrigin(opening: photo, stream: posts, in: host, textReveal: nil, continuation: nil)
        #expect(textOrigin.opensWithNativePush)
        #expect(!photoOrigin.opensWithNativePush)
        flat.endPlaybackHandoff()
        let cards = page(posts, style: .list, listStyle: .cards)
        #expect(!cards.heroOrigin(opening: text, stream: posts, in: host, textReveal: nil, continuation: nil)
            .opensWithNativePush)
        cards.endPlaybackHandoff()
    }
}
