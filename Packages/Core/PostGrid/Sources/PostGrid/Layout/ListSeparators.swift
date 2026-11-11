import DesignSystem

/// A hairline a list row draws (#2243): none, or one across the whole
/// width — one device pixel, `.separator`, edge to edge.
///
/// ⚠️ ONE KIND OF LINE FOR EVERY BOUNDARY (#2289). There was an INSET line
/// between two rows, from the text column after the avatar, as Threads draws
/// it. Threads starts its line there because its text starts there; here the
/// text stands under the avatar, so the line started on nothing and read as
/// cut short (the owner, 2026-11-11). A post ends at every boundary, so every
/// boundary takes the same line.
public enum RowSeparator: Equatable, Sendable {
    case none
    /// Edge to edge.
    case full
}

/// The two hairlines one row draws, above and below it.
public struct RowSeparators: Equatable, Sendable {
    public var top: RowSeparator
    public var bottom: RowSeparator

    public init(top: RowSeparator, bottom: RowSeparator) {
        self.top = top
        self.bottom = bottom
    }

    public static let none = RowSeparators(top: .none, bottom: .none)
}

/// Where the hairlines of a post list go (#2243, #2289) — pure, so the
/// placement is a table rather than a reading of whichever cell happened to
/// be realized.
///
/// ```
///   [shelf / tiles]
///   ──────────────────────  the row's TOP, under something not a row
///   ◯ row
///   ──────────────────────  between two rows, the upper one's BOTTOM
///   ◯ row
///   ──────────────────────  the row's BOTTOM, over something not a row
///   [tiles]
///   ◯ row                    no line under a list's last row,
///   ┄┄ (end) ┄┄              nor above (or under) a section's title
/// ```
///
/// ⚠️ ONE LINE PER BOUNDARY, never two: between two rows only the UPPER one
/// draws (its bottom); a line next to tiles or a shelf is drawn by the row on
/// whichever side of the boundary is a row — tiles and shelves draw nothing.
/// Every line is the same full-width one. A hero page's header draws its own
/// under it (`HeroHeaderView.drawsFootHairline`), so a list's first row
/// takes none above.
public enum ListSeparators {
    /// What lies on one side of a row.
    public enum Neighbour: Equatable, Sendable {
        /// Another row — a text post, or a post whose media is part of its
        /// row.
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
    public static func separators(above: Neighbour, below: Neighbour) -> RowSeparators {
        let bottom: RowSeparator = switch below {
        case .row, .other: .full
        case .sectionHeader, .none: .none
        }
        // The row above draws the line between two rows; a heading and the
        // list's top take none.
        let top: RowSeparator = above == .other ? .full : .none
        return RowSeparators(top: top, bottom: bottom)
    }
}
