import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The list's card at a FIXED height (`PostGridListRowCell.fixedCaptionLines`)
/// — For You's Following row draws its text posts this way, in a lane of one
/// height: the caption held to its lines with the label's own ellipsis and no
/// "Show more", the closing line at the card's foot whatever the caption's
/// length, and the stand-in a close lands as drawn the same way.
@MainActor
struct FixedCaptionCardTests {
    private static let long = String(repeating: "A long post that goes on and on about nothing much. ", count: 10)
    private static let width: CGFloat = 322

    private static func post(caption: String) -> GalleryPost {
        GalleryPost(
            id: PostID("post-1"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 0,
            authorID: ProfileID("ada"), authorName: "Ada Lovelace", authorHandle: "ada",
            reactionCount: 160, commentCount: 3
        )
    }

    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    /// A card in the lane: configured at its size, wired like the lane wires
    /// it (repost, save, a staking like), and laid out.
    private static func card(caption: String, lines: Int? = 2) -> PostGridListRowCell {
        let height = PostGridListRowCell.fixedTextCardHeight(width: width, captionLines: 2)
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: height))
        cell.configure(with: post(caption: caption), imagePipeline: pipeline, captionLines: lines)
        cell.onRepostTapped = {}
        cell.onBookmarkTapped = {}
        cell.onStake = { _ in }
        cell.layoutIfNeeded()
        return cell
    }

    @Test func theCaptionStopsAtItsLinesWithAnEllipsisAndNoShowMore() {
        let cell = Self.card(caption: Self.long)
        #expect(cell.fixedCaptionLines == 2)
        #expect(cell.debugCaptionLineLimit == 2)
        #expect(cell.debugCaptionLineBreakMode == .byTruncatingTail, "the label's own ellipsis")
        #expect(!cell.debugShowsMoreAffordance, "no Show more on a card that cannot grow")
        #expect(cell.debugTapShowMore() == false)
        // Two lines tall, not one and not four.
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
        #expect(cell.debugCaptionFrame.height > line * 1.5)
        #expect(cell.debugCaptionFrame.height < line * 2.6)
        // Its actions: the list's whole closing line.
        #expect(cell.visibleRowActions.repost && cell.visibleRowActions.bookmark)
    }

    /// The measured height IS what the long card needs: it fits, nothing
    /// clipped, and the closing line ends at the card's foot inset.
    @Test func theMeasuredHeightFitsTwoLines() {
        let height = PostGridListRowCell.fixedTextCardHeight(width: Self.width, captionLines: 2)
        let cell = Self.card(caption: Self.long)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: Self.width, height: 999)
        #expect(cell.preferredLayoutAttributesFitting(attributes).frame.height == height)
        let line = cell.debugClosingLineFrame
        #expect(!line.isNull)
        #expect(abs(line.maxY - (height - PostGridListRowCell.metaBottomInset)) < 0.5, "\(line)")
        #expect(cell.debugCaptionFrame.maxY <= line.minY - PostGridListRowCell.captionFollowGap + 0.5)
        // Taller than a one-line card would need, shorter than four lines'.
        #expect(height > PostGridListRowCell.fixedTextCardHeight(width: Self.width, captionLines: 1))
        #expect(height < PostGridListRowCell.fixedTextCardHeight(width: Self.width, captionLines: 4))
    }

    /// A one-line caption in a two-line card: the words stay under the band,
    /// the closing line stays at the foot — the air goes between them.
    @Test func aShortCaptionKeepsTheClosingLineAtTheFoot() {
        let long = Self.card(caption: Self.long)
        let short = Self.card(caption: "Third coffee.")
        #expect(short.debugCaptionFrame.minY == long.debugCaptionFrame.minY)
        #expect(short.debugCaptionFrame.height < long.debugCaptionFrame.height)
        #expect(short.debugClosingLineFrame == long.debugClosingLineFrame)
    }

    /// A recycled cell is the list's card again: four lines, word wrap and
    /// "Show more".
    @Test func reuseRestoresTheListsCard() {
        let cell = Self.card(caption: Self.long)
        cell.prepareForReuse()
        cell.configure(with: Self.post(caption: Self.long), imagePipeline: Self.pipeline)
        #expect(cell.fixedCaptionLines == nil)
        #expect(cell.debugCaptionLineLimit == PostGridListRowCell.captionLineLimit)
        #expect(cell.debugCaptionLineBreakMode == .byWordWrapping)
    }

    /// The close's stand-in, told the same lines and the card's height, draws
    /// the card: the same caption box and the same closing line.
    @Test func theStandInIsTheFixedCard() throws {
        let cell = Self.card(caption: Self.long)
        let standIn = RevealDismissCardView(
            post: Self.post(caption: Self.long), width: Self.width, imagePipeline: Self.pipeline,
            actions: .init(repost: true, bookmark: true, saved: false, stake: 0),
            height: cell.bounds.height, captionLines: 2
        )
        standIn.frame = cell.bounds
        standIn.layoutIfNeeded()
        let card = try #require(standIn.subviews.first as? PostGridListRowCell)
        #expect(card.fixedCaptionLines == 2)
        #expect(card.bounds.size == cell.bounds.size)
        #expect(card.debugCaptionFrame == cell.debugCaptionFrame)
        #expect(card.debugClosingLineFrame == cell.debugClosingLineFrame)
    }

    /// The window's cut: a caption cut short ends where its two lines do, not
    /// at the card's foot — the page below it is veiled.
    @Test func aCutCaptionTellsTheRevealWhereItStops() {
        let cut = Self.card(caption: Self.long)
        #expect(cut.revealCut.map { $0 < cut.bounds.height - cut.revealCaptionTop } == true)
        let whole = Self.card(caption: "Third coffee.")
        #expect(whole.revealCut == whole.bounds.height - whole.revealCaptionTop)
    }
}
