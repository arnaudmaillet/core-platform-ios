import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// The profile's Posts page laid out like For You (#631): every post as a
/// card, chunks of the media mosaic between them, vertical media in pairs, and
/// "View all" under each chunk.
@MainActor
struct ProfileDiscoverListTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func post(_ index: Int, _ kind: GalleryPost.Kind, aspect: Double = 1) -> GalleryPost {
        GalleryPost(
            id: PostID("p\(index)"),
            kind: kind,
            isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(index).jpg"),
            aspectRatio: aspect,
            caption: "Post \(index)",
            publishedAtMS: Int64(10_000 - index)
        )
    }

    /// Every third post is text, the rest square photos — the mock's own mix.
    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { post($0, $0 % 3 == 2 ? .text : .photo) }
    }

    private func page() -> ProfileGalleryGridView {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            style: .discover,
            tab: .format(.activity)
        )
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        return page
    }

    private func show(_ posts: [GalleryPost], complete: Bool, on page: ProfileGalleryGridView) {
        page.setCorpusComplete(complete)
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
    }

    /// Text posts are cards, media fill the chunks, and every post is placed
    /// exactly once — nothing shown both as a card and as a tile.
    @Test func textPostsAreCardsAndMediaFillTheChunks() {
        let page = page()
        let posts = corpus(30)
        show(posts, complete: true, on: page)
        let segments = page.debugSegments

        let placed = segments.flatMap(\.posts).map(\.id)
        #expect(Set(placed) == Set(posts.map(\.id)))
        #expect(placed.count == posts.count, "a post was placed twice")
        #expect(segments.contains { $0.chunk != nil }, "no chunk of the mosaic between the cards")
        for segment in segments where segment.chunk != nil {
            #expect(segment.posts.allSatisfy { $0.kind != .text }, "a text post became a tile")
        }
        #expect(page.collectionView.numberOfSections == segments.count, "one section per stretch")
    }

    /// The tail chunk waits for the last page: with more to come, the posts
    /// after an undecided chunk are held back; once the corpus is complete,
    /// every post is shown and none is a blank tile.
    @Test func theTailSettlesOnceTheCorpusIsComplete() {
        let page = page()
        let posts = corpus(14)
        show(posts, complete: false, on: page)
        let held = page.debugSegments.flatMap(\.posts).count
        show(posts, complete: true, on: page)
        let shown = page.debugSegments.flatMap(\.posts).count

        #expect(held <= posts.count)
        #expect(shown == posts.count, "the complete corpus left posts out")
    }

    /// ⚠️ A PAGE LANDING INSERTS, IT DOES NOT RELOAD: the cards on screen and
    /// their playback stay put while the next stretches arrive below them.
    @Test func aPageLandingIsAnInsert() {
        let page = page()
        show(corpus(18), complete: false, on: page)
        let reloads = page.debugReloadCount

        show(corpus(36), complete: false, on: page)

        #expect(page.debugReloadCount == reloads, "the landing reloaded the list")
        #expect(page.debugSegments.flatMap(\.posts).count > 18)
    }

    /// "View all" under a chunk opens the profile's media gallery.
    @Test func viewAllUnderAChunkOpensTheGallery() throws {
        let page = page()
        show(corpus(30), complete: true, on: page)
        var opened = 0
        page.onViewAllTapped = { opened += 1 }
        let section = try #require(page.debugSegments.firstIndex { $0.chunk != nil })
        page.collectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
        page.collectionView.layoutIfNeeded()

        let footer = try #require(
            page.collectionView.visibleSupplementaryViews(ofKind: DiscoverListLayout.viewAllElementKind)
                .compactMap { $0 as? DiscoverViewAllFooterView }.first
        )
        footer.sendTap()
        #expect(opened == 1)
    }

    /// A paired half-width card is For You's Following card, so it flies as
    /// the list's media (`.listMedia`), not as a mosaic tile — while a chunk's
    /// tile flies as a tile.
    @Test func aPairFliesAsListMediaAndAChunkTileAsATile() throws {
        let page = page()
        // Two tall photos open the list: a run meeting a vertical post pairs it.
        let posts = [post(0, .photo, aspect: 0.5625), post(1, .photo, aspect: 0.5625)] + corpus(30).dropFirst(2)
        show(Array(posts), complete: true, on: page)
        let segments = page.debugSegments

        let pair = try #require(segments.first { $0.isPairs }?.posts.first)
        let pairPath = try #require(page.debugIndexPath(for: pair.id))
        page.collectionView.scrollToItem(at: pairPath, at: .top, animated: false)
        page.collectionView.layoutIfNeeded()
        #expect(page.heroGeometry(for: pair.id)?.isTile == false)

        let tile = try #require(segments.first { $0.chunk != nil }?.posts.first)
        let tilePath = try #require(page.debugIndexPath(for: tile.id))
        page.collectionView.scrollToItem(at: tilePath, at: .top, animated: false)
        page.collectionView.layoutIfNeeded()
        #expect(page.heroGeometry(for: tile.id)?.isTile == true)
    }
}
