import Testing
import UIKit
@testable import Upload

/// **HOW THE TWO BOTTOM STRIPS DIVIDE THE TOOLBAR.**
///
/// The rule as given: the leading strip takes its intrinsic width, whatever it
/// holds, and the trailing one takes what is left.
struct EditorSelectorLayoutTests {
    private let bar: CGFloat = 390
    private let bubble: CGFloat = 38

    @Test func theLeadingStripKeepsItsWidthAndTheRestIsTheOthers() {
        let widths = EditorSelectorLayout.widths(leadingWants: 112, available: bar, trailingFloor: bubble)

        #expect(widths.leading == 112, "the actions were squeezed")
        #expect(widths.trailing == bar - 112, "the selector did not take the rest")
        #expect(widths.leading + widths.trailing == bar, "the bar is not fully spoken for")
    }

    /// ⚠️ **NO CEILING ANY MORE, IN EITHER DIRECTION.** A narrow leading strip
    /// used to be held to seven tenths and so did the trailing one, which left
    /// the middle of the bar to nobody; and when the two would not fit they
    /// halved, which gave three glyphs 159pt of a 375pt bar while the strip that
    /// scrolls went short by the same amount.
    @Test func aNarrowLeadingStripHandsOverEverythingElse() {
        let pill = EditorSelectorLayout.widths(leadingWants: 60, available: bar, trailingFloor: bubble)

        #expect(pill.trailing == bar - 60)
        #expect(pill.trailing > bar * 0.7, "the trailing strip is still capped")
    }

    /// ⚠️ **THE ONE THING THE RULE WILL NOT DO.** A leading strip wider than the
    /// bar would leave the selector nothing at all, and UIKit answers a demand
    /// it cannot meet by sweeping the group into a `•••`
    /// (`navbar-leading-selector-collapse`). One bubble is kept back.
    @Test func theTrailingStripNeverFallsBelowOneBubble() {
        let widths = EditorSelectorLayout.widths(leadingWants: 9999, available: bar, trailingFloor: bubble)

        #expect(widths.trailing == bubble)
        #expect(widths.leading == bar - bubble, "the leading strip did not give up the bubble")
    }

    @Test func anUnlaidBarAsksForNothing() {
        #expect(EditorSelectorLayout.widths(leadingWants: 100, available: 0, trailingFloor: bubble) == (0, 0))
        #expect(EditorSelectorLayout.widths(
            leadingWants: 100, available: .nan, trailingFloor: bubble
        ) == (0, 0))
    }

    /// A strip that states no intrinsic width at all is not allowed to take the
    /// bar with it.
    @Test func anUnstatedWidthTakesNothing() {
        let widths = EditorSelectorLayout.widths(
            leadingWants: .nan, available: bar, trailingFloor: bubble
        )

        #expect(widths.leading == 0)
        #expect(widths.trailing == bar)
    }
}

/// What the bottom bar charges around its two groups.
struct ToolbarGeometryTests {
    /// ⚠️ **THE SE, AS MEASURED:** the pill (121) and the selector (158) sat on
    /// platters 131 and 168 wide, 28 from each edge and 20 apart — exactly 375.
    @Test func theFallbackIsTheSEsBar() {
        let geometry = ToolbarGeometry.fallback
        let strips: CGFloat = 121 + 158
        #expect(geometry.available(in: 375) == strips)
    }

    /// ⚠️ **THE DEFECT:** three actions and six modes on a 375pt bar. What the
    /// two strips are held to must fit with their platters, the gap and both
    /// margins — and it did not while the bar was charged 8pt margins and one
    /// 8pt gap.
    @Test func bothStripsFitAnSEsBar() {
        let geometry = ToolbarGeometry.fallback
        let available = geometry.available(in: 375)
        let held = EditorSelectorLayout.widths(leadingWants: 112, available: available, trailingFloor: 38)
        let used = 2 * geometry.margin + (held.leading + geometry.platter) + geometry.gap
            + (held.trailing + geometry.platter)
        #expect(used <= 375, "the bar is overrun by \(used - 375)pt")
        #expect(held.leading == 112, "the actions were squeezed on a bar that had room")
    }

    /// Read off two hosted platters, in the bar's own coordinates.
    @Test func aMeasurementReadsTheThreeNumbers() {
        let measured = ToolbarGeometry.measured(
            leading: CGRect(x: 33, y: 0, width: 151.5, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 161.5, height: 48),
            trailing: CGRect(x: 214.5, y: 0, width: 90, height: 38),
            trailingPlatter: CGRect(x: 209.5, y: 0, width: 100, height: 48)
        )
        #expect(measured == ToolbarGeometry(margin: 28, platter: 10, gap: 20))
    }

    /// ⚠️ **A BAR CAUGHT MID-MORPH IS REFUSED, EVEN INSIDE THE BANDS.** The
    /// song pill turning into the timeline's actions passes through a platter
    /// 16pt wider than its view — plausible on its own, and wrong: the reading
    /// stuck and the next share overran the bar by 13pt. At rest both platters
    /// are the same distance wider than what they hold; mid-transition the one
    /// that is morphing is not.
    @Test func aPlatterThatDisagreesWithItsNeighbourIsStillMoving() {
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 34, y: 0, width: 112, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 128, height: 48),
            trailing: CGRect(x: 173, y: 0, width: 182, height: 38),
            trailingPlatter: CGRect(x: 168, y: 0, width: 192, height: 48)
        ) == nil, "a 16pt platter beside a 10pt one was accepted")
    }

    /// A platter caught mid-transition answers nonsense; nonsense is refused.
    @Test func anImplausibleMeasurementIsRefused() {
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 0, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: -40, y: 0, width: 110, height: 48),
            trailing: CGRect(x: 95, y: 0, width: 90, height: 38),
            trailingPlatter: CGRect(x: 90, y: 0, width: 100, height: 48)
        ) == nil, "a negative margin")
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 30, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 300, height: 48),
            trailing: CGRect(x: 145, y: 0, width: -100, height: 38),
            trailingPlatter: CGRect(x: 340, y: 0, width: 100, height: 48)
        ) == nil, "a platter far wider than its view")
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 30, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 110, height: 48),
            trailing: CGRect(x: 125, y: 0, width: 90, height: 38),
            trailingPlatter: CGRect(x: 120, y: 0, width: 100, height: 48)
        ) == nil, "overlapping groups")
    }
}
