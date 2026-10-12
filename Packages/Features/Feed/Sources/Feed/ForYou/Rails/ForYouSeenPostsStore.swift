import CoreModels
import CoreStorage
import Foundation

/// The friends' posts the viewer has OPENED from the stories row — what
/// clears a story's ring, persisted so it stays cleared across launches.
///
/// **Why a set of ids and not a watermark.** Everything else "new" on this
/// screen is a watermark (`ForYouUnreadStore`, `ForYouSessionWatermark`): the
/// instant the viewer caught up to. A ring is a different question — "have I
/// watched THIS friend's posts" — asked per friend, answered by a deliberate
/// gesture, and a per-friend watermark would have to be capped at the present
/// moment (a watermark is never set past now, see `ForYouUnreadStore
/// .markSeen`) — which leaves a clock-skewed or future-dated post (every mock
/// arrival is one) new FOR EVER, its ring un-clearable however often it is
/// opened. An id is seen or it is not, whatever its timestamp says.
///
/// Bounded: the newest `capacity` ids are kept and the oldest fall off. A post
/// old enough to fall off is older than the session baseline anyway, so it can
/// no longer be "new" and forgetting it changes nothing on screen.
///
/// **The viewer's own (#978).** What a person has opened is theirs: the key is
/// the active profile's (`StorageScope.profileKey`, the #443 policy), so a
/// profile switch or another account reads its own set. The device-wide key
/// of earlier builds is adopted once, by the first profile that reads it.
public final class ForYouSeenPostsStore {
    private let defaults: UserDefaults
    private let baseKey: String
    private let scope: StorageScope
    private let capacity: Int
    /// The scoped key the copy below was read from; another one is read afresh.
    private var loadedKey: String?
    /// In insertion order, oldest first — what the cap trims.
    private var ordered: [String] = []
    private var members: Set<String> = []

    public init(
        defaults: UserDefaults = .standard,
        key: String = "foryou.friends.seen",
        capacity: Int = 400,
        scope: StorageScope = .shared
    ) {
        self.defaults = defaults
        self.baseKey = key
        self.capacity = capacity
        self.scope = scope
    }

    public func contains(_ id: PostID) -> Bool {
        loadIfViewerChanged()
        return members.contains(id.rawValue)
    }

    /// Reads the current viewer's set when the viewer is not the one the copy
    /// in memory belongs to. Returns the key to write under.
    @discardableResult
    private func loadIfViewerChanged() -> String {
        let key = scope.profileKey(baseKey, adoptingLegacyIn: defaults)
        guard key != loadedKey else { return key }
        loadedKey = key
        ordered = defaults.stringArray(forKey: key) ?? []
        members = Set(ordered)
        return key
    }

    /// Records `ids` as seen. Returns whether anything was new to the store —
    /// a caller republishes only when it was.
    @discardableResult
    public func insert(_ ids: [PostID]) -> Bool {
        let key = loadIfViewerChanged()
        let fresh = ids.map(\.rawValue).filter { !members.contains($0) }
        guard !fresh.isEmpty else { return false }
        // A post opened twice in one call is one entry.
        for id in fresh where members.insert(id).inserted {
            ordered.append(id)
        }
        if ordered.count > capacity {
            let dropped = ordered.prefix(ordered.count - capacity)
            members.subtract(dropped)
            ordered.removeFirst(dropped.count)
        }
        defaults.set(ordered, forKey: key)
        return true
    }
}
