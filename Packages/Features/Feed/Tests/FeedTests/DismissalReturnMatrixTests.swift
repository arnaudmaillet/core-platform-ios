import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Every way a post can come home, for every kind of post.
///
/// ## Why a matrix
///
/// A dismissal is not one transition, it is a product: the shape the feed is
/// drawn in (tiles or timeline rows) × what the post being closed IS (a
/// photograph, a video, text) × where that post sits relative to the one that
/// was tapped (the same, a few rows down, far past the realized window, or no
/// longer in the list at all). Each dimension has changed the answer at some
/// point, and every defect so far has been one cell of this table that nobody
/// had opened.
///
/// The rule the whole table serves: **the viewer lands on the post they were
/// looking at, in the slot they left from, and that post appears exactly once
/// in the feed.**
///
/// Two shipped failures this covers, both invisible to the suites that existed:
///
/// * a landing decided by asking for a REALIZED CELL — so paging deep enough
///   that the row was recycled made every media dismissal land on the departure
///   post instead ("le dernier dismiss n'est pas bon");
/// * a landing post the page no longer held, which was declined outright rather
///   than put back into the list.
@MainActor
struct DismissalReturnMatrixTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A corpus whose kinds cycle photo → video → text, so any index reaches a
    /// known kind and every case below can name the one it wants.
    private func corpus(_ count: Int = 30) -> [GalleryPost] {
        (0..<count).map { index in
            let kind: GalleryPost.Kind = switch index % 3 {
            case 0: .photo
            case 1: .video
            default: .text
            }
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: kind,
                isRepost: false,
                thumbnailURL: kind == .text ? nil : URL(string: "https://example.test/\(index).jpg"),
                aspectRatio: 1,
                caption: "caption \(index)",
                publishedAtMS: 0
            )
        }
    }

    private func page(style: ForYouGridPage.Style, count: Int = 30) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(corpus(count)))
        page.layoutIfNeeded()
        return page
    }

    /// Stages a dismissal exactly as the flight does: build the source the tap
    /// builds, tell it the feed settled on `landed`, and let it re-point.
    @discardableResult
    private func stageDismissal(
        on page: ForYouGridPage,
        tapped: PostID,
        landed: PostID?,
        corpus: [GalleryPost] = []
    ) -> ForYouGridZoomSource {
        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tapped,
            activePostID: { landed },
            landedModel: { id in corpus.first { $0.id == id } },
            depthView: nil
        )
        source.zoomSourceWillStageDismissal()
        return source
    }

    private func index(of id: PostID, in page: ForYouGridPage) -> Int? {
        page.posts.firstIndex { $0.id == id }
    }

    /// The invariant every single case owes, asserted everywhere rather than
    /// once: an id in two slots does not render twice, it makes one of the two
    /// unaddressable — `firstIndex` answers with whichever comes first, so the
    /// flight rect, the hero hide and the playback handoff are each free to
    /// pick a different cell.
    private func expectNoDuplicates(_ page: ForYouGridPage, _ comment: Comment) {
        let ids = page.posts.map(\.id)
        #expect(Set(ids).count == ids.count, comment)
    }

    // MARK: - The tile grid: everything flies

    /// ⚠️ A TILE IS A RECT WHATEVER THE POST IS, text included — the grid draws
    /// a text post as a coloured tile, and a coloured tile can fly.
    @Test(arguments: [0, 1, 2])
    func aGridAdoptsEveryKindOfPost(kindOffset: Int) {
        let page = page(style: .grid)
        let tapped = page.posts[3].id
        let landed = page.posts[12 + kindOffset].id
        let kind = page.posts[12 + kindOffset].kind

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(index(of: landed, in: page) == 3, "a \(kind) tile did not take the departure slot")
        expectNoDuplicates(page, "adopting a \(kind) tile duplicated an id")
        #expect(page.posts.count == 30)
    }

    // MARK: - The timeline: media flies, text does not

    /// A row's hero is its MEDIA, so a media row lands the same way a tile does.
    @Test(arguments: [0, 1])
    func aTimelineAdoptsAMediaRow(kindOffset: Int) {
        let page = page(style: .list)
        let tapped = page.posts[3].id
        let landed = page.posts[12 + kindOffset].id

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(index(of: landed, in: page) == 3)
        expectNoDuplicates(page, "adopting a media row duplicated an id")
    }

    /// ⚠️ AND A TEXT ROW IS NOT THIS DRIVER'S TO LAND.
    ///
    /// It has no media, so there is no object that exists at both ends for a
    /// hero to carry — the card-shaped close takes that post, and it does its
    /// own adoption. This driver declining is what leaves the slot alone for it.
    @Test func aTimelineDeclinesATextRow() {
        let page = page(style: .list)
        let tapped = page.posts[3].id
        let landed = page.posts[14].id
        #expect(page.posts[14].kind == .text)

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(index(of: landed, in: page) == 14, "a text row must be left to the card close")
        #expect(index(of: tapped, in: page) == 3)
        expectNoDuplicates(page, "a declined adoption still moved something")
    }

    // MARK: - Distance: the defect that shipped

    /// ⚠️ HOW FAR THE VIEWER PAGED CANNOT DECIDE WHERE THEY LAND.
    ///
    /// This is the reported one. The landing used to be gated on the landed
    /// post having a REALIZED CELL, and the post being dismissed is precisely
    /// the one the viewer paged away to: the further they went, the more
    /// certain its row had been recycled, and the answer flipped from "adopt"
    /// to "stay" with no rule behind it but the scroll position. Nine pages
    /// down it declined every time and the photograph landed on the tapped
    /// post's card.
    ///
    /// A row at index 25 of a 852pt-tall timeline is far outside anything
    /// realized, which is the whole point of choosing it.
    @Test(arguments: [1, 4, 12, 25])
    func theLandingIsTheSameHoweverFarTheViewerPaged(distance: Int) {
        let page = page(style: .list)
        let tapped = page.posts[0].id
        // Always a media row, so distance is the only thing varying.
        let landingIndex = distance % 3 == 2 ? distance - 1 : distance
        let landed = page.posts[landingIndex].id

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(index(of: landed, in: page) == 0,
                "a landing \(landingIndex) rows down was refused for being off screen")
        expectNoDuplicates(page, "adopting from distance \(landingIndex) duplicated an id")
    }

    // MARK: - Membership: move, insert, or nothing

    /// The ordinary case, stated as an invariant rather than as a swap: after a
    /// dismissal the landed post is in the departure slot ONCE.
    @Test func aPostAlreadyInTheListIsMovedRatherThanCopied() {
        let page = page(style: .grid)
        let countBefore = page.posts.count
        let tapped = page.posts[2].id
        let landed = page.posts[9].id

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(index(of: landed, in: page) == 2)
        #expect(page.posts.count == countBefore, "a move must not grow the feed")
        expectNoDuplicates(page, "the landed post was copied instead of moved")
    }

    /// ⚠️ AND A POST THE LIST NO LONGER HOLDS IS PUT BACK INTO IT.
    ///
    /// The stream a post opens into is seeded off this list, but the two can
    /// drift: a refresh that lands while a post is open re-derives the corpus.
    /// Declining there is the same wrong landing as the distance case above,
    /// from a different cause — so the model the feed still holds is inserted
    /// at the departure slot.
    @Test func aPostDroppedFromTheListIsInsertedAtTheSlot() {
        let page = page(style: .grid)
        let full = corpus(40)
        let missing = full[35]
        let tapped = page.posts[4].id
        let countBefore = page.posts.count

        stageDismissal(on: page, tapped: tapped, landed: missing.id, corpus: full)

        #expect(index(of: missing.id, in: page) == 4, "the dismissed post never came back")
        #expect(page.posts.count == countBefore + 1)
        #expect(index(of: tapped, in: page) == 5, "the departure post should have moved down one")
        expectNoDuplicates(page, "inserting the landed post duplicated an id")
    }

    /// With no corpus to consult there is nothing honest to insert, and the
    /// flight goes home to the tile it left from rather than to a rect invented
    /// for a post nothing can render.
    @Test func aPostNobodyHoldsLeavesTheListAlone() {
        let page = page(style: .grid)
        let tapped = page.posts[4].id

        stageDismissal(on: page, tapped: tapped, landed: PostID("ghost"))

        #expect(page.posts.count == 30)
        #expect(index(of: tapped, in: page) == 4)
        expectNoDuplicates(page, "a refused landing still moved something")
    }

    /// The viewer never paged: the post they close is the one they opened.
    /// Nothing moves, and nothing is duplicated by "moving" a post onto itself.
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func closingTheTappedPostMovesNothing(style: ForYouGridPage.Style) {
        let page = page(style: style)
        let before = page.posts.map(\.id)
        let tapped = page.posts[6].id

        stageDismissal(on: page, tapped: tapped, landed: tapped)

        #expect(page.posts.map(\.id) == before)
        expectNoDuplicates(page, "adopting a post into its own slot duplicated it")
    }

    /// A feed that has not answered yet is asked this too — a pop can beat the
    /// first page in — and there is no slot to land in.
    @Test func anEmptyFeedRefusesQuietly() {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.layoutIfNeeded()

        stageDismissal(on: page, tapped: PostID("p0"), landed: PostID("p1"))

        #expect(page.posts.isEmpty)
    }

    // MARK: - What the adoption owes its caller

    /// ⚠️ THE LANDING RECT IS READABLE THE INSTANT THE ADOPTION RETURNS.
    ///
    /// Every caller reads it immediately — the flight rect, the card's cover,
    /// the reveal's geometry — so a slot whose cell is not realized yet answers
    /// nil and the close collapses to the middle of the screen.
    ///
    /// This is the property a `CATransaction.flush()` used to be here for, and
    /// it is pinned rather than the flush because the flush also flushed
    /// UIKIT'S transaction: on a back-button close the adoption runs inside the
    /// pop's commit, and flushing there aborted the pop outright. The layout
    /// pass is what actually delivers this, and it is safe anywhere.
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func theLandingIsMeasurableAsSoonAsTheAdoptionReturns(style: ForYouGridPage.Style) {
        let page = page(style: style)
        let tapped = page.posts[2].id
        let landed = page.posts[12].id

        stageDismissal(on: page, tapped: tapped, landed: landed)

        #expect(page.hero(for: landed, in: page) != nil,
                "the close had no rect to fly to at the moment it asked")
        #expect(page.isPostVisible(landed))
    }

    /// And the same for a post that had to be INSERTED: it is not enough to be
    /// in the array, it has to be on screen and measurable.
    @Test func anInsertedPostIsMeasurableToo() {
        let page = page(style: .list)
        let full = corpus(40)
        let missing = full[33]
        let tapped = page.posts[1].id

        stageDismissal(on: page, tapped: tapped, landed: missing.id, corpus: full)

        #expect(page.hero(for: missing.id, in: page) != nil)
    }

    // MARK: - What can fly at all

    /// The question both the hero grab and the adoption ask, pinned on its own
    /// so the two can never drift: it is about the POST and the SHAPE, and
    /// about nothing else — no cell, no scroll position, no visibility.
    @Test func whatCanFlyIsAPropertyOfThePostAndTheShape() {
        let grid = page(style: .grid)
        let list = page(style: .list)
        let photo = GalleryPost(
            id: PostID("photo"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/a.jpg"),
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )
        let video = GalleryPost(
            id: PostID("video"), kind: .video, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/a.jpg"),
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )
        let text = GalleryPost(
            id: PostID("text"), kind: .text, isRepost: false, thumbnailURL: nil,
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )

        for post in [photo, video, text] {
            #expect(grid.canLandHero(on: post), "a tile is a rect for every kind")
        }
        #expect(list.canLandHero(on: photo))
        #expect(list.canLandHero(on: video))
        #expect(list.canLandHero(on: text) == false, "a text row has no media to fly")
    }
}
