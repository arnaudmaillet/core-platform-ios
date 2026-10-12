import CacheKit
import CoreModels
import Foundation
import Synchronization

/// One post and one profile per id, in memory, shared by every screen (#896):
/// a like, a follow, a save or a delete made anywhere reaches every screen
/// showing that entity, because they all read the same one.
///
/// Screens keep their own state (order, selection, paging) and their own copy
/// of what they rendered; they read the LIVE fields here and observe them
/// (`observePost`, `observePosts`). A field the store does not know is nil, and
/// the screen keeps its own copy's value: an evicted entity costs a stale
/// number, never a blank cell. Lists write what they load (`upsert`), so a post
/// two lists show — For You's grid and the vertical feed's lookahead window —
/// is one entity (#970).
///
/// Two lifetimes, four `ManagedCache` namespaces (`managedCaches`):
/// - the CONTENT — posts and profiles, their counters — is the same for every
///   viewer and survives a viewer change, like the hydrated posts
///   `FeedRepository` keeps on purpose (`public` scope);
/// - the VIEWER'S FACTS — where they stand with a person, what they saved —
///   are `viewer`-scoped: the coordinator's `.viewerChanged` wipes them and
///   every observer hears `.everything`.
/// The viewer's stake on a post stays in `WalletStore`, which already is one
/// ledger per viewer, persisted and announced; a stake reaches the post's
/// count here through `addLikes`.
///
/// Bounded by count (cost 1 per entity): 2,000 posts and 1,000 profiles by
/// default, in the `preferred` class (#893's structured data). An entity a
/// screen observes is leased: never evicted while observed.
///
/// ⚠️ WHY AN IN-MEMORY MAP AND NOT GRDB's `ValueObservation` OVER THE
/// LOCALSTORE. A cell reads its entity synchronously while it is configured
/// (charter P7), and a like or a realtime tick must reach every visible cell
/// in the same frame; an observation per cell is a SQLite read per change per
/// cell, delivered a hop later. The LocalStore is a budgeted cache wiped on
/// every viewer change, while posts here outlive the viewer; and the viewer's
/// facts (stakes, saves) are not in its rows. The device copy stays the
/// LocalStore's job: lists persist their pages there (`FeedLocalCache`), the
/// posts it holds are rebuilt here as copies at a cold start, and a delete
/// reaches it (`EntityDeviceBacking`, in Feed, which owns the codec).
///
/// A `Mutex`, not an actor (the `MemoryCache` reason): UIKit reads it
/// synchronously, and repositories write it from their own executors.
/// Observers are always called on the main actor, after the write, with the
/// id that changed: they read the current value back, so two writes delivered
/// in either order end on the same screen.
public final class EntityStore: Sendable {
    public static let defaultPostLimit = 2_000
    public static let defaultProfileLimit = 1_000

    let posts: MemoryCache<PostID, PostEntity>
    let profiles: MemoryCache<ProfileID, ProfileEntity>
    let relations: ViewerFacts<ProfileID, FollowRelation>
    let saved: ViewerFacts<PostID, Bool>

    /// Serializes every read-modify-write, so two writers never lose one
    /// another's change. Never held while an observer runs.
    private let writes = Mutex(())
    private let state: Mutex<State>

    public init(
        postLimit: Int = EntityStore.defaultPostLimit,
        profileLimit: Int = EntityStore.defaultProfileLimit,
        tombstoneLimit: Int = 1_000,
        clock: any CacheClock = SystemCacheClock()
    ) {
        posts = MemoryCache(
            namespace: CacheNamespace("entities.posts", category: .other, scope: .public, priorityClass: .preferred),
            budget: .fixed(bytes: postLimit),
            limits: CacheLimits(bytes: postLimit, speculativeShare: CacheCoordinator.speculativeShare),
            clock: clock
        )
        profiles = MemoryCache(
            namespace: CacheNamespace("entities.profiles", category: .other, scope: .public, priorityClass: .preferred),
            budget: .fixed(bytes: profileLimit),
            limits: CacheLimits(bytes: profileLimit, speculativeShare: CacheCoordinator.speculativeShare),
            clock: clock
        )
        relations = ViewerFacts("entities.relations", limit: profileLimit, clock: clock)
        saved = ViewerFacts("entities.saved", limit: postLimit, clock: clock)
        state = Mutex(State(tombstoneLimit: tombstoneLimit))
        relations.setOnWipe { [weak self] in self?.notifyProfiles(.everything) }
        saved.setOnWipe { [weak self] in self?.notifyPosts(.everything) }
    }

