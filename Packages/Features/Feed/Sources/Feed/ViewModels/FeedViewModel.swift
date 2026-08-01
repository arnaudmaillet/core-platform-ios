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

    /// Both comment surfaces' content for one post, built together from a
    /// single comments fetch: the conveyor's micro-reactions and the subtitle
    /// zone's semantic cues. One comment rides exactly one surface (the
    /// builders partition by precedence).
    public nonisolated struct CommentStreams: Equatable, Sendable {
        public let reactions: [TickerCommentModel]
        public let subtitles: [SubtitleCue]
        /// Total top-level comments on the post — every loaded entry, before
        /// either surface's filters. Feeds the subtitle zone's count bubble.
        public let commentCount: Int
        /// True once a comments fetch actually completed for the post. This
        /// is the seam that separates "nothing known yet" (the pre-load
        /// default, where every surface stays blank) from "known to have
        /// zero comments" (where the chrome renders the comments empty
        /// state) — the two are otherwise indistinguishable, and the empty
        /// state must never flash while a load is still in flight. `.empty`
        /// is the only unloaded value by construction.
        public let isLoaded: Bool

        public static let empty = CommentStreams(reactions: [], subtitles: [], commentCount: 0, isLoaded: false)

        public init(reactions: [TickerCommentModel], subtitles: [SubtitleCue], commentCount: Int, isLoaded: Bool = true) {
            self.reactions = reactions
            self.subtitles = subtitles
            self.commentCount = commentCount
            self.isLoaded = isLoaded
        }
    }

    public var onStateChange: ((RenderState) -> Void)?
    /// Per-post engagement updates (like toggles, live counter ticks); the
    /// view reconfigures just that cell — never a full snapshot apply.
    public var onEngagementChange: ((PostID, EngagementState) -> Void)?
    /// Fired when the viewer's own just-composed post is prepended. The
    /// full-screen snap feed scrolls to the top to reveal it (a normal prepend
    /// would otherwise shift it above the viewport).
    public var onOwnPostInserted: (() -> Void)?
    /// A post's comment streams (ticker queue + subtitle cues) became
    /// available (or re-emitted from cache on re-activation); the view routes
    /// them to just that post's cell. An empty stream means the post failed
    /// that surface's engagement gate.
    public var onCommentStreamsChange: ((PostID, CommentStreams) -> Void)?

    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let realtime: (any FeedRealtimeSubscribing)?
    private let composedPosts: ComposedPostChannel?
    private let router: (any Router)?
    private let now: @Sendable () -> Date

    private var phase: Phase = .loading
    private var items: [FeedItemDisplayModel] = []
    private var engagement: [PostID: EngagementState] = [:]
    private var likesInFlight: Set<PostID> = []
    /// Identity slices of every author rendered so far, keyed by profile id —
    /// attached to `.profile` routes so the destination composes its chrome
    /// synchronously (see `didTapAuthor`).
    private var authorStubs: [ProfileID: ProfileIdentityStub] = [:]
    private var isColdRefreshing = false
    private var nextPageToken: String?
    private var builder: FeedDisplayModelBuilder?
    private var initialLoad: Task<Void, Never>?
    private var pagingLoad: Task<Void, Never>?
    private var realtimeTasks: [Task<Void, Never>] = []
    private let tickerBuilder = CommentTickerBuilder()
    private let subtitleBuilder = SubtitleCommentBuilder()
    private var streamsByPost: [PostID: CommentStreams] = [:]
    private var streamLoads: [PostID: Task<Void, Never>] = [:]

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.now = now
    }

    deinit {
        for task in realtimeTasks {
            task.cancel()
        }
        for task in streamLoads.values {
            task.cancel()
        }
    }

    // MARK: - Inputs

    /// Called once the view is laid out; kicks the initial load.
    public func viewDidLoad() {
        builder = FeedDisplayModelBuilder()
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
    /// never imports Profile; it only emits a route. The identity slice the
    /// cell already renders (handle, name) rides along so the profile screen
    /// can compose its navigation chrome before the push animates.
    public func didTapAuthor(_ id: ProfileID) {
        router?.route(to: .profile(id, stub: authorStubs[id]))
    }

    /// The comment button tapped — open the post's comments via routing. On the
    /// snap feed the post is already full-screen, so this opens the comments-only
    /// surface rather than the full post detail.
    public func didTapComments(_ id: PostID) {
        router?.route(to: .comments(id))
    }

    /// The settle seam's comment hook: a page became the active page. Also
    /// warms the immediate neighbors' streams — deterministically, unlike
    /// the collection view's prefetcher (which is velocity-driven and stays
    /// silent after programmatic jumps and at rest) — so the page the user
    /// swipes to next already OWNS its comment content and its subtitle
    /// zone rides the transition with the instant entrance instead of
    /// fading in after arrival.
    public func pageDidBecomeActive(_ id: PostID) {
        ensureCommentStreams(for: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            for neighbor in [index - 1, index + 1] where items.indices.contains(neighbor) {
                ensureCommentStreams(for: items[neighbor].id)
            }
        }
    }

    /// Loads a post's comment streams once (single-flight, cached for the
    /// session) and emits them via `onCommentStreamsChange`. Also the
    /// prefetch side of the seam: called for pages *about to* scroll in —
    /// via `willDisplayItem` and the collection view's prefetcher — so a
    /// page arrives with its band already populated instead of popping it in
    /// at settle. Idempotent and cheap on the cached path.
    public func ensureCommentStreams(for id: PostID) {
        guard commentsProvider != nil else { return }
        if let cached = streamsByPost[id] {
            onCommentStreamsChange?(id, cached)
            return
        }
        guard streamLoads[id] == nil else { return }
        streamLoads[id] = Task { await loadCommentStreams(for: id) }
    }

    /// The cached streams for `id` — the pull side for cell
    /// (re)configuration; `.empty` until `pageDidBecomeActive` has loaded
    /// them or when the post failed both engagement gates.
    public func commentStreams(for id: PostID) -> CommentStreams {
        streamsByPost[id] ?? .empty
    }

    private func loadCommentStreams(for id: PostID) async {
        defer { streamLoads[id] = nil }
        guard let commentsProvider else { return }
        // Silent on failure: the load slot frees up, so the next activation
        // of this page retries.
        guard let entries = try? await commentsProvider.loadComments(for: id) else { return }
        let streams = CommentStreams(
            reactions: tickerBuilder.build(entries, postID: id),
            subtitles: subtitleBuilder.build(entries, postID: id),
            commentCount: entries.count
        )
        streamsByPost[id] = streams
        onCommentStreamsChange?(id, streams)
    }

    /// Called by the view for every cell about to display: pagination
    /// trigger, and the last-resort ticker prefetch (the collection view's
    /// prefetcher usually got there earlier).
    public func willDisplayItem(at index: Int) {
        if items.indices.contains(index) {
            ensureCommentStreams(for: items[index].id)
        }
        guard nextPageToken != nil, pagingLoad == nil, index >= items.count - 5 else { return }
        pagingLoad = Task { await loadNextPage() }
    }

    // MARK: - Loading

    /// Renders a projection the caller already has, before any fetch.
    ///
    /// Only while there is nothing else: a real page always wins, and a seed
    /// arriving after one would be a downgrade. `phase` moves to `.content` so
    /// the page lays out immediately rather than sitting in its loading state.
    public func seed(_ models: [FeedItemDisplayModel]) {
        guard items.isEmpty, !models.isEmpty else { return }
        items = models
        phase = .content
        emit()
    }

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
        onOwnPostInserted?()
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
        // Every entry that can reach the screen passes through here (pages,
        // refreshes, composed-post prepends), so this is the one place to
        // remember each author's identity slice for profile routing.
        for entry in entries {
            authorStubs[entry.author.id] = ProfileIdentityStub(
                handle: entry.author.handle,
                displayName: entry.author.displayName
            )
        }
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
