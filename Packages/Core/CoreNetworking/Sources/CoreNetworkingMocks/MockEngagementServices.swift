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

    public init(dataset: MockSocialDataset = MockSocialDataset()) {
        for (index, post) in dataset.posts.enumerated() {
            likeCounts[post.postID] = Int64(12 + (index * 37) % 900)
        }
    }

    public func likeCount(for postID: String) -> Int64 {
        lock.withLock { likeCounts[postID] ?? 0 }
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
/// snapshots, LIKE metric.
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
        var response = Counter_V1_BatchGetCountersResponse()
        response.snapshots = request.entities.map { entity in
            var value = Counter_V1_CounterValue()
            value.metric = .like
            value.value = store.likeCount(for: entity.id)
            value.kind = .exact

            var snapshot = Counter_V1_CounterSnapshot()
            snapshot.entity = entity
            snapshot.values = [value]
            return snapshot
        }
        return .success(response)
    }
}
