import Foundation

/// The sounds the viewer has saved — the sound sheet's bookmark.
///
/// **Client-side, on the same footing as `PostBookmarkStore`, and for the same
/// reason**: no wire contract saves anything, a sound least of all — `post.v1`
/// does not even carry a post's sound yet (see `PostSound`). There is no
/// server answer this could disagree with, and nothing reads the list back
/// yet: a "Saved sounds" shelf is the obvious next surface, and it would read
/// `savedSoundIDs`.
///
/// ⚠️ What it is NOT, as for saved posts: a list that follows the viewer to
/// another device or survives deleting the app. When a seam arrives this
/// becomes a cache in front of it.
///
/// Most recently saved first, like the post pile.
public final class SavedSoundStore: @unchecked Sendable {
    private static let key = "feed.savedSoundIDs"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recently saved first.
    public var savedSoundIDs: [String] {
        lock.withLock { defaults.array(forKey: Self.key) as? [String] ?? [] }
    }

    public func isSaved(_ id: String) -> Bool {
        savedSoundIDs.contains(id)
    }

    /// Saves, or unsaves if it was already saved, and returns the new state —
    /// the glyph flips from it.
    @discardableResult
    public func toggle(_ id: String) -> Bool {
        lock.withLock {
            var ids = defaults.array(forKey: Self.key) as? [String] ?? []
            if let existing = ids.firstIndex(of: id) {
                ids.remove(at: existing)
                defaults.set(ids, forKey: Self.key)
                return false
            }
            ids.insert(id, at: 0)
            defaults.set(ids, forKey: Self.key)
            return true
        }
    }
}
