import CoreGraphics

/// How two selectors share the toolbar.
///
/// ⚠️ **PURE, BECAUSE A TOOLBAR CANNOT BE MEASURED IN A TEST.** `toolbarItems`
/// are laid out by a `UIToolbar` the screen does not own, inside a navigation
/// controller, after a layout pass that needs a window — so a rule expressed as
/// constraints is a rule no test can ask about.
///
/// ⚠️ **APPLIED BY `MediaEditorViewController.shareTheBarBetweenTheTwoStrips`,
/// AND ONLY WHILE THERE ARE TWO.** The second strip has arrived: with the
/// timeline open the leading slot holds an `IconActionBar` and the trailing one
/// the mode selector, and the two widths below are what they are held to. With
/// the sound pill in that slot instead the constraints come off — the pill
/// states a width FLOOR and the selector is told it may give, which is a
/// different arrangement that already works and is not this rule's to re-decide.
///
/// ⚠️ **AND IT IS NOT "SHARE WHAT IS THERE".** With one selector the answer is
/// "as much as it wants, up to most of the bar" — a strip that shrank to half a
/// screen when nothing was competing with it would be throwing space away. With
/// two, neither may crowd the other out. Those are different rules and the
/// ceiling is what joins them.
enum EditorSelectorLayout {
    /// The most of the bar one selector may take when it is not competing.
    ///
    /// Seven tenths: enough for a five-item strip on a small phone, and short of
    /// the whole bar so a second selector arriving is never a surprise.
    static let ceiling: CGFloat = 0.7

    /// What each gets when the two together will not fit.
    static let share: CGFloat = 0.5

    /// The widths to hold the two selectors to.
    ///
    /// `wants` are the widths they would take if nothing stopped them — an
    /// `IconSelectorBar` states an intrinsic width, so this is that.
    static func widths(
        leadingWants leading: CGFloat, trailingWants trailing: CGFloat, available: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard available > 0, available.isFinite else { return (0, 0) }
        let cap = available * ceiling
        let held = (
            leading: min(max(leading, 0), cap),
            trailing: min(max(trailing, 0), cap)
        )
        guard held.leading + held.trailing > available else { return held }
        let half = available * share
        return (half, half)
    }

    /// The width ONE selector may take, when it is alone in the bar.
    ///
    /// ⚠️ **THE CEILING STILL APPLIES.** A lone strip that filled the bar edge to
    /// edge would leave no room for the space that separates it from whatever
    /// arrives next, and the moment a second selector appeared every item in it
    /// would move. Holding the ceiling means the layout does not rearrange itself
    /// when a mode opens.
    static func width(wants: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 0, available.isFinite else { return 0 }
        return min(max(wants, 0), available * ceiling)
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
        guard (0...64).contains(geometry.margin),
              (0...24).contains(geometry.platter),
              (0...64).contains(geometry.gap)
        else { return nil }
        return geometry
    }
}
