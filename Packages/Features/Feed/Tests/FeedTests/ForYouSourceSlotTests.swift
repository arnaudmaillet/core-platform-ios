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

    /// ⚠️ ACROSS THE "New" BOUNDARY TOO — the case that crashed.
    ///
    /// `split` is the length of the leading RUN of arrivals, not a stored
    /// number, so swapping an old post into that run cuts it short and both
    /// sections' counts change — while `reloadItems` promises UIKit they did
    /// not. Reported from a device: "the number of items in section 0 after the
    /// update (1) must be equal to the number before (6)".
    ///
    /// It must still SWAP: the arrivals sit at the top, so paging a few posts
    /// down crosses the boundary almost immediately, and a dismissal that
    /// declined there would land on the card the viewer left. The update takes
    /// the honest verb for a changed shape instead.
    ///
    /// Both directions, because the run can be entered from either side, and
    /// the run's own length is asserted rather than a literal index — that is
    /// the number UIKit was crashing on.
    @Test func aSwapAcrossTheArrivalsBoundaryReshapesTheSections() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let corpus = posts(30)
        page.render(.content(corpus))
        page.setNewPosts(Set(corpus.prefix(6).map(\.id)))
        page.layoutIfNeeded()

        let arrival = page.posts[2].id
        let older = page.posts[17].id

        #expect(page.adoptPost(older, intoSlotOf: arrival))

        #expect(page.posts[2].id == older)
        #expect(page.posts[17].id == arrival)
        // The run now stops where the old post landed, and the page survived
        // saying so — an update that lied about this is what crashed.
        #expect(page.debugArrivalsRunLength == 2)

        // And back the other way, from the old side into the run.
        #expect(page.adoptPost(arrival, intoSlotOf: older))
        #expect(page.posts[17].id == older)
        #expect(page.debugArrivalsRunLength == 6)
    }

    /// And inside one run it still works: the boundary is the limit, not the
    /// feature.
    @Test func aSwapWithinTheArrivalsIsAllowed() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let corpus = posts(30)
        page.render(.content(corpus))
        page.setNewPosts(Set(corpus.prefix(6).map(\.id)))
        page.layoutIfNeeded()

        let departure = page.posts[1].id
        let landed = page.posts[4].id

        #expect(page.adoptPost(landed, intoSlotOf: departure))
        #expect(page.posts[1].id == landed)
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

/// WHICH post the arrival tile shows when a TEXT post is dismissed onto the
/// grid.
///
/// A text page has no media, so there is nothing for the departing post to
/// become — the close cannot land on its own post the way a media dismissal
/// does. The product answer is the NEXT media post: the one the viewer would
/// have reached with one more swipe, so the grid they come back to is the feed
/// they were in the middle of rather than a tile they have already read past.
///
/// "Next" is only answerable HERE. The snap feed is seeded as a suffix of this
/// page's ordered ids (`ForYouViewController.openFeed`), and the view model's
/// corpus is neither ordered nor filtered the same way, so the same question
/// asked there answers about a different list.
@MainActor
struct ForYouNextLandingTests {
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

