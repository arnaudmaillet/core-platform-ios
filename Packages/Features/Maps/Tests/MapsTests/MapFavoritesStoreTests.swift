import CoreModels
import Foundation
import Testing
@testable import Maps

/// The tri-state persistence behind the favorites section: nil until first
/// curated (→ following fallback), then an authoritative ordered list.
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
        #expect(makeStore().pinnedProfileIDs == nil)
    }

    @Test func persistsAnOrderedList() {
        let store = makeStore()
        store.setPinned([ProfileID("prof-3"), ProfileID("prof-0")])
        #expect(store.pinnedProfileIDs == [ProfileID("prof-3"), ProfileID("prof-0")])

        store.setPinned([])
        #expect(store.pinnedProfileIDs == [])
    }
}
