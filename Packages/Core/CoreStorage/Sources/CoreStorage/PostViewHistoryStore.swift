import Foundation

/// The posts the viewer viewed (#1344): the profile's History tab, newest
/// first. A post counts once it has stayed on screen in the vertical feed for
/// `PostViewHistoryStore.dwell` — the feed records it; a fast swipe-past
/// never reaches here.
///
/// **On the device, for now.** The backend keeps no viewing history yet
/// (arnaudmaillet/core-platform-backend#944): this pile is the whole truth,
/// one per profile (`StorageScope`), so a profile switch shows that
/// profile's history. A server list replaces it once #944 ships.
///
/// A re-viewed post moves to the front rather than appearing twice, and the
/// pile keeps the `capacity` most recent.
public final class PostViewHistoryStore: @unchecked Sendable {
    /// The app's one pile: the feed records into it, the profile reads it.
    public static let shared = PostViewHistoryStore()

    /// How long a post must stay on screen to count as viewed (the owner,
    /// 2026-10-17): a fast swipe-past is not a view.
    public static let dwell: TimeInterval = 2

    static let baseKey = "profile.viewHistory"
    /// The most recent posts kept.
    public static let capacity = 300

    private let defaults: UserDefaults
    private let scope: StorageScope
    private var key: String { scope.profileKey(Self.baseKey, adoptingLegacyIn: defaults) }
    private let lock = NSLock()

    /// Fires after every change, on whatever thread made it — the History
    /// tab reloads from this rather than polling.
    public var onChange: (() -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    private var _onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard, scope: StorageScope = .shared) {
        self.defaults = defaults
        self.scope = scope
        #if DEBUG
        // Every profile's pile: the active profile is not known yet at launch.
        if ProcessInfo.processInfo.arguments.contains("-reset-view-history") {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.baseKey) {
                defaults.removeObject(forKey: key)
            }
        }
        #endif
    }

    /// Most recently viewed first.
    public var postIDs: [String] {
        lock.withLock { defaults.array(forKey: key) as? [String] ?? [] }
    }

    /// The viewer viewed `id`: it goes to the front.
    public func record(_ id: String) {
        mutate { ids in
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
            if ids.count > Self.capacity { ids.removeLast(ids.count - Self.capacity) }
        }
    }

    /// Takes one post out of the history.
    public func remove(_ id: String) {
        mutate { $0.removeAll { $0 == id } }
    }

    /// Empties the history.
    public func clear() {
        mutate { $0.removeAll() }
    }

    private func mutate(_ change: (inout [String]) -> Void) {
        let handler: (() -> Void)? = lock.withLock {
            var ids = defaults.array(forKey: key) as? [String] ?? []
            let before = ids
            change(&ids)
            guard ids != before else { return nil }
            defaults.set(ids, forKey: key)
            return _onChange
        }
        handler?()
    }
}
