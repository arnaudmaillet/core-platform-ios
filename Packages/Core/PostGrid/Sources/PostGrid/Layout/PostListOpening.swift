/// How a post opens from where it is drawn (#2243; the only rule since #2290)
/// — the rule a close then follows (the owner, 2026-11-01: a screen closes
/// the way it opened).
public enum PostListOpening: Equatable, Sendable {
    /// The stack's own push, closed by its own pop — a list row of words: it
    /// has no card shape for a window to grow from.
    case push
    /// The zoom flight: there is a picture at both ends.
    case flight
    /// The text window: a tile or a shelf's card grows into the page, and
    /// shrinks back.
    case window

    /// What a post is drawn as.
    public enum Item: Equatable, Sendable {
        /// A vertical list's row (`PostGridListRowCell`, dressed `.row`).
        case listRow
        /// A media tile, or a tile of words (a mosaic's, a chunk's).
        case tile
        /// A horizontal shelf's card (Following, the PostShelf rails).
        case shelfCard
    }

    /// The opening for a post drawn as `item`; `hasMedia` is whether it has a
    /// picture to fly.
    ///
    /// A list ROW of words opens as Threads, X and Bluesky open a post, with
    /// the native push: the window grows a card into the page, and a row has
    /// no card to grow from. A picture flies; a tile of words and a shelf's
    /// text card keep the window.
    public static func opening(for item: Item, hasMedia: Bool) -> PostListOpening {
        if hasMedia { return .flight }
        return item == .listRow ? .push : .window
    }
}
