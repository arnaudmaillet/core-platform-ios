import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreRealtime
import CoreStorage
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
    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload a failed timeline — the shared
    /// one; a test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
    private var items: [FeedItemDisplayModel] = []
    private var engagement: [PostID: EngagementState] = [:]
    private var likesInFlight: Set<PostID> = []
    /// Identity slices of every author rendered so far, keyed by profile id —
    /// attached to `.profile` routes so the destination composes its chrome
    /// synchronously (see `didTapAuthor`).
    private var authorStubs: [ProfileID: ProfileIdentityStub] = [:]
    private var isColdRefreshing = false
    private var nextPageToken: String?
    /// Whether the source has nothing after the last post loaded (#628) — the
    /// one moment a swipe up past the end may close the feed.
    ///
    /// True only when a page said so (`FeedPage.isEndOfSource`) AND left no
    /// cursor. ⚠️ No longer the end-of-list gate (#761): the snap feed's
    /// upward grab closes past the last post LOADED, on every feed — a failed
    /// page included, which the 2026-10-07 rule kept from counting; the
    /// owner's "systematic" call of 2026-10-10 supersedes it.
    public private(set) var isSourceExhausted = false

    /// Whether posts are on their way — the first page, or a next one (#761):
    /// until they land, the last post loaded is not the end of the list.
    public var isLoadingNextPage: Bool { pagingLoad != nil || initialLoad != nil }

    /// The last index a cell displayed at — so the near-end check can run
    /// again once a cursor arrives (a seeded feed opened on its last tile
    /// displayed it before the first page said more would follow).
    private var lastDisplayedIndex: Int?
    private var builder: FeedDisplayModelBuilder?
    private var initialLoad: Task<Void, Never>?
    /// Which first-page load is current (#836): bumped each time the slot is
    /// filled. A superseded load touches NOTHING once it wakes — not the
    /// slot, not the posts, not the phase.
    ///
    /// ⚠️ CANCELLING IS NOT ENOUGH: `loadFirstPage()` and `build()` (a
    /// detached task) finish anyway. A load superseded by `refresh()` or
    /// `repoint()` used to clear its successor's slot (`isLoadingNextPage`
    /// read false with the new first page on its way), and after a
    /// `repoint` its late answer wrote the old window's posts, cursor and
    /// counter subscriptions into the new one — or `.failed` over it.
    private var initialLoadGeneration = 0
    private var pagingLoad: Task<Void, Never>?
    private var realtimeTasks: [Task<Void, Never>] = []
    private let tickerBuilder = CommentTickerBuilder()
    private let subtitleBuilder = SubtitleCommentBuilder()
    private var streamsByPost: [PostID: CommentStreams] = [:]
    private var streamLoads: [PostID: Task<Void, Never>] = [:]
    /// Settings → App Preferences: band and subtitle switches, muted words
    /// and accounts (#410). Applied every time a post's streams are built.
    private let commentPreferences: MediaCommentPreferencesStore
    /// The loaded comments behind each built stream, so a preference change
    /// rebuilds every stream in place instead of waiting for a reload.
    private var entriesByPost: [PostID: [CommentEntry]] = [:]
    /// Unregisters itself when the view model goes: a block observer's
    /// token is not `Sendable`, so the nonisolated `deinit` can't touch it.
    private let preferencesObservation = NotificationObservation()

    public init(
        repository: any FeedProviding,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        commentPreferences: MediaCommentPreferencesStore = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.commentPreferences = commentPreferences
        self.repository = repository
        self.engagementProvider = engagementProvider
        self.commentsProvider = commentsProvider
        self.realtime = realtime
        self.composedPosts = composedPosts
        self.router = router
        self.now = now
        preferencesObservation.token = NotificationCenter.default.addObserver(
            forName: .mediaCommentPreferencesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildCommentStreams() }
        }
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
        armRecovery()
        builder = FeedDisplayModelBuilder()
        let generation = nextInitialLoadGeneration()
        initialLoad = Task { await loadInitial(generation: generation) }
        startRealtimeIfConfigured()
        startComposedPostsIfConfigured()
    }

    /// Whether a like on the post is still on its way. Internal for tests.
    func isLikeInFlight(_ id: PostID) -> Bool { likesInFlight.contains(id) }

    public func engagementState(for id: PostID) -> EngagementState {
        engagement[id] ?? EngagementState(likeCount: 0, isLiked: false)
    }

    /// Optimistic like: one point on the post (#676), shown at once, taken
    /// back if it does not land. A like is final — there is no unlike — so
    /// every like adds one. One in flight per post; extra taps are dropped.
    public func like(for id: PostID) {
        guard let engagementProvider, !likesInFlight.contains(id) else { return }
        let before = engagementState(for: id)
        var state = before
        state.isLiked = true
        state.likeCount += 1
        engagement[id] = state
        likesInFlight.insert(id)
        onEngagementChange?(id, state)

        Task {
            do {
                try await engagementProvider.like(id)
            } catch {
                // Roll back: the point did not land.
                var reverted = self.engagementState(for: id)
                reverted.isLiked = before.isLiked
                reverted.likeCount = max(0, reverted.likeCount - 1)
                self.engagement[id] = reverted
                self.onEngagementChange?(id, reverted)
            }
            self.likesInFlight.remove(id)
        }
    }

    /// Reloads after an outage (#793): what failed while the network was gone
    /// comes back on its own when it returns — the viewer no longer has to
    /// find a way to retry, screen by screen.
    private func armRecovery() {
        guard recovery == nil else { return }
        recovery = connectivity.onRecovery { [weak self] in self?.recoverFromOutage() }
    }

    private func recoverFromOutage() {
        // A pull already on its way is the answer; cancelling it would flash
        // the failure again.
        guard case .failed = phase, initialLoad == nil else { return }
        refresh()
    }

    public func refresh() {
        // A first load already on its way is the answer to a second ask: a
        // double-tapped Try Again cancelled it, and the cancelled load's
        // catch flashed the failure before the new one landed (#797).
        guard pagingLoad == nil, initialLoad == nil else { return }
        let generation = nextInitialLoadGeneration()
        initialLoad = Task { await loadFirstPageFromNetwork(renderCacheFirst: false, generation: generation) }
    }

    private func nextInitialLoadGeneration() -> Int {
        initialLoadGeneration += 1
        return initialLoadGeneration
    }

    /// Whether the load of `generation` is still the current one.
    private func isCurrentInitialLoad(_ generation: Int) -> Bool {
        generation == initialLoadGeneration
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
    /// What a cell shows at once. ⚠️ **READ FROM THE WARM CACHE FIRST,
    /// SYNCHRONOUSLY (charter P7).** The grid prefetches a visible tile's
    /// top comments, so by the time the tile is tapped the repository holds
    /// them; building the ticker and the subtitle cues from that cache here
    /// puts them on the page's first frame instead of after the flight. The
    /// seed is kept apart from `streamsByPost` so the full load still runs
    /// and replaces it. `isLoaded` stays false on a seed: a seed can never
    /// say "no comments".
    public func commentStreams(for id: PostID) -> CommentStreams {
        if let loaded = streamsByPost[id] { return loaded }
        if let seeded = seededStreams[id] { return seeded }
        #if DEBUG
        // `-no-comment-seed`: the FIRST push of a post, as a device sees it
        // before the grid has prefetched anything — the streams land by the
        // load alone, after the flight. The ticker's pre-fill has to hold
        // on that path too, and this is how it is filmed on the simulator.
        if ProcessInfo.processInfo.arguments.contains("-no-comment-seed") { return .empty }
        #endif
        guard let entries = commentsProvider?.cachedTopComments(for: id), !entries.isEmpty else { return .empty }
        let seed = makeStreams(from: entries, for: id, isLoaded: false)
        seededStreams[id] = seed
        return seed
    }

    /// The band and the zone for one post, under the viewer's preferences.
    ///
    /// Muted words and accounts leave first, so the band's engagement gate
    /// counts only what may actually ride. ORDER MATTERS after that: the
    /// band resolves first, and whether it renders tells the zone how much
    /// of the post it must speak for — a band switched off, or below its
    /// gate, hands every comment to the zone. A zone switched off renders
    /// nothing but never changes what the band carries.
    func makeStreams(from entries: [CommentEntry], for id: PostID, isLoaded: Bool = true) -> CommentStreams {
        let preferences = commentPreferences.preferences
        let visible = entries.filter { !preferences.mutes(body: $0.body, authorHandle: $0.authorHandle) }
        let reactions = preferences.showsReactionBand ? tickerBuilder.build(visible, postID: id) : []
        let subtitles = preferences.showsSubtitles
            ? subtitleBuilder.build(visible, postID: id, tickerIsRendering: !reactions.isEmpty)
            : []
        return CommentStreams(reactions: reactions, subtitles: subtitles, commentCount: entries.count, isLoaded: isLoaded)
    }

    /// A preference changed: rebuild every stream from the comments already
    /// in hand and push the loaded ones to the cells showing them.
    private func rebuildCommentStreams() {
        seededStreams.removeAll()
        for (id, entries) in entriesByPost {
            let streams = makeStreams(from: entries, for: id)
            streamsByPost[id] = streams
            onCommentStreamsChange?(id, streams)
        }
    }

    private var seededStreams: [PostID: CommentStreams] = [:]

    private func loadCommentStreams(for id: PostID) async {
        defer { streamLoads[id] = nil }
        guard let commentsProvider else { return }
        #if DEBUG
        // `-comment-streams-delay <ms>`: the streams land this long after
        // they were asked for — a device on a real network, where the ticker
        // has to fill a page that is already on screen (filmed 25 September
        // 2026: empty band, bubbles from the right). Pair with
        // `-no-comment-seed` so nothing arrives earlier from the cache.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-comment-streams-delay"),
           let ms = arguments.dropFirst(position + 1).first.flatMap(Int.init) {
            try? await Task.sleep(for: .milliseconds(ms))
        }
        #endif
        // Silent on failure: the load slot frees up, so the next activation
        // of this page retries.
        guard let entries = try? await commentsProvider.loadComments(for: id) else { return }
        // ORDER MATTERS inside `makeStreams`: the band resolves first, and
        // whether it came back with a queue is what tells the zone how much
        // of the post it has to speak for. A band below its engagement gate
        // renders nothing, so the zone must then carry every comment —
        // otherwise a sparse post's comments are claimed by a surface that
        // never shows them, which is exactly how the zone ended up blank on
        // posts that had a conversation.
        entriesByPost[id] = entries
        let streams = makeStreams(from: entries, for: id)
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
        lastDisplayedIndex = index
        startPagingIfNearEnd(index)
    }

    private func startPagingIfNearEnd(_ index: Int) {
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

    /// Aims this view model at a different window of posts and reloads, so the
    /// screen around it can be REUSED rather than rebuilt.
    ///
    /// Everything derived from the old corpus goes: items, engagement, comment
    /// streams, paging. Everything in flight for it is cancelled first, or a
    /// late response would land against the new window and render posts the
    /// viewer did not open. What survives is deliberately narrow —
    /// `authorStubs` is a profile-keyed identity cache that is correct
    /// regardless of which posts are on screen, and re-fetching it would only
    /// slow the next push down.
    ///
    /// Silent no-op when the provider cannot be re-aimed: the open-ended
    /// timeline has no fixed window to replace, and its caller does not reuse.
    public func repoint(to ids: [PostID]) {
        guard let repointable = repository as? any RepointableFeedProviding else { return }
        initialLoad?.cancel()
        pagingLoad?.cancel()
        // Gone with its window: a cancelled page left set read as "still
        // loading" for good, and nothing would ever page again (#761).
        pagingLoad = nil
        lastDisplayedIndex = nil
        for task in streamLoads.values { task.cancel() }
        streamLoads = [:]
        streamsByPost = [:]
        items = []
        engagement = [:]
        likesInFlight = []
        nextPageToken = nil
        isSourceExhausted = false
        isColdRefreshing = false
        phase = .loading
        // A fresh builder, matching `viewDidLoad` — it carries per-corpus
        // derivation state, and reusing one across windows is the kind of
        // thing that shows up later as one post wearing another's furniture.
        builder = FeedDisplayModelBuilder()
        let generation = nextInitialLoadGeneration()
        initialLoad = Task {
            await repointable.repoint(to: ids)
            guard !Task.isCancelled else { return }
            await loadInitial(generation: generation)
        }
    }

    private func loadInitial(generation: Int) async {
        // Offline-first: render the snapshot immediately if there is one…
        if let cached = await repository.cachedFirstPage(), isCurrentInitialLoad(generation),
           let models = await build(cached), isCurrentInitialLoad(generation) {
            items = models
            seedEngagement(from: cached)
            phase = .content
            emit()
        }
        // …then replace it with the network truth.
        guard isCurrentInitialLoad(generation) else { return }
        await loadFirstPageFromNetwork(renderCacheFirst: true, generation: generation)
    }

    private func loadFirstPageFromNetwork(renderCacheFirst: Bool, generation: Int) async {
        do {
            let page = try await repository.loadFirstPage()
            // Superseded: its successor owns the slot, the posts and the phase.
            guard isCurrentInitialLoad(generation) else { return }
            let built = await build(page.entries)
            guard isCurrentInitialLoad(generation) else { return }
            guard let models = built else {
                // No builder yet: nothing to render, but the slot is freed.
                initialLoad = nil
                return
            }
            items = models
            seedEngagement(from: page.entries)
            subscribeToCounters(for: models.map(\.id))
            nextPageToken = page.nextPageToken
            isSourceExhausted = page.nextPageToken == nil && page.isEndOfSource
            isColdRefreshing = page.isCold
            phase = models.isEmpty ? .empty : .content
        } catch {
            // A superseded load's failure is not the feed's.
            guard isCurrentInitialLoad(generation) else { return }
            // Keep showing cached content on failure; only fail visibly when
            // there is nothing at all to show.
            if items.isEmpty {
                // "You're offline" when that is why (#794).
                phase = .failed(message: FailureCopy.message(for: error, fallback: "Couldn't load your timeline"))
            }
        }
        initialLoad = nil
        emit()
        // A cursor that arrived after the viewer's cell displayed: the
        // near-end check runs again for it (#761).
        if let lastDisplayedIndex { startPagingIfNearEnd(lastDisplayedIndex) }
    }

    private func loadNextPage() async {
        guard let token = nextPageToken else {
            if !Task.isCancelled { pagingLoad = nil }
            return
        }
        do {
            let page = try await repository.loadPage(afterToken: token)
            if let models = await build(page.entries) {
                let known = Set(items.map(\.id))
                let fresh = models.filter { !known.contains($0.id) }
                items += fresh
                seedEngagement(from: page.entries)
                subscribeToCounters(for: fresh.map(\.id))
                nextPageToken = page.nextPageToken
                isSourceExhausted = page.nextPageToken == nil && page.isEndOfSource
                isColdRefreshing = page.isCold
            }
        } catch {
            // Silent: the trigger fires again on further scrolling.
        }
        // A cancelled page (a `repoint`) leaves the slot to its successor.
        if !Task.isCancelled { pagingLoad = nil }
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

/// Holds a block-based `NotificationCenter` token and removes it on release.
final class NotificationObservation: @unchecked Sendable {
    var token: NSObjectProtocol?

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
