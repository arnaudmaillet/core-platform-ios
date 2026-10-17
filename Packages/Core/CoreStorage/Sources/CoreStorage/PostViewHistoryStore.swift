import Foundation

/// The posts the viewer viewed (#1344): the profile's History tab, newest
/// first. Every post opened or swiped onto in the vertical feed counts, the
/// moment it becomes the page on screen (the owner, 2026-10-17: like
/// Instagram or TikTok).
///
/// **On the device, for now.** The backend keeps no viewing history yet
/// (arnaudmaillet/core-platform-backend#944): this pile is the whole truth,
/// one per profile (`StorageScope`), so a profile switch shows that
/// profile's history. A server list replaces it once #944 ships.
///
/// A re-viewed post moves to the front rather than appearing twice, and the
/// pile keeps the `capacity` most recent. Each view keeps WHEN it happened,
/// which the tab groups by day (#1344).
public final class PostViewHistoryStore: @unchecked Sendable {
    /// The app's one pile: the feed records into it, the profile reads it.
    public static let shared = PostViewHistoryStore()

    static let baseKey = "profile.viewHistory"
    /// When each post in the pile was last viewed, in seconds since 1970 —
    /// beside the ids rather than in them, so a pile written before the times
    /// were kept still reads.
    static let timesBaseKey = "profile.viewHistory.times"
    /// The most recent posts kept.
    public static let capacity = 300

    private let defaults: UserDefaults
    private let scope: StorageScope
    private var key: String { scope.profileKey(Self.baseKey, adoptingLegacyIn: defaults) }
    private var timesKey: String { scope.profileKey(Self.timesBaseKey, adoptingLegacyIn: defaults) }
    /// The clock a view is stamped with. Tests set it.
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// Fires after every change, on whatever thread made it — the History
    /// tab reloads from this rather than polling.
    public var onChange: (() -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    private var _onChange: (() -> Void)?

    public init(
        defaults: UserDefaults = .standard, scope: StorageScope = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.scope = scope
        self.now = now
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

    /// One post of the pile and when it was last viewed — nil for a view
    /// recorded before the times were kept.
    public struct View: Equatable, Sendable {
        public let postID: String
        public let viewedAt: Date?

        public init(postID: String, viewedAt: Date?) {
            self.postID = postID
            self.viewedAt = viewedAt
        }
    }

    /// The pile with its times, most recently viewed first.
    public var views: [View] {
        lock.withLock {
            let times = defaults.dictionary(forKey: timesKey) as? [String: Double] ?? [:]
            return (defaults.array(forKey: key) as? [String] ?? []).map { id in
                View(postID: id, viewedAt: times[id].map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// The viewer viewed `id`: it goes to the front, stamped now.
    public func record(_ id: String) {
        let stamp = now().timeIntervalSince1970
        mutate(stamping: (id, stamp)) { ids in
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

    /// Changes the pile, and its times with it: `stamping` dates one id, and
    /// the times of ids no longer in the pile go. A re-view of the post
    /// already at the front changes no order but is still a change — its day
    /// may have moved.
    private func mutate(stamping: (id: String, at: Double)? = nil, _ change: (inout [String]) -> Void) {
        let handler: (() -> Void)? = lock.withLock {
            var ids = defaults.array(forKey: key) as? [String] ?? []
            var times = defaults.dictionary(forKey: timesKey) as? [String: Double] ?? [:]
            let before = (ids, times)
            change(&ids)
            if let stamping { times[stamping.id] = stamping.at }
            let kept = Set(ids)
            times = times.filter { kept.contains($0.key) }
            guard ids != before.0 || times != before.1 else { return nil }
            defaults.set(ids, forKey: key)
            defaults.set(times, forKey: timesKey)
            return _onChange
        }
        handler?()
    }
}
