import CoreModels
import Foundation
import MapsInterface
import Testing
@testable import Maps

/// The tri-state persistence behind the favorites section, ONE LIST PER RAIL:
/// nil until that rail is first curated (→ its graph fallback), then an
/// authoritative ordered list.
struct MapFavoritesStoreTests {
    private func makeStore() -> MapFavoritesStore {
        // Unique suite per test — the swift-testing runner is parallel, and a
        // shared suite would let one test's writes race another's reads.
        let suite = "maps-favorites-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MapFavoritesStore(defaults: defaults)
    }

    @Test func startsUncuratedAsNilNotEmpty() {
        // nil vs [] is the fallback contract — an empty ARRAY would mean
        // "curated everything away", which must render no favorites.
        let store = makeStore()
        for category in MapFavoriteCategory.allCases {
            #expect(store.pinnedProfileIDs(in: category) == nil)
        }
    }

    @Test func persistsAnOrderedList() {
        let store = makeStore()
        store.setPinned([ProfileID("prof-3"), ProfileID("prof-0")], in: .following)
        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("prof-3"), ProfileID("prof-0")])

        store.setPinned([], in: .following)
        #expect(store.pinnedProfileIDs(in: .following) == [])
    }

    /// The rails are separate storage, not one list with a tag: writing one
    /// must leave the other exactly as it was — including still uncurated,
    /// which is a state an accidental shared key would destroy.
    @Test func theRailsDoNotShareStorage() {
        let store = makeStore()
        store.setPinned([ProfileID("prof-1")], in: .friends)

        #expect(store.pinnedProfileIDs(in: .friends) == [ProfileID("prof-1")])
        #expect(store.pinnedProfileIDs(in: .following) == nil, "writing Friends curated Following")
    }

    /// ⚠️ The Following rail keeps the ORIGINAL key. Every install that
    /// curated favorites before the split wrote there, and renaming it would
    /// silently empty their rail — the migration nobody would notice until
    /// their people were gone.
    @Test func theFollowingRailKeepsTheLegacyKey() {
        let suite = "maps-favorites-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["prof-7"], forKey: "maps.pinnedFavoriteProfileIDs")

        let store = MapFavoritesStore(defaults: defaults)

        #expect(store.pinnedProfileIDs(in: .following) == [ProfileID("prof-7")])
    }
}
