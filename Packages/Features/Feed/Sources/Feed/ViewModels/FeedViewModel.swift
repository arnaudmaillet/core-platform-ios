import CoreContracts
import CoreModels
import CoreNavigation
import CoreRealtime
import Foundation

/// The slice of the realtime client the feed consumes; a seam for tests.
public protocol FeedRealtimeSubscribing: Sendable {
    func subscribe(to channels: Set<RealtimeChannel>) async
    func events() async -> AsyncStream<RealtimeEvent>
    func connectionEvents() async -> AsyncStream<RealtimeConnectionEvent>
}

extension RealtimeClient: FeedRealtimeSubscribing {}

@MainActor
public final class FeedViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content
        case empty
        case failed(message: String)
    }

    public nonisolated struct RenderState: Sendable {
        public let phase: Phase
        public let items: [FeedItemDisplayModel]
        /// True while the backend reported a cold feed (cache warming); the UI
        /// shows a transient banner and the next refresh clears it.
        public let isColdRefreshing: Bool
    }

    public nonisolated struct EngagementState: Equatable, Sendable {
        public var likeCount: Int64
        public var isLiked: Bool

        public init(likeCount: Int64, isLiked: Bool) {
            self.likeCount = likeCount
            self.isLiked = isLiked
        }
    }

    public var onStateChange: ((RenderState) -> Void)?
    /// Per-post engagement updates (like toggles, live counter ticks); the
    /// view reconfigures just that cell — never a full snapshot apply.
    public var onEngagementChange: ((PostID, EngagementState) -> Void)?

    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel?
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var phase: Phase = .loading
    private var items: [FeedItemDisplayModel] = []
    private var engagement: [PostID: EngagementState] = [:]
    private var likesInFlight: Set<PostID> = []
    private var isColdRefreshing = false
    private var nextPageToken: String?
    private var builder: FeedDisplayModelBuilder?
    private var initialLoad: Task<Void, Never>?
    private var pagingLoad: Task<Void, Never>?
    private var realtimeTasks: [Task<Void, Never>] = []

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.now = now
    }

    deinit {
        for task in realtimeTasks {
            task.cancel()
        }
    }

    // MARK: - Inputs

    /// Called once the collection view knows its width; display heights are
    /// computed against it.
    public func viewDidLoad(layoutWidth: CGFloat) {
        builder = FeedDisplayModelBuilder(cellWidth: layoutWidth)
        initialLoad = Task { await loadInitial() }
        startRealtimeIfConfigured()
        startComposedPostsIfConfigured()
    }

    public func engagementState(for id: PostID) -> EngagementState {
        engagement[id] ?? EngagementState(likeCount: 0, isLiked: false)
    }

    /// Optimistic like toggle: flip immediately, roll back if the server
    /// rejects. One in-flight mutation per post — extra taps are dropped
    /// rather than queued (single-use rotation semantics don't apply here,
    /// but interleaved flips would corrupt the count).
    public func toggleLike(for id: PostID) {
        guard let engagementProvider, !likesInFlight.contains(id) else { return }
        var state = engagementState(for: id)
        state.isLiked.toggle()
        state.likeCount = max(0, state.likeCount + (state.isLiked ? 1 : -1))
        engagement[id] = state
        likesInFlight.insert(id)
        onEngagementChange?(id, state)

        let liked = state.isLiked
        Task {
            do {
                try await engagementProvider.setLiked(liked, for: id)
            } catch {
                // Roll back to the pre-toggle state.
                var reverted = self.engagementState(for: id)
                reverted.isLiked = !liked
                reverted.likeCount = max(0, reverted.likeCount + (liked ? -1 : 1))
                self.engagement[id] = reverted
                self.onEngagementChange?(id, reverted)
            }
            self.likesInFlight.remove(id)
        }
    }

    public func refresh() {
        guard pagingLoad == nil else { return }
        initialLoad?.cancel()
        initialLoad = Task { await loadFirstPageFromNetwork(renderCacheFirst: false) }
    }

    /// Author tapped in a cell — hand off to cross-feature routing. The feed
    /// never imports Profile; it only emits a route.
    public func didTapAuthor(_ id: ProfileID) {
        router?.route(to: .profile(id))
    }

    /// A post row tapped — open its detail via routing.
    public func didTapPost(_ id: PostID) {
        router?.route(to: .post(id))
    }

    /// Pagination trigger: called by the view for every cell about to display.
    public func willDisplayItem(at index: Int) {
        guard nextPageToken != nil, pagingLoad == nil, index >= items.count - 5 else { return }
        pagingLoad = Task { await loadNextPage() }
    }

    // MARK: - Loading

    private func loadInitial() async {
        // Offline-first: render the snapshot immediately if there is one…
        if let cached = await repository.cachedFirstPage(), let models = await build(cached) {
            items = models
            seedEngagement(from: cached)
            phase = .content
            emit()
        }
        // …then replace it with the network truth.
        await loadFirstPageFromNetwork(renderCacheFirst: true)
    }

    private func loadFirstPageFromNetwork(renderCacheFirst: Bool) async {
        do {
            let page = try await repository.loadFirstPage()
            guard let models = await build(page.entries) else { return }
            items = models
            seedEngagement(from: page.entries)
            subscribeToCounters(for: models.map(\.id))
            nextPageToken = page.nextPageToken
            isColdRefreshing = page.isCold
            phase = models.isEmpty ? .empty : .content
        } catch {
            // Keep showing cached content on failure; only fail visibly when
            // there is nothing at all to show.
            if items.isEmpty {
                phase = .failed(message: "Couldn't load your timeline. Pull to retry.")
            }
        }
        initialLoad = nil
        emit()
    }

    private func loadNextPage() async {
        guard let token = nextPageToken else { return }
        do {
            let page = try await repository.loadPage(afterToken: token)
            if let models = await build(page.entries) {
                let known = Set(items.map(\.id))
                let fresh = models.filter { !known.contains($0.id) }
                items += fresh
                seedEngagement(from: page.entries)
                subscribeToCounters(for: fresh.map(\.id))
                nextPageToken = page.nextPageToken
                isColdRefreshing = page.isCold
            }
        } catch {
            // Silent: the trigger fires again on further scrolling.
        }
        pagingLoad = nil
        emit()
    }

    // MARK: - Realtime

    private func startRealtimeIfConfigured() {
        guard let realtime, realtimeTasks.isEmpty else { return }

        realtimeTasks.append(Task { [weak self] in
            for await event in await realtime.events() {
                guard event.channel.channelClass == .counter, event.eventType == "counter.update" else { continue }
                guard let snapshot = try? Counter_V1_CounterSnapshot(serializedBytes: event.payload) else { continue }
                self?.applyCounterSnapshot(snapshot)
            }
        })

        realtimeTasks.append(Task { [weak self] in
            for await connection in await realtime.connectionEvents() {
                // The plane buffers nothing: after any reconnect, re-read the
                // authoritative counters for everything on screen.
                if case .connected(resumed: true) = connection {
                    await self?.reconcileCounts()
                }
            }
        })
    }

    private func startComposedPostsIfConfigured() {
        guard let composedPosts else { return }
        realtimeTasks.append(Task { [weak self] in
            for await entry in await composedPosts.entries() {
                await self?.prepend(entry)
            }
        })
    }

    /// Optimistic insert of a locally-composed post at the top of the feed.
    private func prepend(_ entry: FeedEntry) async {
        guard let models = await build([entry]), let model = models.first else { return }
        // Guard against a later network refresh having already surfaced it.
        guard !items.contains(where: { $0.id == model.id }) else { return }
        items.insert(model, at: 0)
        seedEngagement(from: [entry])
        subscribeToCounters(for: [model.id])
        phase = .content
        emit()
    }

    private func subscribeToCounters(for ids: [PostID]) {
        guard let realtime else { return }
        let channels = Set(ids.map { RealtimeChannel.counter(entityID: $0.rawValue) })
        Task { await realtime.subscribe(to: channels) }
    }

    private func applyCounterSnapshot(_ snapshot: Counter_V1_CounterSnapshot) {
        guard let like = snapshot.values.first(where: { $0.metric == .like }) else { return }
        let id = PostID(snapshot.entity.id)
        var state = engagementState(for: id)
        state.likeCount = like.value
        engagement[id] = state
        onEngagementChange?(id, state)
    }

    private func reconcileCounts() async {
        guard let engagementProvider, !items.isEmpty else { return }
        guard let counts = try? await engagementProvider.likeCounts(for: items.map(\.id)) else { return }
        for (id, count) in counts {
            var state = engagementState(for: id)
            guard state.likeCount != count else { continue }
            state.likeCount = count
            engagement[id] = state
            onEngagementChange?(id, state)
        }
    }

    private func seedEngagement(from entries: [FeedEntry]) {
        for entry in entries {
            let id = entry.post.id
            var state = engagementState(for: id)
            state.likeCount = entry.likeCount
            engagement[id] = state
        }
    }

    private func build(_ entries: [FeedEntry]) async -> [FeedItemDisplayModel]? {
        guard let builder else { return nil }
        let now = now()
        // Text measurement runs off the main actor by design.
        return await Task.detached(priority: .userInitiated) {
            builder.build(entries, relativeTo: now)
        }.value
    }

    private func emit() {
        onStateChange?(RenderState(phase: phase, items: items, isColdRefreshing: isColdRefreshing))
    }
}
