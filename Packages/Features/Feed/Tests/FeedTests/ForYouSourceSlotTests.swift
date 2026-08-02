import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A dismissal lands on the tile the viewer LEFT from, not on the tile the post
/// they ended on happens to occupy. Rather than scrolling the gallery under a
/// card that is about to land on it, the active post is moved into the
/// departure slot.
///
/// The swap is what makes that safe: every lookup on the page resolves a post
/// id to a cell through `firstIndex`, so the same id in two slots would let the
/// flight rect, the hero hide and the playback adoption each address a
/// different tile.
@MainActor
struct ForYouSourceSlotTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func posts(_ count: Int) -> [GalleryPost] {
        (0..<count).map {
            GalleryPost(
                id: PostID("p\($0)"), kind: .photo, isRepost: false, thumbnailURL: nil,
                aspectRatio: 1, caption: "", publishedAtMS: 0
            )
        }
    }

    private func page(_ count: Int = 30) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(posts(count)))
        page.layoutIfNeeded()
        return page
    }

    private func frames(of page: ForYouGridPage) -> [CGRect] {
        let scroll = page.subviews.compactMap { $0 as? UICollectionView }.first!
        return (0..<page.posts.count).compactMap {
            scroll.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
    }

    @Test func theActivePostMovesIntoTheDepartureSlot() {
        let page = page()
        let departure = page.posts[3].id
        let active = page.posts[17].id

        #expect(page.adoptPost(active, intoSlotOf: departure))
        #expect(page.posts[3].id == active, "the departure slot does not hold the active post")
        #expect(page.posts[17].id == departure, "the two posts did not swap")
    }

    /// The point of the swap. If both slots held the active post, `firstIndex`
    /// would answer with whichever came first and the flight could aim at a
    /// different tile than the one the hide covered.
    @Test func idsStayUnique() {
        let page = page()
        let before = Set(page.posts.map(\.id))
        page.adoptPost(page.posts[17].id, intoSlotOf: page.posts[3].id)
        #expect(Set(page.posts.map(\.id)) == before, "the swap changed which posts exist")
        #expect(page.posts.count == Set(page.posts.map(\.id)).count, "a post id was duplicated")
    }

    /// The landing rect must be the one the flight launched from. The chaotic
    /// layout maps INDEX to frame, so exchanging two indices' contents cannot
    /// move a tile — this pins that, since it is the whole reason the grid no
    /// longer has to scroll.
    @Test func noTileMovesWhenTheSlotIsReused() {
        let page = page()
        let before = frames(of: page)
        page.adoptPost(page.posts[17].id, intoSlotOf: page.posts[3].id)
        page.layoutIfNeeded()
        #expect(frames(of: page) == before, "swapping content moved a tile")
    }

    /// The viewer never left the tile they tapped: nothing to move.
    @Test func adoptingIntoItsOwnSlotDoesNothing() {
        let page = page()
        let id = page.posts[3].id
        #expect(!page.adoptPost(id, intoSlotOf: id))
        #expect(page.posts[3].id == id)
    }

    /// The feed settled on something this grid no longer holds. The caller
    /// falls back to the departure tile, so this must report that nothing moved
    /// rather than silently rearranging.
    @Test func anAbsentPostIsRefused() {
        let page = page()
        let departure = page.posts[3].id
        #expect(!page.adoptPost(PostID("nowhere"), intoSlotOf: departure))
        #expect(!page.adoptPost(departure, intoSlotOf: PostID("nowhere")))
        #expect(page.posts[3].id == departure)
    }

    /// A skeleton page has slots but no posts behind them.
    @Test func aLoadingPageIsRefused() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.loading)
        page.layoutIfNeeded()
        #expect(!page.adoptPost(PostID("p1"), intoSlotOf: PostID("p0")))
    }
}

/// The card is held over the landing tile until it has something to show. What
/// counts as "something" is the whole subject: the gate used to answer only
/// "is playback running", so a tile with neither a cover nor a rendered frame
/// could report itself ready and the card would let go over an empty square.
///
/// Driven through the page rather than the simulator because the failing case
/// needs a landing post whose cover is not cached — reproducible on demand here,
/// and a matter of luck with injected input.
@MainActor
struct ForYouLandingGateTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func page(_ posts: [GalleryPost]) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(posts))
        page.layoutIfNeeded()
        return page
    }

    private func photo(_ id: String, cover: Bool) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: cover ? URL(string: "mock://cover/\(id)") : nil,
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )
    }

    /// The regression. A still tile that is *supposed* to show a cover, and has
    /// not loaded one, is not ready — the fetcher here never returns, so the
    /// cover cannot arrive and the gate must keep saying no.
    @Test func aStillTileWithoutItsCoverIsNotReady() {
        let page = page((0..<12).map { photo("p\($0)", cover: true) })
        #expect(!page.isLandingPlaybackReady(for: PostID("p3")),
                "the card would have let go over a tile with no cover")
    }

    /// A post that carries no thumbnail has nothing to wait for — waiting would
    /// hold the card for the ceiling and then reveal the same empty tile.
    @Test func aTileWithNothingToLoadIsReady() {
        let page = page((0..<12).map { photo("p\($0)", cover: false) })
        #expect(page.isLandingPlaybackReady(for: PostID("p3")))
    }

    /// A post the grid no longer holds cannot be waited on.
    @Test func anAbsentPostIsReady() {
        let page = page((0..<12).map { photo("p\($0)", cover: true) })
        #expect(page.isLandingPlaybackReady(for: PostID("gone")))
    }

    /// Nothing realized off-screen: no tile, no gap, no wait.
    @Test func anUnrealizedTileIsReady() {
        let page = page((0..<60).map { photo("p\($0)", cover: true) })
        #expect(page.isLandingPlaybackReady(for: PostID("p58")))
    }
}
