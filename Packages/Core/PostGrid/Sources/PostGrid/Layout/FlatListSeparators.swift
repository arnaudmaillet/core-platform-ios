import DesignSystem

/// A hairline a FLAT list row draws (#2243): none, one inset to the text
/// column — between two posts, as Threads draws it — or one across the whole
/// width, where the list meets something that is not a row (a block of
/// tiles, a shelf).
public enum FlatRowSeparator: Equatable, Sendable {
    case none
    /// From the text column (after the avatar) to the trailing margin.
    case inset
    /// Edge to edge.
    case full
}

/// The two hairlines one flat row draws, above and below it.
public struct FlatRowSeparators: Equatable, Sendable {
    public var top: FlatRowSeparator
    public var bottom: FlatRowSeparator

    public init(top: FlatRowSeparator, bottom: FlatRowSeparator) {
        self.top = top
        self.bottom = bottom
    }

    public static let none = FlatRowSeparators(top: .none, bottom: .none)
}

/// Where the hairlines of a flat list go (#2243) — pure, so the placement is
/// a table rather than a reading of whichever cell happened to be realized.
///
/// ```
///   [shelf / tiles]
///   ──────────────────────  full: the row's TOP, under something not a row
///   ◯ row
///       ────────────────     inset: between two rows, the upper one's BOTTOM
///   ◯ row
///   ──────────────────────  full: the row's BOTTOM, over something not a row
///   [tiles]
///   ◯ row                    no line under a list's last row,
///   ┄┄ (end) ┄┄              nor above (or under) a section's title
/// ```
///
/// ⚠️ ONE LINE PER BOUNDARY, never two: between two rows only the UPPER one
/// draws (its bottom); a full line is drawn by the row on whichever side of
/// the boundary is a row — tiles and shelves draw nothing.
public enum FlatListSeparators {
    /// What lies on one side of a row.
    public enum Neighbour: Equatable, Sendable {
        /// Another flat row — a text post, or a post whose media is part of
        /// its row.
        case row
        /// Something that is not a row: a block of tiles, paired cards, the
        /// list's leading shelf.
        case other
        /// A section's title. No hairline crosses into a heading.
        case sectionHeader
        /// The list's end (or its start, with nothing above it).
        case none
    }

    /// The hairlines a row draws, given what lies above and below it.
    public static func separators(above: Neighbour, below: Neighbour) -> FlatRowSeparators {
        let bottom: FlatRowSeparator = switch below {
        case .row: .inset
        case .other: .full
        case .sectionHeader, .none: .none
        }
        // The row above draws the line between two rows; a heading and the
        // list's top take none.
        let top: FlatRowSeparator = above == .other ? .full : .none
        return FlatRowSeparators(top: top, bottom: bottom)
    }
}

/// How a post opens from where it is drawn (#2243) — the rule a close then
/// follows (the owner, 2026-11-01: a screen closes the way it opened).
public enum PostListOpening: Equatable, Sendable {
    /// The stack's own push, closed by its own pop — a flat text row: it has
    /// no card shape for a window to grow from.
    case push
    /// The zoom flight: there is a picture at both ends.
    case flight
    /// The text window: a card grows into the page, and shrinks back.
    case window

    /// What a post is drawn as.
    public enum Item: Equatable, Sendable {
        /// A vertical list's row (`PostGridListRowCell`): a card, or a flat row.
        case listRow
        /// A media tile, or a tile of words (a mosaic's, a chunk's).
        case tile
        /// A horizontal shelf's card (Following, the PostShelf rails).
        case shelfCard
    }

    /// The opening for a post drawn as `item` in a list of `style`; `hasMedia`
    /// is whether it has a picture to fly.
    ///
    /// Only a FLAT ROW of words changes (#2243): the window grows the card
    /// into the page, and a flat row has no card to grow from — so it opens
    /// as Threads, X and Bluesky open a post, with the native push. A media
    /// tile keeps its flight; a shelf's text card and the cards style keep
    /// the window.
    public static func opening(for item: Item, hasMedia: Bool, style: PostListStyle) -> PostListOpening {
        if hasMedia { return .flight }
        if item == .listRow, style == .flat { return .push }
        return .window
    }
}
