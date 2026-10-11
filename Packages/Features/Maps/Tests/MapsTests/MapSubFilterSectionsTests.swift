import CoreModels
import Testing
@testable import Maps

/// The Active / Available split: membership, capacity and order.
struct MapSubFilterSectionsTests {
    private static func people(_ ids: [String]) -> [MapSubFilterOption] {
        MapSubFilterOption.people(ids.map {
            MapFavorite(profileID: ProfileID($0), title: $0.uppercased(), avatarURL: nil, handle: $0)
        })
    }

    private static let all = people(["a", "b", "c", "d"])
    private static func sub(_ id: String) -> MapSubFilter { .profile(ProfileID(id)) }

    @Test func splitsTheCatalogueByWhatTheBarCarries() {
        let sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("c"), Self.sub("a")]
        )
        // Active keeps BAR order, not catalogue order.
        #expect(sections.active.map(\.subFilter) == [Self.sub("c"), Self.sub("a")])
        #expect(sections.available.map(\.subFilter) == [Self.sub("b"), Self.sub("d")])
    }

    @Test func unknownActiveIDsAreIgnored() {
        // A stale order (someone unfollowed since) must not mint empty rows.
        let sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("zzz"), Self.sub("b")]
        )
        #expect(sections.active.map(\.subFilter) == [Self.sub("b")])
        #expect(sections.available.count == 3)
    }

    @Test func activateAppendsToTheEnd() {
        // The order above a newcomer is the viewer's arrangement — it keeps it.
        var sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("d"), Self.sub("a")]
        )
        let promoted = sections.activate(Self.sub("b"))
        #expect(promoted)
        #expect(sections.active.map(\.subFilter) == [Self.sub("d"), Self.sub("a"), Self.sub("b")])
        #expect(sections.available.map(\.subFilter) == [Self.sub("c")])
    }

    @Test func activateRefusesWhenFull() {
        var sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("a"), Self.sub("b")], maxActive: 2
        )
        #expect(sections.isFull)
        let refused = sections.activate(Self.sub("c"))
        #expect(refused == false)
        // A refused promotion changes nothing at all.
        #expect(sections.active.count == 2)
        #expect(sections.available.map(\.subFilter) == [Self.sub("c"), Self.sub("d")])
    }

    @Test func deactivateReturnsToCatalogueOrder() {
        // "b" goes back between "a" and "c", not onto the end.
        var sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("b"), Self.sub("d")]
        )
        #expect(sections.available.map(\.subFilter) == [Self.sub("a"), Self.sub("c")])
        sections.deactivate(Self.sub("b"), naturalOrder: Self.all.map(\.subFilter))
        #expect(sections.active.map(\.subFilter) == [Self.sub("d")])
        #expect(sections.available.map(\.subFilter) == [Self.sub("a"), Self.sub("b"), Self.sub("c")])
    }

    @Test func adoptTakesADropThatFitsAndRefusesOneThatDoesNot() {
        var sections = MapSubFilterSections(
            all: Self.all, activeSubFilters: [Self.sub("a")], maxActive: 2
        )
        let two = Array(Self.all.prefix(2))
        let adopted = sections.adopt(active: two, available: Array(Self.all.suffix(2)))
        #expect(adopted)
        #expect(sections.active.count == 2)

        // A drop that would overflow leaves the model untouched, so the view
        // can just re-apply its snapshot.
        let before = sections
        let overflowed = sections.adopt(active: Self.all, available: [])
        #expect(overflowed == false)
        #expect(sections == before)
    }

    // MARK: - A row given over the cap (#867)

    /// Twelve people in the bar, two more on offer — the shape the favorites
    /// repository serves (rails of up to 12) against a default cap of 6.
    private static let crowd = people((1...14).map { "p\($0)" })
    private static let twelve = Array(crowd.prefix(12)).map(\.subFilter)

    @Test("A row given over the default cap is taken as it is, and its header never reads more active than its max")
    func anOverCapRowRaisesTheCapToItsOwnSize() {
        let sections = MapSubFilterSections(all: Self.crowd, activeSubFilters: Self.twelve)
        #expect(sections.active.count == 12)
        #expect(sections.maxActive == 12)
        #expect(sections.active.count <= sections.maxActive)
        #expect(sections.capacityLabel == "12 of 12")
    }

    @Test("A row at or under the default cap keeps the default")
    func aRowUnderTheCapKeepsTheDefault() {
        let sections = MapSubFilterSections(all: Self.crowd, activeSubFilters: Array(Self.twelve.prefix(2)))
        #expect(sections.maxActive == MapSubFilterSections.defaultMaxActive)
        #expect(sections.capacityLabel == "2 of 6")
    }

    @Test("Reordering the active section of an over-cap row is accepted")
    func reorderingAnOverCapRowIsAccepted() {
        var sections = MapSubFilterSections(all: Self.crowd, activeSubFilters: Self.twelve)
        let reordered = Array(sections.active.reversed())
        let available = sections.available
        let adopted = sections.adopt(active: reordered, available: available)
        #expect(adopted)
        #expect(sections.active == reordered)
    }

    @Test("An over-cap row still refuses to grow past the size it was given")
    func anOverCapRowRefusesToGrow() {
        var sections = MapSubFilterSections(all: Self.crowd, activeSubFilters: Self.twelve)
        #expect(sections.isFull)
        let promoted = sections.activate(Self.crowd[12].subFilter)
        #expect(promoted == false)
        // A drop that carries a thirteenth person across the divide is refused too.
        let before = sections
        let thirteen = sections.active + [sections.available[0]]
        let rest = Array(sections.available.dropFirst())
        let adopted = sections.adopt(active: thirteen, available: rest)
        #expect(adopted == false)
        #expect(sections == before)
    }

    @Test("Demoting from an over-cap row frees a seat that can be taken back")
    func aDemotionFromAnOverCapRowFreesASeat() {
        var sections = MapSubFilterSections(all: Self.crowd, activeSubFilters: Self.twelve)
        sections.deactivate(Self.twelve[0], naturalOrder: Self.crowd.map(\.subFilter))
        #expect(sections.capacityLabel == "11 of 12")
        let retaken = sections.activate(Self.crowd[13].subFilter)
        #expect(retaken)
        #expect(sections.capacityLabel == "12 of 12")
        let thirteenth = sections.activate(Self.twelve[0])
        #expect(thirteenth == false)
    }

    // MARK: - The cap depends on the row type (#876)

    /// Category options beyond the real six, so the cap, not the size of the
    /// vocabulary, is what refuses a seventh.
    private static func categories(_ count: Int) -> [MapSubFilterOption] {
        (1...count).map {
            MapSubFilterOption(
                subFilter: .placeCategory("c\($0)"),
                content: MapPillButton.Content(
                    title: nil, symbolName: "mappin", selectedSymbolName: "mappin",
                    accessibilityLabel: "Category \($0)"
                ),
                favorite: nil
            )
        }
    }

    @Test("People primaries cap at twelve and every other primary at six")
    func theCapFollowsThePrimary() {
        #expect(MapSubFilterSections.maxActive(for: .following) == 12)
        #expect(MapSubFilterSections.maxActive(for: .friends) == 12)
        #expect(MapSubFilterSections.maxActive(for: .pinned) == 6)
        #expect(MapSubFilterSections.maxActive(for: nil) == 6)
    }

    @Test("A people row trimmed from twelve to five grows back to twelve in a later session")
    func aTrimmedPeopleRowCanBeRebuilt() {
        let cap = MapSubFilterSections.maxActive(for: .following)
        // First session: the default rail, trimmed to five.
        var first = MapSubFilterSections(all: Self.crowd, activeSubFilters: Self.twelve, maxActive: cap)
        for subFilter in Self.twelve.suffix(7) {
            first.deactivate(subFilter, naturalOrder: Self.crowd.map(\.subFilter))
        }
        let committed = first.active.map(\.subFilter)
        #expect(committed.count == 5)

        // Later session: the sheet only knows the five it is given.
        var later = MapSubFilterSections(all: Self.crowd, activeSubFilters: committed, maxActive: cap)
        #expect(later.capacityLabel == "5 of 12")
        for subFilter in Self.twelve.suffix(7) {
            let promoted = later.activate(subFilter)
            #expect(promoted)
        }
        #expect(later.capacityLabel == "12 of 12")
        let thirteenth = later.activate(Self.crowd[12].subFilter)
        #expect(thirteenth == false)
    }

    @Test("A category row still caps at six")
    func aCategoryRowCapsAtSix() {
        let catalogue = Self.categories(8)
        var sections = MapSubFilterSections(
            all: catalogue, activeSubFilters: [catalogue[0].subFilter],
            maxActive: MapSubFilterSections.maxActive(for: .pinned)
        )
        #expect(sections.capacityLabel == "1 of 6")
        for option in catalogue[1..<6] {
            let promoted = sections.activate(option.subFilter)
            #expect(promoted)
        }
        let seventh = sections.activate(catalogue[6].subFilter)
        #expect(seventh == false)
        #expect(sections.capacityLabel == "6 of 6")
    }

    @Test("A row given more than its type's cap opens with that count as its cap")
    func aRowOverItsTypeCapKeepsItsSize() {
        let crowd = Self.people((1...16).map { "q\($0)" })
        let fourteen = Array(crowd.prefix(14)).map(\.subFilter)
        let peopleRow = MapSubFilterSections(
            all: crowd, activeSubFilters: fourteen,
            maxActive: MapSubFilterSections.maxActive(for: .friends)
        )
        #expect(peopleRow.capacityLabel == "14 of 14")

        let catalogue = Self.categories(9)
        let categoryRow = MapSubFilterSections(
            all: catalogue, activeSubFilters: Array(catalogue.prefix(8)).map(\.subFilter),
            maxActive: MapSubFilterSections.maxActive(for: .pinned)
        )
        #expect(categoryRow.capacityLabel == "8 of 8")
    }
}
