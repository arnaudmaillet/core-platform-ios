import Connect
import CoreContracts
import Foundation

/// Shared mutable counter state: seeded like-counts per post, mutated by the
/// engagement mock (likes) and by the demo realtime ticker, read by the
/// counter mock. One source of truth so optimistic UI, reconcile reads, and
/// live ticks all agree.
public final class MockCounterStore: @unchecked Sendable {
    private let lock = NSLock()
    private var likeCounts: [String: Int64] = [:]
    /// Views and comments are read-only projections (no mock mutates them):
    /// deterministic, varied, and shaped like reality — views a magnitude
    /// above likes, comments a fraction of them, an occasional zero.
    private let viewCounts: [String: Int64]
    private let commentCounts: [String: Int64]
    private let postsByAuthor: [String: [String]]

    public init(dataset: MockSocialDataset = MockSocialDataset()) {
        var views: [String: Int64] = [:]
        var comments: [String: Int64] = [:]
        for (index, post) in dataset.posts.enumerated() {
            likeCounts[post.postID] = Int64(12 + (index * 37) % 900)
            views[post.postID] = Int64(140 + (index * 271) % 24_000)
            comments[post.postID] = Int64((index * 13) % 220)
        }
        viewCounts = views
        commentCounts = comments
        postsByAuthor = Dictionary(grouping: dataset.posts, by: \.authorProfileID)
            .mapValues { $0.map(\.postID) }
    }

    public func likeCount(for postID: String) -> Int64 {
        lock.withLock { likeCounts[postID] ?? 0 }
    }

    public func viewCount(for postID: String) -> Int64 {
        viewCounts[postID] ?? 0
    }

    public func commentCount(for postID: String) -> Int64 {
        commentCounts[postID] ?? 0
    }

    /// Profile-scoped LIKE: the sum of like counts across the author's posts —
    /// what counter.v1 projects as a profile's total received reactions. A
    /// profile with no posts truthfully reads 0.
    public func totalLikes(forAuthor profileID: String) -> Int64 {
        lock.withLock {
            (postsByAuthor[profileID] ?? []).reduce(0) { $0 + (likeCounts[$1] ?? 0) }
        }
    }

    @discardableResult
    public func incrementLikes(for postID: String, by delta: Int64) -> Int64 {
        lock.withLock {
            let next = max(0, (likeCounts[postID] ?? 0) + delta)
            likeCounts[postID] = next
            return next
        }
    }
}

/// Fake of engagement.v1: reaction upserts/removals are idempotent per
/// (post, profile) and feed the shared counter store.
public final class MockEngagementService: @unchecked Sendable {
    private let store: MockCounterStore
    private let lock = NSLock()
    private var reactions: [String: Set<String>] = [:] // postID → profileIDs

    public init(store: MockCounterStore) {
        self.store = store
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/engagement.v1.EngagementService/UpsertReaction") { [self] (request: Engagement_V1_UpsertReactionRequest) in
            upsertReaction(request)
        }
        bff.register(path: "/engagement.v1.EngagementService/RemoveReaction") { [self] (request: Engagement_V1_RemoveReactionRequest) in
            removeReaction(request)
        }
    }

    private func upsertReaction(_ request: Engagement_V1_UpsertReactionRequest) -> Result<Engagement_V1_CommandResponse, ConnectError> {
        guard !request.postID.isEmpty, !request.profileID.isEmpty else {
            return .failure(ConnectError(code: .invalidArgument, message: "post_id and profile_id required"))
        }
        let inserted = lock.withLock {
            reactions[request.postID, default: []].insert(request.profileID).inserted
        }
        if inserted {
            store.incrementLikes(for: request.postID, by: 1)
        }
        var response = Engagement_V1_CommandResponse()
        response.success = true
        return .success(response)
    }

    private func removeReaction(_ request: Engagement_V1_RemoveReactionRequest) -> Result<Engagement_V1_CommandResponse, ConnectError> {
        let removed = lock.withLock {
            reactions[request.postID]?.remove(request.profileID) != nil
        }
        if removed {
            store.incrementLikes(for: request.postID, by: -1)
        }
        var response = Engagement_V1_CommandResponse()
        response.success = true
        return .success(response)
    }
}

/// Fake of counter.v1.BatchGetCounters over the shared store: positional
/// snapshots, LIKE metric only — post-scoped per post, profile-scoped as the
/// author's aggregate. Other metrics (follower/following/view) are never
/// answered, mirroring the fleet's unprojected read-model so clients exercise
/// their fallback/unavailable paths.
public final class MockCounterService: @unchecked Sendable {
    private let store: MockCounterStore

    public init(store: MockCounterStore) {
        self.store = store
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/counter.v1.CounterService/BatchGetCounters") { [self] (request: Counter_V1_BatchGetCountersRequest) in
            batchGetCounters(request)
        }
    }

    private func batchGetCounters(_ request: Counter_V1_BatchGetCountersRequest) -> Result<Counter_V1_BatchGetCountersResponse, ConnectError> {
        // An empty metric filter means "everything you have", per the contract.
        let wantsLike = request.metrics.isEmpty || request.metrics.contains(.like)
        let wantsView = request.metrics.isEmpty || request.metrics.contains(.view)
        let wantsComment = request.metrics.isEmpty || request.metrics.contains(.comment)

        var response = Counter_V1_BatchGetCountersResponse()
        response.snapshots = request.entities.map { entity in
            var snapshot = Counter_V1_CounterSnapshot()
            snapshot.entity = entity
            func append(_ metric: Counter_V1_CounterMetric, _ count: Int64) {
                var value = Counter_V1_CounterValue()
                value.metric = metric
                value.value = count
                value.kind = .exact
                snapshot.values.append(value)
            }
            if wantsLike {
                append(.like, entity.entityType == .profile
                    ? store.totalLikes(forAuthor: entity.id)
                    : store.likeCount(for: entity.id))
            }
            // Views and comments are projected for POSTS only: profile-scoped
            // views intentionally stay unanswered so the header's "—" state
            // keeps exercising the unavailable path.
            if entity.entityType == .post {
                if wantsView { append(.view, store.viewCount(for: entity.id)) }
                if wantsComment { append(.comment, store.commentCount(for: entity.id)) }
            }
            return snapshot
        }
        return .success(response)
    }
}
