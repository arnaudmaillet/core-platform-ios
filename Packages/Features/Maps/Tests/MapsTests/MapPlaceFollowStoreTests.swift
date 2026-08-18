import Foundation
import Testing
@testable import Maps

/// The followed-places persistence behind the gallery header's toggle and the
/// Places row's Favorites refinement: a flat set of place ids, toggled on and
/// off, with a change notification per write.
struct MapPlaceFollowStoreTests {
    private func makeSuite() -> UserDefaults {
        // Unique suite per test — the swift-testing runner is parallel, and a
        // shared suite would let one test's writes race another's reads.
        let suite = "maps-place-follows-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func togglingFollowsThenUnfollows() {
        let store = MapPlaceFollowStore(defaults: makeSuite())
        #expect(!store.isFollowed("city:paris"))
        #expect(store.followedPlaceIDs.isEmpty)

        #expect(store.toggle("city:paris") == true)
        #expect(store.isFollowed("city:paris"))
        #expect(store.followedPlaceIDs == ["city:paris"])

        #expect(store.toggle("city:paris") == false)
        #expect(!store.isFollowed("city:paris"))
        #expect(store.followedPlaceIDs.isEmpty)
    }

    /// The active favorites list is the union of everything toggled ON —
    /// following one place never disturbs another.
    @Test func followsAccumulateIndependently() {
        let store = MapPlaceFollowStore(defaults: makeSuite())
        store.toggle("city:paris")
        store.toggle("region:idf")
        store.toggle("country:spain")
        store.toggle("region:idf") // and back off again
        #expect(store.followedPlaceIDs == ["city:paris", "country:spain"])
    }

    /// The set survives the store instance — it is the DEFAULTS that hold it.
    @Test func followsPersistAcrossInstances() {
        let defaults = makeSuite()
        MapPlaceFollowStore(defaults: defaults).toggle("city:paris")
        #expect(MapPlaceFollowStore(defaults: defaults).isFollowed("city:paris"))
    }

    /// Every write posts the change notification, scoped to the store that
    /// wrote (parallel suites must not count each other's writes) — what the
    /// map observes to re-apply an active Favorites refinement.
    @Test func everyTogglePostsTheChangeNotification() {
        let store = MapPlaceFollowStore(defaults: makeSuite())
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: MapPlaceFollowStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.toggle("city:paris")
        store.toggle("city:paris")
        #expect(posts == 2)
    }
}
