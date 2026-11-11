import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// One column on both sides of a list's row (#2289, the owner 2026-11-11):
/// the band, the caption, the "..." glyph and the closing line's first and
/// last ink all stand on the caption's column — 16pt from the screen with the
/// row's own inset (`PostGridListLayout.rowInset`) — where a shelf's card
/// keeps its own columns (the closing line one plain padding further in).
///
/// Measured on the drawn INK (the glyph's alignment rect, the count's label),
/// never on the hang the cell computed: a hang that agreed with itself would
/// pass either way.
@MainActor
struct RowColumnTests {
    private static let width: CGFloat = 370
    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func post(kind: GalleryPost.Kind = .text, author: Bool = true) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: kind, isRepost: false,
            pages: kind == .text ? [] : [GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://photo/1"))],
            caption: "A note that is long enough to wrap onto a second line of the row's caption.",
            publishedAtMS: 0,
            authorID: author ? ProfileID("a") : nil, authorName: author ? "Sofía" : nil,
            authorHandle: author ? "sofia" : nil,
            reactionCount: 160, commentCount: 12
        )
    }

    /// A row the way For You wires one: both secondary actions, a "...".
    private func cell(
        _ dress: PostGridListRowCell.Dress, kind: GalleryPost.Kind = .text, author: Bool = true, saves: Bool = true
    ) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        cell.dress = dress
        cell.configure(with: Self.post(kind: kind, author: author), imagePipeline: Self.pipeline)
        // No repost and no save (the viewer's own post): the date leads the
        // closing line.
        if saves {
            cell.onRepostTapped = {}
            cell.onBookmarkTapped = {}
        }
        cell.authorMenuActions = { [.report(perform: {})] }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    private func walk<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { walk($0, type) }
    }

    private func shown<T: UIView>(_ cell: PostGridListRowCell, _ type: T.Type) -> [T] {
        walk(cell.contentView, type).filter { !$0.isHidden && $0.superviewChainIsVisible }
    }

    /// The closing line's actions, left to right: save, repost, comments, likes.
    private func line(_ cell: PostGridListRowCell) -> [AppIconButton] {
        shown(cell, AppIconButton.self)
            .sorted { $0.convert($0.bounds, to: cell.contentView).minX < $1.convert($1.bounds, to: cell.contentView).minX }
    }

    /// A glyph's INK in the cell's space: its image view less the symbol's
    /// alignment insets, which is how the button lays it.
    private func ink(of button: UIButton, in cell: PostGridListRowCell) throws -> CGRect {
        let image = try #require(button.imageView)
        let insets = image.image?.alignmentRectInsets ?? .zero
        return image.convert(image.bounds.inset(by: insets), to: cell.contentView)
    }

    /// Where the closing line's first ink starts and its last ink ends, from
    /// the cell's edges.
    private func lineInk(_ cell: PostGridListRowCell) throws -> (leading: CGFloat, trailing: CGFloat) {
        let actions = line(cell)
        try #require(actions.count == 4)
        let save = try ink(of: actions[0], in: cell)
        let count = try #require(actions[3].titleLabel)
        let text = count.convert(count.bounds, to: cell.contentView)
        return (save.minX, cell.contentView.bounds.maxX - text.maxX)
    }

    /// Where the "..." glyph's ink ends, from the cell's trailing edge.
    private func menuInk(_ cell: PostGridListRowCell) throws -> CGFloat {
        let menu = try #require(shown(cell, UIButton.self).first { $0.accessibilityLabel == "More actions" })
        let glyph = try ink(of: menu, in: cell)
        return cell.contentView.bounds.maxX - glyph.maxX
    }

    // MARK: - A row: one column, both sides

    /// The closing line's first ink (the save glyph) and its last (the like
    /// count) stand on the caption's column, a text row and a media row alike.
    @Test func aRowsClosingLineStandsOnTheCaptionsColumn() throws {
        for kind in [GalleryPost.Kind.text, .photo] {
            let ends = try lineInk(cell(.row, kind: kind))
            #expect(abs(ends.leading - PostGridListRowCell.captionInset) < 1, "\(kind): first ink at \(ends.leading)")
            #expect(abs(ends.trailing - PostGridListRowCell.captionInset) < 1, "\(kind): last ink at \(ends.trailing)")
        }
    }

    /// The "..." glyph's ink ends on the caption's column too — over the
    /// closing line's last count — under an identity band and a bare one.
    @Test func aRowsMenuGlyphEndsOnTheCaptionsColumn() throws {
        for author in [true, false] {
            let trailing = try menuInk(self.cell(.row, author: author))
            #expect(abs(trailing - PostGridListRowCell.captionInset) < 1, "author \(author): ... ink at \(trailing)")
        }
        let row = cell(.row)
        let menuEnd = try menuInk(row)
        let lineEnd = try lineInk(row).trailing
        #expect(abs(menuEnd - lineEnd) < 1, "the ... and the last count on one column")
    }

    /// The band, the caption and the voice panel lead on the caption's column
    /// (unchanged): the left side of the one column.
    @Test func aRowsBandLeadsOnTheCaptionsColumn() throws {
        let row = cell(.row)
        let band = try #require(shown(row, PostAuthorBandView.self).first)
        #expect(abs(band.convert(band.bounds, to: row.contentView).minX - PostGridListRowCell.captionInset) < 0.5)
    }

    /// Under a bare band with no save (the viewer's own post) the date leads
    /// the closing line, on the caption's column too.
    @Test func aRowsLeadingDateStandsOnTheCaptionsColumn() throws {
        let row = cell(.row, author: false, saves: false)
        let age = PostMetadata.compactAge(ofMillis: 0)
        // The closing line's date: the lowest label with the age (a bare band
        // may say it too, beside its face).
        let dates = shown(row, UILabel.self).filter { $0.text == age }
        let date = try #require(dates.max {
            $0.convert($0.bounds, to: row.contentView).maxY < $1.convert($1.bounds, to: row.contentView).maxY
        })
        #expect(abs(date.convert(date.bounds, to: row.contentView).minX - PostGridListRowCell.captionInset) < 0.5,
                "the closing line's date at \(date.convert(date.bounds, to: row.contentView).minX), of \(dates.count)")
    }

    /// On a row, the whole column stands 16pt from the screen on both sides:
    /// the row's inset plus the caption's.
    @Test func theColumnIsSixteenFromTheScreen() {
        let column = PostGridListLayout.rowInset + PostGridListRowCell.closingLineInset(for: .row)
        #expect(column == 16)
        #expect(column == PostGridListLayout.sideMargin)
        #expect(PostGridListLayout.rowInset + PostGridListRowCell.captionInset == column)
    }

    /// A press's capsule spills into the margin on a row, never off the row.
    @Test func aRowsBoxesStayOnTheRow() {
        let row = cell(.row)
        for action in line(row) {
            let box = action.convert(action.bounds, to: row.contentView)
            #expect(box.minX >= 0 && box.maxX <= row.contentView.bounds.maxX, "\(box)")
        }
    }

    // MARK: - A shelf's card: unchanged

    /// A card keeps its columns: the closing line one plain padding inside the
    /// caption's (`actionLineInset`), the "..." control's box on the caption's.
    @Test func aCardKeepsItsColumns() throws {
        let card = cell(.card)
        let ends = try lineInk(card)
        #expect(abs(ends.leading - PostGridListRowCell.actionLineInset) < 1, "first ink at \(ends.leading)")
        #expect(abs(ends.trailing - PostGridListRowCell.actionLineInset) < 1, "last ink at \(ends.trailing)")
        let menu = try #require(shown(card, UIButton.self).first { $0.accessibilityLabel == "More actions" })
        let box = menu.convert(menu.bounds, to: card.contentView)
        #expect(abs(card.contentView.bounds.maxX - box.maxX - PostGridListRowCell.captionInset) < 0.5)
    }

    /// The shared constants do not move (the post's page and the windows are
    /// built on them); only the dress picks its column.
    @Test func theSharedConstantsDoNotMove() {
        #expect(PostGridListRowCell.contentInset == 12)
        #expect(PostGridListRowCell.captionInset == 12)
        #expect(PostGridListRowCell.actionLineInset == 20)
        #expect(PostGridListRowCell.closingLineInset(for: .card) == PostGridListRowCell.actionLineInset)
        #expect(PostGridListRowCell.closingLineInset(for: .row) == PostGridListRowCell.captionInset)
        #expect(PostGridListRowCell.bandTrailingInset(for: .card) == PostGridListRowCell.captionInset)
        #expect(PostGridListRowCell.bandTrailingInset(for: .row)
            == PostGridListRowCell.captionInset - PostAuthorBandView.menuInkTrailing)
        #expect(PostAuthorBandView.menuInkTrailing > 0
            && PostAuthorBandView.menuInkTrailing < PostAuthorBandView.actionControlWidth / 2)
    }

    /// A cell whose dress changes takes the other column, both ways.
    @Test func theColumnFollowsTheDress() throws {
        let flipped = cell(.card)
        flipped.dress = .row
        flipped.layoutIfNeeded()
        let rowLead = try lineInk(flipped).leading
        let rowMenu = try menuInk(flipped)
        #expect(abs(rowLead - PostGridListRowCell.captionInset) < 1)
        #expect(abs(rowMenu - PostGridListRowCell.captionInset) < 1)
        flipped.dress = .card
        flipped.layoutIfNeeded()
        let cardLead = try lineInk(flipped).leading
        #expect(abs(cardLead - PostGridListRowCell.actionLineInset) < 1)
    }

    // MARK: - The skeleton

    /// The skeleton row follows the same column on both sides, and draws the
    /// same full-width hairline mid-gap under it.
    @Test func theSkeletonFollowsTheColumnAndTheLine() throws {
        let skeleton = PostGridSkeletonRow()
        skeleton.frame = CGRect(x: 0, y: 0, width: Self.width, height: 120)
        skeleton.layoutIfNeeded()
        let bones = walk(skeleton, SkeletonBoneView.self).filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: skeleton) }
        let widest = try #require(bones.max { $0.width < $1.width })
        #expect(abs(widest.minX - PostGridListRowCell.captionInset) < 0.5)
        #expect(abs(skeleton.bounds.maxX - widest.maxX - PostGridListRowCell.captionInset) < 0.5)
        let rule = skeleton.debugRuleFrame
        #expect(rule.minX == -PostGridListLayout.rowInset)
        #expect(abs(rule.maxX - (Self.width + PostGridListLayout.rowInset)) < 0.01)
        #expect(abs(rule.midY - (skeleton.bounds.height + PostGridListRowCell.separatorOffset)) < 0.01)
    }
}
