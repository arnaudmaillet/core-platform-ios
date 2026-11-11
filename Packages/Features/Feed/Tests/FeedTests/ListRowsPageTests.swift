import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's page drawing the post lists' rows (#2243; the only style since
/// #2290): its rows with no card, the hairlines it decides from each row's
/// neighbours, and the opening it describes per post.
@MainActor
struct ListRowsPageTests {
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

    private func page(_ posts: [GalleryPost], style: ForYouGridPage.Style = .discover) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    // MARK: - The rows

    /// Only the vertical lists draw rows: a grid's tiles and History's rows
    /// are other cells.
    @Test func onlyTheVerticalListsDrawRows() {
        #expect(page([], style: .discover).drawsRows)
        #expect(page([], style: .list).drawsRows)
        #expect(!page([], style: .grid).drawsRows)
        #expect(!page([], style: .rows).drawsRows)
    }

    /// A text row drawn by the page wears the row's dress: no card.
    @Test func aTextRowWearsNoCard() throws {
        let page = page(corpus(3, allText: true), style: .list)
        let row = try #require(collectionView(of: page).cellForItem(at: IndexPath(item: 0, section: 0))
            as? PostGridListRowCell)
        #expect(row.dress == .row)
        #expect(row.debugDress.cornerRadius == 0)
    }

    // MARK: - The hairlines

    /// A run of rows: one full-width line between two (#2289), none over the
    /// first nor under the last.
    @Test func aRunOfRowsHasFullLinesBetweenAndNoneAtTheEnds() {
        let page = page(corpus(4, allText: true), style: .list)
        #expect(page.rowSeparators(at: IndexPath(item: 0, section: 0)) == RowSeparators(top: .none, bottom: .full))
        #expect(page.rowSeparators(at: IndexPath(item: 1, section: 0)) == RowSeparators(top: .none, bottom: .full))
        #expect(page.rowSeparators(at: IndexPath(item: 2, section: 0)) == RowSeparators(top: .none, bottom: .full))
        #expect(page.rowSeparators(at: IndexPath(item: 3, section: 0)) == .none, "a line under the last post")
    }

    /// Discover: the run's last row draws a FULL line over the chunk under
    /// it, and the row after a chunk a full line under it.
    @Test func aChunkIsFramedByFullLines() throws {
        let page = page(corpus(60))
        let firstRun = try #require(page.segments.first)
        #expect(page.segments.dropFirst().first?.chunk != nil, "precondition: a chunk follows the first run")
        let lastOfRun = IndexPath(item: firstRun.posts.count - 1, section: 0)
        #expect(page.rowSeparators(at: lastOfRun).bottom == .full)
        let afterChunk = try #require(page.segments.indices.dropFirst(2).first {
            page.segments[$0].chunk == nil && !page.segments[$0].isPairs && !page.segments[$0].posts.isEmpty
        })
        if page.segments[afterChunk - 1].chunk != nil || page.segments[afterChunk - 1].isPairs {
            #expect(page.rowSeparators(at: IndexPath(item: 0, section: afterChunk)).top == .full)
        }
    }

    // MARK: - The opening

    /// ⚠️ A LIST ROW OF WORDS NEVER OPENS THROUGH THE WINDOW (#2290): it opens
    /// with the native push; a picture keeps its flight.
    @Test func aRowOfWordsPushesNatively() throws {
        let posts = corpus(3)
        let page = page(posts, style: .list)
        let text = try #require(posts.first { $0.kind == .text })
        let photo = try #require(posts.first { $0.kind != .text })
        #expect(page.opensWithNativePush(text.id))
        #expect(!page.opensWithNativePush(photo.id))
    }

    /// The origin the page describes for every other host (a profile, a
    /// place, a post set) carries the answer to `presentSnapFeedHero`.
    @Test func theHeroOriginCarriesTheNativePush() throws {
        let posts = corpus(3)
        let text = try #require(posts.first { $0.kind == .text })
        let photo = try #require(posts.first { $0.kind != .text })
        let page = page(posts, style: .list)
        let host = UIView()
        let textOrigin = page.heroOrigin(opening: text, stream: posts, in: host, textReveal: nil, continuation: nil)
        let photoOrigin = page.heroOrigin(opening: photo, stream: posts, in: host, textReveal: nil, continuation: nil)
        #expect(textOrigin.opensWithNativePush)
        #expect(!photoOrigin.opensWithNativePush)
        page.endPlaybackHandoff()
    }

    // MARK: - The header's hairline (#2289)

    /// The place page's header closes with the posts' hairline, as the
    /// profile's does: the list's first row draws none above it.
    @Test func thePlacesHeaderClosesWithTheHairline() {
        let place = PlaceProfileViewController(
            postIDs: [],
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil,
            loadPosts: { [] },
            openPost: { _, _, _ in }
        )
        #expect(place.debugHeader.drawsFootHairline)
        let rows = page(corpus(3, allText: true), style: .list)
        #expect(rows.rowSeparators(at: IndexPath(item: 0, section: 0)).top == .none, "a second line under the header")
    }
}
