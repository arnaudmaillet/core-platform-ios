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
}
