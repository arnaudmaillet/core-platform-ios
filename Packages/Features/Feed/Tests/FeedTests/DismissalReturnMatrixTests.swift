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
/// The rule the whole table serves (the owner, 2026-10-16, #1269/#1283):
/// **a close always comes home to the tile that was tapped**, whatever the
/// viewer paged to, crossfading the page's picture into the tile's own clip —
/// and nothing in the grid moves to meet it. The close used to ADOPT the post
/// the viewer ended on into the tapped slot on a mosaic; that is gone, and so
/// are its tests.
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

    private func page(
        style: ForYouGridPage.Style, count: Int = 30, height: CGFloat = 852
    ) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        page.render(.content(corpus(count)))
        page.layoutIfNeeded()
        return page
    }

    /// Stages a dismissal exactly as the flight does: build the source the tap
    /// builds, tell it the feed settled on `landed`, and let it stage.
    @discardableResult
    private func stageDismissal(
        on page: ForYouGridPage, tapped: PostID, landed: PostID?,
        activeMediaPage: (() -> Int?)? = nil
    ) -> ForYouGridZoomSource {
        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed },
            activeMediaPage: activeMediaPage, depthView: nil
        )
        source.zoomSourceWillStageDismissal()
        return source
    }

    /// Where a close anchored to `id` lands: its media, its text row, or its
    /// row — the answers `zoomHeroFrame` tries in turn.
    private func landingRect(of id: PostID, in page: ForYouGridPage) -> CGRect? {
        page.hero(for: id, in: page)?.frame ?? page.rowFrame(for: id, in: page)
    }

    // MARK: - Home to the tapped tile, always

    /// ⚠️ THE MATRIX: every shape × what the post being closed IS × how far the
    /// viewer paged. The grid holds still, and the close lands on the tile
    /// that was tapped — never on the post the viewer ended on.
    @Test(arguments: [ForYouGridPage.Style.discover, .grid, .list], [0, 1, 2])
    func aCloseAlwaysComesHomeToTheTappedTile(style: ForYouGridPage.Style, landingKind: Int) {
        for distance in [0, 3, 24] {
            let page = page(style: style)
            let before = page.posts.map(\.id)
            let tapped = before[1]
            let landed = before[min(before.count - 1, 1 + distance + landingKind)]

            let source = stageDismissal(on: page, tapped: tapped, landed: landed)

            #expect(page.posts.map(\.id) == before,
                    "a \(style) close from \(distance) posts on moved the grid to meet it")
            let home = landingRect(of: tapped, in: page)
            #expect(home != nil, "precondition: the tapped tile is on screen")
            #expect(source.zoomHeroFrame(in: page) == home,
                    "a \(style) close from \(distance) posts on did not land on the tapped tile")
        }
    }

    /// ⚠️ STAGING IS NOT ONCE-ONLY: a cancelled grab keeps its source, and the
    /// second staging must leave the grid exactly as the first.
    @Test func stagingTwiceLeavesTheGridUntouched() {
        let page = page(style: .grid, count: 8)
        let before = page.posts.map(\.id)
        var landed = before[5]
        let source = ForYouGridZoomSource(
            page: page, tappedID: before[1], activePostID: { landed }, depthView: nil
        )
        source.zoomSourceWillStageDismissal()
        landed = before[6]
        source.zoomSourceWillStageDismissal()
        #expect(page.posts.map(\.id) == before)
        #expect(source.zoomHeroFrame(in: page) == landingRect(of: before[1], in: page))
    }

    /// A post the page does not hold (dropped by a refresh, or never there)
    /// changes nothing: the close goes home.
    @Test func aPostNobodyHoldsLeavesTheGridAlone() {
        let page = page(style: .grid)
        let before = page.posts.map(\.id)
        let source = stageDismissal(on: page, tapped: before[4], landed: PostID("ghost"))
        #expect(page.posts.map(\.id) == before)
        #expect(source.zoomHeroFrame(in: page) == landingRect(of: before[4], in: page))
    }

    /// A feed that has not answered yet is asked this too — a pop can beat the
    /// first page in — and nothing breaks.
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
    /// the tapped tile, and then either the flight lands (and puts
    /// its own hide back) or another driver finishes the close and the screen's
    /// own return sweep does.
    private func roundTrip(
        on page: ForYouGridPage,
        tapped: PostID,
        landed: PostID,
        flightLands: Bool
    ) {
        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed }, depthView: nil
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
        }
        #expect(page.posts.count == 30)
    }

    /// ⚠️ A WINDOW CAN CLOSE AS A FLIGHT: a text tile opened as a window, the
    /// viewer paged onto a photograph, and the flight lands on the TEXT tile it
    /// left from — a tile is a rect for every kind, so it never collapses to
    /// the middle of the screen.
    @Test func aWindowThatEndsOnAPhotographLandsOnItsTextTile() {
        let page = page(style: .grid)
        let text = page.posts[2].id
        #expect(page.posts[2].kind == .text)
        page.setRevealConcealed(true, for: text)

        let source = stageDismissal(on: page, tapped: text, landed: page.posts[12].id)

        let home = landingRect(of: text, in: page)
        #expect(home != nil)
        #expect(source.zoomHeroFrame(in: page) == home, "the flight did not land on its text tile")
    }

    /// And the row the window departed from comes back when the close is over.
    @Test func theWindowsOwnRowComesBackAfterAFlightCloses() {
        let page = page(style: .list)
        let text = page.posts[2].id
        page.setRevealConcealed(true, for: text)

        stageDismissal(on: page, tapped: text, landed: page.posts[12].id)
        page.clearHeroConcealment()
        page.clearRevealConcealment()

        expectNothingConcealed(page, "the window's row stayed hidden after a flight close")
    }

    /// ⚠️ A GRID'S LANDING IS CONCEALED TOO, and for a long time it was not.
    ///
    /// `setRevealConcealed` resolved its cell `as? PostGridListRowCell` and did
    /// nothing at all for anything else, so on the Discover GRID — whose cells
    /// are tiles — the window closed onto a tile that stayed visible underneath
    /// it the whole way: two copies of the same post, one inside the window and
    /// one behind it. Filmed before this test existed, and invisible to every
    /// other assertion in this suite because they all use `.list`.
    ///
    /// The hero channel beside it has always switched on the cell; this one was
    /// written when only list surfaces opened windows and never caught up.
    @Test func aGridsLandingIsConcealedLikeARows() {
        for style in [ForYouGridPage.Style.grid, .list] {
            let page = page(style: style)
            let target = page.posts[1].id
            #expect(page.isPostVisible(target), "precondition: it is on screen to begin with")

            // ⚠️ Asked of the CELLS, not of the concealment flags: the flag
            // was being set the whole time — it is the cell that was never
            // touched, which is exactly the shape of the defect.
            page.setRevealConcealed(true, for: target)
            #expect(concealedPosts(in: page).contains(target),
                    "the \(style) landing was left showing under its own window")

            page.setRevealConcealed(false, for: target)
            #expect(!concealedPosts(in: page).contains(target),
                    "the \(style) landing never came back")
        }
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
    /// The anchor is the DEPARTURE post whatever the viewer paged to — which for
    /// a window is a text post, and for a flight is a media one.
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
        // Tall enough that the THIRD row is realized: two square media cards,
        // each with its closing line, run past a phone's height, and a row
        // that is not on screen has no rect to land on by design.
        let page = page(style: .list, height: 1400)
        let text = page.posts[2].id
        #expect(page.posts[2].kind == .text)
        #expect(page.hero(for: text, in: page) == nil, "a text row has no hero — the premise")

        // A window opened from this text post: the anchor stays here whatever
        // the viewer paged to.
        let source = ForYouGridZoomSource(
            page: page, tappedID: text, activePostID: { PostID("gone") }, depthView: nil
        )
        source.zoomSourceWillStageDismissal()

        let frame = source.zoomHeroFrame(in: page)
        let row = page.rowFrame(for: text, in: page)
        #expect(row != nil)
        #expect(frame == row, "the close collapsed to the centre instead of onto its card")
    }

    /// The posts whose row is currently standing aside for a transition —
    /// concealed on either channel.
    ///
    /// Read off the cells rather than off a flag, because "which flag is set"
    /// and "which card the viewer cannot see" came apart, and only the second
    /// one is the bug.
    private func concealedPosts(in page: ForYouGridPage) -> Set<PostID> {
        page.concealedPosts()
    }

    // MARK: - What the landing tile is showing when the card arrives

    /// ⚠️ A SAME-POST CLOSE PUTS THE TILE ON THE PAGE THE CARD IS CARRYING: a
    /// close from page four of a collection flies page four, and the tile it
    /// lands on would otherwise keep the page it was left on.
    @Test func aSamePostCloseTurnsTheTileToThePageTheCardIsCarrying() {
        let page = page(style: .grid)
        let tapped = page.posts[0].id
        var asked = 0
        stageDismissal(on: page, tapped: tapped, landed: tapped, activeMediaPage: { asked += 1; return 3 })
        #expect(asked == 1, "the close never asked which page it was flying")
    }

    /// A close from ANOTHER post leaves the tile on its own page: the page on
    /// screen belongs to the other post, and the tile crossfades into its own
    /// clip.
    @Test func aCloseFromAnotherPostLeavesTheTilesPageAlone() {
        let page = page(style: .grid)
        var asked = 0
        stageDismissal(
            on: page, tapped: page.posts[0].id, landed: page.posts[12].id,
            activeMediaPage: { asked += 1; return 3 }
        )
        #expect(asked == 0, "another post's page was applied to the tapped tile")
    }

    /// Nil means "not a collection", and a row with no pages is left alone
    /// rather than sent to page zero.
    @Test func aRowWithNoPagesIsNotSentToPageZero() {
        let page = page(style: .list)
        let before = page.posts.map(\.id)
        stageDismissal(on: page, tapped: before[0], landed: before[0], activeMediaPage: { nil })
        #expect(page.posts.map(\.id) == before)
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
}
