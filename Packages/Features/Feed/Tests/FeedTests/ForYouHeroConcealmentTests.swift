import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES.
///
/// The two grid styles need opposite treatment and the difference is not
/// cosmetic. A TILE is its media edge to edge, so a flight departing one takes
/// the whole cell with it and the cell must go. A ROW is a card of which the
/// media is one part — `hero(for:in:)` flies `mediaHeroRect`, not the row — so
/// hiding the row removed the caption, author line and metrics that nothing in
/// the air was standing in for. They were missing for the length of the flight
/// and snapped back on its last frame, reported on the Following tab as "the
/// rest of the post content pops into view only at the very end".
///
/// The routing is what regressed, not either cell, which is why these test the
/// page's decision rather than the cells' APIs (`ListRowHeroConcealmentTests`
/// covers those).
@MainActor
struct ForYouHeroConcealmentTests {
    private func post(_ kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(id: PostID("p"), kind: kind, isRepost: false,
                    thumbnailURL: nil, caption: "caption", publishedAtMS: 0)
    }

    private func row(_ kind: GalleryPost.Kind = .photo) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        cell.configure(with: post(kind),
                       imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    /// The regression itself: a row must NOT be hidden wholesale.
    @Test func aFlyingRowKeepsEverythingTheFlightIsNotCarrying() {
        let cell = row()

        ForYouGridPage.applyHeroConcealment(true, to: cell)

        #expect(cell.isHidden == false, "the row was hidden whole — its caption and metrics vanish")
        // …and it can still say where its media is, which is the rect the
        // dismissal flies home to.
        #expect(cell.mediaHeroRect != nil)
    }

    /// A tile still hides whole, because there the cell IS what flies.
    @Test func aFlyingTileHidesWhole() {
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 130, height: 130))
        cell.configure(with: post(.photo),
                       imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))

        ForYouGridPage.applyHeroConcealment(true, to: cell)
        #expect(cell.isHidden == true)

        ForYouGridPage.applyHeroConcealment(false, to: cell)
        #expect(cell.isHidden == false)
    }

    /// Landing restores the row's preview. The un-conceal runs on the last
    /// frame of the flight, so anything it misses is a permanently blank slot.
    @Test func landingRestoresTheRowsPreview() {
        let cell = row()
        ForYouGridPage.applyHeroConcealment(true, to: cell)

        ForYouGridPage.applyHeroConcealment(false, to: cell)

        #expect(cell.isHidden == false)
        #expect(cell.mediaHeroRect != nil)
    }

    /// A row recycled out of a flight must never carry the concealment to
    /// whatever post it is used for next — the failure mode that leaves a
    /// permanently media-less row somewhere else in the list.
    @Test func aRecycledRowDoesNotInheritTheConcealment() {
        let cell = row()
        ForYouGridPage.applyHeroConcealment(true, to: cell)

        // Re-dequeued for a different post: the page applies concealment for
        // the NEW post, which is not flying.
        cell.configure(with: post(.video),
                       imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        ForYouGridPage.applyHeroConcealment(false, to: cell)

        #expect(cell.isHidden == false)
        #expect(cell.mediaHeroRect != nil)
    }

    /// Nil is the scrolled-out case and must be a clean no-op, not a crash:
    /// the page concealing by post id may find nothing realized.
    @Test func concealingNothingIsHarmless() {
        ForYouGridPage.applyHeroConcealment(true, to: nil)
        ForYouGridPage.applyHeroConcealment(false, to: nil)
    }

    /// A TEXT row hides WHOLE, and that is the same invariant reaching the
    /// opposite answer: it has no media, so the flight carries its entire
    /// card, so its entire card is what must be concealed. Leave it visible
    /// and the row and its flying twin are on screen together.
    @Test func aFlyingTextRowHidesWholeBecauseTheCardIsWhatFlies() {
        let cell = row(.text)
        #expect(cell.mediaHeroRect == nil, "a text row must have no media to fly")

        ForYouGridPage.applyHeroConcealment(true, to: cell)
        #expect(cell.isHidden == true)

        ForYouGridPage.applyHeroConcealment(false, to: cell)
        #expect(cell.isHidden == false)
    }

    /// And it has somewhere to fly FROM: the card's rect, which is what gives
    /// text posts a hero at all. Without it they fell back to a plain push —
    /// the one place in For You where opening a post did not fly.
    @Test func aTextRowOffersItsCardAsTheFlightsOrigin() {
        let cell = row(.text)

        #expect(cell.cardHeroRect != .zero)
        #expect(cell.cardHeroRect.width > 0)
        #expect(cell.cardHeroRect.height > 0)
    }
}
