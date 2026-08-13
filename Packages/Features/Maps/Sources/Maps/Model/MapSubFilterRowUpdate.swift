import CoreModels

/// What the sub-filter row is showing, as far as anything outside the view is
/// concerned: whose people they are, who they are, and whether that primary
/// has anyone left to add.
struct MapSubFilterRowState: Equatable {
    let primary: MapFilter
    let people: [MapFavorite]
    /// Whether the primary's catalogue has anyone in it — the difference
    /// between an empty row worth keeping (there is someone to add back) and
    /// one worth retiring (there is nobody).
    let hasCatalogue: Bool
}

/// Whether a freshly resolved row should be applied, and as what.
///
/// Pure, and separate from the view controller, because the interesting case
/// is a comparison and comparisons are exactly what go wrong quietly. The one
/// this exists to prevent: switching from a populated primary to an EMPTY one
/// left the previous primary's pills on screen. The refresh was comparing the
/// incoming people against the CACHE for the primary being switched to — both
/// empty, so "nothing changed" — while what the viewer was looking at belonged
/// to the primary they had just left. Comparing against what is RENDERED makes
/// that impossible to express.
enum MapSubFilterRowUpdate: Equatable {
    /// How the row should get from what it shows to what it should show.
    enum Style: Equatable {
        /// A different list entirely — the viewer switched primaries. The row
        /// cross-dissolves as one surface, because every pill is being
        /// replaced and animating them individually would read as a shuffle
        /// between two unrelated sets.
        case swap
        /// The SAME list, edited — someone was added or removed. Only the
        /// pills that changed may move: a whole-row dissolve for a
        /// one-pill edit is the flash this distinction exists to remove, and
        /// it drops the viewer's scroll position and selection with it.
        case diff
    }

    /// The row already shows exactly this. Re-applying would churn the pills
    /// (and the selection) for nothing.
    case unchanged
    /// Render these options — an EMPTY array is the add-affordance state, not
    /// a reason to hide.
    case show([MapSubFilterOption], style: Style)
    /// Retire the row: nothing to show and nobody to add.
    case hide

    static func resolve(rendered: MapSubFilterRowState?, incoming: MapSubFilterRowState) -> Self {
        // ⚠️ The whole state, not just the people: a different PRIMARY with an
        // identical (often empty) list is a different row, and a catalogue
        // that has just arrived turns a retired row into an addable one.
        guard rendered != incoming else { return .unchanged }
        let options = MapSubFilterOption.people(incoming.people)
        if options.isEmpty && !incoming.hasCatalogue { return .hide }
        // Same primary → an edit of the list the viewer is already reading.
        let style: Style = rendered?.primary == incoming.primary ? .diff : .swap
        return .show(options, style: style)
    }
}
