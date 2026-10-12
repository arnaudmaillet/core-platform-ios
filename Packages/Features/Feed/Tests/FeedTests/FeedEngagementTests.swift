import CoreContracts
import CoreModels
import CoreRealtime
import EntityStore
import Foundation
import Testing
@testable import Feed

// MARK: - Fakes

private final class FakeEngagementProvider: EngagementProviding, @unchecked Sendable {
    private let lock = NSLock()
    var failNextLike = false
    private(set) var likeCalls: [PostID] = []
    var counts: [PostID: Int64] = [:]

    func like(_ postID: PostID) async throws {
        let shouldFail = lock.withLock {
            likeCalls.append(postID)
            let fail = failNextLike
            failNextLike = false
            return fail
        }
        if shouldFail {
            throw FeedError.transport(message: "engagement unavailable")
        }
    }

    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] {
        lock.withLock { counts.filter { postIDs.contains($0.key) } }
    }

    var recordedCalls: [PostID] { lock.withLock { likeCalls } }
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

/// A provider whose posts come from a cache (`FixedPostsFeedProvider`'s shape).
private final class CachedPageProvider: FeedProviding, @unchecked Sendable {
    let entries: [FeedEntry]
    init(entries: [FeedEntry]) { self.entries = entries }

    var pagesCarryFreshCounts: Bool { false }
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: entries, nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        guard let entry = entries.first(where: { $0.post.id == id }) else { throw FeedError.transport(message: "not found") }
        return entry
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

    /// A like is a point (#676): shown at once, and every like adds one —
    /// there is no unlike.
    @Test func aLikeIsOptimisticAndEachAddsOne() async {
        let engagement = FakeEngagementProvider()
        let viewModel = await loadedViewModel(engagement: engagement, realtime: nil)
        let id = PostID("post-a")

        var updates: [FeedViewModel.EngagementState] = []
        viewModel.onEngagementChange = { _, state in updates.append(state) }

        viewModel.like(for: id)

        // Optimistic: shown before any RPC completes.
        #expect(updates.first == .init(likeCount: 11, isLiked: true))
        #expect(await eventuallyMain { engagement.recordedCalls.count == 1 })
        #expect(viewModel.engagementState(for: id) == .init(likeCount: 11, isLiked: true))

        // A second like adds a second point; it never takes one back. (Once
        // the first has landed: one like in flight per post.)
        #expect(await eventuallyMain { !viewModel.isLikeInFlight(id) })
        viewModel.like(for: id)
        #expect(await eventuallyMain { engagement.recordedCalls.count == 2 })
        #expect(viewModel.engagementState(for: id) == .init(likeCount: 12, isLiked: true))
    }