    /// The namespaces the coordinator budgets, trims and wipes.
    public var managedCaches: [any ManagedCache] { [posts, profiles, relations, saved] }

    public func register(with coordinator: CacheCoordinator) {
        for cache in managedCaches { coordinator.register(cache) }
    }

    /// Forgets every viewer's fact at once — what the coordinator's
    /// `.viewerChanged` does through the `viewer`-scoped namespaces; for a
    /// host without one.
    public func viewerDidChange() {
        relations.removeAll()
        saved.removeAll()
    }

    // MARK: - Posts

    /// The post, as a use: it becomes the most recently used of its tier.
    public func post(_ id: PostID) -> PostEntity? {
        posts.value(for: id)
    }

    /// Whether the post was deleted in this session: no write brings it back.
    public func isDeleted(_ id: PostID) -> Bool {
        state.withLock { $0.tombstones.contains(id) }
    }

    /// What a list loaded: the posts, their authors and their like counts.
    /// `tier: .speculative` for a lookahead nobody has seen yet. A copy
    /// (`.ifUnknown`) fills what the store lacks and replaces nothing — not a
    /// count, not an edited caption, not a renamed author.
    public func upsert(_ entries: [FeedEntry], tier: CacheTier = .recent, counts freshness: CountFreshness = .fresh) {
        guard !entries.isEmpty else { return }
        let (changedPosts, changedProfiles) = writes.withLock { _ -> (Set<PostID>, Set<ProfileID>) in
            var changedPosts = Set<PostID>()
            var changedProfiles = Set<ProfileID>()
            for entry in entries {
                let changed = writePost(entry.post.id, tier: tier) { current in
                    var next = current ?? PostEntity(id: entry.post.id)
                    if freshness == .fresh || next.post == nil { next.post = entry.post }
                    next.likeCount = Self.merge(entry.likeCount, over: next.likeCount, freshness)
                    return next
                }
                if changed { changedPosts.insert(entry.post.id) }
                if writeProfile(entry.author.id, tier: tier, { current in
                    var next = current ?? ProfileEntity(id: entry.author.id)
                    if freshness == .fresh || next.summary == nil { next.summary = entry.author }
                    return next
                }) {
                    changedProfiles.insert(entry.author.id)
                }
            }
            return (changedPosts, changedProfiles)
        }
        notifyPosts(.some(changedPosts))
        notifyProfiles(.some(changedProfiles))
    }

    /// Counters a list read, for posts it may not hydrate (a grid's tiles).
    public func mergeCounts(_ counts: [PostID: PostCounts], tier: CacheTier = .recent, freshness: CountFreshness = .fresh) {
        guard !counts.isEmpty else { return }
        let changed = writes.withLock { _ -> Set<PostID> in
            var changed = Set<PostID>()
            for (id, value) in counts {
                let didChange = writePost(id, tier: tier) { current in
                    var next = current ?? PostEntity(id: id)
                    if let likes = value.likes { next.likeCount = Self.merge(likes, over: next.likeCount, freshness) }
                    if let comments = value.comments {
                        next.commentCount = Self.merge(comments, over: next.commentCount, freshness)
                    }
                    return next
                }
                if didChange { changed.insert(id) }
            }
            return changed
        }
        notifyPosts(.some(changed))
    }

    /// The server's like count — a page, a realtime `counter.update`, a
    /// reconcile after a reconnect.
    public func setLikeCount(_ count: Int64, for id: PostID) {
        mergeCounts([id: PostCounts(likes: count)])
    }

    /// Points staked on the post from this device (a like, an undo's
    /// negative): the count moves at once, as the server's will once the
    /// stake is committed. Nothing for a post whose count is unknown — there
    /// is no number to move, and the next read brings one that includes it.
    public func addLikes(_ delta: Int64, to id: PostID) {
        guard delta != 0 else { return }
        let changed = writes.withLock { _ in
            writePost(id, tier: .recent) { current in
                guard var next = current, let count = next.likeCount else { return current }
                next.likeCount = max(0, count + delta)
                return next
            }
        }
        if changed { notifyPosts(.some([id])) }
    }

