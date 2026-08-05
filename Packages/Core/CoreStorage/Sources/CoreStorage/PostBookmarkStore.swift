import Foundation

/// The posts the viewer has saved.
///
/// **Client-side, and that is the whole truth rather than a stand-in for it.**
/// No wire contract for saving exists — `engagement.v1` carries reactions,
/// views and shares and nothing else, and no service anywhere accepts a "saved
/// by" predicate — so there is no server answer this could disagree with. That
/// is the same footing `MapFavoritesStore` stands on for the map's pinned
/// profiles, and this follows its shape deliberately.
///
/// ⚠️ It also means what this is NOT. A saved list that lives on the device
/// does not follow the viewer to another one and does not survive deleting the
/// app. When a real seam arrives, this becomes a local cache in front of it and
/// the reconciliation is the interesting part — a post saved here while offline
/// has to be pushed, and one saved elsewhere has to arrive. Nothing here
/// pretends that work is done.
///
/// Order is preserved and most-recent-first, because a saved list is read as a
/// pile rather than as a set: the thing you saved a minute ago is the thing you
/// came back for.
public final class PostBookmarkStore: @unchecked Sendable {
    private static let key = "profile.savedPostIDs"
    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Fires after every change, on whatever thread made it — the profile's
    /// Saved tab reloads from this rather than polling.
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-reset-bookmarks`: deterministic QA, so a scripted launch always
        // starts from an empty pile. The map's favorites store carries the
        // same hook for the same reason.
        if ProcessInfo.processInfo.arguments.contains("-reset-bookmarks") {
            defaults.removeObject(forKey: Self.key)
        }
        // `-seed-bookmarks a,b,c`: a pile without having to save three posts by
        // hand first. The Saved tab is otherwise empty on a fresh install,
        // which is exactly the state that cannot show whether it renders.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-seed-bookmarks"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let ids = ProcessInfo.processInfo.arguments[index + 1]
                .split(separator: ",")
                .map(String.init)
            defaults.set(ids, forKey: Self.key)
        }
        #endif
    }

    /// Most recently saved first.
    public var savedPostIDs: [String] {
        lock.withLock { defaults.array(forKey: Self.key) as? [String] ?? [] }
    }

    public func isSaved(_ id: String) -> Bool {
        savedPostIDs.contains(id)
    }

    /// Saves, or unsaves if it was already there, and reports which it did.
    ///
    /// Returns the new state rather than nothing, because every caller so far
    /// needs it immediately: the glyph flips from it.
    @discardableResult
    public func toggle(_ id: String) -> Bool {
        let saved: Bool = lock.withLock {
            var ids = defaults.array(forKey: Self.key) as? [String] ?? []
            if let existing = ids.firstIndex(of: id) {
                ids.remove(at: existing)
                defaults.set(ids, forKey: Self.key)
                return false
            }
            // Front, not back: newest first is how the pile reads.
            ids.insert(id, at: 0)
            defaults.set(ids, forKey: Self.key)
            return true
        }
        onChange?()
        return saved
    }
}
