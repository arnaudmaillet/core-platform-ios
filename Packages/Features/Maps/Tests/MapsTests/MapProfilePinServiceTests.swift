import CoreModels
import Foundation
import MapsInterface
import Testing
@testable import Maps

/// THE FAVORITE RAILS' ONE TRICKY RULE, NOW TWICE OVER.
///
/// Each rail in `MapFavoritesStore` is tri-state, and the third state does the
/// damage: `nil` means "never curated", and the map then shows the graph
/// behind that rail — mutuals for Friends, follows for Following. So a person
/// is already on a rail as far as the viewer can see, and the first write has
/// to materialize that list before editing it; write a bare `[id]` instead and
/// everyone else silently leaves the rail.
///
/// It matters more now than when the map was the only caller: the profile
/// screen's star writes through this same service, and it can write ONE rail
/// without disturbing the other.
struct MapProfilePinServiceTests {
    /// The two graph lists the fallbacks resolve to, and nothing else the
    /// service asks for.
    private struct StubFavorites: MapFavoritesProviding {
        let mutuals: [ProfileID]
        let followed: [ProfileID]

        func profiles(for ids: [ProfileID]) async -> [MapFavorite] { [] }
        func friends() async -> [MapFavorite] { mutuals.map(Self.favorite) }
        func following() async -> [MapFavorite] { followed.map(Self.favorite) }

        private static func favorite(_ id: ProfileID) -> MapFavorite {
            MapFavorite(profileID: id, title: id.rawValue)
        }
    }

    /// A store on its own `UserDefaults` suite, so suites running in parallel
    /// cannot read each other's lists — `.standard` is one shared mutable
    /// object and these tests write to it.
    private func makeStore(_ name: String = UUID().uuidString) -> MapFavoritesStore {
        MapFavoritesStore(defaults: UserDefaults(suiteName: name)!)
    }

    private func makeService(
        store: MapFavoritesStore, mutuals: [ProfileID] = [], followed: [ProfileID] = []
    ) -> MapProfilePinService {
        MapProfilePinService(
            store: store, favorites: StubFavorites(mutuals: mutuals, followed: followed)
        )
    }

    // MARK: - Reading

    /// Never curated: what a rail SHOWS is the graph behind it, so that is
    /// what membership has to mean. Reporting empty here would put an unfilled
    /// star on a profile the map is already showing.
    @Test func theGraphIsTheAnswerBeforeAnyCuration() async {
        let mutual = ProfileID("a")
        let follower = ProfileID("b")
        let service = makeService(
            store: makeStore(), mutuals: [mutual], followed: [mutual, follower]
        )

        // A mutual is on all three by default — they are in both graphs, and
        // the dock falls back to the following list.
        #expect(await service.categories(for: mutual) == [.friends, .following, .dock])
        // Someone merely followed is on the two rails open to them.
        #expect(await service.categories(for: follower) == [.following, .dock])
        #expect(await service.categories(for: ProfileID("zzz")).isEmpty)
    }

    /// ⚠️ THE MUTUALITY RULE. The Friends row means friends, so someone who
    /// stops following back leaves it — even though the viewer once put them
    /// there. Enforced on the way OUT rather than by editing the stored list:
    /// the choice survives, and they return if they follow back again.
    @Test func aFormerMutualLeavesTheFriendsRow() async {
        let store = makeStore()
        let id = ProfileID("a")
        store.setPinned([id], in: .friends)
        store.setPinned([id], in: .following)
        store.setPinned([id], in: .dock)
        // Curated onto Friends, but no longer in the mutual graph.
        let service = makeService(store: store, mutuals: [], followed: [id])

        #expect(await service.categories(for: id) == [.following, .dock])
        #expect(store.pinnedProfileIDs(in: .friends) == [id], "the stored choice was destroyed")

        // ...and they come back when the graph says friend again.
        let refriended = makeService(store: store, mutuals: [id], followed: [id])
        #expect(await refriended.categories(for: id) == [.friends, .following, .dock])
    }

    /// The same rule on the way IN: a non-mutual cannot be written onto the
    /// Friends row at all, so a stale menu cannot leave an entry that would
    /// appear the day they happen to follow back.
    @Test func aNonMutualCannotBeWrittenToTheFriendsRow() async {
        let store = makeStore()
        let id = ProfileID("a")
        let service = makeService(store: store, mutuals: [], followed: [id])

        await service.setCategories([.friends, .dock], for: id)

        #expect(store.pinnedProfileIDs(in: .friends)?.contains(id) != true)
        #expect(await service.categories(for: id) == [.dock])
    }

    @Test func aCuratedRailIsAuthoritative() async {
        let store = makeStore()
        store.setPinned([ProfileID("a")], in: .following)
        store.setPinned([], in: .dock)
        // `b` is followed but NOT curated — once the viewer has a list, the
        // graph stops deciding what that rail holds.
        let service = makeService(store: store, followed: [ProfileID("a"), ProfileID("b")])

        #expect(await service.categories(for: ProfileID("a")) == [.following])
        #expect(await service.categories(for: ProfileID("b")).isEmpty)
    }

