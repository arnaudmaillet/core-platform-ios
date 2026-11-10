import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The flat post lists of #2243: a text post's row with no card, the
/// hairlines between rows, the list's insets, and how a post opens from
/// where it is drawn — each in both styles.
@MainActor
struct FlatListStyleTests {
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

    private static func row(style: PostListStyle, separators: FlatRowSeparators = .none) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 140))
        cell.listStyle = style
        cell.configure(with: post(), imagePipeline: pipeline)
        cell.flatSeparators = separators
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - The row

    /// Flat: no ground, no corner, no edge — the row's words on the page.
    @Test func aFlatTextRowHasNoCard() {
        let dress = Self.row(style: .flat).debugCardDress
        #expect(dress.fill == .clear || dress.fill == nil)
        #expect(dress.cornerRadius == 0)
        #expect(dress.borderWidth == 0)
    }

    /// Cards (the default): today's card, untouched.
    @Test func theCardsStyleKeepsTodaysCard() {
        let dress = Self.row(style: .cards).debugCardDress
        #expect(dress.fill == PostGridListRowCell.cardFillColor)
        #expect(dress.cornerRadius == PostGridListRowCell.cardCornerRadius)
        #expect(dress.borderWidth > 0)
    }

    /// A recycled row moving between styles takes the new dress both ways.
    @Test func theDressFollowsAStyleChange() {
        let cell = Self.row(style: .flat)
        cell.listStyle = .cards
        #expect(cell.debugCardDress.cornerRadius == PostGridListRowCell.cardCornerRadius)
        cell.listStyle = .flat
        #expect(cell.debugCardDress.cornerRadius == 0)
    }

    /// An inset hairline starts at the text column — after the avatar — and
    /// sits mid-gap under the row; a full one bleeds to the screen's edges.
    @Test func theHairlinesSitWhereTheyShould() throws {
        let cell = Self.row(style: .flat, separators: FlatRowSeparators(top: .full, bottom: .inset))
        let frames = cell.debugFlatRuleFrames
        let bottom = try #require(frames.bottom)
        let top = try #require(frames.top)
        #expect(bottom.minX == PostGridListRowCell.flatSeparatorLeading(showsIdentity: true))
        #expect(abs(bottom.midY - (cell.bounds.height + PostGridListRowCell.flatSeparatorOffset)) < 0.01)
        #expect(top.minX == -PostGridListLayout.flatRowInset)
        #expect(abs(top.maxX - (cell.bounds.width + PostGridListLayout.flatRowInset)) < 0.01)
        #expect(top.midY < 0, "the top line sits in the gap above the row")
    }

    /// The text column after the avatar; the caption's column under a bare
    /// band, which has no avatar.
    @Test func theInsetIsTheTextColumn() {
        #expect(PostGridListRowCell.flatSeparatorLeading(showsIdentity: true)
            == PostGridListRowCell.captionInset + PostAuthorBandView.avatarDiameter + Spacing.sm)
        #expect(PostGridListRowCell.flatSeparatorLeading(showsIdentity: false) == PostGridListRowCell.captionInset)
    }

    /// No hairline is drawn in the cards style, whatever the page decided,
    /// nor where the page asked for none.
    @Test func noHairlineUnderCardsOrWhereNoneIsAsked() {
        let cards = Self.row(style: .cards, separators: FlatRowSeparators(top: .full, bottom: .inset)).debugFlatRuleFrames
        #expect(cards.top == nil && cards.bottom == nil)
        let flat = Self.row(style: .flat, separators: .none).debugFlatRuleFrames
        #expect(flat.top == nil && flat.bottom == nil)
    }

    // MARK: - The hairlines' placement

    /// Between two rows: one inset line, the upper row's.
    @Test func betweenTwoRowsOneInsetLine() {
        let upper = FlatListSeparators.separators(above: .none, below: .row)
        let lower = FlatListSeparators.separators(above: .row, below: .none)
        #expect(upper == FlatRowSeparators(top: .none, bottom: .inset))
        #expect(lower == FlatRowSeparators(top: .none, bottom: .none), "two lines between two rows")
    }

    /// Around tiles and a shelf: a full line, drawn by the row.
    @Test func aroundTilesAndShelvesAFullLine() {
        #expect(FlatListSeparators.separators(above: .row, below: .other).bottom == .full)
        #expect(FlatListSeparators.separators(above: .other, below: .row).top == .full)
        #expect(FlatListSeparators.separators(above: .other, below: .other) == FlatRowSeparators(top: .full, bottom: .full))
    }

    /// None at the ends: not over the first row, not under the last, not
    /// next to a section's title.
    @Test func noneAtTheEnds() {
        #expect(FlatListSeparators.separators(above: .none, below: .none) == .none)
        #expect(FlatListSeparators.separators(above: .sectionHeader, below: .sectionHeader) == .none)
        #expect(FlatListSeparators.separators(above: .row, below: .sectionHeader).bottom == .none)
    }

    // MARK: - The list's insets

    /// A flat row stands `flatRowInset` from the screen so its words land on
    /// the page's margin — the tiles' edge — through the row's own inset.
    @Test func aFlatRowsWordsStandOnThePagesMargin() {
        #expect(PostGridListLayout.flatRowInset + PostGridListRowCell.contentInset == PostGridListLayout.sideMargin)
        #expect(PostGridListLayout.rowSideInset(for: .cards) == PostGridListLayout.sideMargin)
        #expect(PostGridListLayout.rowSideInset(for: .flat) == PostGridListLayout.flatRowInset)
        #expect(PostGridListLayout.rowSpacing(for: .cards) == PostGridListLayout.rowSpacing)
        #expect(PostGridListLayout.rowSpacing(for: .flat) == PostGridListLayout.flatRowSpacing)
    }

    /// A section's title keeps the page's margin in both styles.
    @Test func aTitleKeepsThePagesMargin() {
        #expect(PostGridListLayout.headerInsets(for: .cards).leading == 0)
        #expect(PostGridListLayout.rowSideInset(for: .flat) + PostGridListLayout.headerInsets(for: .flat).leading
            == PostGridListLayout.sideMargin)
    }

    // MARK: - The opening

    /// Per style and per item: only a flat row of words pushes natively; a
    /// picture always flies; a shelf's text card and the cards style keep the
    /// window.
    @Test func theOpeningPerStyleAndPerItem() {
        #expect(PostListOpening.opening(for: .listRow, hasMedia: false, style: .flat) == .push)
        #expect(PostListOpening.opening(for: .listRow, hasMedia: false, style: .cards) == .window)
        #expect(PostListOpening.opening(for: .listRow, hasMedia: true, style: .flat) == .flight)
        #expect(PostListOpening.opening(for: .tile, hasMedia: true, style: .flat) == .flight)
        #expect(PostListOpening.opening(for: .tile, hasMedia: false, style: .flat) == .window)
        #expect(PostListOpening.opening(for: .shelfCard, hasMedia: false, style: .flat) == .window)
        #expect(PostListOpening.opening(for: .shelfCard, hasMedia: true, style: .cards) == .flight)
    }

    // MARK: - Tiles on the flat page

    /// A tile of words stays distinct on the flat page; a picture's ground is
    /// the media ground in both styles.
    @Test func aTextTileStaysDistinctOnTheFlatPage() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let text = Self.post()
        #expect(PostGridTileCell.fillColor(for: text, style: .cards) == Surface.card)
        #expect(PostGridTileCell.fillColor(for: text, style: .flat).resolvedColor(with: light)
            != PostListStyle.flat.pageGround.resolvedColor(with: light))
        #expect(PostGridTileCell.fillColor(for: Self.post(kind: .photo), style: .flat) == Surface.mediaGround)
    }
}
