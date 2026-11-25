import CoreModels
import DesignSystem
import MediaCore
import MediaCoreFixtures
import Testing
import UIKit
@testable import PostGrid

/// The text post's closing line in two groups (#2441): `☆ ⇄ ↗` on the left,
/// icons only and close together; `💬 n` and `♥ n` in fixed slots on the
/// trailing margin, so the bubble and the heart stand at one x on every post.
@MainActor
struct ClosingLineGroupsTests {
    private static func post(likes: Int64?, comments: Int64?) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .text, isRepost: false,
            thumbnailURL: nil, caption: "Third coffee.", publishedAtMS: 0,
            authorID: ProfileID("a"), authorName: "Sofía", authorHandle: "sofia",
            reactionCount: likes, commentCount: comments
        )
    }

    private func row(
        likes: Int64? = 234, comments: Int64? = 78, dress: PostGridListRowCell.Dress = .row,
        repost: Bool = true, width: CGFloat = 375
    ) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.dress = dress
        cell.configure(
            with: Self.post(likes: likes, comments: comments),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.onBookmarkTapped = {}
        if repost { cell.onRepostTapped = {} }
        cell.onShareTapped = {}
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    private func control(_ label: String, in cell: PostGridListRowCell) throws -> CGRect {
        try #require(cell.closingLineControls.first { $0.label == label }?.frame)
    }

    // MARK: - The left group

    /// Save, repost, share, in that order, from me outward.
    @Test func theLeftGroupReadsSaveRepostShare() {
        let labels = row().closingLineControls.map(\.label)
        #expect(Array(labels.prefix(3)) == ["Save", "Repost", "Share"])
        #expect(Array(labels.suffix(2)) == ["Comments", "Likes"])
    }

    /// Each a 44 × 44 pt target, the glyphs about 41 pt apart centre to centre.
    @Test func theLeftGroupsGlyphsAreCloseTogetherWithFullTargets() throws {
        let cell = row()
        let frames = try ["Save", "Repost", "Share"].map { try control($0, in: cell) }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(abs((right.midX - left.midX) - PostGridListRowCell.leadingGlyphPitch) < 0.5)
        }
        for button in cell.debugLeftGroup {
            #expect(button.hitRegion.width >= 44 && button.hitRegion.height >= 44)
        }
    }

    /// The first glyph's INK on the text's 16 pt margin, the dress's column.
    @Test func theFirstGlyphsInkIsOnTheColumn() throws {
        let cell = row()
        let save = try #require(cell.debugLeftGroup.first)
        let box = save.convert(save.bounds, to: cell)
        let ink = box.minX + PostCardAction.inkLeading(save)
        #expect(abs(ink - PostGridListRowCell.closingLineInset(for: .row)) < 0.5, "ink at \(ink)")
    }

    /// No publish path for a repost yet (#801): the group closes up to ☆ ↗,
    /// on the same pitch.
    @Test func withNoRepostTheGroupIsSaveAndShare() throws {
        let cell = row(repost: false)
        #expect(Array(cell.closingLineControls.map(\.label).prefix(2)) == ["Save", "Share"])
        let save = try control("Save", in: cell)
        let share = try control("Share", in: cell)
        #expect(abs((share.midX - save.midX) - PostGridListRowCell.leadingGlyphPitch) < 0.5)
    }

    /// A share with no handler is not drawn, and the row says so to its menu.
    @Test func shareFollowsItsHandler() {
        let cell = row()
        #expect(cell.drawsShare)
        cell.onShareTapped = nil
        #expect(!cell.drawsShare)
        #expect(!cell.closingLineControls.contains { $0.label == "Share" })
    }

    // MARK: - The right slots

    /// "0 / 0", "5 / 78", "1.2K / 234" and "999K / 999K": the bubble and the
    /// heart at the same x on every post, the slots one fixed width.
    @Test func theBubbleAndTheHeartStandAtOneXWhateverTheCounts() throws {
        let counts: [(comments: Int64, likes: Int64)] = [(0, 0), (5, 78), (1_200, 234), (999_000, 999_000)]
        let rows = counts.map { row(likes: $0.likes, comments: $0.comments) }
        let bubbles = try rows.map { try control("Comments", in: $0) }
        let hearts = try rows.map { try control("Likes", in: $0) }
        for frame in bubbles + hearts {
            #expect(abs(frame.width - rows[0].countSlotWidth) < 0.5, "a slot of \(frame.width)")
        }
        for frame in bubbles.dropFirst() { #expect(abs(frame.minX - bubbles[0].minX) < 0.5) }
        for frame in hearts.dropFirst() { #expect(abs(frame.minX - hearts[0].minX) < 0.5) }
        // Comments, then the like last, under the thumb.
        #expect(bubbles[0].maxX <= hearts[0].minX)
    }

    /// The slot holds the widest count the app writes.
    @Test func theSlotHoldsTheWidestCount() {
        let cell = row()
        let widest = cell.debugCountSlots.map {
            $0.fittingSize(for: .init(symbol: $0.content.symbol, count: 999_000)).width
        }
        for width in widest { #expect(cell.countSlotWidth >= width - 0.5) }
    }

    /// No count at zero: the glyph alone, in its slot.
    @Test func aZeroCountDrawsTheGlyphAlone() {
        let cell = row(likes: 0, comments: 0)
        for slot in cell.debugCountSlots {
            #expect(!slot.isHidden)
            #expect(slot.content.count == nil, "\(slot.accessibilityLabel ?? "") writes a zero")
        }
    }

    /// A shelf's text card (#2417) holds both groups at its width: the slots
    /// narrow before anything clips.
    @Test func aShelfCardHoldsBothGroups() throws {
        let cell = row(likes: 1_200, comments: 999, dress: .card, width: 300)
        let share = try control("Share", in: cell)
        let bubble = try control("Comments", in: cell)
        #expect(share.maxX <= bubble.minX)
        for slot in cell.debugCountSlots {
            #expect(slot.bounds.width >= slot.fittingSize(for: slot.content).width - 0.5, "a count clipped")
        }
    }
}