    /// An edit: the post's new content, counters kept.
    public func replacePost(_ post: Post) {
        let changed = writes.withLock { _ in
            writePost(post.id, tier: .recent) { current in
                var next = current ?? PostEntity(id: post.id)
                next.post = post
                return next
            }
        }
        if changed { notifyPosts(.some([post.id])) }
    }

    /// A delete, from anywhere: the post leaves memory, every observer hears
    /// it, and no later write — a page fetched before the delete, a realtime
    /// tick — brings it back. Lists drop it on `isDeleted`.
    public func deletePost(_ id: PostID) {
        let inserted = writes.withLock { _ -> Bool in
            posts.removeValue(for: id)
            saved.cache.removeValue(for: id)
            return state.withLock { $0.addTombstone(id) }
        }
        if inserted { notifyPosts(.some([id])) }
    }

    /// A delete undone (Settings → Recently Deleted): the post may come back
    /// with the next page that carries it. Nothing is put back now — the
    /// store forgot the post, and the lists load it again.
    public func restorePost(_ id: PostID) {
        writes.withLock { _ in
            state.withLock { $0.removeTombstone(id) }
        }
    }

    // MARK: - Profiles

    public func profile(_ id: ProfileID) -> ProfileEntity? {
        profiles.value(for: id)
    }

    public func upsert(_ summary: AuthorSummary, tier: CacheTier = .recent) {
        let changed = writes.withLock { _ in
            writeProfile(summary.id, tier: tier) { current in
                var next = current ?? ProfileEntity(id: summary.id)
                next.summary = summary
                return next
            }
        }
        if changed { notifyProfiles(.some([summary.id])) }
    }

    // MARK: - The viewer's facts

    /// Where the viewer stands with the person; nil while not known.
    public func relation(to id: ProfileID) -> FollowRelation? {
        relations.cache.value(for: id)
    }

    /// Records where the viewer stands with the person (nil forgets it), and
    /// returns what was known before — an optimistic follow's rollback.
    @discardableResult
    public func setRelation(_ relation: FollowRelation?, for id: ProfileID) -> FollowRelation? {
        let (previous, changed) = writes.withLock { _ -> (FollowRelation?, Bool) in
            let previous = relations.cache.peek(id)
            guard previous != relation else { return (previous, false) }
            if let relation {
                storeFact(relation, for: id, in: relations.cache, registry: \.profiles)
            } else {
                relations.cache.removeValue(for: id)
            }
            return (previous, true)
        }
        if changed { notifyProfiles(.some([id])) }
        return previous
    }

    /// A follow or unfollow the graph accepted (`FollowGraphEvents`): moves a
    /// KNOWN relation, keeping whether they follow the viewer back. An
    /// unknown one stays unknown — guessing it would draw a one-way follow
    /// for a friend; whoever shows that person asks the graph.
    public func applyFollowChange(_ change: FollowChange) {
        let changed = writes.withLock { _ -> Bool in
            guard let known = relations.cache.peek(change.profileID) else { return false }
            let next = known.settingFollow(change.isFollowing)
            guard next != known else { return false }
            storeFact(next, for: change.profileID, in: relations.cache, registry: \.profiles)
            return true
        }
        if changed { notifyProfiles(.some([change.profileID])) }
    }

    /// Whether the viewer saved the post; nil while not known.
    public func isSaved(_ id: PostID) -> Bool? {
        saved.cache.value(for: id)
    }

    /// What the viewer saved, as `PostBookmarkStore` writes it (its pile is
    /// the persistence; this is what every screen observes).
    public func setSaved(_ isSaved: Bool, for id: PostID) {
        let changed = writes.withLock { _ -> Bool in
            guard saved.cache.peek(id) != isSaved else { return false }
            storeFact(isSaved, for: id, in: saved.cache, registry: \.posts)
            return true
        }
        if changed { notifyPosts(.some([id])) }
    }

    // MARK: - Observation

