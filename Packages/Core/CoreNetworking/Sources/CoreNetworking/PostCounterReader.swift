import CoreContracts
import Foundation

/// The two numbers the app reads from `counter.v1` about a post.
///
/// Views are not read any more (2026-09-30): no surface shows them — tiles,
/// cards and the profile / place headers all count likes — so the metric is
/// not asked for.
///
/// Each is OPTIONAL because absent and zero are different claims: a surface
/// hides a counter it has no value for and renders a `0` it does have, and
/// collapsing the two would make every counter outage look like a post nobody
/// touched.
public struct PostCounters: Sendable, Equatable {
    public let likes: Int64?
    public let comments: Int64?

    public init(likes: Int64?, comments: Int64?) {
        self.likes = likes
        self.comments = comments
    }
}

/// One batched `counter.v1` read for a page of posts.
///
/// ⚠️ SHARED because it was about to exist twice. The profile gallery has read
/// counters this way since it had a grid; when the feed's cards started showing
/// reach, the obvious move was a second copy of the same twenty lines in the
/// other feature — and this session has already paid for that shape twice, once
/// with two pagers where only one got a gesture fix, and once with two carousels
/// narrowly avoided.
///
/// Deliberately knows NOTHING about either feature's model: it answers a
/// dictionary keyed by post id, and each caller maps it onto whatever it
/// renders. That is what lets it live below both of them without either's view
/// types coming with it.
public enum PostCounterReader {
    /// Best-effort: a counter outage answers an empty dictionary rather than
    /// throwing, so a grid still renders with its counters hidden. A page of
    /// posts is ONE round trip.
    public static func counters(
        forPostIDs ids: [String],
        using client: any Counter_V1_CounterServiceClientInterface
    ) async -> [String: PostCounters] {
        guard !ids.isEmpty else { return [:] }
        var request = Counter_V1_BatchGetCountersRequest()
        request.entities = ids.map { id in
            var entity = Counter_V1_EntityRef()
            entity.entityType = .post
            entity.id = id
            return entity
        }
        request.metrics = [.like, .comment]
        let response = await client.batchGetCounters(request: request, headers: [:])
        guard let snapshots = response.message?.snapshots else { return [:] }
        return Dictionary(
            snapshots.map { snapshot in
                (
                    snapshot.entity.id,
                    PostCounters(
                        likes: snapshot.values.first { $0.metric == .like }?.value,
                        comments: snapshot.values.first { $0.metric == .comment }?.value
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
