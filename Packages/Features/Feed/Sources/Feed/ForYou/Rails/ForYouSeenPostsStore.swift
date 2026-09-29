import CoreModels
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
public final class ForYouSeenPostsStore {
    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    /// In insertion order, oldest first — what the cap trims.
    private var ordered: [String]
    private var members: Set<String>

    public init(
        defaults: UserDefaults = .standard,
        key: String = "foryou.friends.seen",
        capacity: Int = 400
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = capacity
        ordered = defaults.stringArray(forKey: key) ?? []
        members = Set(ordered)
    }

    public func contains(_ id: PostID) -> Bool {
        members.contains(id.rawValue)
    }

    /// Records `ids` as seen. Returns whether anything was new to the store —
    /// a caller republishes only when it was.
    @discardableResult
    public func insert(_ ids: [PostID]) -> Bool {
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
