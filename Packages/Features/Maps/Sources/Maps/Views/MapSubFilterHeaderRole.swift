import UIKit

/// What the sub-filter bar's one fixed leading button currently does.
///
/// The button is contextual because the row's head is: "All" rides the
/// scrolling collection as its first cell (not as fixed furniture), so once
/// the viewer has scrolled past it, the reset has no on-screen affordance
/// left. Rather than park a second permanent bubble in the leading margin —
/// which spends the same real estate on every screen forever — the ONE button
/// already there takes the job over for exactly as long as it is needed.
///
/// The flip is pinned to the duck-fade, not to a separate threshold: the
/// button becomes a rewind precisely when the All pill has finished
/// dissolving beneath the header (`MapBarDuckFade.alpha` hits zero). So the
/// icon never changes while All is still legible, and it has always changed
/// by the time All is gone — there is no window where the row shows neither
/// an All pill nor a way back to one.
enum MapSubFilterHeaderRole: Equatable {
    /// All is on screen: the button opens the reordering / full-list sheet.
    case organize
    /// All has dissolved under the header: the button rewinds the row to it.
    case rewind
    /// The row is EMPTY — the viewer has curated everyone off this rail. There
    /// is no All pill to reset to and nothing to organize, so the one button
    /// becomes the only thing worth offering: a way to put someone back. It
    /// opens the same sheet `organize` does; what changes is the glyph and the
    /// promise it makes.
    case add

    /// Resolves the role from geometry alone — pure, so the rule is testable
    /// without a window or a live collection view.
    ///
    /// - Parameters:
    ///   - rowIsEmpty: whether the row carries no refinements at all. Asked
    ///     SEPARATELY from the All cell's position, because a missing All cell
    ///     no longer means an empty row: a one- or two-pill row drops All as
    ///     clutter (`MapSubFilterBarView.allPillMinimumCount`) while being
    ///     perfectly populated, and that row wants its organize button, not an
    ///     add button.
    ///   - allLeadingEdgeX: the All cell's leading edge in BAR coordinates
    ///     (`frame.minX - contentOffset.x`), or nil when the row carries no
    ///     All cell — nothing to rewind to, so the button keeps its resting
    ///     job.
    ///   - headerTrailingX: the fixed button's trailing edge, also in bar
    ///     coordinates.
    static func resolve(
        rowIsEmpty: Bool, allLeadingEdgeX: CGFloat?, headerTrailingX: CGFloat
    ) -> Self {
        guard !rowIsEmpty else { return .add }
        guard let allLeadingEdgeX else { return .organize }
        // The same penetration the duck-fade measures: how far All's leading
        // edge has advanced past the fade line trailing the header.
        let penetration = headerTrailingX + MapBarDuckFade.approach - allLeadingEdgeX
        return MapBarDuckFade.alpha(forPenetration: penetration) <= 0 ? .rewind : .organize
    }

    /// The pill content the button wears in this role.
    var content: MapPillButton.Content {
        switch self {
        case .organize:
            MapPillButton.Content(
                title: nil,
                symbolName: "list.bullet", selectedSymbolName: "list.bullet",
                accessibilityLabel: "Show full list"
            )
        case .rewind:
            MapPillButton.Content(
                title: nil,
                symbolName: "chevron.left", selectedSymbolName: "chevron.left",
                accessibilityLabel: "Back to all"
            )
        case .add:
            MapPillButton.Content(
                title: nil,
                symbolName: "plus", selectedSymbolName: "plus",
                accessibilityLabel: "Add people to this filter"
            )
        }
    }
}
