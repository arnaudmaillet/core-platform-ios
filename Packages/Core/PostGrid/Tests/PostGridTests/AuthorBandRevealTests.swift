import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A list row can carry an author band above its caption, and the post's page
/// has no counterpart for it — a page carries its author in the nav pill.
///
/// These pin the consequence, which is not obvious and is silent when wrong: a
/// reveal must depart from BELOW the band, or the caption stops being
/// `captionTopInset` from the window's top edge, and that single coincidence is
/// what the whole registration rests on. Get it wrong and the transition still
/// runs, still lands, still completes — with the text sliding half a band out
/// of place on the way.
@MainActor
struct AuthorBandRevealTests {
    private static let rowWidth: CGFloat = 343
    private static let long = """
        Shipping the new build tonight. The changelog is longer than I expected: two \
        crashes that only reproduced on a cold launch, a migration that had been \
        silently no-oping since spring, and a rewrite of the retry logic that finally \
        makes sense.
        """
    private static let short = "Refactor landed and the office survived it."

    private static func post(_ caption: String, authored: Bool) -> GalleryPost {
        GalleryPost(
            id: PostID("post-0001"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: caption,
            publishedAtMS: 1_780_000_000_000,
            authorID: authored ? ProfileID("p1") : nil,
            authorName: authored ? "Ava Moreau" : nil,
            authorHandle: authored ? "ava" : nil
        )
    }

    private static func sized(_ caption: String, authored: Bool) -> PostGridListRowCell {
        let cell = PostGridListRowCell(
            frame: CGRect(x: 0, y: 0, width: rowWidth, height: 200)
        )
        cell.configure(
            with: post(caption, authored: authored),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = CGRect(x: 0, y: 0, width: rowWidth, height: 200)
        // The SIZE the collection view would assign, applied by hand.
        // `preferredLayoutAttributesFitting` only ANSWERS with a height; it does
        // not set one, so a cell left as built stays at its construction size
        // and every rect read off it is that size rather than the row's.
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        cell.bounds.size.height = fitted.frame.height
        cell.layoutIfNeeded()
        return cell
    }

    /// A post with no author identity has no band, and the flight departs from
    /// the card itself — the behaviour every profile gallery still gets.
    @Test func anUnauthoredRowDepartsFromItsWholeCard() {
        let cell = Self.sized(Self.short, authored: false)
        #expect(cell.revealBand.minY == 0)
        #expect(cell.revealBand.height == cell.bounds.height)
    }

    /// An authored row departs from below the band — the disc and the gap under
    /// it, exactly.
    @Test func anAuthoredRowDepartsFromBelowItsBand() {
        let cell = Self.sized(Self.short, authored: true)
        #expect(cell.revealBand.minY
            == PostGridListRowCell.authorAvatarDiameter + PostGridListRowCell.authorFollowGap)
        #expect(cell.revealBand.height == cell.bounds.height - cell.revealBand.minY)
    }

    /// THE INVARIANT. The band grows the card, and the flight's window must not
    /// notice: what it departs from is the same rectangle either way, because
    /// the band is excluded from it exactly.
    ///
    /// Within a point rather than exactly — the heights ceil a fractional text
    /// measurement, and `==` on fractional-scale `CGFloat`s is how this repo has
    /// failed CI before.
    @Test func theBandGrowsTheCardAndNotTheWindow() {
        let bare = Self.sized(Self.short, authored: false)
        let banded = Self.sized(Self.short, authored: true)
        #expect(banded.bounds.height > bare.bounds.height)
        #expect(abs(banded.revealBand.height - bare.revealBand.height) < 1)
    }

    /// And the cut is measured from the BAND's top, so a truncated caption's
    /// veil falls in the same place whether or not the row names its author.
    @Test func theCutIsUnmovedByTheBand() throws {
        let bare = try #require(Self.sized(Self.long, authored: false).revealCut)
        let banded = try #require(Self.sized(Self.long, authored: true).revealCut)
        #expect(abs(banded - bare) < 1)
    }
}