    private func post(
        _ id: String, kind: GalleryPost.Kind = .photo, cover: Bool = true
    ) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: cover ? URL(string: "mock://cover/\(id)") : nil,
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )
    }

    /// A page of media, which is the ordinary case.
    private func media(_ count: Int) -> [GalleryPost] {
        (0..<count).map { post("p\($0)") }
    }

    /// Below the fold nothing is realized, so neither preference can fire and
    /// ORDER is the only thing left to decide — the next post is the very next
    /// post, which is what "one more swipe" means.
    @Test func theNextLandingIsTheVeryNextPostInTheRenderedOrder() {
        let page = page(media(60))
        let anchor = page.posts[40]
        #expect(!page.isPostVisible(anchor.id), "the fixture put the anchor on screen")

        #expect(page.nextLandableMedia(after: anchor.id)?.id == page.posts[41].id)
    }

    /// ⚠️ AND IT PASSES OVER WHAT THE VIEWER IS LOOKING AT.
    ///
    /// The landing swaps the chosen post into the departure slot, so choosing a
    /// tile that is on screen makes it vanish from where it lives and reappear
    /// in the arrival cell, mid-landing, in front of the viewer.
    @Test func aVisibleCandidateIsPassedOverForAnOffScreenOne() {
        let page = page(media(60))
        let anchor = page.posts[0]
        // The setup, asserted rather than assumed: the tiles just after the
        // anchor are exactly the ones being looked at.
        #expect(page.isPostVisible(page.posts[1].id), "the fixture put nothing on screen")

        let landing = page.nextLandableMedia(after: anchor.id)

        let expected = page.posts.dropFirst().first { !page.isPostVisible($0.id) }
        #expect(landing?.id == expected?.id)
        #expect(landing?.id != page.posts[1].id, "the landing took a tile off the viewer's screen")
    }

    /// A TEXT post is never a landing — it has no media, which is the whole
    /// reason this question is being asked. `canLandHero` says so for a list and
    /// the kind says so everywhere.
    @Test func aTextPostIsNeverALanding() throws {
        var corpus = (0..<30).map { post("t\($0)", kind: .text, cover: false) }
        corpus.append(post("media"))
        let page = page(corpus)
        // The arrangement permutes the corpus into slots, so the anchor is
        // found by property rather than by the index it went in at.
        let anchor = try #require(page.posts.first { $0.kind == .text })

        #expect(page.nextLandableMedia(after: anchor.id)?.id == PostID("media"))
    }

    /// Neither is a post with no cover: the arrival tile would be a coloured
    /// square, and the readiness gate would hold the card for its whole ceiling
    /// waiting for an image that is never coming.
    @Test func aPostWithNoCoverIsNeverALanding() throws {
        var corpus = (0..<30).map { post("bare\($0)", cover: false) }
        corpus.append(post("media"))
        let page = page(corpus)
        let anchor = try #require(page.posts.first { $0.id != PostID("media") })

        #expect(page.nextLandableMedia(after: anchor.id)?.id == PostID("media"))
    }

    /// The last post still has to land somewhere, so the search wraps to the
    /// head of the page — the alternative is nil, which is a close with no
    /// arrival at all.
    @Test func theLastPostWrapsToTheHeadOfThePage() {
        let page = page(media(60))
        let last = page.posts[page.posts.count - 1]

        let landing = page.nextLandableMedia(after: last.id)

        #expect(landing != nil)
        #expect(landing?.id != last.id)
        // The same preference applies on the way round: the head of a page is
        // on screen, so the wrap still skips what the viewer is looking at.
        #expect(landing?.id == page.posts.dropLast().first { !page.isPostVisible($0.id) }?.id)
    }

    /// ⚠️ AND ONLY WHEN NOTHING FOLLOWS. Wrapping is the fallback, not a
    /// ranking: a candidate after the anchor wins over an equally good one
    /// before it, or "next" would mean "anywhere" and a close could land the
    /// viewer further back in the feed than they started.
    @Test func aCandidateAfterTheAnchorBeatsOneBeforeIt() throws {
        let page = page(media(60))
        let anchorIndex = 40
        let landing = try #require(page.nextLandableMedia(after: page.posts[anchorIndex].id))

        let landed = try #require(page.posts.firstIndex { $0.id == landing.id })
        #expect(landed > anchorIndex, "the search wrapped while posts still followed")
    }

    /// A page with nothing landable on it answers nil rather than a text post:
    /// the caller has a fallback (the departure tile), and a dishonest answer
    /// would fly the close onto a card with no media to receive it.
    @Test func aPageOfTextAnswersNil() {
        let page = page((0..<20).map { post("t\($0)", kind: .text, cover: false) })
        #expect(page.nextLandableMedia(after: page.posts[0].id) == nil)
    }

    /// An anchor this page does not hold has no "next" — the feed settled on
    /// something the grid no longer carries.
    @Test func anAbsentAnchorAnswersNil() {
        let page = page(media(30))
        #expect(page.nextLandableMedia(after: PostID("nowhere")) == nil)
    }

    /// The stand-in is sized from the SLOT, not from the post: the landing
    /// swaps this post into the departure slot, so the rect the window closes
    /// onto is that slot's, whatever was in it a moment ago.
    @Test func theTileStandInIsSizedFromTheSlotItLandsIn() throws {
        let page = page(media(60))
        let occupant = page.posts[2].id
        let arriving = try #require(page.nextLandableMedia(after: page.posts[0].id))

        let standIn = try #require(page.makeTileStandIn(for: arriving, slotOf: occupant))
        let scroll = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        let slot = try #require(scroll.cellForItem(at: IndexPath(item: 2, section: 0)))

        #expect(standIn.bounds.size == slot.bounds.size)
    }

    /// Nothing realized at the slot means no rect to size to, and a stand-in
    /// built at a guessed size lands at the wrong one.
    @Test func anUnrealizedSlotHasNoStandIn() {
        let page = page(media(120))
        let arriving = page.posts[1]
        #expect(page.makeTileStandIn(for: arriving, slotOf: page.posts[119].id) == nil)
        #expect(page.makeTileStandIn(for: arriving, slotOf: PostID("nowhere")) == nil)
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