    /// Calls `handler` on the main actor after every change to the post — its
    /// content, its counters, the viewer's facts about it, its delete — and
    /// once with every post on a viewer change. The post stays in memory while
    /// observed.
    public func observePost(_ id: PostID, _ handler: @escaping @MainActor @Sendable (PostID) -> Void) -> EntityObservation {
        let observer = Observer(handler)
        let token = writes.withLock { _ -> UInt64 in
            let isFirst = state.withLock { $0.posts.observers[id]?.isEmpty ?? true }
            let leases = isFirst ? [posts.lease(id), saved.cache.lease(id)].compactMap { $0 } : []
            return state.withLock { state in
                let token = state.nextToken()
                state.posts.add(observer, for: id, pinning: leases, token: token)
                return token
            }
        }
        return EntityObservation { [weak self] in
            observer.cancel()
            self?.endObservation(of: id, token: token, registry: \.posts)
        }
    }

    /// The same for one person: their summary and where the viewer stands.
    public func observeProfile(_ id: ProfileID, _ handler: @escaping @MainActor @Sendable (ProfileID) -> Void) -> EntityObservation {
        let observer = Observer(handler)
        let token = writes.withLock { _ -> UInt64 in
            let isFirst = state.withLock { $0.profiles.observers[id]?.isEmpty ?? true }
            let leases = isFirst ? [profiles.lease(id), relations.cache.lease(id)].compactMap { $0 } : []
            return state.withLock { state in
                let token = state.nextToken()
                state.profiles.add(observer, for: id, pinning: leases, token: token)
                return token
            }
        }
        return EntityObservation { [weak self] in
            observer.cancel()
            self?.endObservation(of: id, token: token, registry: \.profiles)
        }
    }

    /// Every change to any post, batched per write — for a screen drawing
    /// many (a grid binds its cells and re-reads the ones that changed).
    /// Pins nothing.
    public func observePosts(_ handler: @escaping @MainActor @Sendable (EntityChange<PostID>) -> Void) -> EntityObservation {
        let observer = Observer(handler)
        let token = state.withLock { state in
            let token = state.nextToken()
            state.posts.bulk[token] = observer
            return token
        }
        return EntityObservation { [weak self] in
            observer.cancel()
            _ = self?.state.withLock { $0.posts.bulk.removeValue(forKey: token) }
        }
    }

    public func observeProfiles(_ handler: @escaping @MainActor @Sendable (EntityChange<ProfileID>) -> Void) -> EntityObservation {
        let observer = Observer(handler)
        let token = state.withLock { state in
            let token = state.nextToken()
            state.profiles.bulk[token] = observer
            return token
        }
        return EntityObservation { [weak self] in
            observer.cancel()
            _ = self?.state.withLock { $0.profiles.bulk.removeValue(forKey: token) }
        }
    }

    // MARK: - Internals (`writes` held)

    /// Applies `transform` to the stored post; false when nothing changed, or
    /// the post was deleted.
    private func writePost(_ id: PostID, tier: CacheTier, _ transform: (PostEntity?) -> PostEntity?) -> Bool {
        guard !state.withLock({ $0.tombstones.contains(id) }) else { return false }
        let current = posts.peek(id)
        guard let next = transform(current), next != current else { return false }
        storeFact(next, for: id, in: posts, registry: \.posts, tier: tier)
        return true
    }

    private func writeProfile(_ id: ProfileID, tier: CacheTier, _ transform: (ProfileEntity?) -> ProfileEntity?) -> Bool {
        let current = profiles.peek(id)
        guard let next = transform(current), next != current else { return false }
        storeFact(next, for: id, in: profiles, registry: \.profiles, tier: tier)
        return true
    }

    /// Stores `value`, leased when a screen observes `id` and the cache does
    /// not hold it leased already (an entity observed before it was loaded).
    private func storeFact<ID: Hashable & Sendable, Value: Sendable>(
        _ value: Value, for id: ID, in cache: MemoryCache<ID, Value>,
        registry: WritableKeyPath<State, Registry<ID>>, tier: CacheTier = .recent
    ) {
        let observed = state.withLock { !($0[keyPath: registry].observers[id]?.isEmpty ?? true) }
        if observed, !cache.isLeased(id) {
            let lease = cache.insertLeased(value, for: id, cost: 1, tier: tier)
            state.withLock { $0[keyPath: registry].pins[id, default: []].append(lease) }
        } else {
            cache.insert(value, for: id, cost: 1, tier: tier)
        }
    }

    private func endObservation<ID: Hashable & Sendable>(
        of id: ID, token: UInt64, registry: WritableKeyPath<State, Registry<ID>>
    ) {
        // Released after the lock: a lease's release takes its cache's lock.
        let released = state.withLock { $0[keyPath: registry].remove(token, for: id) }
        withExtendedLifetime(released) {}
    }

