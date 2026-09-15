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
