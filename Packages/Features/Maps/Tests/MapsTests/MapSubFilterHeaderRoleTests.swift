import Testing
import UIKit
@testable import Maps

/// The sub-filter bar's contextual leading button: it organizes while the
/// "All" pill is on screen and becomes a rewind once All has dissolved
/// beneath it.
///
/// The rule is deliberately pinned to the duck-fade curve rather than to a
/// threshold of its own, so these assert the two must stay welded: the button
/// may not still say "organize" once All is invisible, and may not already say
/// "back" while All is still legible.
///
/// Windowless and view-free: the rule is pure geometry, so it needs neither a
/// live collection view nor the Liquid Glass material (the CI doctrine).
@MainActor
struct MapSubFilterHeaderRoleTests {
    /// The bar's real geometry — the button's trailing edge is a constant
    /// (title-less pills are circles pinned to their height).
    private static let headerX = MapSubFilterBarView.headerTrailingX

    /// All's leading edge for a row scrolled `points` past its resting seat.
    private static func allEdge(scrolledBy points: CGFloat) -> CGFloat {
        MapSubFilterBarView.rowInsetLeft - points
    }

    private static func role(scrolledBy points: CGFloat) -> MapSubFilterHeaderRole {
        MapSubFilterHeaderRole.resolve(
            allLeadingEdgeX: allEdge(scrolledBy: points), headerTrailingX: headerX
        )
    }

    @Test("A row at rest organizes — All is sitting right there")
    func restingRowOrganizes() {
        #expect(Self.role(scrolledBy: 0) == .organize)
    }

    @Test("Overscroll past the head still organizes")
    func overscrollOrganizes() {
        #expect(Self.role(scrolledBy: -40) == .organize)
    }

    @Test("While All is still part-visible the button keeps organizing")
    func partiallyDuckedAllStillOrganizes() {
        // Anywhere strictly inside the fade ramp, All still renders.
        let ramp = MapBarDuckFade.approach + MapBarDuckFade.depth
        for scrolled in stride(from: CGFloat(1), to: ramp, by: 4) {
            #expect(Self.role(scrolledBy: scrolled) == .organize, "scrolled \(scrolled)pt")
        }
    }

    @Test("The flip lands exactly where All finishes dissolving")
    func flipsWhenAllIsFullyDissolved() {
        let ramp = MapBarDuckFade.approach + MapBarDuckFade.depth
        #expect(Self.role(scrolledBy: ramp) == .rewind)
        #expect(Self.role(scrolledBy: ramp + 200) == .rewind)
    }

    @Test("The flip and the duck-fade agree at every offset")
    func roleTracksTheDuckFade() {
        for scrolled in stride(from: CGFloat(-20), through: 120, by: 1) {
            let penetration = Self.headerX + MapBarDuckFade.approach - Self.allEdge(scrolledBy: scrolled)
            let allIsInvisible = MapBarDuckFade.alpha(forPenetration: penetration) <= 0
            let expected: MapSubFilterHeaderRole = allIsInvisible ? .rewind : .organize
            #expect(Self.role(scrolledBy: scrolled) == expected, "scrolled \(scrolled)pt")
        }
    }

    @Test("A row with no All cell keeps organizing — there is nothing to rewind to")
    func absentAllCellOrganizes() {
        #expect(
            MapSubFilterHeaderRole.resolve(allLeadingEdgeX: nil, headerTrailingX: Self.headerX)
                == .organize
        )
    }

    @Test("Each role wears its own glyph, and both are circles")
    func rolesCarryDistinctIconOnlyContent() {
        let organize = MapSubFilterHeaderRole.organize.content
        let rewind = MapSubFilterHeaderRole.rewind.content
        #expect(organize.symbolName != rewind.symbolName)
        #expect(organize.accessibilityLabel != rewind.accessibilityLabel)
        // Title-less on both sides: the cross-dissolve may not resize the
        // button, or a fixed piece of chrome twitches on every flip.
        #expect(organize.title == nil)
        #expect(rewind.title == nil)
    }

    @Test("The row rests exactly one approach-margin past the button")
    func rowInsetClearsTheButtonByTheApproachMargin() {
        #expect(
            MapSubFilterBarView.rowInsetLeft
                == MapSubFilterBarView.headerTrailingX + MapBarDuckFade.approach
        )
        // …which is what makes a pill parked on the snap anchor fully opaque.
        let penetration = MapSubFilterBarView.headerTrailingX + MapBarDuckFade.approach
            - MapSubFilterBarView.rowInsetLeft
        #expect(MapBarDuckFade.alpha(forPenetration: penetration) == 1)
    }
}
