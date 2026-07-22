import CoreModels
import Foundation

/// Client-side persistence for the main bar's favorites section — the
/// profiles the viewer pinned (long-press on a friend/following pill). No
/// backend contract for favorites exists, so this is the source of truth.
///
/// Tri-state by design: `pinnedProfileIDs == nil` means the viewer has NEVER
/// curated favorites — the bar then falls back to the followed profiles (the
/// original Phase-1 stand-in), so fresh installs still show a lively rail.
/// The first pin/unpin materializes whatever was on screen into a real list
/// and appends the change; from then on the stored list is authoritative.
public final class MapFavoritesStore: @unchecked Sendable {
    private static let key = "maps.pinnedFavoriteProfileIDs"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-maps-reset-favorites`: deterministic QA — wipe the curated list
        // so a scripted launch always starts from the following fallback.
        if ProcessInfo.processInfo.arguments.contains("-maps-reset-favorites") {
            defaults.removeObject(forKey: Self.key)
        }
        #endif
    }

    /// The curated list, in pin order; `nil` when never curated.
    public var pinnedProfileIDs: [ProfileID]? {
        lock.withLock {
            (defaults.array(forKey: Self.key) as? [String]).map { $0.map { ProfileID($0) } }
        }
    }

    /// Replaces the curated list (used to materialize the on-screen fallback
    /// before the first mutation).
    public func setPinned(_ ids: [ProfileID]) {
        lock.withLock { defaults.set(ids.map(\.rawValue), forKey: Self.key) }
    }
}
