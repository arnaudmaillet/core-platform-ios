import Testing
import UIKit
@testable import Upload

/// **HOW TWO SELECTORS SHARE THE TOOLBAR.**
///
/// The rule as given: each may take at most 70% of what there is, and if the two
/// together will not fit, each takes 50%.
struct EditorSelectorLayoutTests {
    private let bar: CGFloat = 390

    @Test func oneSelectorTakesWhatItWantsUpToTheCeiling() {
        #expect(EditorSelectorLayout.width(wants: 120, available: bar) == 120)
        #expect(EditorSelectorLayout.width(wants: 380, available: bar) == bar * 0.7)
    }

    /// ⚠️ **THE CEILING HOLDS EVEN ALONE, AND THAT IS THE POINT.** A lone strip
    /// filling the bar edge to edge leaves no room for the gap before whatever
    /// arrives next — so the moment a second selector appears, every item in the
    /// first one moves. Holding the ceiling means opening a mode does not
    /// rearrange what was already on screen.
    @Test func aLoneSelectorStillLeavesRoomForTheOneThatMayArrive() {
        let alone = EditorSelectorLayout.width(wants: 999, available: bar)

        #expect(alone < bar, "a lone strip filled the whole bar")
        #expect(alone == bar * EditorSelectorLayout.ceiling)
    }

    @Test func twoThatFitAreLeftAlone() {
        let widths = EditorSelectorLayout.widths(
            leadingWants: 100, trailingWants: 180, available: bar
        )

        #expect(widths.leading == 100)
        #expect(widths.trailing == 180)
    }

    /// ⚠️ **NEITHER MAY CROWD THE OTHER OUT.** Two strips that each want most of
    /// the bar cannot both have it, and letting the first one served win would
    /// make the layout depend on which mode was opened first.
    @Test func twoThatDoNotFitSplitTheBarEvenly() {
        let widths = EditorSelectorLayout.widths(
            leadingWants: 260, trailingWants: 260, available: bar
        )

        #expect(widths.leading == bar * 0.5)
        #expect(widths.trailing == bar * 0.5)
    }

    /// And evenly means EVENLY — a greedy strip does not keep more of the bar
    /// just because it asked for more.
    @Test func theEvenSplitIgnoresWhoWantedMore() {
        let lopsided = EditorSelectorLayout.widths(
            leadingWants: 340, trailingWants: 200, available: bar
        )

        #expect(lopsided.leading == lopsided.trailing,
                "\(lopsided.leading) against \(lopsided.trailing)")
    }

    /// ⚠️ **THE CEILING IS APPLIED BEFORE THE FIT IS JUDGED, AND THIS IS THE ONE
    /// CASE THAT CAN TELL.** A greedy strip beside a narrow one: held to 70%
    /// first, 273 + 100 fits in 390 and each keeps what it may have. Judged on
    /// what they ASKED for, 9999 + 100 overflows and both would be cut to half —
    /// the narrow one losing nothing it wanted and the greedy one losing 78
    /// points for no reason.
    ///
    /// My first draft of this test paired 273 with 40, which fits either way and
    /// proved nothing; the expectation was simply wrong and the implementation
    /// was right.
    @Test func theCeilingIsAppliedBeforeTheFitIsJudged() {
        let widths = EditorSelectorLayout.widths(
            leadingWants: 9999, trailingWants: 100, available: bar
        )

        #expect(widths.leading == bar * EditorSelectorLayout.ceiling)
        #expect(widths.trailing == 100, "the narrow one was cut to fit something that fits")
    }

    /// And when they genuinely do not fit, they halve.
    @Test func aGreedyPairHalvesTheBar() {
        let widths = EditorSelectorLayout.widths(
            leadingWants: 9999, trailingWants: 200, available: bar
        )

        #expect(widths.leading == bar * 0.5)
        #expect(widths.trailing == bar * 0.5)
    }

    @Test func anUnlaidBarAsksForNothing() {
        #expect(EditorSelectorLayout.width(wants: 100, available: 0) == 0)
        #expect(EditorSelectorLayout.widths(
            leadingWants: 100, trailingWants: 100, available: 0
        ) == (0, 0))
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

    /// ⚠️ **THE DEFECT:** three actions and six modes on a 375pt bar. Two
    /// halves of what the bar has left must fit with their platters, the gap
    /// and both margins — and they did not while the bar was charged 8pt
    /// margins and one 8pt gap.
    @Test func twoHalvesFitAnSEsBar() {
        let geometry = ToolbarGeometry.fallback
        let available = geometry.available(in: 375)
        let held = EditorSelectorLayout.widths(leadingWants: 112, trailingWants: 226, available: available)
        let used = 2 * geometry.margin + (held.leading + geometry.platter) + geometry.gap
            + (held.trailing + geometry.platter)
        #expect(used <= 375, "the bar is overrun by \(used - 375)pt")
        #expect(held.leading == held.trailing, "they do not fit together, so each takes half")
    }

    /// Read off two hosted platters, in the bar's own coordinates.
    @Test func aMeasurementReadsTheThreeNumbers() {
        let measured = ToolbarGeometry.measured(
            leading: CGRect(x: 33, y: 0, width: 151.5, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 161.5, height: 48),
            trailingPlatter: CGRect(x: 209.5, y: 0, width: 100, height: 48)
        )
        #expect(measured == ToolbarGeometry(margin: 28, platter: 10, gap: 20))
    }

    /// A platter caught mid-transition answers nonsense; nonsense is refused.
    @Test func anImplausibleMeasurementIsRefused() {
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 0, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: -40, y: 0, width: 110, height: 48),
            trailingPlatter: CGRect(x: 90, y: 0, width: 100, height: 48)
        ) == nil, "a negative margin")
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 30, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 300, height: 48),
            trailingPlatter: CGRect(x: 340, y: 0, width: 100, height: 48)
        ) == nil, "a platter far wider than its view")
        #expect(ToolbarGeometry.measured(
            leading: CGRect(x: 30, y: 0, width: 100, height: 38),
            leadingPlatter: CGRect(x: 28, y: 0, width: 110, height: 48),
            trailingPlatter: CGRect(x: 120, y: 0, width: 100, height: 48)
        ) == nil, "overlapping groups")
    }
}
