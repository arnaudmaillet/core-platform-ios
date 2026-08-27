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

    /// ⚠️ AND A LIST ADOPTS TOO, which it could not until now.
    ///
    /// This was gated to the mosaic on the reasoning that a chaotic layout maps
    /// index to frame, so a swap moves nothing. A LIST's rows self-size, so the
    /// adopted post's height is its own — and the gate meant that on the one
    /// surface where a viewer reads a post, pages to the next and closes it,
    /// the dismissal landed on the card they LEFT rather than the one they
    /// ended on.
    ///
    /// What the return depends on is unmoved: rows ABOVE the slot are
    /// untouched, so the slot's origin is exactly where it was.
    @Test func aListAdoptsIntoTheDepartureSlotToo() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(posts(30)))
        page.layoutIfNeeded()
        let departure = page.posts[3].id
        let active = page.posts[17].id
        let originBefore = frames(of: page)[3].origin

        #expect(page.adoptPost(active, intoSlotOf: departure))

        #expect(page.posts[3].id == active)
        #expect(page.posts[17].id == departure)
        // The slot did not move, which is what makes flying home to it honest.
        let originAfter = frames(of: page)[3].origin
        #expect(abs(originAfter.y - originBefore.y) < 0.5)
        #expect(abs(originAfter.x - originBefore.x) < 0.5)
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

/// Repeated open → swipe → dismiss rounds. Each one swaps a post into the
/// departure slot, hides that tile for the flight, and unhides it on landing.
/// Nothing in that cycle may accumulate: not a duplicated id, not a lost post,
/// and above all not a tile left hidden.
@MainActor
struct ForYouRepeatedRoundTripTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func page(_ count: Int) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content((0..<count).map {
            GalleryPost(
                id: PostID("p\($0)"), kind: .photo, isRepost: false, thumbnailURL: nil,
                aspectRatio: 1, caption: "", publishedAtMS: 0
            )
        }))
        page.layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    /// Every realized tile must be visible once no flight is in the air.
    private func hiddenTiles(of page: ForYouGridPage) -> [Int] {
        let view = collectionView(of: page)
        return (0..<page.posts.count).filter {
            view.cellForItem(at: IndexPath(item: $0, section: 0))?.isHidden == true
        }
    }

    /// The headline: 25 rounds, each landing on a different post than it left
    /// from, and the grid must be exactly as complete at the end as at the
    /// start.
    @Test func twentyFiveRoundTripsLeaveTheGridIntact() {
        let page = page(40)
        let original = Set(page.posts.map(\.id))

        for round in 0..<25 {
            // Tap a tile near the top, the way a viewer would.
            let departure = page.posts[round % 6].id
            // Swipe forward a few posts, landing somewhere further down.
            let active = page.posts[(round % 6) + 3 + (round % 9)].id

            page.adoptPost(active, intoSlotOf: departure)
            let anchor = page.posts.contains { $0.id == active } ? active : departure
            page.setHeroHidden(true, for: anchor)
            page.layoutIfNeeded()
            page.setHeroHidden(false, for: anchor)
            page.layoutIfNeeded()

            #expect(page.posts.count == 40, "round \(round): the grid lost or gained a slot")
            #expect(Set(page.posts.map(\.id)) == original, "round \(round): the post set changed")
            #expect(page.posts.count == Set(page.posts.map(\.id)).count,
                    "round \(round): a post id was duplicated")
            #expect(hiddenTiles(of: page).isEmpty,
                    "round \(round): tiles left hidden at \(hiddenTiles(of: page))")
        }
    }

    /// The same cycle where the viewer never swipes — departure and active are
    /// the same post, so `adoptPost` refuses and the anchor falls back. The
    /// hide/unhide still has to balance.
    @Test func roundTripsWithoutSwipingLeaveNothingHidden() {
        let page = page(30)
        for round in 0..<25 {
            let departure = page.posts[round % 8].id
            page.adoptPost(departure, intoSlotOf: departure)
            page.setHeroHidden(true, for: departure)
            page.layoutIfNeeded()
            page.setHeroHidden(false, for: departure)
            page.layoutIfNeeded()
            #expect(hiddenTiles(of: page).isEmpty, "round \(round): a tile stayed hidden")
        }
    }

    /// A dismissal that lands on a post the grid no longer holds: the source
    /// falls back to the departure tile, and the hide it set must still be
    /// lifted from the tile it was actually applied to.
    @Test func aFallbackLandingStillUnhidesItsTile() {
        let page = page(20)
        for round in 0..<25 {
            let departure = page.posts[round % 5].id
            #expect(!page.adoptPost(PostID("absent"), intoSlotOf: departure))
            page.setHeroHidden(true, for: departure)
            page.layoutIfNeeded()
            page.setHeroHidden(false, for: departure)
            page.layoutIfNeeded()
            #expect(hiddenTiles(of: page).isEmpty, "round \(round): a tile stayed hidden")
        }
    }
}

