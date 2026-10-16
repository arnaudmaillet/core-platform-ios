import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

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

/// Repeated open → swipe → dismiss rounds. Each one hides the tapped tile for
/// the flight and unhides it on landing — the close always comes home to the
/// tile that was tapped (#1283). Nothing in that cycle may accumulate: not a
/// lost post, not a moved one, and above all not a tile left hidden.
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

    /// The headline: 25 rounds, each closed from a different post than it
    /// left from, landing home on the tapped tile — the grid must be exactly
    /// as it was at the end.
    @Test func twentyFiveRoundTripsLeaveTheGridIntact() {
        let page = page(40)
        let original = page.posts.map(\.id)

        for round in 0..<25 {
            // Tap a tile near the top, the way a viewer would; the source
            // anchors on it whatever the viewer paged to.
            let departure = page.posts[round % 6].id
            let active = page.posts[(round % 6) + 3 + (round % 9)].id
            let source = ForYouGridZoomSource(
                page: page, tappedID: departure, activePostID: { active }, depthView: nil
            )
            source.zoomSourceWillStageDismissal()
            source.setZoomSourceHidden(false)
            page.layoutIfNeeded()

            #expect(page.posts.map(\.id) == original, "round \(round): the grid moved")
            #expect(hiddenTiles(of: page).isEmpty,
                    "round \(round): tiles left hidden at \(hiddenTiles(of: page))")
        }
    }

    /// The same cycle where the viewer never swipes. The hide/unhide still has
    /// to balance.
    @Test func roundTripsWithoutSwipingLeaveNothingHidden() {
        let page = page(30)
        for round in 0..<25 {
            let departure = page.posts[round % 8].id
            page.setHeroHidden(true, for: departure)
            page.layoutIfNeeded()
            page.setHeroHidden(false, for: departure)
            page.layoutIfNeeded()
            #expect(hiddenTiles(of: page).isEmpty, "round \(round): a tile stayed hidden")
        }
    }

    /// A dismissal from a post the grid does not hold: the hide set on the
    /// tapped tile must still be lifted from the tile it was applied to.
    @Test func aFallbackLandingStillUnhidesItsTile() {
        let page = page(20)
        for round in 0..<25 {
            let departure = page.posts[round % 5].id
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
