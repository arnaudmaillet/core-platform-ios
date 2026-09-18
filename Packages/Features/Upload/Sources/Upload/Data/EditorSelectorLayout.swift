import CoreGraphics

/// How the two bottom strips divide the toolbar.
///
/// ⚠️ **PURE, BECAUSE A TOOLBAR CANNOT BE MEASURED IN A TEST.** `toolbarItems`
/// are laid out by a `UIToolbar` the screen does not own, inside a navigation
/// controller, after a layout pass that needs a window — so a rule expressed as
/// constraints is a rule no test can ask about.
///
/// ⚠️ **THE LEADING STRIP IS NEVER SQUEEZED; THE TRAILING ONE TAKES WHAT IS
/// LEFT.** Asked for in those words: *"la toolbar de gauche prend en largeur
/// toujours sa taille intrinsèque, et la toolbar de droite prendra ce qui reste
/// de disponible"*. The percentages that used to govern this — at most seven
/// tenths each, half and half when the two would not fit — are gone. They gave
/// the actions room they did not want (three glyphs holding 159pt of a 375pt
/// bar) while the mode selector, the one strip that SCROLLS and so is the one
/// that can use width, went short by the same amount.
///
/// ⚠️ **AND IT DOES NOT CARE WHAT IS IN EITHER.** The leading slot holds the
/// track's actions with the timeline open and the song pill without it; a pill
/// carrying a long title simply leaves the selector less. The one thing the
/// rule will not do is leave the trailing strip narrower than one bubble —
/// `navbar-leading-selector-collapse` records what UIKit does with a demand it
/// cannot meet.
enum EditorSelectorLayout {
    /// The widths to hold the two strips to: `leadingWants` is what the leading
    /// one would take on its own (its intrinsic width), `available` is what the
    /// bar has left once its margins, platters and group gap are charged
    /// (`ToolbarGeometry`), and `trailingFloor` is one bubble.
    static func widths(
        leadingWants: CGFloat, available: CGFloat, trailingFloor: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard available > 0, available.isFinite else { return (0, 0) }
        let floor = min(max(trailingFloor, 0), available)
        let leading = min(max(leadingWants.isFinite ? leadingWants : 0, 0), available - floor)
        return (leading, available - leading)
    }
}

/// What the bottom bar charges around its items, which is what decides how
/// much of it the two strips may share.
///
/// ⚠️ **NOT `toolbar.layoutMargins`.** Since iOS 26 the items are not hosted in
/// the `UIToolbar` (`navbar-leading-selector-collapse`), and its margins answer
/// 8 while the bar keeps 28. Charged 8, the two halves overran an iPhone SE's
/// bar and iOS swept the mode selector into a `•••`.
///
/// ⚠️ **MEASURED FROM THE BAR WHEN IT CAN BE, AND THE SE'S NUMBERS OTHERWISE.**
/// The bar hosts the pill and the selector side by side before any mode opens,
/// so their platters are there to be read; `fallback` is what they read on an
/// iPhone SE under iOS 27 — `28 + (pill + 10) + 20 + (strip + 10) + 28`, which
/// is exactly 375.
struct ToolbarGeometry: Equatable {
    /// The bar's margin on each side.
    var margin: CGFloat
    /// How much wider a platter is than the view it holds.
    var platter: CGFloat
    /// The room between the leading and the trailing group.
    var gap: CGFloat

    static let fallback = ToolbarGeometry(margin: 28, platter: 10, gap: 20)

    /// What is left for the two strips' own widths on a bar `width` wide.
    func available(in width: CGFloat) -> CGFloat {
        width - 2 * margin - 2 * platter - gap
    }

    /// The geometry read from two neighbouring platters, given each view's
    /// frame and its platter's, in one coordinate space whose origin is the
    /// bar's leading edge. Nil for an answer no bar would give — a measurement
    /// taken mid-transition is worse than the fallback.
    static func measured(
        leading: CGRect, leadingPlatter: CGRect, trailingPlatter: CGRect
    ) -> ToolbarGeometry? {
        let geometry = ToolbarGeometry(
            margin: leadingPlatter.minX,
            platter: leadingPlatter.width - leading.width,
            gap: trailingPlatter.minX - leadingPlatter.maxX
        )
        // ⚠️ **THE BANDS REFUSE A MID-LAYOUT READ, WHICH MEANS THEY MUST NOT
        // ADMIT ZERO.** They used to start at 0 on all three, and a pass caught
        // before the platters had grown answers platter ≈ 0 and gap ≈ 0 — which
        // passed, and made `available` up to 20pt LARGER than the bar really
        // has. `barGeometry` never reverts, so one such reading poisons every
        // later share for the life of the screen and the two groups overrun.
        // A real bar's platter is the 10pt measured on every device this ships
        // to, and its gap is 20; the floors are half of each.
        guard (8...64).contains(geometry.margin),
              (4...24).contains(geometry.platter),
              (8...64).contains(geometry.gap)
        else { return nil }
        return geometry
    }
}
