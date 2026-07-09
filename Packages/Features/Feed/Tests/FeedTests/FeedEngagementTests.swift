import CoreContracts
import CoreModels
import CoreRealtime
import Foundation
import Testing
@testable import Feed

// MARK: - Fakes

private final class FakeEngagementProvider: EngagementProviding, @unchecked Sendable {
    private let lock = NSLock()
    var failNextSetLiked = false
    private(set) var setLikedCalls: [(PostID, Bool)] = []
    var counts: [PostID: Int64] = [:]

    func setLiked(_ liked: Bool, for postID: PostID) async throws {
        let shouldFail = lock.withLock {
            setLikedCalls.append((postID, liked))
            let fail = failNextSetLiked
            failNextSetLiked = false
            return fail
        }
        if shouldFail {
            throw FeedError.transport(message: "engagement unavailable")
        }
    }

    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] {
        lock.withLock { counts.filter { postIDs.contains($0.key) } }
    }

    var recordedCalls: [(PostID, Bool)] { lock.withLock { setLikedCalls } }
}

/// Scriptable realtime seam: the test drives events/connection transitions.
private final class FakeRealtime: FeedRealtimeSubscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribedChannels: Set<RealtimeChannel> = []
    private let eventStream: AsyncStream<RealtimeEvent>
    private let eventContinuation: AsyncStream<RealtimeEvent>.Continuation
    private let connectionStream: AsyncStream<RealtimeConnectionEvent>
    private let connectionContinuation: AsyncStream<RealtimeConnectionEvent>.Continuation

    init() {
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        (connectionStream, connectionContinuation) = AsyncStream.makeStream(of: RealtimeConnectionEvent.self)
    }

    func subscribe(to channels: Set<RealtimeChannel>) async {
        lock.withLock { subscribedChannels.formUnion(channels) }
    }

    func events() async -> AsyncStream<RealtimeEvent> { eventStream }
    func connectionEvents() async -> AsyncStream<RealtimeConnectionEvent> { connectionStream }

    var subscribed: Set<RealtimeChannel> { lock.withLock { subscribedChannels } }

    func pushLikeCount(_ count: Int64, postID: String, streamSeq: UInt64) {
        var entity = Counter_V1_EntityRef()
        entity.entityType = .post
        entity.id = postID
        var value = Counter_V1_CounterValue()
        value.metric = .like
        value.value = count
        value.kind = .exact
        var snapshot = Counter_V1_CounterSnapshot()
        snapshot.entity = entity
        snapshot.values = [value]

        eventContinuation.yield(RealtimeEvent(
            channel: .counter(entityID: postID),
            streamSeq: streamSeq,
            eventType: "counter.update",
            payload: try! snapshot.serializedData()
        ))
    }

    func pushReconnected() {
        connectionContinuation.yield(.connected(resumed: true))
    }
}

private final class SinglePageProvider: FeedProviding, @unchecked Sendable {
    let entries: [FeedEntry]
    init(entries: [FeedEntry]) { self.entries = entries }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: entries, nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        guard let entry = entries.first(where: { $0.post.id == id }) else {
            throw FeedError.transport(message: "not found")
        }
        return entry
    }
}

private func makeEntry(_ id: String, likeCount: Int64) -> FeedEntry {
    FeedEntry(
        post: Post(id: PostID(id), authorID: ProfileID("prof-1"), caption: "c", attachments: [], publishedAt: .init(timeIntervalSince1970: 0)),
        author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil),
        likeCount: likeCount
    )
}

// MARK: - Tests

@MainActor
struct FeedEngagementTests {
    private func loadedViewModel(
        engagement: FakeEngagementProvider,
        realtime: FakeRealtime?
    ) async -> FeedViewModel {
        let viewModel = FeedViewModel(
            repository: SinglePageProvider(entries: [makeEntry("post-a", likeCount: 10), makeEntry("post-b", likeCount: 5)]),
            engagementProvider: engagement,
            realtime: realtime
        )
        await withCheckedContinuation { continuation in
            viewModel.onStateChange = { state in
                if state.phase == .content {
                    viewModel.onStateChange = nil
                    continuation.resume()
                }
            }
            viewModel.viewDidLoad()
        }
        return viewModel
    }

