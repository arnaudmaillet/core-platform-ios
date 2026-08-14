import CoreModels
import Foundation
import MapsInterface
import Testing
@testable import Maps

/// TWO BARS, TWO LISTS, TWO UPDATES THAT MUST NOT TOUCH EACH OTHER.
///
/// The map draws people twice: the dock's carousel in the main bar, and the
/// sub-filter row above it. They hold different lists, and every write to
/// either used to wake both — so removing someone from a ROW rebuilt the
/// CAROUSEL, which flashed a list that had not changed.
///
/// Two things keep them apart, and both are pinned here: a change says which
/// rail it was about, and each bar refuses an update that would not change
/// what it is showing.
struct MapBarIsolationTests {
    private static func person(_ id: String) -> MapFavorite {
        MapFavorite(profileID: ProfileID(id), title: id)
    }

    private func makeStore() -> MapFavoritesStore {
        let suite = "maps-isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MapFavoritesStore(defaults: defaults)
    }

    // MARK: - A change names its rail

    /// Without this the observer cannot tell a dock edit from a row edit, and
    /// has to refresh both — which is the flash.
    @Test(arguments: MapFavoriteCategory.allCases)
    func aChangeNamesTheRailItWasAbout(category: MapFavoriteCategory) async {
        let store = makeStore()
        let box = NotificationBox()
        let token = NotificationCenter.default.addObserver(
            forName: MapFavoritesStore.didChangeNotification, object: store, queue: nil
        ) { box.record(MapFavoritesStore.changedCategory(in: $0)) }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setPinned([ProfileID("a")], in: category)

        #expect(box.categories == [category])
    }

    /// And a notification that is not one of ours (or an older one carrying no
    /// category) reads as nil rather than as some default rail — the observer
    /// then refreshes everything, which is slow but never wrong.
    @Test func aCategorylessNotificationNamesNothing() {
        let notification = Notification(
            name: MapFavoritesStore.didChangeNotification, object: nil, userInfo: nil
        )

        #expect(MapFavoritesStore.changedCategory(in: notification) == nil)
    }

    // MARK: - The dock refuses a pointless update

    /// THE FLASH. The carousel is refreshed on every appearance and after any
    /// favorites change, so "the same list again" is its most common input —
    /// and it used to replay its arrival cross-dissolve for each one.
    @Test func anIdenticalCarouselIsANoOp() {
        let people = ["ada", "lena"].map(Self.person)

        #expect(
            MapFilterBarView.FavoritesUpdate.resolve(rendered: people, incoming: people)
                == .unchanged
        )
    }

    /// The first list is an ARRIVAL — it may cross-dissolve in, because there
    /// is nothing on screen for it to disturb.
    @Test func theFirstCarouselPopulates() {
        #expect(
            MapFilterBarView.FavoritesUpdate.resolve(rendered: nil, incoming: [Self.person("ada")])
                == .populate
        )
    }

    /// Every list after that is an edit of one already on screen: only the
    /// pills that changed may move.
    @Test func aChangedCarouselDiffs() {
        let update = MapFilterBarView.FavoritesUpdate.resolve(
            rendered: [Self.person("ada")],
            incoming: ["ada", "lena"].map(Self.person)
        )

        #expect(update == .diff)
    }

    /// Emptying the carousel is still an edit of it, not a fresh arrival.
    @Test func anEmptiedCarouselDiffs() {
        #expect(
            MapFilterBarView.FavoritesUpdate.resolve(rendered: [Self.person("ada")], incoming: [])
                == .diff
        )
    }

    /// An empty first list is still the first list: nothing to disturb, and
    /// the next real list must not be mistaken for an arrival.
    @Test func anEmptyFirstListStillPopulates() {
        #expect(MapFilterBarView.FavoritesUpdate.resolve(rendered: nil, incoming: []) == .populate)
        #expect(
            MapFilterBarView.FavoritesUpdate.resolve(rendered: [], incoming: [Self.person("ada")])
                == .diff
        )
    }

    private final class NotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MapFavoriteCategory?] = []
        var categories: [MapFavoriteCategory?] { lock.withLock { values } }
        func record(_ category: MapFavoriteCategory?) { lock.withLock { values.append(category) } }
    }
}
