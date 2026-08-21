import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A list row can carry an author band above its caption, and the post's page
/// has no counterpart for it — a page carries its author in the nav pill.
///
/// The first design had the flight DEPART from below the band, which kept the
/// caption `captionTopInset` from the window's top at both ends and left the
/// registration alone. Frames killed it: a window that stops short of the
/// card's top leaves the band outside the transition entirely, so the card
/// gains it in one frame at the landing — a cut exactly where this is supposed
/// to be seamless.
///
/// So the window is the whole card and the offset is CARRIED. These pin the two
/// numbers that carry it, and the fact that the band moves neither the cut nor
/// the caption's own measurement.
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

    /// A post with no author identity has no band, so its caption starts at the
    /// card's own inset and the transition needs no offset at all — the
    /// behaviour every profile gallery still gets.
    @Test func anUnauthoredRowHasNoCaptionOffset() {
        #expect(Self.sized(Self.short, authored: false).revealCaptionTop == 0)
    }

    /// An authored one offsets by the disc and the gap under it, exactly.
    @Test func anAuthoredRowOffsetsByItsBand() {
        #expect(Self.sized(Self.short, authored: true).revealCaptionTop
            == PostGridListRowCell.authorAvatarDiameter + PostGridListRowCell.authorFollowGap)
    }

    /// The band grows the card by exactly the offset it declares — which is
    /// what makes the offset usable as a pose term rather than an estimate.
    ///
    /// Within a point rather than exactly: the heights ceil a fractional text
    /// measurement, and `==` on fractional-scale `CGFloat`s is how this repo has
    /// failed CI before.
    @Test func theBandGrowsTheCardByTheOffsetItDeclares() {
        let bare = Self.sized(Self.short, authored: false)
        let banded = Self.sized(Self.short, authored: true)
        #expect(abs((banded.bounds.height - bare.bounds.height) - banded.revealCaptionTop) < 1)
    }

    /// And the cut does not move, because it is measured in the DESTINATION's
    /// register — from where the caption starts, never from the card's edge.
    /// The veil is hung inside the page, whose caption row has no band.
    @Test func theCutIsUnmovedByTheBand() throws {
        let bare = try #require(Self.sized(Self.long, authored: false).revealCut)
        let banded = try #require(Self.sized(Self.long, authored: true).revealCut)
        #expect(abs(banded - bare) < 1)
    }

    /// Including for a whole caption, where the cut is the card's height LESS
    /// the band — the page's equivalent of "everything the card has".
    @Test func theCutIsUnmovedForAWholeCaptionToo() throws {
        let bare = try #require(Self.sized(Self.short, authored: false).revealCut)
        let banded = try #require(Self.sized(Self.short, authored: true).revealCut)
        #expect(abs(banded - bare) < 1)
    }
}
