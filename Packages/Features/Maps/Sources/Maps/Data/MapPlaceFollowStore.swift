import Foundation

/// Client-side persistence for FOLLOWED PLACES — the cities/regions/countries
/// the viewer favorites from a place gallery's header. No backend contract for
/// place follows exists (places themselves are mock-era, `BACKEND_GAPS` §18),
/// so, like `MapFavoritesStore` for people, the device is the source of truth.
///
/// Keys are `MapPlace.id` ("city:paris") rather than the H3 index: the id is
/// the place's IDENTITY (stable across resolution changes and present on every
/// rung), where the cell is its geometry. When `GeoCluster` ships, the stored
/// ids migrate 1:1 onto `cluster_id`.
///
/// A `Set`, not a list: follows have no viewer-arranged order (the Favorites
/// sub-filter shows matching places wherever they are on the map), so there is
/// nothing for insertion order to mean.
public final class MapPlaceFollowStore: @unchecked Sendable {
    private static let key = "maps.followedPlaceIDs"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-maps-reset-followed-places`: deterministic QA — every scripted
        // launch starts unfollowed.
        if ProcessInfo.processInfo.arguments.contains("-maps-reset-followed-places") {
            defaults.removeObject(forKey: Self.key)
        }
        // `-maps-follow-place <placeID>`: start with one place followed, so a
        // launch can land straight on the Favorites sub-filter's filtered map
        // without driving the gallery toggle first.
        if let position = ProcessInfo.processInfo.arguments.firstIndex(of: "-maps-follow-place"),
           position + 1 < ProcessInfo.processInfo.arguments.count {
            let seeded = ProcessInfo.processInfo.arguments[position + 1]
            var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
            ids.insert(seeded)
            defaults.set(ids.sorted(), forKey: Self.key)
        }
        #endif
    }

    /// Posted after every write — same contract (and same reasoning) as
    /// `MapFavoritesStore.didChangeNotification`: the map re-applies its
    /// Favorites sub-filter, however the write arrived. `object` is the store,
    /// so parallel test suites don't count each other's writes.
    public static let didChangeNotification = Notification.Name("maps.placeFollows.didChange")

    public var followedPlaceIDs: Set<String> {
        lock.withLock { Set(defaults.stringArray(forKey: Self.key) ?? []) }
    }

    public func isFollowed(_ placeID: String) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: Self.key) ?? []).contains(placeID) }
    }

    /// Follows an unfollowed place and unfollows a followed one.
    /// - Returns: the NEW state, which is what the toggling button renders.
    @discardableResult
    public func toggle(_ placeID: String) -> Bool {
        let nowFollowed: Bool = lock.withLock {
            var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
            let inserted = ids.insert(placeID).inserted
            if !inserted { ids.remove(placeID) }
            // Sorted so the persisted array is deterministic — sets have no
            // order and defaults round-trip arrays.
            defaults.set(ids.sorted(), forKey: Self.key)
            return inserted
        }
        // Outside the lock, like every store here: an observer re-entering
        // the store must not deadlock.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return nowFollowed
    }
}
