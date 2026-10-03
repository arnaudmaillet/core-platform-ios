import CoreGraphics
import Foundation
import PostGrid
import UIKit

/// The Following section as TWO INDEPENDENT ROWS under one heading —
/// pictures on top, words below, each its own horizontal scroller (the user's
/// call of 3 October 2026, replacing #375's two lanes in one scroller).
///
/// ```
///     Following 5 ›
///   ┌──────┐ ┌──────┐ ┌───       the media row: MEDIA posts only, the
///   │ ▶    │ │ ▶    │ │ ▶        Following cards (`ForYouFollowingCardCell`)
///   │ Ana  │ │ Bo   │ │          — scrolls on its own
///   └──────┘ └──────┘ └───
///   ┌───────────────┐ ┌────     the text row: TEXT posts only, each the
///   │ ◉ Cy @cy · 2h │ │ ◉ D     list's own card (`PostGridListRowCell`),
///   │ two lines of… │ │ two     two lines at most — scrolls on its own
///   │ ⎘ ⌑     💬 ♡ │ │ ⎘ ⌑
///   └───────────────┘ └────
/// ```
///
/// **Scrolling one row never moves the other.** Each is a collection view of
/// its own, with its own offset and its own rests; nothing ties a text card
/// to a pair of media columns any more, so the pair-snapping the shared
/// scroller needed is gone.
///
/// **A text card is the CLASSIC card**, the one Discover's list draws: the
/// author band, the caption, and the closing line with its repost, save,
/// comments and like — the like a real stake (`PostCardStaking.bind`), not
/// the compact cards' readout. Its caption stops at two lines with an
/// ellipsis and no "Show more" (`PostGridListRowCell.fixedCaptionLines`), and
/// its height is what that card needs for two lines at its width
/// (`textCardHeight(forWidth:)`). It opens and closes as the list's text
/// cards do (`ForYouRowOrigins.textCardReveal`).
///
/// **A text card is still two media cards and their gap wide** — kept,
/// although nothing aligns it to the columns now, because it is the one width
/// at which the text row reads like the media row: at 2.3 media cards per
/// width, `2 × card + gap` leaves exactly the media row's sliver of the next
/// item at the right edge (both rows' second item starts at the same x at
/// rest), so the two rows peek alike and say "this scrolls" the same way.
/// Sized on its own (say 1.3 cards per width, 284pt on a 402pt screen) the
/// text row would peek wider than the media row under it, and its two lines
/// would hold fewer words, for no gain. Each row comes to rest per card by
/// `RowEdgeSnap` — see `ForYouRailsView.snapTarget`.
///
/// **A row with nothing in it is not drawn**: no media posts, and the text
/// row sits right under the heading; no text posts, and the section is the
/// media row alone. The heading ("Following", its New count and link) stays
/// over whichever rows there are.
enum ForYouFollowingRows {
    /// A row, by the kind of post it holds.
    enum Row: CaseIterable {
        /// Photos and videos — the Following cards.
        case media
        /// Words alone: the list's card, two lines at most.
        case text

        init(_ post: GalleryPost) {
            self = post.kind == .text ? .text : .media
        }
    }

    /// The lines of words a text card shows; the rest is truncated.
    static let textLines = 2

    /// Each row's posts, in the section's order (unseen first, newest first).
    static func partition(_ posts: [GalleryPost]) -> (media: [GalleryPost], text: [GalleryPost]) {
        (posts.filter { Row($0) == .media }, posts.filter { Row($0) == .text })
    }

    /// A text card's width in a section `width` wide: two media cards and the
    /// gap between them — see the note on the type.
    @MainActor
    static func textCardWidth(forWidth width: CGFloat) -> CGFloat {
        ForYouRailsView.Metrics.cardSize(forWidth: width).width * 2 + ForYouRailsView.Metrics.itemGap
    }

    /// A text card's height in a section `width` wide: the list's card at
    /// `textCardWidth` with its caption filling `textLines` lines — band,
    /// words and closing line (`PostGridListRowCell.fixedTextCardHeight`).
    @MainActor
    static func textCardHeight(forWidth width: CGFloat) -> CGFloat {
        PostGridListRowCell.fixedTextCardHeight(
            width: textCardWidth(forWidth: width), captionLines: textLines
        )
    }

    @MainActor
    static func textCardSize(forWidth width: CGFloat) -> CGSize {
        CGSize(width: textCardWidth(forWidth: width), height: textCardHeight(forWidth: width))
    }

    /// The section's rows, stacked: the media row, the gap, the text row —
    /// or the one row there is. Zero with neither.
    @MainActor
    static func height(forWidth width: CGFloat, media: Int, text: Int) -> CGFloat {
        let hasMedia = media > 0, hasText = text > 0
        return (hasMedia ? ForYouRailsView.Metrics.cardSize(forWidth: width).height : 0)
            + (hasMedia && hasText ? rowGap : 0)
            // Measured only when there is a text card to size.
            + (hasText ? textCardHeight(forWidth: width) : 0)
    }

    /// Between the media row and the text row: the rows' item gap, so the
    /// two read as one section rather than two.
    @MainActor
    static var rowGap: CGFloat { ForYouRailsView.Metrics.itemGap }
}
