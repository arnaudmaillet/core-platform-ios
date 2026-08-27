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

    /// Closes the post the way the APP would, by asking the same question the
    /// app asks: a post with something to fly goes home on the flight, and one
    /// without goes home as a card — which on this page is a direct adoption,
    /// because the card driver owns the animation and the page only owns the
    /// slot.
    ///
    /// Written as one helper because the permutation below is a rule about the
    /// FEED, not about a driver: which one carries the post is an implementation
    /// detail the viewer cannot see, and a test that only exercised the flight
    /// would leave every text landing unproven.
    private func close(on page: ForYouGridPage, tapped: PostID, landed: PostID) {
        guard let model = page.post(for: landed) else { return }
        if page.canLandHero(on: model) {
            stageDismissal(on: page, tapped: tapped, landed: landed)
        } else {
            page.adoptPost(landed, intoSlotOf: tapped, orInsert: model)
        }
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

    // MARK: - The display the viewer gets back

    /// Nothing on the grid may be invisible once no flight is in the air.
    ///
    /// The end state, not the calls: a row hidden by a driver that never got to
    /// put it back looks exactly like a row nobody ever hid, and only the
    /// pixels tell them apart.
    private func expectNothingConcealed(_ page: ForYouGridPage, _ comment: Comment) {
        let collection = page.subviews.compactMap { $0 as? UICollectionView }.first
        for cell in collection?.visibleCells ?? [] {
            #expect(cell.isHidden == false, comment)
            #expect(cell.alpha == 1, comment)
            if let row = cell as? PostGridListRowCell {
                #expect(row.isHeroMediaConcealed == false, comment)
            }
        }
    }

    /// A whole round trip, the way the app performs one: the push hides the
    /// tapped row's media so the card flies alone, the close re-points at
    /// whatever the viewer ended on, and then either the flight lands (and puts
    /// its own hide back) or another driver finishes the close and the screen's
    /// own return sweep does.
    private func roundTrip(
        on page: ForYouGridPage,
        tapped: PostID,
        landed: PostID,
        flightLands: Bool
    ) {
        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed },
            landedModel: { id in page.post(for: id) }, depthView: nil
        )
        source.setZoomSourceHidden(true)
        source.zoomSourceWillStageDismissal()
        if flightLands {
            source.setZoomSourceHidden(false)
        } else {
            // What `viewDidAppear` does when the grid is on screen again.
            page.clearHeroConcealment()
            page.clearRevealConcealment()
        }
    }

    /// ⚠️ THE HIDE AND THE UNHIDE CAN BELONG TO DIFFERENT DRIVERS.
    ///
    /// This is the reported leak. The push hides the tapped row's media; the
    /// flight's own return is what puts it back. But the feed is a pager — end
    /// on a text post and the close belongs to the CARD driver, which knows
    /// nothing about a hide it did not make. The row came back with its caption
    /// and a blank where its photograph was, and stayed that way: one more row
    /// per round trip, which is why it was reported "after several iterations".
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func aCloseFinishedByAnotherDriverStillGivesTheRowBack(style: ForYouGridPage.Style) {
        let page = page(style: style)
        let tapped = page.posts[1].id

        roundTrip(on: page, tapped: tapped, landed: page.posts[14].id, flightLands: false)

        expectNothingConcealed(page, "a row stayed hidden after the close ended")
    }

    /// And the ordinary case, where the flight does land, is unchanged.
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func aFlightThatLandsGivesTheRowBackItself(style: ForYouGridPage.Style) {
        let page = page(style: style)

        roundTrip(
            on: page, tapped: page.posts[1].id, landed: page.posts[13].id, flightLands: true
        )

        expectNothingConcealed(page, "the flight's own return left something hidden")
    }

    /// ⚠️ AND IT DOES NOT ACCUMULATE.
    ///
    /// One leaked row is a bug; the report was about what six of them look
    /// like. Each trip departs from a different row, so a leak that survives
    /// one round trip is still on screen at the end of the next.
    @Test func sixRoundTripsLeaveNothingHidden() {
        let page = page(style: .list)

        for trip in 0..<6 {
            roundTrip(
                on: page,
                tapped: page.posts[trip].id,
                landed: page.posts[trip + 13].id,
                flightLands: trip.isMultiple(of: 2)
            )
            expectNothingConcealed(page, "a row was left hidden by trip \(trip)")
            expectNoDuplicates(page, "trip \(trip) duplicated an id")
        }
        #expect(page.posts.count == 30)
    }

    /// ⚠️ A WINDOW CAN CLOSE AS A FLIGHT, and the row it opened from is
    /// CONCEALED for the whole visit.
    ///
    /// The two openings are not symmetric. A media post opens with a flight,
    /// which hides the row's MEDIA; a text post opens as a window, and the
    /// reveal takes the whole ROW away — "the row goes the moment the window
    /// takes its place". Page from that text post onto a photograph and the
    /// close is the flight's, landing in the slot the window left behind: a
    /// slot the reveal is still holding concealed.
    ///
    /// Reported as the transition window "returning to the middle of the
    /// screen", which is exactly what a flight does when its source reports
    /// nothing to land on — `ZoomTransitionGeometry.centeredFallback`.
    @Test func aWindowThatEndsOnAPhotographHasSomewhereToLand() {
        let page = page(style: .list)
        let text = page.posts[2].id
        #expect(page.posts[2].kind == .text)
        let media = page.posts[12].id
        // What the window's opening does to the row it came from.
        page.setRevealConcealed(true, for: text)

        stageDismissal(on: page, tapped: text, landed: media)

        #expect(index(of: media, in: page) == 2, "the landing post never reached the slot")
        #expect(page.hero(for: media, in: page) != nil, "the flight had no rect and collapsed")
        #expect(page.isPostVisible(media), "the landing row is concealed under the card")
    }

    /// And the row the window departed from comes back when the flight lands —
    /// it is the other end of the same swap, and nothing else revisits it.
    @Test func theWindowsOwnRowComesBackAfterAFlightCloses() {
        let page = page(style: .list)
        let text = page.posts[2].id
        let media = page.posts[12].id
        page.setRevealConcealed(true, for: text)

        stageDismissal(on: page, tapped: text, landed: media)
        page.clearHeroConcealment()
        page.clearRevealConcealment()

        expectNothingConcealed(page, "the window's row stayed hidden after a flight close")
    }

    /// ⚠️ NO CLOSE COLLAPSES INTO THE MIDDLE OF THE SCREEN WHILE ITS POST HAS A
    /// ROW.
    ///
    /// The two rect lookups refuse each other's rows on purpose: `hero(for:)`
    /// answers nil for a text row, `textRowFrame(for:)` answers nil for a media
    /// row. Each refusal is right on its own — and between them sits a close
    /// whose anchor is the OTHER kind, which had no rect at all and flew a
    /// blank card into the centre of the screen. Reported as "the transition
    /// window returns to the middle".
    ///
    /// The anchor lands on the other kind by ordinary use: it is re-pointed at
    /// whatever the viewer paged to, and when that post cannot be adopted the
    /// anchor stays the DEPARTURE post — which for a window is a text post, and
    /// for a flight is a media one.
    @Test(arguments: [0, 1, 2])
    func aCloseAlwaysHasARectWhateverKindItsAnchorTurnedOutToBe(kindOffset: Int) {
        let page = page(style: .list)
        let anchor = page.posts[kindOffset].id   // 0,1,2 → photo, video, text
        let kind = page.posts[kindOffset].kind

        let rect = page.hero(for: anchor, in: page)?.frame
            ?? page.textRowFrame(for: anchor, in: page)
            ?? page.rowFrame(for: anchor, in: page)

        #expect(rect != nil, Comment(rawValue: "a \\(kind) anchor had nowhere to land"))
        #expect(rect != .zero)
    }

    /// The flight's own answer, end to end: a source anchored to a post with no
    /// media still reports the row rather than the middle of the screen.
    @Test func aFlightAnchoredToATextRowLandsOnTheRow() {
        let page = page(style: .list)
        let text = page.posts[2].id
        #expect(page.posts[2].kind == .text)
        #expect(page.hero(for: text, in: page) == nil, "a text row has no hero — the premise")

        // The case that produces it: a window opened from this text post, the
        // viewer paged to a post the grid cannot land on, so the anchor stayed
        // here.
        let source = ForYouGridZoomSource(
            page: page, tappedID: text, activePostID: { PostID("gone") },
            landedModel: { _ in nil }, depthView: nil
        )
        source.zoomSourceWillStageDismissal()

        let frame = source.zoomHeroFrame(in: page)
        let row = page.rowFrame(for: text, in: page)
        #expect(row != nil)
        #expect(frame == row, "the close collapsed to the centre instead of onto its card")
    }

    // MARK: - What the landing row is showing when the card arrives

    /// ⚠️ THE ROW IS PUT ON THE PAGE THE CARD IS CARRYING.
    ///
    /// A close from page four of a collection flies page four, and the row it
    /// lands on keeps whatever page it was left on — the first, for a row the
    /// viewer never touched. The photograph therefore changed under the card at
    /// the exact moment the card was removed. The opening has had this in both
    /// directions since `openMediaPage`; the close only ever had it in one.
    @Test func theLandingRowIsPutOnThePageTheCardIsCarrying() {
        let page = page(style: .list)
        let tapped = page.posts[0].id
        let landed = page.posts[12].id
        var asked = 0

        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed },
            landedModel: { id in page.post(for: id) },
            activeMediaPage: { asked += 1; return 3 },
            depthView: nil
        )
        source.zoomSourceWillStageDismissal()

        #expect(asked == 1, "the close never asked which page it was flying")
        #expect(index(of: landed, in: page) == 0)
    }

    /// Nil means "not a collection", and a row with no pages must be left alone
    /// rather than sent to page zero — the same distinction `openMediaPage`
    /// draws in the other direction.
    @Test func aRowWithNoPagesIsNotSentToPageZero() {
        let page = page(style: .list)

        let source = ForYouGridZoomSource(
            page: page, tappedID: page.posts[0].id, activePostID: { page.posts[12].id },
            landedModel: { id in page.post(for: id) },
            activeMediaPage: { nil },
            depthView: nil
        )
        source.zoomSourceWillStageDismissal()

        #expect(index(of: page.posts[0].id, in: page) == 0)
    }

    /// ⚠️ THE CARD STAYS AND THE MEDIA GOES, on a timeline.
    ///
    /// The landing needs somewhere for the flying photograph to arrive INTO:
    /// with the row's preview left showing, the same picture is on screen twice
    /// for the whole return and the card lands on a copy of itself. Concealing
    /// a ROW takes the preview and leaves the card — header, caption, counters
    /// — so the viewer sees the card they are returning to with a gap in it.
    ///
    /// A tile is the opposite case and keeps the old behaviour: a tile IS its
    /// media, so concealing it would leave a hole in the mosaic.
    @Test func aTimelineLandingOpensAGapForTheMediaToArriveInto() {
        let list = page(style: .list)
        let grid = page(style: .grid)

        #expect(list.landingConcealsMedia)
        #expect(grid.landingConcealsMedia == false)
    }

    // MARK: - The order the viewer gets back

    /// ⚠️ THE FEED IS PERMUTED, NOT REBUILT: A, B, C read from A to C comes back
    /// C, B, A.
    ///
    /// Stated as the product rule it is. The post the viewer ended on takes the
    /// slot they left from — that is the whole point of the adoption — and the
    /// post that was there goes where the other one came from. Everything
    /// between them is untouched, which is what makes the grid hold still under
    /// a card that is landing on it.
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func readingFromTheFirstPostToTheLastReversesTheEnds(style: ForYouGridPage.Style) {
        let page = page(style: style, count: 3)
        let (a, b, c) = (page.posts[0].id, page.posts[1].id, page.posts[2].id)

        close(on: page, tapped: a, landed: c)

        #expect(page.posts.map(\.id) == [c, b, a])
    }

    /// The same rule with the ends further apart: only the two ends move.
    /// The same rule with the ends further apart, for every combination of what
    /// the two ends ARE: only the two ends move, whichever driver carries the
    /// post home.
    @Test(arguments: [0, 1, 2], [0, 1, 2])
    func onlyTheTwoEndsOfTheReadingMove(departureKind: Int, landingKind: Int) {
        let page = page(style: .list)
        let before = page.posts.map(\.id)
        let from = 3 + departureKind      // 3,4,5 → photo, video, text
        let to = 12 + landingKind         // 12,13,14 → photo, video, text

        close(on: page, tapped: before[from], landed: before[to])

        var expected = before
        expected.swapAt(from, to)
        let story = "a \(page.post(for: before[from])!.kind) → "
            + "\(page.post(for: before[to])!.kind) reading did not permute its ends"
        #expect(page.posts.map(\.id) == expected, Comment(rawValue: story))
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
