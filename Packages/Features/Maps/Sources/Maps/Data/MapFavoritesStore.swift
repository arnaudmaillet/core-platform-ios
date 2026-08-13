import CoreModels
import Foundation
import MapsInterface

/// Client-side persistence for the filter bar's favorites — the profiles the
/// viewer keeps on the map's people rails. No backend contract for favorites
/// exists, so this is the source of truth.
///
/// **One list per rail** (`MapFavoriteCategory`), because the map's primaries
/// already split people that way and a favorite has to say which rail it wants
/// to sit on. They are stored, read and materialized independently: a mutual
/// can be on Friends, on Following, on both, or on neither, and putting them
/// on one must not disturb the other.
///
/// Tri-state by design, per list: `nil` means the viewer has NEVER curated
/// that rail — it then falls back to the graph behind it (mutuals for Friends,
/// follows for Following), so fresh installs still show a lively rail. The
/// first pin/unpin materializes whatever was on screen into a real list and
/// appends the change; from then on the stored list is authoritative.
public final class MapFavoritesStore: @unchecked Sendable {
    /// The Following rail's key is the ORIGINAL one, unversioned and
    /// unrenamed: it is what every existing install has already written, and
    /// changing it would silently empty the rail of anyone who had curated it.
    /// Friends is the new list, so it gets the new key.
    private static func key(for category: MapFavoriteCategory) -> String {
        switch category {
        case .following: "maps.pinnedFavoriteProfileIDs"
        case .friends: "maps.pinnedFavoriteProfileIDs.friends"
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-maps-reset-favorites`: deterministic QA — wipe the curated lists
        // so a scripted launch always starts from the graph fallback.
        if ProcessInfo.processInfo.arguments.contains("-maps-reset-favorites") {
            for category in MapFavoriteCategory.allCases {
                defaults.removeObject(forKey: Self.key(for: category))
            }
        }
        #endif
    }

    /// Posted after every write, so a map already on screen re-reads its rails
    /// instead of showing yesterday's list.
    ///
    /// On the store rather than on `MapProfilePinService` deliberately: what
    /// changed is the storage, and an observer must not be able to miss a
    /// write because it arrived through a different door. Today the other door
    /// is the profile's star button; tomorrow it might be a settings screen or
    /// a restore.
    public static let didChangeNotification = Notification.Name("maps.favorites.didChange")

    /// The curated list for one rail, in pin order; `nil` when never curated.
    public func pinnedProfileIDs(in category: MapFavoriteCategory) -> [ProfileID]? {
        lock.withLock {
            (defaults.array(forKey: Self.key(for: category)) as? [String])
                .map { $0.map { ProfileID($0) } }
        }
    }

    /// Replaces one rail's curated list (used to materialize the on-screen
    /// fallback before the first mutation).
    public func setPinned(_ ids: [ProfileID], in category: MapFavoriteCategory) {
        lock.withLock { defaults.set(ids.map(\.rawValue), forKey: Self.key(for: category)) }
        // Outside the lock: an observer that re-entered this store while it
        // was held would deadlock on a non-recursive lock, and posting is not
        // part of the write.
        //
        // `object` is the store that changed. The app has one and observes
        // with `nil` (every change is its change); tests run suites in
        // PARALLEL against their own stores, and an unscoped post makes each
        // of them count the others' writes.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
