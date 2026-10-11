import CoreModels
import MapsInterface
import Testing
@testable import Maps

/// The sub-filter row's session memory: the viewer's dragged order and
/// deleted rows per primary, the people caches behind the sheet, and the mutes.
///
/// These rules used to sit inside `MapsViewController`, reachable only
/// through a live screen. A wrong answer is quiet: a deleted person comes
/// back on the next background refresh, or a dragged row jumps back to where
/// the graph put it.
struct MapSubFilterRowMemoryTests {
    private static func person(_ id: String) -> MapFavorite {
        MapFavorite(profileID: ProfileID(id), title: id)
    }

    private static func people(_ ids: String...) -> [MapSubFilterOption] {
        MapSubFilterOption.people(ids.map(person))
    }

    private static func ids(_ options: [MapSubFilterOption]) -> [String] {
        options.compactMap { $0.favorite?.profileID.rawValue }
    }

    // MARK: - Order and deletions

    @Test("A row nobody arranged comes back exactly as the graph built it")
    func untouchedRowKeepsItsOrder() {
        let memory = MapSubFilterRowMemory()

        let ordered = memory.ordered(Self.people("ada", "ben", "cyd"), for: .friends)

        #expect(Self.ids(ordered) == ["ada", "ben", "cyd"])
    }

    @Test("Without a selected primary the options pass through untouched")
    func noPrimaryPassesThrough() {
        var memory = MapSubFilterRowMemory()
        memory.adopt(Self.people("cyd", "ada"), for: .friends)

        let ordered = memory.ordered(Self.people("ada", "ben", "cyd"), for: nil)

        #expect(Self.ids(ordered) == ["ada", "ben", "cyd"])
    }

    @Test("A dragged order survives a refresh, and newcomers land at the end in the graph's order")
    func draggedOrderSurvivesARefresh() {
        var memory = MapSubFilterRowMemory()
        memory.adopt(Self.people("cyd", "ada"), for: .following)

        let ordered = memory.ordered(Self.people("ada", "eve", "cyd", "dan"), for: .following)

        #expect(Self.ids(ordered) == ["cyd", "ada", "eve", "dan"])
    }

    @Test("A person deleted in the sheet stays gone when the graph still returns them")
    func deletedRowStaysGone() {
        var memory = MapSubFilterRowMemory()
        memory.catalogue[.friends] = ["ada", "ben", "cyd"].map(Self.person)
        memory.adopt(Self.people("ada", "cyd"), for: .friends)

        let ordered = memory.ordered(Self.people("ada", "ben", "cyd"), for: .friends)

        #expect(Self.ids(ordered) == ["ada", "cyd"])
        #expect(memory.hidden[.friends] == [.profile(ProfileID("ben"))])
    }

    @Test("Adding someone back from the Available section un-hides them in the same commit")
    func promotionUnhides() {
        var memory = MapSubFilterRowMemory()
        memory.catalogue[.friends] = ["ada", "ben"].map(Self.person)
        memory.adopt(Self.people("ada"), for: .friends)

        memory.adopt(Self.people("ben", "ada"), for: .friends)

        #expect(memory.hidden[.friends] == [])
        #expect(Self.ids(memory.ordered(Self.people("ada", "ben"), for: .friends)) == ["ben", "ada"])
    }

    @Test("Each primary keeps its own arrangement")
    func primariesDoNotShareAnArrangement() {
        var memory = MapSubFilterRowMemory()
        memory.catalogue[.friends] = ["ada", "ben"].map(Self.person)
        memory.adopt(Self.people("ben"), for: .friends)

        let following = memory.ordered(Self.people("ada", "ben"), for: .following)

        #expect(Self.ids(following) == ["ada", "ben"])
    }

