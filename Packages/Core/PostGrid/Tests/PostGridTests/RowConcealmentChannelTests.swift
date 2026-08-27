import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A row is concealed on ONE of two channels and must be restored on BOTH.
///
/// ## Why this is a suite and not a line
///
/// Which channel a row uses is a property of the post it is bound to: a media
/// row hides its PREVIEW (the flight carries the photograph), a text row hides
/// the whole CARD (the reveal carries the card itself). The routing therefore
/// reads mutable state — is there a preview showing — and a flight outlives it.
/// A row concealed as text and reconfigured as media is restored through the
/// media branch, which clears a concealment that was never set and leaves the
/// card at alpha 0.
///
/// What that looks like: an invisible card that still holds its slot — a hole
/// in the feed, one card tall, that nothing later goes back to fix. Reported
/// after several hero round trips, because each trip can leave another.
@MainActor
struct RowConcealmentChannelTests {
    private func post(_ kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID("post-\(kind)"),
            kind: kind,
            isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "mock://photo/1"),
            caption: "Golden hour over the harbour.",
            publishedAtMS: 0,
            reactionCount: 160,
            commentCount: 12,
            viewCount: 4_200
        )
    }

    private func row(_ kind: GalleryPost.Kind) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 520))
        configure(cell, as: kind)
        return cell
    }

    private func configure(_ cell: PostGridListRowCell, as kind: GalleryPost.Kind) {
        cell.configure(with: post(kind), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
    }

    /// The card is the channel a text row uses, so `alpha` is where the answer
    /// lives. Read through the view tree rather than a flag: the flag is what
    /// went missing, and a test that read it would have agreed with the bug.
    private func cardAlpha(of cell: PostGridListRowCell) -> CGFloat? {
        cell.contentView.subviews.first?.alpha
    }

    /// The plain case, so the ones below are read as deviations from it.
    @Test func aTextRowIsConcealedAndRestoredOnTheCard() {
        let cell = row(.text)

        cell.setHeroConcealed(true)
        #expect(cardAlpha(of: cell) == 0)

        cell.setHeroConcealed(false)
        #expect(cardAlpha(of: cell) == 1)
    }

    /// ⚠️ THE DEFECT: concealed as TEXT, restored as MEDIA.
    ///
    /// The row is reconfigured mid-flight — which is ordinary, since a
    /// dismissal moves the landed post into the departure slot — and the
    /// restore then routes on the NEW post's shape.
    @Test func aRowConcealedAsTextIsRestoredEvenAfterItGainsMedia() {
        let cell = row(.text)
        cell.setHeroConcealed(true)
        #expect(cardAlpha(of: cell) == 0)

        configure(cell, as: .photo)
        cell.setHeroConcealed(false)

        #expect(cardAlpha(of: cell) == 1, "the card stayed invisible and kept its slot — a hole")
    }

    /// And the mirror, which the same asymmetry would produce the other way
    /// round: concealed with a preview, restored without one.
    @Test func aRowConcealedAsMediaIsRestoredEvenAfterItLosesIt() {
        let cell = row(.photo)
        cell.setHeroConcealed(true)
        #expect(cell.isHeroMediaConcealed)

        configure(cell, as: .text)
        cell.setHeroConcealed(false)

        #expect(cell.isHeroMediaConcealed == false)
        #expect(cardAlpha(of: cell) == 1)
    }

    /// ⚠️ AND A RECYCLED ROW CARRIES NOTHING, on either channel.
    ///
    /// `prepareForReuse` reset the media channel and named itself "BOTH
    /// channels" while there were three.
    ///
    /// Asserted at the moment reuse ENDS rather than after the next configure:
    /// configuring happens to reset the alpha as well, so a test that looked
    /// afterwards agreed with the bug and with the fix alike. What this pins is
    /// that a row handed back to the queue is clean — which is the promise
    /// `prepareForReuse` makes, and the only one that holds for a cell nothing
    /// reconfigures before it is measured.
    @Test func reuseClearsEveryChannel() {
        let cell = row(.text)
        cell.setHeroConcealed(true)

        cell.prepareForReuse()

        #expect(cardAlpha(of: cell) == 1, "a row went back to the queue invisible")
        #expect(cell.isHeroMediaConcealed == false)
    }

    /// Restoring what was never concealed is a no-op, which is what makes
    /// restoring both channels safe.
    @Test func restoringTwiceIsHarmless() {
        let cell = row(.photo)

        cell.setHeroConcealed(false)
        cell.setHeroConcealed(false)

        #expect(cardAlpha(of: cell) == 1)
        #expect(cell.isHeroMediaConcealed == false)
    }
}
