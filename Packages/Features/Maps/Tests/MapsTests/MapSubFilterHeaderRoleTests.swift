import CoreModels
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

    private static func profiles(_ count: Int) -> [MapSubFilter] {
        (0..<count).map { .profile(ProfileID("prof-\($0)")) }
    }

    /// All's leading edge for a row scrolled `points` past its resting seat.
    private static func allEdge(scrolledBy points: CGFloat) -> CGFloat {
        MapSubFilterBarView.rowInsetLeft - points
    }

    private static func role(scrolledBy points: CGFloat) -> MapSubFilterHeaderRole {
        MapSubFilterHeaderRole.resolve(
            rowIsEmpty: false,
            allLeadingEdgeX: allEdge(scrolledBy: points),
            headerTrailingX: headerX
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

    // MARK: - The empty rail

    /// No All cell means an EMPTY rail — the viewer curated everyone off it.
    /// There is nothing to organize and nothing to rewind to, so the one
    /// button becomes the way back in.
    @Test("An empty row offers the add button")
    func anEmptyRowOffersAdd() {
        #expect(
            MapSubFilterHeaderRole.resolve(
                rowIsEmpty: true, allLeadingEdgeX: nil, headerTrailingX: Self.headerX
            ) == .add
        )
    }

    /// ⚠️ A missing All cell no longer means an empty row — a one- or two-pill
    /// row drops All as clutter while being perfectly populated. That row
    /// wants its organize button; offering "+" there would tell the viewer
    /// their people are gone.
    @Test("A populated row without an All pill still organizes")
    func aShortRowStillOrganizes() {
        #expect(
            MapSubFilterHeaderRole.resolve(
                rowIsEmpty: false, allLeadingEdgeX: nil, headerTrailingX: Self.headerX
            ) == .organize
        )
    }

    // MARK: - When All earns its seat

    /// An empty rail carries nothing at all — All included.
    @Test("An empty rail carries no cells")
    func anEmptyRailHasNoCells() {
        #expect(MapSubFilterBarView.items(for: []).isEmpty)
    }

    /// Below the threshold the row is just its people: All means "none of
    /// these selected", which a one- or two-pill row already shows.
    @Test(arguments: 1...2)
    func aShortRailShowsOnlyItsPeople(count: Int) {
        let items = MapSubFilterBarView.items(for: Self.profiles(count))

        #expect(items.count == count, "an All pill crept into a \(count)-pill row")
        #expect(!items.contains(.all))
    }

    /// At the threshold it earns its seat, and leads.
    @Test(arguments: 3...5)
    func aLongerRailLeadsWithAll(count: Int) {
        let items = MapSubFilterBarView.items(for: Self.profiles(count))

        #expect(items.count == count + 1)
        #expect(items.first == .all)
    }

    /// The boundary, stated once rather than left to two argument ranges that
    /// could drift apart from the constant.
    @Test("The threshold is where the constant says it is")
    func theThresholdMatchesTheConstant() {
        let minimum = MapSubFilterBarView.allPillMinimumCount
        #expect(!MapSubFilterBarView.items(for: Self.profiles(minimum - 1)).contains(.all))
        #expect(MapSubFilterBarView.items(for: Self.profiles(minimum)).contains(.all))
    }

    @Test("Each role wears its own glyph, and all are circles")
    func rolesCarryDistinctIconOnlyContent() {
        let contents = [
            MapSubFilterHeaderRole.organize.content,
            MapSubFilterHeaderRole.rewind.content,
            MapSubFilterHeaderRole.add.content
        ]
        #expect(Set(contents.map(\.symbolName)).count == contents.count)
        #expect(Set(contents.map(\.accessibilityLabel)).count == contents.count)
        // Title-less on every side: the cross-dissolve may not resize the
        // button, or a fixed piece of chrome twitches on every flip.
        #expect(contents.allSatisfy { $0.title == nil })
    }

    /// The "+" is only offered when it leads somewhere. It opens the
    /// full-list sheet, and a sheet with an empty catalogue answers the tap
    /// with nothing — worse than the row simply not being there.
    @Test("An empty rail keeps its row only while someone can be added")
    func anEmptyRailSurvivesOnlyWithACatalogue() {
        let catalogue = MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID("prof-1"), title: "Ada")
        ])
        #expect(MapSubFilterOption.rowSurvivesEmpty(catalogue: catalogue))
        #expect(MapSubFilterOption.rowSurvivesEmpty(catalogue: []) == false)
    }

    /// The add button says what it is FOR. An empty row is the one state where
    /// the button is the entire interface, so a bare "list" label there would
    /// leave a VoiceOver user with a row that announces nothing about what it
    /// offers.
    @Test("The add button names the thing it adds to")
    func theAddButtonIsLabelled() {
        let label = MapSubFilterHeaderRole.add.content.accessibilityLabel
        #expect(label.localizedCaseInsensitiveContains("add"))
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
