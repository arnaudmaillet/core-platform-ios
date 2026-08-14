import CoreModels
import Foundation
import MapsInterface

/// Client-side persistence for the filter bar's favorites — the profiles the
/// viewer keeps on the map's people rails. No backend contract for favorites
/// exists, so this is the source of truth.
///
/// **One list per rail** (`MapFavoriteCategory`) — the dock's carousel and the
/// two sub-filter rows — because they are different places on screen and a
/// favorite has to say which it wants. They are stored, read and materialized
/// independently: docking someone must not put them in a row, and taking them
/// out of a row must not undock them.
///
/// Tri-state by design, per list: `nil` means the viewer has NEVER curated
/// that rail — it then falls back to the graph behind it (mutuals for Friends,
/// follows for Following and for the dock), so fresh installs still show a
/// lively bar. The first pin/unpin materializes whatever was on screen into a
/// real list and appends the change; from then on the stored list is
/// authoritative — subject, for Friends, to the mutuality rule
/// `MapProfilePinService` applies on the way out.
public final class MapFavoritesStore: @unchecked Sendable {
    /// The DOCK's key is the ORIGINAL one, unversioned and unrenamed: the
    /// carousel is what that list has always filled, and every existing
    /// install wrote there. Changing it would silently empty the dock of
    /// anyone who had curated it. The two sub-filter rows are new lists, so
    /// they get new keys.
    private static func key(for category: MapFavoriteCategory) -> String {
        switch category {
        case .dock: "maps.pinnedFavoriteProfileIDs"
        case .following: "maps.pinnedFavoriteProfileIDs.following"
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
    /// `userInfo` key naming the rail that changed, so an observer can refresh
    /// the ONE surface that shows it. Without it every write woke every
    /// surface: editing a sub-filter row rebuilt the dock's carousel, which is
    /// a different list that had not moved.
    public static let changedCategoryKey = "category"

    /// The rail a change notification is about, or nil if it is not one of
    /// ours. Read through this rather than by reaching into `userInfo`, so the
    /// key and its encoding stay in one place.
    public static func changedCategory(in notification: Notification) -> MapFavoriteCategory? {
        (notification.userInfo?[changedCategoryKey] as? String).flatMap(MapFavoriteCategory.init)
    }

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
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changedCategoryKey: category.rawValue]
        )
    }
}
