import CoreModels
import CoreNetworking
import CoreStorage
import EntityStore
import Foundation
import PostGrid

/// Drives For You: one accumulated corpus, and every surface the screen and
/// the screens it pushes draw from it.
///
/// **One page, no tabs** (2026-09-29). The screen is Discover's list, led by
/// two rows — the viewer's FRIENDS (mutual follows) as story avatars, and the
/// rest of the people they FOLLOW as cards — each of which pushes its own
/// list. So this answers, from one corpus and in one publish, for five
/// surfaces at once: the list, the two rows, and the two pushed lists (plus
/// the pushed mosaic, which is Discover's media). One publish is what keeps a
/// row, its badge and the list it pushes from ever disagreeing.
@MainActor
public final class ForYouViewModel {
    public nonisolated enum PageState: Equatable, Sendable {
        case loading
        case content([GalleryPost])
        /// The combination has nothing to show, said in two parts so the page
        /// reads intentional rather than broken.
        case empty(EmptyState)
        case failed(message: String)
    }

    /// An empty page, in the two pieces the viewer needs separately.
    ///
    /// The split is not cosmetic. The TITLE is the finding — "No activity yet"
    /// — and is true regardless of how the viewer got here. The SUBTITLE is the
    /// reason the page might be narrower than they expected, and it is the only
    /// part that tells them there is something they can change. Running them
    /// into one sentence made the actionable half look like punctuation.
    public nonisolated struct EmptyState: Equatable, Sendable {
        public let title: String
        /// Absent when nothing is narrowing the page — an unfiltered surface
        /// with no content has no explanation to offer, and inventing one would
        /// be noise.
        public let subtitle: String?

        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// One friend in the stories row.
    public nonisolated struct FriendStory: Equatable, Sendable {
        public let authorID: ProfileID
        public let name: String
        public let handle: String
        public let avatarURL: URL?
        /// What a tap opens, newest first: the friend's UNSEEN posts when
        /// there are any — "only those of the selected friend" — and their
        /// recent ones otherwise, so a friend with nothing new still opens
        /// onto something.
        public let posts: [GalleryPost]
        /// Whether any of `posts` is new to the viewer — what the ring says.
        public let hasUnseen: Bool
    }

    /// The two rows that lead the list, and the counts on their headers.
    public nonisolated struct Rails: Equatable, Sendable {
        /// Every friend with something loaded, those with unseen posts first.
        public var friends: [FriendStory] = []
        /// The people the viewer follows who are NOT friends: their posts,
        /// unseen first, as cards.
        public var following: [GalleryPost] = []
        /// The pushed Following list holds more than the rows show: a row cut
        /// at its limit, or a timeline page not loaded yet — the rows then
        /// end on "View all" (the shelf contract, #1671).
        public var followingHasMore = false
        /// The Friends header's count: friends' posts the viewer has not seen.
        public var friendsBadge = 0
        /// The Following header's count: arrivals since the session baseline —
        /// the number the Following TAB's badge used to be.
        public var followingBadge = 0

        public init() {}
    }

    public nonisolated struct Snapshot: Equatable, Sendable {
        /// Discover's list: the DISCOVERY corpus — every author, every kind,
        /// in ranked order — from which the list decides for itself which
        /// posts become mosaic tiles (`MosaicChunkPlanner`).
        public var discover: PageState = .loading
        /// Discover narrowed to media: the pushed "View all" mosaic.
        public var media: PageState = .loading
        /// The pushed FOLLOWING list: the people the viewer follows who are
        /// not friends — one plain run of posts, no sections.
        public var following: PageState = .loading
        /// The pushed FRIENDS list: mutual follows, one plain run too.
        public var friends: PageState = .loading
        /// Which of Following's posts arrived since the session baseline —
        /// what orders the row's cards (unseen first) and what its badge
        /// counts, so the two cannot disagree.
        public var followingNew: Set<PostID> = []
        /// Which of the friends' posts the viewer has not seen yet.
        public var friendsUnseen: Set<PostID> = []
        public var rails = Rails()

        public init() {}
    }

    /// Whether another page of the corpus can still be fetched. What lets
    /// Discover decide the chunk at its tail instead of holding the posts
    /// behind it back for a page that is never coming.
    public var hasMorePages: Bool { hasDiscovery ? discoveryToken != nil : nextPageToken != nil }
    /// Whether the FOLLOWING timeline (the Friends and Following lists) has
    /// another page (#566).
    public var hasMoreFollowingPages: Bool { nextPageToken != nil }

    public var onSnapshotChange: ((Snapshot) -> Void)?
    /// Fires when a NEXT-PAGE fetch starts and again when it settles.
    ///
    /// Separate from `onSnapshotChange` on purpose: a page landing publishes a
    /// snapshot, but a page *starting* publishes nothing, and the grid's footer
    /// spinner needs the leading edge. Also distinct from the first load, which
    /// the pages already render as skeletons.
    public var onPagingChange: ((Bool) -> Void)?
    /// The FOLLOWING timeline's page load starting and ending — the Friends
    /// and Following lists' footer (#566). Discover's is `onPagingChange`.
    public var onFollowingPagingChange: ((Bool) -> Void)?
    /// Fires when a load settles, however it settled — the view closes out its
    /// refresh control on this rather than inferring it from a snapshot that
    /// may be identical to the last one.
    public var onLoadSettled: (() -> Void)?
    /// Fires when a pull-to-refresh FAILED while content was already on
    /// screen — the content stays, and the screen says the refresh did not
    /// happen (#798).
    ///
    /// ⚠️ A refresh used to drop the corpus before asking for the new one, so
    /// a failed refresh published an empty FAILED page: one dropped request
    /// wiped everything the viewer was looking at. Now the corpus stays until
    /// its replacement lands, and a failure keeps it; but kept silently, a
    /// refresh that did nothing reads as "there is nothing new", which is a
    /// lie of its own. So it is said — once, out of the way (a toast), since
    /// the page itself is still good. Fires before `onLoadSettled`.
    ///
    /// A failure with NOTHING loaded is not this: it is the failed page, with
    /// its own retry, exactly as before.
    public var onRefreshFailed: (() -> Void)?
    /// Everything waiting on the two rows — the For You tab's unread signal.
    /// The sum of the two headers' numbers, as they read them (a forced
    /// `-foryou-badges` count included), never derived separately (#1423).
    public var onNewCountChange: ((Int) -> Void)?
    /// Fires immediately BEFORE a publish whose corpus was re-derived rather
    /// than extended — a re-ordering, a follow moving an author between rows.
    ///
    /// ⚠️ The pages cannot work this out for themselves, and trying to crashed
    /// the app. A page treats "same posts plus some new ones" as an append and
    /// expresses it as an insert, which is what keeps the mosaic from
    /// reshuffling when Trending re-ranks a landing page. A re-derivation can
    /// produce exactly that shape — every post still there, plus thirty more —
    /// but it is NOT an append: the newcomers belong all through the list, not
    /// after it. Inserted at the end they mis-order the timeline,
    /// and when the sectioning moves in the same pass `performBatchUpdates`
    /// takes the whole app down with an inconsistency exception.
    ///
    /// So the distinction is stated by the only type that knows which it is.
    public var onCorpusReset: (() -> Void)?

    private let repository: any ForYouProviding
    /// The baseline "new" is counted from. Owned here rather than by the view
    /// controller because every input it needs is already this type's.
    private let unreadStore: ForYouUnreadStore
    /// The friends' posts the viewer has OPENED — what clears a story's ring.
    private let seenStore: ForYouSeenPostsStore

    /// The key the session baseline is persisted under — FOLLOWING's, which
    /// is what the badged tab was called and what installed apps have stored.
    /// One baseline serves both rows: a friend is someone the viewer follows,
    /// and "since you last looked" is one instant for all of them.
    nonisolated static let unreadKey: GalleryFilter.Format = .activity

    /// How many cards the Following row carries, and how many posts a story
    /// opens onto. The row is a way INTO the list; the list is one tap away.
    nonisolated static let railLimit = 20

    /// How many more following pages the rows may fetch to fill up. The
    /// following timeline's first page also carries FRIENDS' posts, which go
    /// to their own row: on the mock, 7 of its 20 posts were the Following
    /// row's, so its two rows showed a handful each. The rows page on until
    /// each holds `PostShelfSection.rowLimit` cards or the timeline ends —
    /// capped, so a timeline of friends alone does not page through everything.
    nonisolated static let maxFollowingTopUps = 3
    private var followingTopUps = 0

    /// Fetches the following timeline's next page when either Following row is
    /// short of its limit — once per page, the next decided when it lands.
    private func topUpFollowingIfShort(_ cards: [GalleryPost]) {
        let text = cards.filter { $0.kind == .text }.count
        let short = cards.count - text < PostShelfSection.rowLimit || text < PostShelfSection.rowLimit
        // ⚠️ ONLY WITH DISCOVERY WIRED (always, in the app). Without it the
        // following timeline IS Discover's grid, which pages itself as the
        // viewer nears its end — a top-up there would page the grid unasked.
        guard hasDiscovery, short, followingTopUps < Self.maxFollowingTopUps,
              followingPageLoad == nil, load == nil, nextPageToken != nil
        else { return }
        followingTopUps += 1
        loadNextPageIfNeeded(.following)
    }

    /// What a failed first page says when the device is online (#794). The
    /// page's Try Again sits under it, so it promises no pull.
    nonisolated static let failureMessage = "Couldn't load these posts."

    public private(set) var source: DiscoverySource = .trending

    /// Everything loaded so far, **in the order it is displayed**. nil = the
    /// first page is still in flight (pages report loading); a failure records
    /// instead.
    ///
    /// The ordering is applied when content ARRIVES, not on every read, and an
    /// appended page is ordered among itself and added to the end. Re-sorting
    /// the whole corpus on every page would renumber tiles the viewer is
    /// already looking at — caught in-sim as the grid visibly rearranging half
    /// a second after a hero had landed on one of them.
    ///
    /// The cost is stated plainly: "trending" ranks within each page rather
    /// than across the whole loaded corpus. That is the honest trade for a
    /// list that holds still, and it is moot once ranking is the server's job
    /// (see `dev/BACKEND_GAPS.md` §14). A source change re-sorts everything,
    /// because there the viewer asked for exactly that.
    private var corpus: [GalleryPost]?
    /// DISCOVER's own corpus (`GetDiscoveryFeed`), in the SERVER's order —
    /// nil until its first page lands. Only when the repository serves one
    /// (`hasDiscovery`); otherwise Discover is `corpus`, as before.
    private var discovery: [GalleryPost]?
    private var discoveryToken: String?
    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload this store — the shared one; a
    /// test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
    /// Whether the repository answered with a discovery corpus of its own.
    private var hasDiscovery = false
    /// The instant this session counts from, frozen the first time a corpus
    /// lands and never moved again. See `ForYouSessionWatermark`.
    private var sessionWatermark: ForYouSessionWatermark?
    private var failure: String?
    /// The corpora on screen are the LAST SESSION's, restored from the device
    /// (#893) and not yet confirmed by the network: a failed first load keeps
    /// them without a word (the offline indicator says why), and a recovery
    /// loads again.
    private var isShowingCachedCorpus = false
    private var nextPageToken: String?
    private var load: Task<Void, Never>?
    private var pageLoad: Task<Void, Never>?
    /// The following timeline's page in flight, apart from Discover's
    /// (`pageLoad`): each corpus pages on its own cursor (#566).
    private var followingPageLoad: Task<Void, Never>?

    /// Where the viewer stands with each author — what splits FRIENDS from
    /// FOLLOWING. Nil (a test, a composition without the graph) leaves every
    /// author in Following and nobody a friend, which is what the surface was
    /// before it had a graph to ask.
    private let followRelations: (any SocialGraphReading)?
    /// Keeps the answers live: a follow or an unfollow ACCEPTED anywhere in
    /// the app lands here (`FollowGraphEvents`, #300).
    private var followSubscription: FollowGraphSubscription?
    /// The app's posts (#896): a post deleted anywhere — the author's
    /// profile — leaves both corpora, and no later page, refresh or restored
    /// corpus brings it back for the session. Nil: only what the server
    /// serves decides.
    private let entities: EntityStore?
    private var entityObservation: EntityObservation?

    public init(
        repository: any ForYouProviding,
        unreadStore: ForYouUnreadStore = ForYouUnreadStore(),
        seenStore: ForYouSeenPostsStore = ForYouSeenPostsStore(),
        followRelations: (any SocialGraphReading)? = nil,
        followEvents: FollowGraphEvents? = nil,
        entities: EntityStore? = nil
    ) {
        self.repository = repository
        self.unreadStore = unreadStore
        self.seenStore = seenStore
        self.followRelations = followRelations
        self.entities = entities
        // Weak: the channel holds the handler, the handler must not hold this.
        followSubscription = followEvents?.subscribeOnMain { [weak self] change in
            self?.apply(change)
        }
        entityObservation = entities?.observePosts { [weak self] change in
            self?.dropDeleted(change)
        }
    }

    public func viewDidLoad() {
        armRecovery()
        restoreCachedCorpus()
        loadFirstPage(reset: false)
    }

    /// Opens on what the last session loaded, before any await, so the first
    /// frame is content rather than skeletons (#893). The first load that
    /// follows revalidates it in place.
    private func restoreCachedCorpus() {
        guard corpus == nil, failure == nil, let cached = repository.cachedPages() else { return }
        // Provisional: every author is asked again with the first load, and
        // the answers take over (`relation(of:)`).
        cachedRelations = cached.relations
        corpus = source.ordering(withoutDeleted(cached.following.posts))
        nextPageToken = cached.following.nextPageToken
        hasDiscovery = cached.discovery != nil
        discovery = cached.discovery.map { Self.unique(withoutDeleted($0.posts)) }
        discoveryToken = cached.discovery?.nextPageToken
        isShowingCachedCorpus = true
        publish()
    }

    /// Reloads after an outage (#793): what failed while the network was gone
    /// comes back on its own when it returns — the viewer no longer has to
    /// find a way to retry, screen by screen.
    private func armRecovery() {
        guard recovery == nil else { return }
        recovery = connectivity.onRecovery { [weak self] in self?.recoverFromOutage() }
    }

    private func recoverFromOutage() {
        // Only a corpus that never arrived, a failure, or the last session's
        // corpus the network has not confirmed yet: `refresh` drops a loaded
        // one.
        guard corpus == nil || failure != nil || isShowingCachedCorpus else { return }
        loadFirstPage(reset: false)
    }

    /// Pull-to-refresh: asks for the first page again and replaces the corpus
    /// with it. What is on screen stays there until the answer lands, and a
    /// failed answer leaves it there (`onRefreshFailed`, #798).
    public func refresh() {
        // A new corpus: the vertical feed's own list starts over (#1343).
        ownFeed.reset()
        rearmMockNewActivity()
        loadFirstPage(reset: true)
    }

    /// A list about to display `id`: its page, fetched ahead, was shown
    /// (#970).
    public func didShow(_ id: PostID) {
        repository.didShow(id)
    }

    /// The ordering modifier: recomputes every surface locally, no round trip.
    public func setSource(_ source: DiscoverySource) {
        guard self.source != source else { return }
        self.source = source
        // The one place the whole corpus legitimately reorders.
        corpus = corpus.map(source.ordering)
        onCorpusReset?()
        publish()
    }

    /// The viewer opened these posts from a friend's story: they are seen, and
    /// the ring clears once the row hears it.
    ///
    /// ⚠️ CALLED AT THE LANDING, not at the tap. The row re-sorts on it (a
    /// friend with nothing unseen joins the ones after), and a close flying
    /// home to an avatar that has just moved would land on another friend's
    /// face — so the host marks them once the close is over.
    public func markStoryPostsSeen(_ ids: [PostID]) {
        guard seenStore.insert(ids) else { return }
        publish()
    }

    /// The viewer opened the Following list — READING it, the way arriving on
    /// the Following tab was. Retires a forced `-foryou-badges` count; the
    /// session's own count does not move (nothing in a session retires it —
    /// `ForYouSessionWatermark`).
    public func followingListOpened() {
        guard corpus != nil else { return }
        unreadStore.markSeen(Self.unreadKey, in: followedCorpus, clearingOverride: true)
        publish()
    }

    /// Takes one author out of the rows they no longer belong to, after an
    /// unfollow succeeds.
    ///
    /// ⚠️ DISCOVER KEEPS THEM: it is everyone, followed or not, and an author
    /// the viewer does not follow is exactly what it is for.
    ///
    /// It is the follow graph's own answer, folded in straight away: the same
    /// change also arrives through `FollowGraphEvents` when the channel is
    /// wired, and folding it twice changes nothing. This path is what serves
    /// a composition without the channel.
    public func removeAuthor(_ authorID: ProfileID) {
        apply(FollowChange(profileID: authorID, isFollowing: false))
    }

    /// A post deleted anywhere leaves Discover and the rows at once — a
    /// re-derivation, so the pages are told first (`onCorpusReset`).
    private func dropDeleted(_ change: EntityChange<PostID>) {
        // `.everything` is a viewer change wiping the viewer's facts: nothing
        // was deleted.
        guard let entities, case .some(let ids) = change else { return }
        let deleted = ids.filter(entities.isDeleted)
        guard !deleted.isEmpty else { return }
        let shown = (corpus ?? []).contains { deleted.contains($0.id) }
            || (discovery ?? []).contains { deleted.contains($0.id) }
        guard shown else { return }
        corpus?.removeAll { deleted.contains($0.id) }
        discovery?.removeAll { deleted.contains($0.id) }
        onCorpusReset?()
        publish()
    }

    /// `posts` without the ones deleted this session (`dropDeleted`): a page
    /// fetched before the delete, or the device's copy of one, still carries
    /// them.
    private func withoutDeleted(_ posts: [GalleryPost]) -> [GalleryPost] {
        guard let entities else { return posts }
        return posts.filter { !entities.isDeleted($0.id) }
    }

    /// Puts an author back in their rows after an unfollow was taken back
    /// (#957, the toast's Undo) and the follow accepted again. The inbound
    /// half was kept by `removeAuthor`, so a friend comes back a friend.
    public func restoreAuthor(_ authorID: ProfileID) {
        apply(FollowChange(profileID: authorID, isFollowing: true))
    }

    // MARK: - Who is who

    /// Where an author sits on this screen.
    nonisolated enum Circle: Equatable, Sendable {
        /// The viewer themself: on Discover, never in a row.
        case viewer
        /// A mutual follow — the stories row.
        case friend
        /// Followed and not a friend — the cards row. Also an author the
        /// graph could not answer for: the rows fail OPEN, which is what
        /// Following did before it had a graph to ask, rather than hiding
        /// posts on a hunch.
        case following
        /// Not followed: Discover only.
        case other

        nonisolated static func of(_ relation: FollowRelation?) -> Circle {
            switch relation {
            case nil: .following
            case .viewer: .viewer
            case .mutual: .friend
            case .following: .following
            case .notFollowing, .followedBy, .blocked, .requested: .other
            }
        }
    }

    /// Where the viewer stands with each author seen so far. Filled by
    /// `resolveRelations` as pages land, kept live by `FollowGraphEvents`.
    private var relations: [ProfileID: FollowRelation] = [:]
    /// The answers the last session stored (#893): what splits a restored
    /// corpus's rows in its first frame, until `relations` answers.
    private var cachedRelations: [ProfileID: FollowRelation] = [:]

    /// The fresh answer, else the last session's.
    private func relation(of author: ProfileID) -> FollowRelation? {
        relations[author] ?? cachedRelations[author]
    }

    /// Whether `author` is someone the viewer follows — what offers
    /// Unfollow on a card. A known answer decides; an unanswered author is
    /// followed only if the FOLLOWING timeline served them. With Discover on
    /// its own pool, an author it ranked is anyone, and an Unfollow on a
    /// stranger would be a lie.
    public func isFollowed(_ author: ProfileID?) -> Bool {
        guard let author else { return false }
        if let known = relation(of: author) {
            return Circle.of(known) == .friend || Circle.of(known) == .following
        }
        guard hasDiscovery else { return true }
        return corpus?.contains { $0.authorID == author } == true
    }

    func circle(of author: ProfileID?) -> Circle {
        guard let author else { return .following }
        return Circle.of(relation(of: author))
    }

    /// A follow or unfollow ACCEPTED anywhere in the app. The author's posts
    /// join or leave the rows (a follow of someone who follows the viewer
    /// makes a FRIEND); Discover, which is everyone, does not move.
    ///
    /// A re-derivation when it changes anything the viewer can see, so the
    /// pages are told first (`onCorpusReset`), exactly as a re-ordering tells
    /// them.
    private func apply(_ change: FollowChange) {
        let previous = relation(of: change.profileID)
        let before = Circle.of(previous)
        // The INBOUND half is kept (`settingFollow`), so following back makes
        // a friend and unfollowing a friend leaves a follower. An author never
        // answered for has no known inbound half: asked again below.
        let updated = (previous ?? .notFollowing).settingFollow(change.isFollowing)
        relations[change.profileID] = updated
        remember([change.profileID: updated])
        if previous == nil, change.isFollowing { reresolve(change.profileID) }
        guard Circle.of(relations[change.profileID]) != before,
              let corpus, corpus.contains(where: { $0.authorID == change.profileID })
        else { return }
        onCorpusReset?()
        publish()
    }

    /// Asks the graph for one author again — for a follow event about someone
    /// never answered for, whose inbound half (friend or not) is unknown.
    private func reresolve(_ id: ProfileID) {
        guard let followRelations else { return }
        Task { [weak self] in
            guard let relation = try? await followRelations.followRelation(to: id),
                  let self, relations[id] != relation else { return }
            let before = circle(of: id)
            relations[id] = relation
            remember([id: relation])
            guard circle(of: id) != before,
                  corpus?.contains(where: { $0.authorID == id }) == true else { return }
            onCorpusReset?()
            publish()
        }
    }

    /// Asks the graph about every author in `posts` it has not answered for
    /// yet, concurrently, BEFORE the page that carries them is published — so
    /// the rows are split from their first frame and a page landing stays an
    /// append rather than a re-derivation a moment later.
    ///
    /// Only answers are stored: a failed lookup leaves the author unanswered
    /// (Following, see `Circle`) and is asked again with the next page. An
    /// answer that arrives after a follow EVENT for the same author never
    /// overwrites it — the event is the newer truth.
    private func resolveRelations(for posts: [GalleryPost]) async {
        guard let followRelations else { return }
        let unknown = Set(posts.compactMap(\.authorID)).filter { relations[$0] == nil }
        guard !unknown.isEmpty else { return }
        let answers = await withTaskGroup(of: (ProfileID, FollowRelation?).self) { group in
            for id in unknown {
                group.addTask { (id, try? await followRelations.followRelation(to: id)) }
            }
            var collected: [(ProfileID, FollowRelation?)] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        var stored: [ProfileID: FollowRelation] = [:]
        for case let (id, relation?) in answers where relations[id] == nil {
            relations[id] = relation
            stored[id] = relation
        }
        remember(stored)
    }

    /// Keeps answers for the next cold start (#893), off the main actor.
    private func remember(_ answers: [ProfileID: FollowRelation]) {
        guard !answers.isEmpty else { return }
        let repository = repository
        Task { await repository.rememberRelations(answers) }
    }

    // MARK: - The corpora

    /// DISCOVER's corpus: every loaded post, every author and kind — the
    /// widest corpus the app has. There is no discovery RPC
    /// (BACKEND_GAPS §14), and the timeline is the whole population this
    /// screen sees; followed and not.
    public var discoverPosts: [GalleryPost] {
        (hasDiscovery ? discovery ?? [] : corpus ?? []).filter(isShown)
    }

    /// The loaded posts of one circle, in display order —
    /// from the FOLLOWING timeline, never from Discover's pool: a followed
    /// author's posts the discovery pool happened to rank are not the rows.
    private func posts(in circle: Circle) -> [GalleryPost] {
        (corpus ?? []).filter { self.circle(of: $0.authorID) == circle && self.isShown($0) }
    }

    /// FOLLOWING's posts: the people the viewer follows who are not friends.
    ///
    /// ⚠️ Split HERE, by the follow graph, because the served timeline is not:
    /// `timeline.v1.GetFollowingFeed` promises no such thing, and the mock
    /// serves every author's posts.
    public var followingPosts: [GalleryPost] { posts(in: .following) }

    /// The vertical feed's own list for a post opened from the "For you"
    /// section or its gallery (#1343): the discovery pool on a cursor of its
    /// own, past everything the grid holds, then the grid's posts (#1511).
    private(set) lazy var ownFeed = ForYouOwnFeed(
        repository: repository,
        isAvailable: { [weak self] in self?.hasDiscovery ?? false },
        // What the vertical feed recorded as viewed (#1344): a post handed
        // out and never viewed comes back first next time (#1511).
        viewedSince: { since in
            Set(PostViewHistoryStore.shared.views
                .filter { ($0.viewedAt ?? .distantPast) >= since }
                .map { PostID($0.postID) })
        }
    ) { [weak self] in
        self?.discoverPosts ?? []
    }

    /// FRIENDS' posts: mutual follows.
    public var friendPosts: [GalleryPost] { posts(in: .friend) }

    /// Both rows' authors — what the session baseline is frozen against and
    /// the persisted cursor advanced over.
    private var followedCorpus: [GalleryPost] {
        (corpus ?? []).filter {
            let circle = circle(of: $0.authorID)
            return circle == .friend || circle == .following
        }
    }

    /// The two corpora that page on their own cursors (#566).
    public enum Corpus: Sendable {
        /// Discover's grid and its "View all": `GetDiscoveryFeed` (the
        /// following timeline when no discovery is wired).
        case discover
        /// The Friends and Following rows and their pushed lists:
        /// `GetFollowingFeed`, always.
        case following
    }

    /// Called as a list nears its end. A no-op when that corpus already has a
    /// page in flight, is exhausted, or has not landed its first page.
    ///
    /// ⚠️ BY CORPUS (#566). One entry point used to page Discover whenever
    /// discovery was wired — always, in the app — so a pushed Following or
    /// Friends list scrolled to its end fetched DISCOVER pages and stayed on
    /// the first twenty following posts forever.
    public func loadNextPageIfNeeded(_ corpus: Corpus) {
        switch corpus {
        case .discover where hasDiscovery:
            loadNextDiscoveryPageIfNeeded()
        case .discover:
            // Without discovery, Discover IS the following timeline.
            loadNextFollowingPageIfNeeded { [weak self] paging in self?.onPagingChange?(paging) }
        case .following:
            loadNextFollowingPageIfNeeded { [weak self] paging in self?.onFollowingPagingChange?(paging) }
        }
    }

    /// The following timeline's next page; `announce` tells the surfaces
    /// paging on it that a load starts (true) and ends (false).
    private func loadNextFollowingPageIfNeeded(announce: @escaping (Bool) -> Void) {
        guard followingPageLoad == nil, load == nil, corpus != nil, let token = nextPageToken else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[foryou-page] fetch after=\(token)")
        }
        #endif
        followingPageLoad = Task { [weak self] in
            guard let self else { return }
            defer {
                self.followingPageLoad = nil
                announce(false)
            }
            guard let page = try? await repository.page(after: token), !Task.isCancelled else { return }
            // The rows are split by the graph from the page's first frame.
            await resolveRelations(for: page.posts)
            guard !Task.isCancelled else { return }
            // Append, never reorder: the new page is ranked among ITSELF and
            // added to the end, so a page landing cannot renumber what is
            // already on screen.
            //
            // Deduplicated against everything already loaded: a re-served row
            // is never trusted into the corpus, whoever serves it. A repeated
            // id is not cosmetic — every id-keyed structure downstream assumes
            // uniqueness, and the first one (the snap feed seeding
            // `Dictionary(uniqueKeysWithValues:)` from a tapped tile's slice)
            // took the whole app down when a duplicate reached it.
            let existing = Set((corpus ?? []).map(\.id))
            let fresh = withoutDeleted(page.posts).filter { !existing.contains($0.id) }
            #if DEBUG
            if fresh.count != page.posts.count,
               ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                let repeated = page.posts.filter { existing.contains($0.id) }.map(\.id.rawValue)
                print("[foryou-page] token=\(token) re-served \(repeated)")
            }
            #endif
            corpus = (corpus ?? []) + source.ordering(fresh)
            nextPageToken = page.nextPageToken
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[foryou-page] appended fresh=\(fresh.count) corpus=\(corpus?.count ?? 0) next=\(page.nextPageToken ?? "nil")")
            }
            #endif
            publish()
            onLoadSettled?()
        }
        // Announced only past the guard, and only AFTER the task is assigned.
        // Showing the footer runs a layout pass, a layout pass can fire
        // `onNearEnd`, and a re-entrant call arriving before the assignment
        // passed the in-flight guard and started a SECOND fetch with the same
        // token — the whole second page appended twice, and the next tile tap
        // trapping on the duplicate id.
        announce(true)
    }

    /// Discover's next page: appended in the server's order, de-duplicated
    /// (the contract warns a post can come back on a later page when it moves
    /// between rankings).
    private func loadNextDiscoveryPageIfNeeded() {
        guard pageLoad == nil, load == nil, discovery != nil, let token = discoveryToken else { return }
        pageLoad = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pageLoad = nil
                self.onPagingChange?(false)
            }
            guard let page = try? await repository.discoveryPage(after: token), !Task.isCancelled else { return }
            let existing = Set((discovery ?? []).map(\.id))
            discovery = (discovery ?? []) + Self.unique(withoutDeleted(page.posts)).filter { !existing.contains($0.id) }
            discoveryToken = page.nextPageToken
            publish()
            onLoadSettled?()
        }
        // After the assignment — see `loadNextPageIfNeeded`.
        onPagingChange?(true)
    }

    /// `posts` with each id once, first occurrence kept.
    nonisolated static func unique(_ posts: [GalleryPost]) -> [GalleryPost] {
        var seen = Set<PostID>()
        return posts.filter { seen.insert($0.id).inserted }
    }

    private func loadFirstPage(reset: Bool) {
        // ⚠️ A REFRESH DURING A LOAD WAITS FOR THAT LOAD (#798). It used to
        // cancel it and then stop at `guard load == nil` below — the cancelled
        // task returns before publishing or settling, and the new one never
        // started — so a pull during the INITIAL load left the page loading
        // for good, with no Try Again and a refresh control that never ended.
        // The load in flight is already the fresh answer the pull asked for,
        // and its settle ends the controls. (Not cancelled and replaced:
        // `load` cannot be nilled here, because the old task's `defer` would
        // then wipe out the new one.)
        if reset, load != nil { return }
        if reset {
            if pageLoad != nil {
                pageLoad?.cancel()
                // A cancelled task's `defer` does not run, so the footer would
                // be left spinning for a fetch that was thrown away.
                onPagingChange?(false)
            }
            pageLoad = nil
            if followingPageLoad != nil {
                followingPageLoad?.cancel()
                // Same as above: a cancelled task's `defer` does not run.
                onFollowingPagingChange?(false)
                onPagingChange?(false)
            }
            followingPageLoad = nil
            followingTopUps = 0
            // ⚠️ The corpus and its cursors are NOT dropped here (#798): what
            // the viewer is looking at stays on screen while the refresh is in
            // flight, and stays there if it fails. Only a page that has
            // nothing (never loaded, or failed) goes back to loading.
            if corpus == nil {
                failure = nil
            }
        }
        guard load == nil else { return }
        // Read once, before the fetch: whether this load replaces content the
        // viewer can see, which decides both how a success lands (a re-derived
        // corpus, not an append) and how a failure is told (a toast, not the
        // failed page).
        let replacesContent = corpus != nil
        if !replacesContent {
            publish() // every surface reports loading
        }
        load = Task { [weak self] in
            guard let self else { return }
            defer { self.load = nil }
            do {
                // Both corpora at once: Discover's (when the repository serves
                // one) and the following timeline the rows are made of.
                async let discoveryPage = repository.discoveryFirstPage()
                async let followingPage = repository.firstPage()
                let discover = try await discoveryPage
                let page: ForYouPage
                if let discover {
                    // The rows' corpus only: its failure — a guest has no
                    // timeline — leaves them empty, not the page failed.
                    page = (try? await followingPage) ?? ForYouPage(posts: [], nextPageToken: nil)
                } else {
                    page = try await followingPage
                }
                guard !Task.isCancelled else { return }
                // What each surface shows now, to tell a revalidation that
                // changed nothing from one that did.
                let shownBefore = replacesContent ? (discoverPosts, followingPosts, friendPosts) : nil
                // Asked before the first publish, so no row ever shows an
                // author it is about to move.
                await resolveRelations(for: page.posts)
                guard !Task.isCancelled else { return }
                corpus = source.ordering(withoutDeleted(page.posts))
                hasDiscovery = discover != nil
                discovery = discover.map { Self.unique(withoutDeleted($0.posts)) }
                discoveryToken = discover?.nextPageToken
                failure = nil
                isShowingCachedCorpus = false
                nextPageToken = page.nextPageToken
                if let shownBefore, shownBefore.0 != discoverPosts
                    || shownBefore.1 != followingPosts || shownBefore.2 != friendPosts {
                    // Content → content with no loading frame between: the
                    // pages would otherwise read a refreshed corpus that
                    // starts with the old posts as an APPEND (`onCorpusReset`).
                    // A revalidation that changed nothing publishes the same
                    // posts, and the pages keep their cells (#893).
                    onCorpusReset?()
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print("[foryou-page] first count=\(page.posts.count) next=\(page.nextPageToken ?? "nil") reset=\(reset)")
                }
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                if replacesContent {
                    // The corpus, its cursors and the published pages are all
                    // still what the viewer sees: nothing to publish, only to
                    // say (#798) — unless it is the last session's, restored
                    // at launch, and nobody pulled: then the offline indicator
                    // is what says why, and a recovery loads again.
                    if reset || !isShowingCachedCorpus { onRefreshFailed?() }
                    onLoadSettled?()
                    return
                }
                // ⚠️ Not "Pull to retry": a failed page has no rows to pull,
                // its way out is the Try Again under this line. And "You're
                // offline" when that is why (#794).
                failure = FailureCopy.message(for: error, fallback: Self.failureMessage)
            }
            publish()
            onLoadSettled?()
        }
    }

    /// One post out of the whole loaded corpus.
    ///
    /// The dismissal's adoption is the caller: a post the viewer is closing has
    /// to be able to land in the list even when the page it is landing in no
    /// longer holds it — a refresh re-derived the corpus while the post was
    /// open. The question is "does this post exist", not "does this page show
    /// it".
    public func post(for id: PostID) -> GalleryPost? {
        discovery?.first { $0.id == id } ?? corpus?.first { $0.id == id }
    }

    // MARK: - Hide This Post (#1498)

    /// Posts hidden this session ("Hide This Post"). Filtered where the
    /// surfaces read their posts, so a page that lands later (a refresh, the
    /// network after the cache) cannot bring one back.
    private var hiddenIDs: Set<PostID> = []

    /// Takes `id` off every surface of this screen for the session — the
    /// menu's "Hide This Post", undone by `unhidePost`. A re-derivation, so
    /// the pages are told first (`onCorpusReset`); the post comes back in its
    /// own place on Undo, since nothing was removed from the corpus.
    public func hidePost(_ id: PostID) {
        guard hiddenIDs.insert(id).inserted else { return }
        onCorpusReset?()
        publish()
    }

    /// The hide's Undo.
    public func unhidePost(_ id: PostID) {
        guard hiddenIDs.remove(id) != nil else { return }
        onCorpusReset?()
        publish()
    }

    /// Whether `id` is hidden this session. Tests.
    func isHidden(_ id: PostID) -> Bool { hiddenIDs.contains(id) }

    // MARK: - Muted and blocked authors (#1498 §3)

    /// Authors muted or blocked from a post's menu this session: their posts
    /// leave every surface at once, before the next page (which the server
    /// filters) could say so.
    private var hiddenAuthors: Set<ProfileID> = []

    /// Takes every post by `authorID` off this screen — the menu's Mute and
    /// Block. Undone by `showAuthor` (Mute's Undo).
    public func hideAuthor(_ authorID: ProfileID) {
        guard hiddenAuthors.insert(authorID).inserted else { return }
        onCorpusReset?()
        publish()
    }

    /// Mute's Undo.
    public func showAuthor(_ authorID: ProfileID) {
        guard hiddenAuthors.remove(authorID) != nil else { return }
        onCorpusReset?()
        publish()
    }

    /// Whether a post survives Hide This Post, Mute and Block.
    private func isShown(_ post: GalleryPost) -> Bool {
        guard !hiddenIDs.contains(post.id) else { return false }
        guard let author = post.authorID else { return true }
        return !hiddenAuthors.contains(author)
    }

    // MARK: - Publishing

    private func publish() {
        func state(_ posts: [GalleryPost], empty: EmptyState) -> PageState {
            if let failure { return .failed(message: failure) }
            guard corpus != nil else { return .loading }
            return posts.isEmpty ? .empty(empty) : .content(posts)
        }
        applyMockNewActivityIfNeeded()
        var snapshot = Snapshot()
        snapshot.discover = state(
            discoverPosts, empty: Self.discoverEmptyState(source: source)
        )
        snapshot.media = state(
            GalleryFilter.Format.media.filtering(discoverPosts),
            empty: Self.discoverEmptyState(source: source)
        )
        let following = followingPosts
        let friends = friendPosts
        snapshot.following = state(
            following, empty: Self.emptyState(for: .following)
        )
        snapshot.friends = state(
            friends, empty: Self.emptyState(for: .friend)
        )
        if corpus != nil {
            // The session baseline is frozen here, BEFORE the visit advances
            // the persisted cursor below — that ordering is the whole
            // mechanism (`ForYouSessionWatermark`).
            let watermark = sessionWatermark(against: followedCorpus)
            let followingNew = watermark.map { mark in following.filter(mark.isNew) } ?? []
            let friendsUnseen = watermark.map { mark in
                friends.filter { mark.isNew($0) && !seenStore.contains($0.id) }
            } ?? []
            snapshot.followingNew = Set(followingNew.map(\.id))
            snapshot.friendsUnseen = Set(friendsUnseen.map(\.id))
            snapshot.rails = Self.rails(
                following: following, followingNew: snapshot.followingNew,
                friends: friends, friendsUnseen: snapshot.friendsUnseen,
                limit: Self.railLimit, rowLimit: PostShelfSection.rowLimit
            )
            // A page still to load may hold more of them.
            if hasDiscovery, nextPageToken != nil { snapshot.rails.followingHasMore = true }
            // On the next turn: the first page publishes from inside its own
            // load, which is only over once this returns.
            let cards = snapshot.rails.following
            Task { [weak self] in self?.topUpFollowingIfShort(cards) }
            // A forced count is `-foryou-badges` only, and overrides the
            // derivation for the BADGE alone — see `forcedCount`.
            snapshot.rails.followingBadge = unreadStore.forcedCount(for: Self.unreadKey)
                ?? followingNew.count
            snapshot.rails.friendsBadge = friendsUnseen.count
            // The rows are ON this screen: whatever is loaded has been in
            // front of the viewer, so the NEXT session counts from here.
            unreadStore.markSeen(Self.unreadKey, in: followedCorpus)
        }
        onSnapshotChange?(snapshot)
        if corpus != nil {
            // The tab's unread signal: the two headers' numbers, as they read.
            onNewCountChange?(snapshot.rails.followingBadge + snapshot.rails.friendsBadge)
        }
        #if DEBUG
        debugLogCircles()
        #endif
    }

    /// The two rows, from the two corpora and what is new on each.
    ///
    /// Pure and static so a test can pin the ordering rules rather than a
    /// screenshot: unseen first on both rows; within each half the newest
    /// first; a friend opens onto their unseen posts, or their recent ones.
    ///
    /// The Following rows take up to `rowLimit` cards EACH (the owner,
    /// 2026-10-17): ten photos and videos, ten texts — not twenty between
    /// them, which a run of media posts used to spend on one row.
    nonisolated static func rails(
        following: [GalleryPost], followingNew: Set<PostID>,
        friends: [GalleryPost], friendsUnseen: Set<PostID>,
        limit: Int, rowLimit: Int
    ) -> Rails {
        func newestFirst(_ posts: [GalleryPost]) -> [GalleryPost] {
            posts.sorted { $0.publishedAtMS > $1.publishedAtMS }
        }
        var rails = Rails()
        let unseenCards = newestFirst(following.filter { followingNew.contains($0.id) })
        let seenCards = newestFirst(following.filter { !followingNew.contains($0.id) })
        // Each row its own share, in the rows' order; the kind is the rows'
        // own rule (`PostShelfRows.Row`: words alone are the text row).
        var media = 0
        var text = 0
        rails.following = (unseenCards + seenCards).filter { post in
            if post.kind == .text {
                text += 1
                return text <= rowLimit
            }
            media += 1
            return media <= rowLimit
        }
        rails.followingHasMore = text > rowLimit || media > rowLimit

        var byAuthor: [ProfileID: [GalleryPost]] = [:]
        var order: [ProfileID] = []
        for post in friends {
            guard let author = post.authorID else { continue }
            if byAuthor[author] == nil { order.append(author) }
            byAuthor[author, default: []].append(post)
        }
        let stories: [FriendStory] = order.compactMap { author in
            guard let posts = byAuthor[author], let face = posts.first else { return nil }
            let unseen = newestFirst(posts.filter { friendsUnseen.contains($0.id) })
            return FriendStory(
                authorID: author,
                name: face.authorName ?? face.authorHandle ?? author.rawValue,
                handle: face.authorHandle ?? "",
                avatarURL: posts.lazy.compactMap(\.authorAvatarURL).first,
                posts: Array((unseen.isEmpty ? newestFirst(posts) : unseen).prefix(limit)),
                hasUnseen: !unseen.isEmpty
            )
        }
        // Unseen first, and within each half the friend whose newest post is
        // newest first — the order a viewer catches up in.
        rails.friends = stories.sorted { lhs, rhs in
            if lhs.hasUnseen != rhs.hasUnseen { return lhs.hasUnseen }
            return (lhs.posts.first?.publishedAtMS ?? 0) > (rhs.posts.first?.publishedAtMS ?? 0)
        }
        return rails
    }

    #if DEBUG
    /// `-foryou-following-log`: one line per publish in
    /// `Documents/foryou-following.log` — how many posts each row's corpus
    /// holds, and which authors are friends. A file, because the question
    /// ("did the follow I just made reach this row?") is asked of a long list
    /// no screenshot can count, and a console capture is the thing that fails
    /// quietly (see `sim-log-capture-traps`).
    private func debugLogCircles() {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-following-log"),
              let corpus,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let authors = Set(corpus.compactMap(\.authorID))
        let friends = authors.filter { circle(of: $0) == .friend }
        let others = authors.filter { circle(of: $0) == .other }
        let line = "friends=\(friendPosts.count) following=\(followingPosts.count)"
            + " discover=\(corpus.count) answered=\(relations.count)"
            + " friendAuthors=\(friends.map(\.rawValue).sorted().joined(separator: ","))"
            + " notFollowed=\(others.map(\.rawValue).sorted().joined(separator: ","))\n"
        let url = documents.appendingPathComponent("foryou-following.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    #endif

    /// What the rows count against this session, frozen on first sight.
    ///
    /// Taken from the persisted cursor BEFORE this visit advances it — see
    /// `ForYouSessionWatermark`.
    private func sessionWatermark(against posts: [GalleryPost]) -> ForYouSessionWatermark? {
        if let sessionWatermark { return sessionWatermark }
        guard let baseline = unreadStore.sessionBaseline(for: Self.unreadKey, in: posts) else { return nil }
        let watermark = ForYouSessionWatermark(baselineMS: baseline)
        sessionWatermark = watermark
        return watermark
    }

    #if DEBUG
    /// `-foryou-mock-new-activity [n]` (n defaults to 3): back-dates the
    /// baseline so the n newest posts of the people the viewer follows read as
    /// new — on either row, wherever their authors sit.
    ///
    /// Armed once per LOAD, not once per publish — every page that lands would
    /// otherwise re-back-date and the badges would never settle. A pull
    /// re-arms it, which is the point: pull, and three new things are waiting.
    private var hasArmedMockActivity = false

    private func applyMockNewActivityIfNeeded() {
        guard !hasArmedMockActivity, corpus != nil, sessionWatermark == nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-mock-new-activity") else { return }
        let count = position + 1 < arguments.count ? Int(arguments[position + 1]) ?? 3 : 3
        hasArmedMockActivity = true
        unreadStore.stageUnread(count, for: Self.unreadKey, in: followedCorpus)
    }

    /// Re-arms the mock so a pull produces fresh badges — and re-freezes the
    /// baseline, which is what the staging moves.
    private func rearmMockNewActivity() {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-mock-new-activity") else { return }
        hasArmedMockActivity = false
        sessionWatermark = nil
    }
    #else
    private func applyMockNewActivityIfNeeded() {}
    private func rearmMockNewActivity() {}
    #endif

    /// Discover's empty list, in Discover's words — nothing to DISCOVER, not
    /// "no activity": the list is not anyone's activity.
    nonisolated static func discoverEmptyState(source: DiscoverySource) -> EmptyState {
        let title = switch source {
        case .trending: "Nothing trending to discover yet."
        case .recent: "Nothing new to discover yet."
        }
        return EmptyState(title: title)
    }

    /// A pushed list's empty page, named so the blank page reads as an answer.
    nonisolated static func emptyState(for circle: Circle) -> EmptyState {
        let title = circle == .friend
            ? "No posts from your friends yet."
            : "No posts from people you follow yet."
        return EmptyState(title: title)
    }
}
