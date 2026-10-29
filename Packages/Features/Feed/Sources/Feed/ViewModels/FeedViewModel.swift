import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreRealtime
import CoreStorage
import EntityStore
import FeedInterface
import Foundation
import MediaCore
import UIKit

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
    /// The viewer's own like per post, and the count a post had when it was
    /// loaded — the fallback for a post the store no longer holds.
    private var engagement: [PostID: EngagementState] = [:]
    /// Where every post's live count is (#896): what the pages read, the
    /// realtime ticks, the reconciles, and every point the viewer stakes,
    /// from any screen. The view model writes what it loads and re-draws
    /// what changed, whoever changed it.
    private let entities: EntityStore
    private var entityObservation: EntityObservation?
    /// Keeps the active page's post in the store, whatever a memory trim
    /// takes: a stake on it needs a count to move.
    private var activePostPin: EntityObservation?
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
    private let cacheRevalidation: CacheRevalidation
    /// The items on show came from the device's copy, not the network yet.
    private var showsCachedFirstPage = false
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

    /// What the network's first page does to a first page rendered from the
    /// device (#1765).
    public enum CacheRevalidation: Sendable {
        /// It replaces it: a list read from its top.
        case replace
        /// The posts already on screen stay, and the network's come after
        /// them: a full-screen feed whose first post is PLAYING (Shots, the
        /// launch screen) never swaps it under the viewer, as TikTok does.
        case keepShown
    }

    public init(
        repository: any FeedProviding,
        cacheRevalidation: CacheRevalidation = .replace,
        engagementProvider: (any EngagementProviding)? = nil,
        commentsProvider: (any CommentsProviding)? = nil,
        realtime: (any FeedRealtimeSubscribing)? = nil,
        composedPosts: ComposedPostChannel? = nil,
        router: (any Router)? = nil,
        commentPreferences: MediaCommentPreferencesStore = .standard,
        entities: EntityStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.entities = entities ?? EntityStore()
        self.commentPreferences = commentPreferences
        self.repository = repository
        self.cacheRevalidation = cacheRevalidation
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
        entityObservation = self.entities.observePosts { [weak self] change in
            self?.entitiesDidChange(change)
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

    /// The post's live count — the store's, else the one it was loaded
    /// with — and whether the viewer liked it here.
    public func engagementState(for id: PostID) -> EngagementState {
        let own = engagement[id] ?? EngagementState(likeCount: 0, isLiked: false)
        return EngagementState(likeCount: entities.post(id)?.likeCount ?? own.likeCount, isLiked: own.isLiked)
    }

    /// The like count `model`'s page draws: the post's live one (#896). What
    /// a cell is configured with, so a page scrolled back to shows a like
    /// placed meanwhile, here or elsewhere.
    func visibleLikeCount(for model: FeedItemDisplayModel) -> Int64? {
        entities.post(model.id)?.likeCount ?? model.likeCount
    }

    /// Optimistic like: one point on the post (#676), shown at once, taken
    /// back if it does not land. A like is final — there is no unlike — so
    /// every like adds one. One in flight per post; extra taps are dropped.
    ///
    /// The point goes on the store's count, so every screen showing the post
    /// shows it (#896); the store's change is what re-draws this one.
    public func like(for id: PostID) {
        guard let engagementProvider, !likesInFlight.contains(id) else { return }
        let before = engagementState(for: id)
        engagement[id, default: before].isLiked = true
        likesInFlight.insert(id)
        if entities.post(id)?.likeCount == nil {
            entities.setLikeCount(before.likeCount + 1, for: id)
        } else {
            entities.addLikes(1, to: id)
        }

        Task {
            do {
                try await engagementProvider.like(id)
            } catch {
                // Roll back: the point did not land.
                self.engagement[id]?.isLiked = before.isLiked
                self.entities.addLikes(-1, to: id)
            }
            self.likesInFlight.remove(id)
        }
    }

    /// A post changed in the store — this screen's write or anyone's: the
    /// pages showing it re-draw their count, and a post deleted anywhere
    /// leaves the feed.
    private func entitiesDidChange(_ change: EntityChange<PostID>) {
        // `.everything` is a viewer change wiping the viewer's facts: no
        // count moved.
        guard case .some(let ids) = change else { return }
        let shown = Set(items.map(\.id)).intersection(ids)
        guard !shown.isEmpty else { return }
        let deleted = shown.filter(entities.isDeleted)
        if !deleted.isEmpty {
            items.removeAll { deleted.contains($0.id) }
            for id in deleted { engagement[id] = nil }
            if items.isEmpty, phase == .content { phase = .empty }
            emit()
        }
        for id in shown.subtracting(deleted) {
            onEngagementChange?(id, engagementState(for: id))
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

    /// A post's link sent to someone from its share sheet (#1710): a DM
    /// carrying it — the profile sheet's own send (`ProfileViewModel.sendProfile`).
    public func sendLink(_ link: String, to target: ProfileID, stub: ProfileIdentityStub?) {
        router?.route(to: .sendLink(link, to: target, stub: stub))
    }

    /// Author tapped in a cell — hand off to cross-feature routing. The feed
    /// never imports Profile; it only emits a route. The identity slice the
    /// cell already renders (handle, name) rides along so the profile screen
    /// can compose its navigation chrome before the push animates.
    public func didTapAuthor(_ id: ProfileID) {
        router?.route(to: .profile(id, stub: identity(of: id)))
    }

    /// The author's profile opened as a window out of `source`'s author pill
    /// (#1874, `-profile-window`).
    public func didTapAuthor(_ id: ProfileID, throughWindowOf source: any ProfileWindowSource) {
        router?.route(to: .profile(id, stub: identity(of: id)), throughWindowOf: source)
    }

    /// What the feed knows of `id` as it opens them (#1858): the pill's stub,
    /// with the viewer's follow state from the store — the badge the pill
    /// shows — and what the store holds for anything the stub lacks.
    private func identity(of id: ProfileID) -> ProfileIdentityStub? {
        entities.knownIdentity(of: id, stub: authorStubs[id])
    }

    /// The bottom toolbar's author pill (#1524): the author's profile CARD,
    /// or, on the viewer's own post, their profile.
    public func didTapAuthorPill(_ id: ProfileID, isViewer: Bool) {
        let stub = identity(of: id)
        router?.route(to: .profileCard(id, stub: Self.pillStub(stub, isViewer: isViewer)))
    }

    /// The pill's stub, saying whether it is the viewer's. Pure, for tests.
    nonisolated static func pillStub(_ stub: ProfileIdentityStub?, isViewer: Bool) -> ProfileIdentityStub? {
        guard isViewer else { return stub }
        return ProfileIdentityStub(
            handle: stub?.handle, displayName: stub?.displayName ?? "",
            isFollowing: stub?.isFollowing, isSelf: true,
            avatarURL: stub?.avatarURL, avatarFrameID: stub?.avatarFrameID, hasBanner: stub?.hasBanner
        )
    }

    /// The author's profile, made but NOT pushed — what a leftward swipe
    /// pushes following the finger (#1525). Nil without a router that makes
    /// one.
    public func authorProfileDestination(_ id: ProfileID) -> UIViewController? {
        router?.destination(for: .profile(id, stub: identity(of: id)))
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
        activePostPin = entities.observePost(id) { _ in }
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
            // Its page was fetched ahead; this is its first display (#970).
            repository.didShow(items[index].id)
        }
        lastDisplayedIndex = index
        startPagingIfNearEnd(index)
    }

    /// The next page at 5 posts left or fewer (`LookaheadPaging`, #970), one
    /// page in flight; the repository writes it to the LocalStore with its
    /// cursor (#893), and a post re-served by it is dropped by id.
    private func startPagingIfNearEnd(_ index: Int) {
        guard nextPageToken != nil, pagingLoad == nil,
              LookaheadPaging.wantsNextPage(index: index, count: items.count) else { return }
        pagingLoad = Task { await loadNextPage() }
    }

    // MARK: - Loading

    /// Renders a projection the caller already has, before any fetch.
    ///
    /// Only while there is nothing else: a real page always wins, and a seed
    /// arriving after one would be a downgrade. `phase` moves to `.content` so
    /// the page lays out immediately rather than sitting in its loading state.
    public func seed(_ models: [FeedItemDisplayModel]) {
        let kept = withoutDeleted(models)
        guard items.isEmpty, !kept.isEmpty else { return }
        items = kept
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
    public func repoint(to ids: [PostID], continuation: SnapFeedContinuation? = nil) {
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
        showsCachedFirstPage = false
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
            await repointable.repoint(to: ids, continuation: continuation)
            guard !Task.isCancelled else { return }
            await loadInitial(generation: generation)
        }
    }

    private func loadInitial(generation: Int) async {
        LaunchTimeline.mark("feed.loadInitial")
        // Offline-first: render the snapshot immediately if there is one…
        if let cached = await repository.cachedFirstPage(), isCurrentInitialLoad(generation),
           let models = await build(cached), isCurrentInitialLoad(generation) {
            LaunchTimeline.mark("feed.cachedBuilt")
            items = withoutDeleted(models)
            showsCachedFirstPage = !items.isEmpty
            // A copy from the device: it never replaces a fresher count.
            seedEngagement(from: cached, counts: .ifUnknown)
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
            items = revalidated(withoutDeleted(models))
            showsCachedFirstPage = false
            seedEngagement(from: page.entries)
            subscribeToCounters(for: items.map(\.id))
            nextPageToken = page.nextPageToken
            isSourceExhausted = page.nextPageToken == nil && page.isEndOfSource
            isColdRefreshing = page.isCold
            phase = items.isEmpty ? .empty : .content
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

    /// The network's first page over the one shown from the device: replaced,
    /// or — `keepShown` — the posts the viewer has reached (and the one after,
    /// already warming) kept at the head, the network's fresh posts after
    /// them.
    private func revalidated(_ network: [FeedItemDisplayModel]) -> [FeedItemDisplayModel] {
        guard cacheRevalidation == .keepShown, showsCachedFirstPage, !items.isEmpty else { return network }
        let keep = min(items.count, (lastDisplayedIndex ?? 0) + 2)
        let head = Array(items.prefix(keep))
        let shown = Set(head.map(\.id))
        return head + network.filter { !shown.contains($0.id) }
    }

    private func loadNextPage() async {
        guard let token = nextPageToken else {
            if !Task.isCancelled { pagingLoad = nil }
            return
        }
        var addedNothing = false
        do {
            let page = try await repository.loadPage(afterToken: token)
            if let models = await build(page.entries) {
                // A page that lands while the side list drives the card is
                // the SET-ASIDE feed's (#1509): it joins that, not the list.
                if var aside = setAside {
                    let known = Set(aside.items.map(\.id))
                    aside.items += withoutDeleted(models).filter { !known.contains($0.id) }
                    aside.nextPageToken = page.nextPageToken
                    aside.isSourceExhausted = page.nextPageToken == nil && page.isEndOfSource
                    setAside = aside
                    seedEngagement(from: page.entries)
                    if !Task.isCancelled { pagingLoad = nil }
                    return
                }
                let known = Set(items.map(\.id))
                let fresh = withoutDeleted(models).filter { !known.contains($0.id) }
                addedNothing = fresh.isEmpty
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
        // ⚠️ A PAGE THAT ADDED NOTHING (every post filtered — the For You
        // root's media-only source, #1699 — or already shown) displays
        // nothing new, so no `willDisplay` would ask again: the feed would
        // stall at its last post. The next page is asked for now.
        if addedNothing, !Task.isCancelled, nextPageToken != nil, let index = lastDisplayedIndex {
            startPagingIfNearEnd(index)
        }
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

    // MARK: - The side list's session (#1509)

    /// The feed set aside while the side list drives the card: its posts and
    /// its paging, restored untouched on close.
    private struct SetAside {
        var items: [FeedItemDisplayModel]
        var nextPageToken: String?
        var isSourceExhausted: Bool
    }
    private var setAside: SetAside?

    /// Whether the side list drives the card now.
    public var isInSideListSession: Bool { setAside != nil }

    /// The post a list entry would show, as the feed's provider reads it —
    /// the post on show, for the list's first tile.
    func entry(for id: PostID) async -> FeedEntry? {
        try? await repository.loadPost(id)
    }

    /// ⚠️ WHILE THE LIST IS OPEN, PAGING RUNS THROUGH IT (#1509, the owner's
    /// choice): the feed's posts become `[anchor] + entries` — the post on
    /// show first, then the list's — and the feed itself is set aside
    /// untouched, paging included, until `endSideListSession`. Nothing is
    /// injected into it. The list ends where it ends: no paging meanwhile.
    /// False (nothing changed) when the anchor is not in the feed or a
    /// session is already on.
    @discardableResult
    public func beginSideListSession(anchor: PostID, entries: [FeedEntry]) async -> Bool {
        guard setAside == nil, let anchorModel = items.first(where: { $0.id == anchor }) else { return false }
        let others = entries.filter { $0.post.id != anchor }
        let built = others.isEmpty ? [] : await build(others) ?? []
        guard setAside == nil, items.contains(where: { $0.id == anchor }) else { return false }
        setAside = SetAside(items: items, nextPageToken: nextPageToken, isSourceExhausted: isSourceExhausted)
        items = [anchorModel] + withoutDeleted(built).filter { $0.id != anchor }
        nextPageToken = nil
        isSourceExhausted = true
        seedEngagement(from: others)
        subscribeToCounters(for: items.map(\.id))
        emit()
        return true
    }

    /// The list closed: the feed comes back as it was set aside. `shown` —
    /// the post on show when the list closed mid-way (#1509) — goes right
    /// after `anchor` when it is not in the feed already, so the feed
    /// continues from the anchor's place. Returns where the feed should sit:
    /// `shown`'s index, the anchor's, or (with `shown` nil) the post after
    /// the anchor's.
    @discardableResult
    public func endSideListSession(anchor: PostID, keeping shown: PostID?) -> Int? {
        guard let aside = setAside else { return nil }
        setAside = nil
        let sessionModels = items
        items = aside.items
        nextPageToken = aside.nextPageToken
        isSourceExhausted = aside.isSourceExhausted
        let anchorIndex = items.firstIndex { $0.id == anchor }
        if let shown, shown != anchor, !items.contains(where: { $0.id == shown }),
           let model = sessionModels.first(where: { $0.id == shown }) {
            items.insert(model, at: anchorIndex.map { $0 + 1 } ?? items.count)
        }
        emit()
        if let shown { return items.firstIndex { $0.id == shown } }
        return anchorIndex.map { min($0 + 1, items.count - 1) }
    }

    /// Optimistic insert of a locally-composed post at the top of the feed.
    private func prepend(_ entry: FeedEntry) async {
        guard let models = await build([entry]), let model = models.first else { return }
        // The side list drives the card (#1509): the post joins the feed set
        // aside, which it heads when the list closes.
        if var aside = setAside {
            guard !aside.items.contains(where: { $0.id == model.id }) else { return }
            aside.items.insert(model, at: 0)
            setAside = aside
            seedEngagement(from: [entry])
            return
        }
        // Guard against a later network refresh having already surfaced it.
        guard !items.contains(where: { $0.id == model.id }), !entities.isDeleted(model.id) else { return }
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

    /// Into the store: every screen showing the post hears the tick.
    private func applyCounterSnapshot(_ snapshot: Counter_V1_CounterSnapshot) {
        guard let like = snapshot.values.first(where: { $0.metric == .like }) else { return }
        entities.setLikeCount(like.value, for: PostID(snapshot.entity.id))
    }

    private func reconcileCounts() async {
        guard let engagementProvider, !items.isEmpty else { return }
        guard let counts = try? await engagementProvider.likeCounts(for: items.map(\.id)) else { return }
        entities.mergeCounts(counts.mapValues { PostCounts(likes: $0) })
    }

    /// What a page loaded goes into the store — one entity per post, shared
    /// with every other list that loads it (#970) — and is remembered here
    /// as the fallback.
    private func seedEngagement(from entries: [FeedEntry], counts given: CountFreshness? = nil) {
        let freshness = given ?? (repository.pagesCarryFreshCounts ? .fresh : .ifUnknown)
        for entry in entries {
            let id = entry.post.id
            engagement[id] = EngagementState(likeCount: entry.likeCount, isLiked: engagement[id]?.isLiked ?? false)
        }
        entities.upsert(entries, counts: freshness)
    }

    private func build(_ entries: [FeedEntry]) async -> [FeedItemDisplayModel]? {
        guard let builder else { return nil }
        // Every entry that can reach the screen passes through here (pages,
        // refreshes, composed-post prepends), so this is the one place to
        // remember each author's identity slice for profile routing.
        for entry in entries {
            // What the pill draws (#1858): name, handle, avatar and frame. The
            // follow state is read when the person is opened (`identity(of:)`).
            authorStubs[entry.author.id] = ProfileIdentityStub(
                handle: entry.author.handle,
                displayName: entry.author.displayName,
                avatarURL: entry.author.avatarURL,
                avatarFrameID: entry.author.avatarFrameID
            )
        }
        let now = now()
        // Text measurement runs off the main actor by design.
        return await Task.detached(priority: .userInitiated) {
            builder.build(entries, relativeTo: now)
        }.value
    }

    /// A page fetched before a delete still lists the post: it stays out.
    private func withoutDeleted(_ models: [FeedItemDisplayModel]) -> [FeedItemDisplayModel] {
        models.filter { !entities.isDeleted($0.id) }
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