    @Test func likeCountsAreSeededFromHydratedEntries() async {
        let viewModel = await loadedViewModel(engagement: FakeEngagementProvider(), realtime: nil)
        #expect(viewModel.engagementState(for: PostID("post-a")).likeCount == 10)
        #expect(viewModel.engagementState(for: PostID("post-a")).isLiked == false)
    }

    @Test func toggleLikeIsOptimisticAndPersists() async {
        let engagement = FakeEngagementProvider()
        let viewModel = await loadedViewModel(engagement: engagement, realtime: nil)
        let id = PostID("post-a")

        var updates: [FeedViewModel.EngagementState] = []
        viewModel.onEngagementChange = { _, state in updates.append(state) }

        viewModel.toggleLike(for: id)

        // Optimistic: state flips before any RPC completes.
        #expect(updates.first == .init(likeCount: 11, isLiked: true))
        #expect(await eventuallyMain { engagement.recordedCalls.count == 1 })
        #expect(viewModel.engagementState(for: id) == .init(likeCount: 11, isLiked: true))
    }

    @Test func failedLikeRollsBack() async {
        let engagement = FakeEngagementProvider()
        engagement.failNextSetLiked = true
        let viewModel = await loadedViewModel(engagement: engagement, realtime: nil)
        let id = PostID("post-a")

        var updates: [FeedViewModel.EngagementState] = []
        viewModel.onEngagementChange = { _, state in updates.append(state) }

        viewModel.toggleLike(for: id)

        #expect(await eventuallyMain { updates.count == 2 })
        #expect(updates.first == .init(likeCount: 11, isLiked: true)) // optimistic
        #expect(updates.last == .init(likeCount: 10, isLiked: false)) // rollback
    }

    @Test func counterEventsUpdateStateAndSubscriptionsCoverLoadedPosts() async {
        let realtime = FakeRealtime()
        let viewModel = await loadedViewModel(engagement: FakeEngagementProvider(), realtime: realtime)

        #expect(await eventuallyMain {
            realtime.subscribed.contains(.counter(entityID: "post-a")) &&
            realtime.subscribed.contains(.counter(entityID: "post-b"))
        })

        var updates: [(PostID, FeedViewModel.EngagementState)] = []
        viewModel.onEngagementChange = { id, state in updates.append((id, state)) }

        realtime.pushLikeCount(99, postID: "post-a", streamSeq: 1)

        #expect(await eventuallyMain { updates.count == 1 })
        #expect(updates.first?.0 == PostID("post-a"))
        #expect(updates.first?.1.likeCount == 99)
        // Live counts never clobber the viewer's own like state.
        #expect(updates.first?.1.isLiked == false)
    }

    @Test func reconnectReconcilesCountsAgainstAuthoritativeRead() async {
        let engagement = FakeEngagementProvider()
        engagement.counts = [PostID("post-a"): 500, PostID("post-b"): 5]
        let realtime = FakeRealtime()
        let viewModel = await loadedViewModel(engagement: engagement, realtime: realtime)

        var updates: [(PostID, FeedViewModel.EngagementState)] = []
        viewModel.onEngagementChange = { id, state in updates.append((id, state)) }

        realtime.pushReconnected()

        // post-a drifted while disconnected (10 → 500) and must reconcile;
        // post-b is unchanged and must not emit.
        #expect(await eventuallyMain { updates.count == 1 })
        #expect(updates.first?.0 == PostID("post-a"))
        #expect(updates.first?.1.likeCount == 500)
    }
}

/// Main-actor polling helper for callback-driven expectations.
@MainActor
private func eventuallyMain(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