    /// Curating one rail must not disturb the others: Friends and the dock
    /// still answer from the graph while Following answers from storage.
    @Test func railsAreIndependent() async {
        let store = makeStore()
        let mutual = ProfileID("a")
        store.setPinned([], in: .following)
        let service = makeService(store: store, mutuals: [mutual], followed: [mutual])

        #expect(await service.categories(for: mutual) == [.friends, .dock])
    }

    /// ⚠️ The DOCK keeps the original key — every install that curated
    /// favorites before the rails existed wrote there, and that list has
    /// always been the carousel's.
    @Test func theDockInheritsTheLegacyList() async {
        let suite = "maps-pin-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["prof-7"], forKey: "maps.pinnedFavoriteProfileIDs")
        let service = makeService(
            store: MapFavoritesStore(defaults: defaults), followed: [ProfileID("prof-9")]
        )

        #expect(await service.categories(for: ProfileID("prof-7")) == [.dock])
        // ...and the rails that did not exist yet still read from the graph.
        #expect(await service.categories(for: ProfileID("prof-9")) == [.following])
    }

    // MARK: - Writing

    /// The defect this rule exists to prevent: taking one person off an
    /// uncurated rail must keep everyone else on it.
    @Test func theFirstRemovalMaterializesTheRestOfTheRail() async {
        let store = makeStore()
        let followed = [ProfileID("a"), ProfileID("b"), ProfileID("c")]
        let service = makeService(store: store, followed: followed)

        await service.setCategories([], for: ProfileID("b"))

        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("a"), ProfileID("c")])
        #expect(await service.categories(for: ProfileID("a")) == [.following, .dock])
    }

    @Test func addingSomeoneKeepsThePeopleAlreadyThere() async {
        let store = makeStore()
        let service = makeService(store: store, followed: [ProfileID("a")])

        await service.setCategories([.following], for: ProfileID("z"))

        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("a"), ProfileID("z")])
    }

    /// "Exactly these rails" has to mean removal too, or a checklist row
    /// could add but never take away.
    @Test func settingOneRailRemovesTheOthers() async {
        let store = makeStore()
        let mutual = ProfileID("a")
        let service = makeService(store: store, mutuals: [mutual], followed: [mutual])
        #expect(
            await service.categories(for: mutual) == [.friends, .following, .dock], "precondition"
        )

        await service.setCategories([.friends], for: mutual)

        #expect(await service.categories(for: mutual) == [.friends])
        #expect(store.pinnedProfileIDs(in: .following) == [])
        #expect(store.pinnedProfileIDs(in: .dock) == [])
        #expect(store.pinnedProfileIDs(in: .friends) == [mutual])
    }

    /// A viewer who re-affirms what is already true has still MADE a choice,
    /// and the rail must stop tracking the graph from then on — otherwise a
    /// later unfollow would quietly rewrite it.
    @Test func aNoOpWriteStillCommitsTheChoice() async {
        let store = makeStore()
        let service = makeService(store: store, followed: [ProfileID("a")])

        await service.setCategories([.following], for: ProfileID("a"))

        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("a")],
                "the fallback was left uncommitted")
        // And the rails the profile is NOT on are committed too, so they stop
        // tracking the graph as well.
        #expect(store.pinnedProfileIDs(in: .friends) == [])
        #expect(store.pinnedProfileIDs(in: .dock) == [])
    }

    @Test func writingIsIdempotent() async {
        let store = makeStore()
        let service = makeService(store: store)

        await service.setCategories([.following], for: ProfileID("a"))
        await service.setCategories([.following], for: ProfileID("a"))
        await service.setCategories([], for: ProfileID("ghost"))

        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("a")],
                "a repeat write duplicated the entry")
    }

    @Test func aRoundTripReturnsToTheStartingPoint() async {
        let store = makeStore()
        let service = makeService(store: store, followed: [ProfileID("a")])

        await service.setCategories([.following], for: ProfileID("z"))
        await service.setCategories([], for: ProfileID("z"))

        #expect(await service.categories(for: ProfileID("z")).isEmpty)
        #expect(await service.categories(for: ProfileID("a")) == [.following, .dock])
    }

    // MARK: - Telling the map

    /// The map may already be on screen behind the profile that wrote. Without
    /// this notification its rails keep yesterday's lists, which reads as the
    /// star having done nothing at all.
    @Test func everyWriteAnnouncesItself() async {
        let store = makeStore()
        let service = makeService(store: store)
        let box = Box()
        // Scoped to THIS store: suites run in parallel and every one of them
        // writes to a store of its own.
        let token = NotificationCenter.default.addObserver(
            forName: MapFavoritesStore.didChangeNotification, object: store, queue: nil
        ) { _ in box.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        await service.setCategories([.following], for: ProfileID("a"))

        // One per rail written: both are committed, so both announce.
        #expect(box.count == MapFavoriteCategory.allCases.count)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }
}
