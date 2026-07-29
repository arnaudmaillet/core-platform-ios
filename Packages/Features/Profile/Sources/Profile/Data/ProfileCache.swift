import CoreModels
import Foundation

/// Last-known profiles, keyed by id — the "stale" half of stale-while-revalidate.
///
/// **What this is for.** Switching accounts used to leave the PREVIOUS profile
/// on screen until the network answered. That reads as stale data rather than as
/// a transition, and it is worse than stale: it is the wrong person's name and
/// numbers under the identity you just chose. With a cache, a switch to someone
/// you have already opened renders them immediately and the fetch becomes a
/// silent revalidation.
///
/// **Why the repository does not own it.** `ProfileRepository` is an actor, so
/// every read costs a hop and cannot seed a view synchronously — and seeding
/// synchronously is the entire point. This is `@MainActor` and read on the same
/// turn the switch is handled, so the first frame after a switch already carries
/// the new identity.
///
/// In memory only, and deliberately. A profile's counters go stale quickly, so
/// there is no version of this worth persisting to disk; its job is to cover the
/// gap between a switch and a round trip, not to survive relaunch. One instance
/// is held by `ProfileFeatureBuilder` for the app's lifetime, so every profile
/// screen shares it.
@MainActor
public final class ProfileCache {
    /// Enough for an account's own profiles plus a browsing session's worth of
    /// other people. Past it the oldest read is dropped — the cost of a miss is
    /// one fetch, which is what would have happened anyway.
    private let limit: Int
    private var profiles: [ProfileID: UserProfile] = [:]
    /// Ids in least-recently-used order.
    private var recency: [ProfileID] = []

    public init(limit: Int = 16) {
        self.limit = limit
    }

    public func profile(for id: ProfileID) -> UserProfile? {
        guard let profile = profiles[id] else { return nil }
        touch(id)
        return profile
    }

    public func store(_ profile: UserProfile) {
        profiles[profile.id] = profile
        touch(profile.id)
        while recency.count > limit, let oldest = recency.first {
            recency.removeFirst()
            profiles[oldest] = nil
        }
    }

    private func touch(_ id: ProfileID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}