/// Recycling is the trigger the balanced round-trip tests miss: they keep every
/// cell realized, so the hide is always lifted from the same instance it was
/// applied to. A hero hide lives on the CELL, and a cell recycled while hidden
/// carries the invisibility to whatever post it is bound to next.
@MainActor
struct ForYouHiddenCellRecyclingTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// Small viewport, many posts — so most cells are unrealized and the pool
    /// actually recycles when the grid scrolls.
    private func page(_ count: Int = 120) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .grid
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        page.render(.content((0..<count).map {
            GalleryPost(
                id: PostID("p\($0)"), kind: .photo, isRepost: false, thumbnailURL: nil,
                aspectRatio: 1, caption: "", publishedAtMS: 0
            )
        }))
        page.layoutIfNeeded()
        return page
    }

    private func scroll(_ page: ForYouGridPage, to y: CGFloat) {
        let view = page.subviews.compactMap { $0 as? UICollectionView }.first!
        view.contentOffset = CGPoint(x: 0, y: y)
        page.layoutIfNeeded()
        view.layoutIfNeeded()
    }

    private func invisibleTiles(_ page: ForYouGridPage) -> [Int] {
        let view = page.subviews.compactMap { $0 as? UICollectionView }.first!
        return view.indexPathsForVisibleItems.sorted().compactMap { path in
            guard let cell = view.cellForItem(at: path) else { return nil }
            return (cell.isHidden || cell.alpha == 0) ? path.item : nil
        }
    }

    /// Hide a tile for a flight, scroll far enough that its cell is recycled,
    /// then come back. Nothing on screen may be invisible.
    @Test func aCellRecycledWhileHiddenComesBackVisible() {
        let page = page()
        let hidden = page.posts[1].id
        page.setHeroHidden(true, for: hidden)
        page.layoutIfNeeded()

        // Far away, so the hidden cell is returned to the pool and re-issued.
        scroll(page, to: 6000)
        #expect(invisibleTiles(page).isEmpty,
                "recycled cells are invisible at \(invisibleTiles(page))")

        // And back, after the flight has ended.
        page.setHeroHidden(false, for: hidden)
        scroll(page, to: 0)
        #expect(invisibleTiles(page).isEmpty,
                "tiles still invisible after the flight at \(invisibleTiles(page))")
    }

    /// Ten rounds of hide → scroll away → scroll back → unhide, which is the
    /// shape of repeated open/dismiss with a scrolling gallery in between.
    @Test func tenRecyclingRoundsLeaveNothingInvisible() {
        let page = page()
        for round in 0..<10 {
            let hidden = page.posts[round * 2].id
            page.setHeroHidden(true, for: hidden)
            page.layoutIfNeeded()
            scroll(page, to: CGFloat(2000 + round * 400))
            scroll(page, to: 0)
            page.setHeroHidden(false, for: hidden)
            page.layoutIfNeeded()
            #expect(invisibleTiles(page).isEmpty,
                    "round \(round): invisible tiles at \(invisibleTiles(page))")
        }
    }
}
