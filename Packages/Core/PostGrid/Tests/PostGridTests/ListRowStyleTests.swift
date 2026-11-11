import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The post lists' rows (#2243; the only style since #2290): a text post's
/// row with no card, the hairlines between rows, the list's insets, and how a
/// post opens from where it is drawn. A shelf's card is the same cell in its
/// other dress.
@MainActor
struct ListRowStyleTests {
    private static let width: CGFloat = 394
    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func post(kind: GalleryPost.Kind = .text, author: Bool = true) -> GalleryPost {
        GalleryPost(
            id: PostID("post-1"), kind: kind, isRepost: false, thumbnailURL: nil,
            caption: "A short post.", publishedAtMS: 0,
            authorID: author ? ProfileID("ada") : nil, authorName: author ? "Ada Lovelace" : nil,
            authorHandle: author ? "ada" : nil,
            reactionCount: 160, commentCount: 3
        )
    }

    private static func cell(
        dress: PostGridListRowCell.Dress, separators: RowSeparators = .none
    ) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 140))
        cell.dress = dress
        cell.configure(with: post(), imagePipeline: pipeline)
        cell.rowSeparators = separators
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - The row

    /// A list's row: no ground, no corner, no edge — the row's words on the
    /// page.
    @Test func aTextRowHasNoCard() {
        let dress = Self.cell(dress: .row).debugDress
        #expect(dress.fill == .clear || dress.fill == nil)
        #expect(dress.cornerRadius == 0)
        #expect(dress.borderWidth == 0)
    }

    /// A shelf's text card (the cell's default dress) keeps the card: the
    /// shelves are not post lists.
    @Test func aShelfCardKeepsTheCard() {
        let dress = Self.cell(dress: .card).debugDress
        #expect(dress.fill == PostGridListRowCell.cardFillColor)
        #expect(dress.cornerRadius == PostGridListRowCell.cardCornerRadius)
        #expect(dress.borderWidth > 0)
        #expect(PostGridListRowCell(frame: .zero).dress == .card, "the default is the shelf's card")
    }

    /// A cell whose dress changes takes the new one both ways.
    @Test func theDressFollowsAChange() {
        let cell = Self.cell(dress: .row)
        cell.dress = .card
        #expect(cell.debugDress.cornerRadius == PostGridListRowCell.cardCornerRadius)
        cell.dress = .row
        #expect(cell.debugDress.cornerRadius == 0)
    }

    /// An inset hairline starts at the text column — after the avatar — and
    /// sits mid-gap under the row; a full one bleeds to the screen's edges.
    @Test func theHairlinesSitWhereTheyShould() throws {
        let cell = Self.cell(dress: .row, separators: RowSeparators(top: .full, bottom: .inset))
        let frames = cell.debugRuleFrames
        let bottom = try #require(frames.bottom)
        let top = try #require(frames.top)
        #expect(bottom.minX == PostGridListRowCell.separatorLeading(showsIdentity: true))
        #expect(abs(bottom.midY - (cell.bounds.height + PostGridListRowCell.separatorOffset)) < 0.01)
        #expect(top.minX == -PostGridListLayout.rowInset)
        #expect(abs(top.maxX - (cell.bounds.width + PostGridListLayout.rowInset)) < 0.01)
        #expect(top.midY < 0, "the top line sits in the gap above the row")
    }

    /// The text column after the avatar; the caption's column under a bare
    /// band, which has no avatar.
    @Test func theInsetIsTheTextColumn() {
        #expect(PostGridListRowCell.separatorLeading(showsIdentity: true)
            == PostGridListRowCell.captionInset + PostAuthorBandView.avatarDiameter + Spacing.sm)
        #expect(PostGridListRowCell.separatorLeading(showsIdentity: false) == PostGridListRowCell.captionInset)
    }

    /// No hairline is drawn on a shelf's card, whatever it was handed, nor on
    /// a row where the page asked for none.
    @Test func noHairlineOnACardOrWhereNoneIsAsked() {
        let card = Self.cell(dress: .card, separators: RowSeparators(top: .full, bottom: .inset)).debugRuleFrames
        #expect(card.top == nil && card.bottom == nil)
        let row = Self.cell(dress: .row, separators: .none).debugRuleFrames
        #expect(row.top == nil && row.bottom == nil)
    }

    // MARK: - The hairlines' placement

    /// Between two rows: one inset line, the upper row's.
    @Test func betweenTwoRowsOneInsetLine() {
        let upper = ListSeparators.separators(above: .none, below: .row)
        let lower = ListSeparators.separators(above: .row, below: .none)
        #expect(upper == RowSeparators(top: .none, bottom: .inset))
        #expect(lower == RowSeparators(top: .none, bottom: .none), "two lines between two rows")
    }

    /// Around tiles and a shelf: a full line, drawn by the row.
    @Test func aroundTilesAndShelvesAFullLine() {
        #expect(ListSeparators.separators(above: .row, below: .other).bottom == .full)
        #expect(ListSeparators.separators(above: .other, below: .row).top == .full)
        #expect(ListSeparators.separators(above: .other, below: .other) == RowSeparators(top: .full, bottom: .full))
    }

    /// None at the ends: not over the first row, not under the last, not
    /// next to a section's title.
    @Test func noneAtTheEnds() {
        #expect(ListSeparators.separators(above: .none, below: .none) == .none)
        #expect(ListSeparators.separators(above: .sectionHeader, below: .sectionHeader) == .none)
        #expect(ListSeparators.separators(above: .row, below: .sectionHeader).bottom == .none)
    }

    // MARK: - The list's insets

    /// A row stands `rowInset` from the screen so its words land on the
    /// page's margin — the tiles' edge — through the row's own inset; rows
    /// stand `rowSpacing` apart.
    @Test func aRowsWordsStandOnThePagesMargin() {
        #expect(PostGridListLayout.rowInset + PostGridListRowCell.contentInset == PostGridListLayout.sideMargin)
        #expect(PostGridListLayout.rowInset == 4)
        #expect(PostGridListLayout.rowSpacing == 8)
    }

    /// A run's section title keeps the page's margin although the run's
    /// insets narrowed.
    @Test func aTitleKeepsThePagesMargin() {
        #expect(PostGridListLayout.rowInset + PostGridListLayout.headerInsets.leading
            == PostGridListLayout.sideMargin)
        #expect(PostGridListLayout.headerInsets.leading == PostGridListLayout.headerInsets.trailing)
    }

    /// Discover's paired cards keep the gap they had (#2290 changes no value).
    @Test func thePairsKeepTheirGap() {
        #expect(DiscoverListLayout.pairGutter == PostGridListLayout.cardSpacing)
        #expect(PostGridListLayout.cardSpacing == 10)
    }

    // MARK: - The opening

    /// ⚠️ A LIST ROW NEVER OPENS THROUGH THE WINDOW (#2290): a row of words
    /// pushes natively, a picture flies — while a tile of words and a shelf's
    /// text card still open through it.
    @Test func theOpeningPerItem() {
        #expect(PostListOpening.opening(for: .listRow, hasMedia: false) == .push)
        #expect(PostListOpening.opening(for: .listRow, hasMedia: true) == .flight)
        #expect(PostListOpening.opening(for: .tile, hasMedia: true) == .flight)
        #expect(PostListOpening.opening(for: .tile, hasMedia: false) == .window)
        #expect(PostListOpening.opening(for: .shelfCard, hasMedia: false) == .window)
        #expect(PostListOpening.opening(for: .shelfCard, hasMedia: true) == .flight)
    }

    // MARK: - Tiles on the plain page

    /// A tile of words stays distinct on the plain page; a picture's ground is
    /// the media ground.
    @Test func aTextTileStaysDistinctOnThePlainPage() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        #expect(PostGridTileCell.fillColor(for: Self.post()) == Surface.cardOnPlainPage)
        #expect(PostGridTileCell.fillColor(for: Self.post()).resolvedColor(with: light)
            != Surface.plainPage.resolvedColor(with: light))
        #expect(PostGridTileCell.fillColor(for: Self.post(kind: .photo)) == Surface.mediaGround)
    }
}
