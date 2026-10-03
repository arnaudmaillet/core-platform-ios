import AuthInterface
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
    private struct Entry {
        var profile: UserProfile?
        var relationship: ProfileRelationship?
    }
    private var entries: [ProfileID: Entry] = [:]
    /// Ids in least-recently-used order.
    private var recency: [ProfileID] = []
    /// Keeps cached relationships agreeing with a follow made anywhere else
    /// while no screen for that profile is alive to hear it.
    private var followSubscription: FollowGraphSubscription?
    /// Every relationship here is the VIEWER's ("you follow them"): once the
    /// viewer is someone else, none of it is true any more.
    private var viewerObserver: NSObjectProtocol?

    public init(limit: Int = 16) {
        self.limit = limit
        viewerObserver = NotificationCenter.default.addObserver(
            forName: .viewerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    /// Forgets everything — what a change of viewer calls.
    public func removeAll() {
        entries.removeAll()
        recency.removeAll()
    }

    public func profile(for id: ProfileID) -> UserProfile? {
        guard let profile = entries[id]?.profile else { return nil }
        touch(id)
        return profile
    }

    public func store(_ profile: UserProfile) {
        entries[profile.id, default: Entry()].profile = profile
        touch(profile.id)
    }

    /// The viewer's relationship to `id` as last read or changed here — the
    /// Follow / Following a revisit opens on. Stale-while-revalidate like the
    /// profile: the screen reads it again and corrects in place.
    public func relationship(for id: ProfileID) -> ProfileRelationship? {
        entries[id]?.relationship
    }

    public func store(_ relationship: ProfileRelationship, for id: ProfileID) {
        entries[id, default: Entry()].relationship = relationship
        touch(id)
    }

    /// Hears the app's follow channel, once. A follow accepted on a card or
    /// in a list updates the cached answer, so the next visit does not open
    /// on the old one and flip.
    public func observe(_ events: FollowGraphEvents?) {
        guard followSubscription == nil, let events else { return }
        followSubscription = events.subscribeOnMain { [weak self] change in
            self?.followGraphDidChange(change)
        }
    }

    private func followGraphDidChange(_ change: FollowChange) {
        guard case .other(let wasFollowing, let isMutual, let isBlocked)? = entries[change.profileID]?.relationship,
              wasFollowing != change.isFollowing else { return }
        // Mutual implies following: an unfollow ends it. A follow cannot say
        // whether they follow back, so it keeps what was known.
        entries[change.profileID]?.relationship = .other(
            isFollowing: change.isFollowing,
            isMutual: change.isFollowing && isMutual,
            isBlocked: isBlocked
        )
    }

    private func touch(_ id: ProfileID) {
        recency.removeAll { $0 == id }
        recency.append(id)
        while recency.count > limit, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
    }
}