    @Test func failedLikeRollsBack() async {
        let engagement = FakeEngagementProvider()
        engagement.failNextLike = true
        let viewModel = await loadedViewModel(engagement: engagement, realtime: nil)
        let id = PostID("post-a")

        var updates: [FeedViewModel.EngagementState] = []
        viewModel.onEngagementChange = { _, state in updates.append(state) }

        viewModel.like(for: id)

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

// MARK: - One count per post, for every screen (#896)

@MainActor
struct FeedEntityStoreTests {
    private func loaded(
        _ entries: [FeedEntry], entities: EntityStore,
        engagement: FakeEngagementProvider = FakeEngagementProvider(), realtime: FakeRealtime? = nil
    ) async -> FeedViewModel {
        let viewModel = FeedViewModel(
            repository: SinglePageProvider(entries: entries),
            engagementProvider: engagement,
            realtime: realtime,
            entities: entities
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

    private func model(_ id: String, likes: Int64, hidden: Bool = false) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("prof-1"), authorName: "Ava", metaText: "@ava",
            avatarURL: nil, caption: "c", mediaURL: nil, mediaKind: .image, thumbnailURL: nil,
            audioText: nil, likeCount: likes, likeCountHidden: hidden
        )
    }

    /// The Following feed and a feed opened from a grid show the same post:
    /// a like in one is the count of the other, and a realtime tick heard by
    /// one reaches both.
    @Test func aLikeOrATickInOneFeedReachesTheOther() async {
        let entities = EntityStore()
        let realtime = FakeRealtime()
        let following = await loaded(
            [makeEntry("post-a", likeCount: 10), makeEntry("post-b", likeCount: 5)],
            entities: entities, realtime: realtime
        )
        let opened = await loaded([makeEntry("post-a", likeCount: 10)], entities: entities)
        var openedHeard: [Int64] = []
        opened.onEngagementChange = { _, state in openedHeard.append(state.likeCount) }

        following.like(for: PostID("post-a"))
        #expect(openedHeard == [11])
        #expect(opened.engagementState(for: PostID("post-a")).isLiked == false, "the like is the other screen's own")

        #expect(await eventuallyMain { realtime.subscribed.contains(.counter(entityID: "post-a")) })
        realtime.pushLikeCount(99, postID: "post-a", streamSeq: 1)
        #expect(await eventuallyMain { openedHeard.last == 99 })
    }

    /// A page drawn again after a like elsewhere draws the live count, not
    /// the one it was loaded with.
    @Test func aPageConfiguredAfterALikeElsewhereDrawsTheLiveCount() async {
        let entities = EntityStore()
        let viewModel = await loaded([makeEntry("post-a", likeCount: 10)], entities: entities)
        entities.addLikes(3, to: PostID("post-a"))
        #expect(viewModel.visibleLikeCount(for: model("post-a", likes: 10)) == 13)
        #expect(viewModel.visibleLikeCount(for: model("post-a", likes: 10, hidden: true)) == nil)
    }

    /// Deleted from the profile: the post leaves the feed, and a page that
    /// still lists it never brings it back.
    @Test func aPostDeletedElsewhereLeavesTheFeed() async {
        let entities = EntityStore()
        let viewModel = await loaded(
            [makeEntry("post-a", likeCount: 10), makeEntry("post-b", likeCount: 5)], entities: entities
        )
        var rendered: [[PostID]] = []
        viewModel.onStateChange = { rendered.append($0.items.map(\.id)) }

        entities.deletePost(PostID("post-a"))

        #expect(rendered.last == [PostID("post-b")])
        viewModel.refresh()
        #expect(await eventuallyMain { rendered.count >= 2 })
        #expect(rendered.last == [PostID("post-b")], "the refreshed page still lists it")
    }

    /// A feed opened from a tile reads its posts through the repository's
    /// cache, whose counts are as old as the fetch: opening it again after a
    /// like never takes the like back.
    @Test func aFeedReadFromACacheNeverUndoesALike() async {
        let entities = EntityStore()
        let first = await loaded([makeEntry("post-a", likeCount: 10)], entities: entities)
        first.like(for: PostID("post-a"))
        let cached = FeedViewModel(
            repository: CachedPageProvider(entries: [makeEntry("post-a", likeCount: 10)]),
            entities: entities
        )
        await withCheckedContinuation { continuation in
            cached.onStateChange = { state in
                if state.phase == .content {
                    cached.onStateChange = nil
                    continuation.resume()
                }
            }
            cached.viewDidLoad()
        }
        #expect(cached.engagementState(for: PostID("post-a")).likeCount == 11)
        #expect(first.engagementState(for: PostID("post-a")).likeCount == 11)
    }

    /// The post page opened from the feed shows the feed's like, and its own
    /// like reaches the feed.
    @Test func thePostPageAndTheFeedShareTheCount() async {
        let entities = EntityStore()
        let feed = await loaded([makeEntry("post-a", likeCount: 10)], entities: entities)
        feed.like(for: PostID("post-a"))
        let detail = PostDetailViewModel(
            postID: PostID("post-a"),
            repository: SinglePageProvider(entries: [makeEntry("post-a", likeCount: 10)]),
            engagementProvider: FakeEngagementProvider(),
            entities: entities
        )
        var detailHeard: PostDetailViewModel.EngagementState?
        detail.onEngagementChange = { detailHeard = $0 }
        detail.viewDidLoad()
        #expect(await eventuallyMain { detailHeard != nil })
        #expect(detailHeard?.likeCount == 11, "the repository's older copy did not replace the live count")

        var feedHeard: [Int64] = []
        feed.onEngagementChange = { _, state in feedHeard.append(state.likeCount) }
        #expect(await eventuallyMain { !feed.isLikeInFlight(PostID("post-a")) })
        detail.like()
        #expect(feedHeard == [12])
    }
}

/// Main-actor polling helper for callback-driven expectations.
///
/// ⚠️ BOUNDED BY TRIES, NOT BY A CLOCK — and the difference is a red CI.
///
/// This waited two seconds of WALL TIME, which is a statement about how fast
/// the machine is rather than about the work being waited on. Locally the
/// reconcile it polls for settles in tens of milliseconds; on CI, running every
/// package's tests at once, `reconnectReconcilesCountsAgainstAuthoritativeRead`
/// took twelve seconds to run and the two-second budget expired inside it. The
/// test was reported as an assertion failure — "updates.count == 1" — which
/// reads exactly like a broken reconcile and is nothing of the kind.
///
/// A try count spends nothing when the condition is already true (the common
/// case returns on the first pass) and gives a loaded machine room to finish.
/// The ceiling is what a genuine failure costs, and it is paid once.
@MainActor
private func eventuallyMain(tries: Int = 1500, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<tries {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