    @Test("Removing a place category hides it against the fixed vocabulary")
    func placeCategoryRemovalHidesIt() {
        var memory = MapSubFilterRowMemory()
        let kept = MapSubFilterOption.placeCategories.filter { $0.subFilter != .placeCategory("parks") }

        memory.adopt(kept, for: .pinned)

        #expect(memory.hidden[.pinned] == [.placeCategory("parks")])
        #expect(memory.order[.pinned] == kept.map(\.subFilter))
        #expect(memory.ordered(MapSubFilterOption.placeCategories, for: .pinned).map(\.subFilter)
            == kept.map(\.subFilter))
    }

    // MARK: - Primaries

    @Test("Only Friends and Following curate a rail")
    func railCategories() {
        #expect(MapSubFilterRowMemory.railCategory(for: .friends) == .friends)
        #expect(MapSubFilterRowMemory.railCategory(for: .following) == .following)
        #expect(MapSubFilterRowMemory.railCategory(for: .pinned) == nil)
        #expect(MapSubFilterRowMemory.railCategory(for: .profile(ProfileID("ada"))) == nil)
    }

    @Test("The sheet's title names the primary, and All or a favorite gets no sheet")
    func sheetTitles() {
        #expect(MapSubFilterRowMemory.title(for: .friends) == "Friends")
        #expect(MapSubFilterRowMemory.title(for: .following) == "Following")
        #expect(MapSubFilterRowMemory.title(for: .pinned) == "Places")
        #expect(MapSubFilterRowMemory.title(for: nil) == nil)
        #expect(MapSubFilterRowMemory.title(for: .profile(ProfileID("ada"))) == nil)
    }

    @Test("The sheet offers the primary's whole graph, the place vocabulary, or nothing")
    func catalogueOptions() {
        var memory = MapSubFilterRowMemory()
        memory.catalogue[.following] = ["ada", "ben"].map(Self.person)

        #expect(Self.ids(memory.catalogueOptions(for: .following)) == ["ada", "ben"])
        #expect(memory.catalogueOptions(for: .friends).isEmpty)
        #expect(memory.catalogueOptions(for: .pinned) == MapSubFilterOption.placeCategories)
        #expect(memory.catalogueOptions(for: nil).isEmpty)
        #expect(memory.catalogueOptions(for: .nearby).isEmpty)
    }

    @Test("An empty row keeps its seat only while the catalogue has someone to add back")
    func rowStateReadsTheCatalogue() {
        var memory = MapSubFilterRowMemory()

        #expect(memory.rowState(primary: .friends, people: []).hasCatalogue == false)

        memory.catalogue[.friends] = [Self.person("ada")]
        let state = memory.rowState(primary: .friends, people: [])

        #expect(state == MapSubFilterRowState(primary: .friends, people: [], hasCatalogue: true))
    }

    // MARK: - Mute and viewer change

    @Test("Muting twice unmutes")
    func muteToggles() {
        var memory = MapSubFilterRowMemory()
        let ada = ProfileID("ada")

        memory.toggleMute(ada)
        #expect(memory.isMuted(ada))
        #expect(!memory.isMuted(ProfileID("ben")))

        memory.toggleMute(ada)
        #expect(!memory.isMuted(ada))
    }

    @Test("A viewer change forgets the people and keeps the arrangement and the mutes")
    func viewerChangeForgetsOnlyThePeople() {
        var memory = MapSubFilterRowMemory()
        memory.people[.friends] = [Self.person("ada")]
        memory.catalogue[.friends] = ["ada", "ben"].map(Self.person)
        memory.adopt(Self.people("ada"), for: .friends)
        memory.toggleMute(ProfileID("ada"))

        memory.forgetPeople()

        #expect(memory.people.isEmpty)
        #expect(memory.catalogue.isEmpty)
        #expect(memory.order[.friends] == [.profile(ProfileID("ada"))])
        #expect(memory.hidden[.friends] == [.profile(ProfileID("ben"))])
        #expect(memory.isMuted(ProfileID("ada")))
    }
}