    private static func merge(_ incoming: Int64, over stored: Int64?, _ freshness: CountFreshness) -> Int64 {
        switch freshness {
        case .fresh: incoming
        case .ifUnknown: stored ?? incoming
        }
    }

    // MARK: - Delivery

    private func notifyPosts(_ change: EntityChange<PostID>) {
        deliver(change, registry: \.posts)
    }

    private func notifyProfiles(_ change: EntityChange<ProfileID>) {
        deliver(change, registry: \.profiles)
    }

    private func deliver<ID: Hashable & Sendable>(_ change: EntityChange<ID>, registry: KeyPath<State, Registry<ID>>) {
        if case .some(let ids) = change, ids.isEmpty { return }
        let (single, bulk) = state.withLock { state in
            state[keyPath: registry].observers(for: change)
        }
        guard !single.isEmpty || !bulk.isEmpty else { return }
        Self.onMain {
            for (id, observer) in single { observer.call(id) }
            for observer in bulk { observer.call(change) }
        }
    }

    /// At once on the main thread, so a tap's own write re-draws in the same
    /// frame; otherwise on the next main-queue turn.
    private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    // MARK: - State

    final class Observer<Argument: Sendable>: Sendable {
        private let handler: @MainActor @Sendable (Argument) -> Void
        private let cancelled = Flag()

        init(_ handler: @escaping @MainActor @Sendable (Argument) -> Void) {
            self.handler = handler
        }

        func cancel() { _ = cancelled.set() }

        /// Nothing once cancelled: a delivery queued before the cancel never
        /// reaches a screen that let go.
        @MainActor func call(_ argument: Argument) {
            guard !cancelled.isSet else { return }
            handler(argument)
        }
    }

    struct Registry<ID: Hashable & Sendable> {
        var observers: [ID: [UInt64: Observer<ID>]] = [:]
        var bulk: [UInt64: Observer<EntityChange<ID>>] = [:]
        /// The leases that keep an observed entity (and the viewer's fact
        /// about it) in memory, held while anyone observes it.
        var pins: [ID: [CacheLease]] = [:]

        mutating func add(_ observer: Observer<ID>, for id: ID, pinning leases: [CacheLease], token: UInt64) {
            observers[id, default: [:]][token] = observer
            if !leases.isEmpty { pins[id, default: []].append(contentsOf: leases) }
        }

        /// The pins to release once the last observer of `id` left.
        mutating func remove(_ token: UInt64, for id: ID) -> [CacheLease] {
            observers[id]?.removeValue(forKey: token)
            guard observers[id]?.isEmpty ?? true else { return [] }
            observers[id] = nil
            return pins.removeValue(forKey: id) ?? []
        }

        func observers(for change: EntityChange<ID>) -> ([(ID, Observer<ID>)], [Observer<EntityChange<ID>>]) {
            var single: [(ID, Observer<ID>)] = []
            switch change {
            case .some(let ids):
                for id in ids {
                    guard let registered = observers[id] else { continue }
                    for observer in registered.values { single.append((id, observer)) }
                }
            case .everything:
                for (id, registered) in observers {
                    for observer in registered.values { single.append((id, observer)) }
                }
            }
            return (single, Array(bulk.values))
        }
    }

    struct State {
        var posts = Registry<PostID>()
        var profiles = Registry<ProfileID>()
        private var lastToken: UInt64 = 0
        /// Posts deleted in this session, oldest first, bounded.
        private(set) var tombstones: Set<PostID> = []
        private var tombstoneOrder: [PostID] = []
        let tombstoneLimit: Int

        init(tombstoneLimit: Int) {
            self.tombstoneLimit = max(1, tombstoneLimit)
        }

        mutating func nextToken() -> UInt64 {
            lastToken += 1
            return lastToken
        }

        /// False when the post was already deleted.
        mutating func addTombstone(_ id: PostID) -> Bool {
            guard tombstones.insert(id).inserted else { return false }
            tombstoneOrder.append(id)
            if tombstoneOrder.count > tombstoneLimit {
                tombstones.remove(tombstoneOrder.removeFirst())
            }
            return true
        }

        mutating func removeTombstone(_ id: PostID) {
            guard tombstones.remove(id) != nil else { return }
            tombstoneOrder.removeAll { $0 == id }
        }
    }
}
