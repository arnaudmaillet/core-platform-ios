import CoreModels
import Testing
@testable import Maps

/// SWITCHING PRIMARIES, AND THE ROW THAT WOULD NOT LET GO.
///
/// The refresh that repopulates the sub-filter row has to answer one question:
/// is this worth applying? Answering it against the CACHE for the primary
/// being switched to — rather than against what is on screen — produced a bug
/// that looks like nothing at all in code: Following → Friends, where Friends
/// is empty, compared empty against empty, called it "unchanged", and left
/// Following's pills sitting under the Friends primary.
///
/// So the comparison is against the RENDERED state, and these hold it there.
struct MapSubFilterRowUpdateTests {
    private static func person(_ id: String) -> MapFavorite {
        MapFavorite(profileID: ProfileID(id), title: id)
    }

    private static func state(
        _ primary: MapFilter, _ people: [String], hasCatalogue: Bool = true
    ) -> MapSubFilterRowState {
        MapSubFilterRowState(
            primary: primary, people: people.map(person), hasCatalogue: hasCatalogue
        )
    }

    // MARK: - The bug

    /// THE REGRESSION. An empty Friends rail arriving over a populated
    /// Following row is a change, however identical the two empty lists look.
    @Test("Switching to an empty primary re-renders rather than standing pat")
    func switchingToAnEmptyPrimaryRenders() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.following, ["ada", "lena"]),
            incoming: Self.state(.friends, [])
        )

        #expect(update == .show([], style: .swap), "the previous primary's row was left standing")
    }

    /// And the same switch the other way: an empty row replaced by a populated
    /// one for a different primary.
    @Test("Switching from an empty primary to a populated one renders")
    func switchingFromAnEmptyPrimaryRenders() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, []),
            incoming: Self.state(.following, ["ada"])
        )

        #expect(update == .show(MapSubFilterOption.people([Self.person("ada")]), style: .swap))
    }

    /// Two primaries can hold the SAME people (friends ⊆ following) — and it
    /// is still a different row, because the pills belong to a different
    /// primary and its selection.
    @Test("Identical people under a different primary is still a change")
    func identicalPeopleUnderADifferentPrimaryRenders() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.following, ["ada"]),
            incoming: Self.state(.friends, ["ada"])
        )

        #expect(update != .unchanged)
    }

    // MARK: - Still not churning

    /// The reason the comparison exists at all: a background refresh that
    /// resolves to what is already on screen must not restack the pills, which
    /// would drop the viewer's selection and re-run the arrival animation.
    @Test("An identical refresh changes nothing")
    func anIdenticalRefreshIsUnchanged() {
        let rendered = Self.state(.friends, ["ada", "lena"])

        #expect(MapSubFilterRowUpdate.resolve(rendered: rendered, incoming: rendered) == .unchanged)
    }

    @Test("A changed list under the same primary renders")
    func aChangedListRenders() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, ["ada"]),
            incoming: Self.state(.friends, ["ada", "lena"])
        )

        #expect(update != .unchanged)
    }

    // MARK: - Empty, with and without a way out

    /// An empty rail with someone available keeps the row — that is where the
    /// "+" lives.
    @Test("Empty with a catalogue shows the add row")
    func emptyWithACatalogueShows() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: nil, incoming: Self.state(.friends, [], hasCatalogue: true)
        )

        #expect(update == .show([], style: .swap))
    }

    /// An empty rail with nobody to add retires: the "+" opens a sheet, and a
    /// sheet with nothing in it answers the tap with nothing.
    @Test("Empty with no catalogue hides")
    func emptyWithNoCatalogueHides() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: nil, incoming: Self.state(.friends, [], hasCatalogue: false)
        )

        #expect(update == .hide)
    }

    /// The cold path: the row retired because the catalogue had not loaded
    /// yet, and must come back the moment it does — even though the people
    /// list is empty both times.
    @Test("A catalogue arriving late un-retires the row")
    func aLateCatalogueRestoresTheRow() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, [], hasCatalogue: false),
            incoming: Self.state(.friends, [], hasCatalogue: true)
        )

        #expect(update == .show([], style: .diff))
    }

    /// Nothing rendered yet — the first paint always applies.
    @Test("The first render always applies")
    func theFirstRenderApplies() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: nil, incoming: Self.state(.following, ["ada"])
        )

        #expect(update != .unchanged)
    }

    // MARK: - How it gets there

    /// THE FLICKER. Adding or removing one person from the rail the viewer is
    /// reading is an EDIT of that row — only the pill that changed may move.
    /// Cross-dissolving the whole surface for it is the flash, and it takes
    /// the scroll position and the selection with it.
    @Test("Editing the visible rail diffs rather than swapping")
    func anEditOfTheSameRailDiffs() {
        let added = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, ["ada"]),
            incoming: Self.state(.friends, ["ada", "lena"])
        )
        let removed = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, ["ada", "lena"]),
            incoming: Self.state(.friends, ["ada"])
        )

        #expect(added == .show(MapSubFilterOption.people(["ada", "lena"].map(Self.person)), style: .diff))
        #expect(removed == .show(MapSubFilterOption.people([Self.person("ada")]), style: .diff))
    }

    /// A different primary is a different list, and animating pill-by-pill
    /// between two unrelated sets reads as a shuffle. That one keeps the
    /// cross-dissolve.
    @Test("Switching primaries swaps rather than diffing")
    func aPrimarySwitchSwaps() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.following, ["ada"]),
            incoming: Self.state(.friends, ["ada"])
        )

        #expect(update == .show(MapSubFilterOption.people([Self.person("ada")]), style: .swap))
    }

    /// Curating the last person off the rail the viewer is reading is still an
    /// edit of it — the pills collapse out, they do not flash away.
    @Test("Emptying the visible rail diffs too")
    func emptyingTheVisibleRailDiffs() {
        let update = MapSubFilterRowUpdate.resolve(
            rendered: Self.state(.friends, ["ada"]),
            incoming: Self.state(.friends, [])
        )

        #expect(update == .show([], style: .diff))
    }
}
