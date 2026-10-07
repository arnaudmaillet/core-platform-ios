import CoreContracts
import CoreModels
import DesignSystem
import FeedInterface
import MediaPlayback
import PostGrid
import MediaCore
import UIKit

/// A `ForYouGridPage` over an arbitrary set of post ids, vended across the
/// feature seam.
///
/// # Why this is thin
///
/// Everything it does already existed. `ForYouGridPage` is the component both
/// For You tabs are — one type, two styles — and `PlaceProfileViewController`
/// already drives it over a fixed id set with `render(.content(posts))` and no
/// `ForYouViewModel` anywhere. The hydration is the same one the place profile
/// runs: a fixed-set provider through `ForYouRepository`, then one batched
/// counter read, so every member is a cache hit against what the feed already
/// holds.
///
/// ⚠️ IT PLAYS, AND IT DID NOT. `ForYouGridPage` takes an optional
/// `VideoPlaybackController`, and this passed `nil` on the argument that the
/// player pool is app-wide, that its budget is the tightest thing the hero
/// suite measures, and that one tab of a pushed screen is not where the
/// remaining loans belong.
///
/// That was the wrong trade to make quietly. These pages ARE For You's tabs:
/// a viewer scrolling search results reads the same rows they read on the feed,
/// and clips that stay frozen there make the surface look broken rather than
/// frugal. The pool is handed over now, and the page's own autoplay reconcile —
/// the same one For You runs, with the same fling gate and the same visibility
/// rules — decides what plays.
///
/// ⚠️ WHAT THIS COSTS IS REAL AND IS NOT PAID HERE. The pool is shared, and
/// `HeroSoak`'s `players<=6` is already red on develop for reasons that predate
/// this screen (the profile gallery holds loans for a tab nobody opened). Two
/// more grids that can borrow makes a tight budget tighter. The honest position
/// is that the surface should behave like the feed and the pool accounting is a
/// separate, already-open problem — not that this screen should be the one to
/// go without.
@MainActor
final class PostSetSurfaceViewController: UIViewController, PostSetSurface {
    var viewController: UIViewController { self }

    private let page: ForYouGridPage
    private let style: PostSetSurfaceStyle
    private let hydrate: ([PostID]) async -> [GalleryPost]

    // MARK: Discover (#629)

    /// `.discover`'s leading header: For You's own rows view, with only its
    /// card row ("Following" there, the caller's title here) and the list's
    /// title under it. Nil for the other styles.
    private var rails: ForYouRailsView?
    /// The lead row's ids, so an identical re-show is not a re-fetch.
    private var leadIDs: [PostID] = []
    private var leadTask: Task<Void, Never>?
    /// See `PostSetSurface.onLeadRowTitleTapped`.
    var onLeadRowTitleTapped: (() -> Void)?
    /// The media gallery "View all" pushes — For You's own, made by the
    /// builder, which holds what its header needs.
    var makeGallery: (() -> DiscoverGalleryViewController)?
    /// The gallery while it is up, so later pages reach it.
    private weak var gallery: DiscoverGalleryViewController?
    private var loadTask: Task<Void, Never>?
    /// The ids currently on screen, so an identical re-show is not a re-fetch.
    private var shownIDs: [PostID] = []
    /// The posts hydrated for `shownIDs`, in their order — what a next page
    /// is appended to (#579).
    private var shownPosts: [GalleryPost] = []

    /// See `PostSetSurface.onNearEnd`.
    var onNearEnd: (() -> Void)?

    /// See `PostSetSurface.setHasMore` — whether the caller has another page.
    private(set) var hasMore = false
    /// The answer to a feed opened from one of these tiles (#638).
    private lazy var feedContinuation = GridFeedContinuation(
        ids: { [weak self] in self?.shownIDs ?? [] },
        hasMore: { [weak self] in self?.hasMore ?? false },
        askMore: { [weak self] in self?.onNearEnd?() }
    )

    /// Opens a post WITH a flight. Supplied by the builder, which owns the
    /// snap feed and the transition — the same closure the place profile is
    /// handed, and for the same reason: this file describes a departure, and
    /// something else knows how to fly from one.
    var openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?

    /// How many posts follow the tapped one into the feed. The place profile's
    /// number, because this is the same kind of doorway: enough to page
    /// through without a fetch, not so many that the seed costs more than the
    /// open saves.
    private static let seedWindow = 12

    init(
        style: PostSetSurfaceStyle,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        hydrate: @escaping ([PostID]) async -> [GalleryPost]
    ) {
        page = ForYouGridPage(
            imagePipeline: imagePipeline,
            style: Self.pageStyle(for: style),
            videoPlayback: videoPlayback
        )
        self.style = style
        self.hydrate = hydrate
        if style == .discover {
            rails = ForYouRailsView(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The page each surface style is. Pure, for tests.
    nonisolated static func pageStyle(for style: PostSetSurfaceStyle) -> ForYouGridPage.Style {
        switch style {
        case .cards: .list
        case .gallery: .grid
        case .discover: .discover
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        page.onItemTapped = { [weak self] index in self?.openTile(at: index) }
        page.onNearEnd = { [weak self] in self?.onNearEnd?() }
        if style == .discover { wireDiscover() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The rows' height depends on the WIDTH (a card is a fraction of it).
        updateLeadHeight()
    }

    // MARK: - Discover (#629)

    /// For You's coupling of its rows and its list, verbatim in shape
    /// (`ForYouViewController.viewDidLoad`): the header's taps, the cards'
    /// flights, and ONE player budget the two share — the list leaves the
    /// players the row has claimed (`ForYouGridPage.playerReserve`).
    private func wireDiscover() {
        guard let rails else { return }
        rails.visibleBand = { [weak self] in self?.visibleBand() }
        rails.onHeightChange = { [weak self] in self?.updateLeadHeight() }
        rails.onCardTapped = { [weak self] index in self?.openCard(at: index) }
        rails.onFollowingHeaderTapped = { [weak self] in self?.onLeadRowTitleTapped?() }
        rails.onListHeaderTapped = { [weak self] in self?.pushGallery() }
        page.onViewAllTapped = { [weak self] in self?.pushGallery() }
        page.onAutoplayReconcile = { [weak self] allowingStarts in
            self?.rails?.updateAutoplay(allowingStarts: allowingStarts, notifiesClaimChange: false)
        }
        page.playerReserve = { [weak self] in self?.rails?.claimedPlayers ?? 0 }
        rails.onPlayerClaimChange = { [weak self] in self?.page.updateAutoplay() }
    }

    func setSectionTitles(row: String, list: String) {
        rails?.followingTitle = row
        rails?.listTitle = list
    }

    func showLeadRow(_ state: PostSetSurfaceState) {
        loadViewIfNeeded()
        guard let rails else { return }
        guard case .posts(let ids) = state, !ids.isEmpty else {
            leadIDs = []
            leadTask?.cancel()
            rails.render(ForYouViewModel.Rails())
            updateLeadHeight()
            return
        }
        guard ids != leadIDs else { return }
        leadIDs = ids
        leadTask?.cancel()
        leadTask = Task { [weak self] in
            guard let self else { return }
            let posts = await self.hydrate(ids)
            guard !Task.isCancelled, self.leadIDs == ids else { return }
            let byID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var row = ForYouViewModel.Rails()
            row.following = ids.compactMap { byID[$0] }
            self.rails?.render(row)
            self.updateLeadHeight()
        }
    }

    #if DEBUG
    /// The lead row's posts as drawn, for tests.
    var debugLeadRowIDs: [PostID] { rails?.cards.map(\.id) ?? [] }
    /// Whether this surface has a lead header at all (`.discover` only).
    var debugHasLeadHeader: Bool { rails != nil }
    #endif

    /// Sizes the list's leading header to the rows it holds.
    private func updateLeadHeight() {
        guard let rails else { return }
        let width = page.bounds.width
        guard width > 0 else { return }
        page.setLead(rails, height: rails.preferredHeight(forWidth: width))
    }

    /// The part of the screen the viewer can see, in the rows' space — what a
    /// row's card must be half inside to play.
    private func visibleBand() -> CGRect? {
        guard let rails, rails.window != nil, view.window != nil else { return nil }
        let band = view.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 0, bottom: view.safeAreaInsets.bottom, right: 0
        ))
        return rails.convert(band, from: view)
    }

    /// A lead-row card opens the way For You's Following cards do
    /// (`ForYouViewController.openCard`, `ForYouRowOrigins.card`).
    private func openCard(at index: Int) {
        guard let rails, let openPost else { return }
        let cards = rails.cards
        guard cards.indices.contains(index),
              navigationController.map({ FeedFeatureBuilder.canOpen(from: self, on: $0) }) ?? true
        else { return }
        let tapped = cards[index]
        let stream = Array(cards[index...].prefix(Self.seedWindow))
        // The card's player is the flight's from here; the list stops.
        rails.beginPlaybackHandoff(of: tapped.id)
        page.setAutoplayActive(false)
        let origin = ForYouRowOrigins.card(tapped, stream: stream, rails: rails, page: page, host: view)
        openPost(self, origin, stream.map(\.id))
    }

    /// "View all": For You's media gallery over this page's media posts, fed
    /// the next pages as they land (#629).
    private func pushGallery() {
        guard let makeGallery, let navigationController,
              navigationController.transitionCoordinator == nil,
              FeedFeatureBuilder.canOpen(from: self, on: navigationController)
        else { return }
        let gallery = makeGallery()
        gallery.onNearEnd = { [weak self] in self?.onNearEnd?() }
        gallery.hasMore = { [weak self] in self?.hasMore ?? false }
        gallery.render(.content(GalleryFilter.Format.media.filtering(shownPosts)))
        self.gallery = gallery
        navigationController.pushViewController(gallery, animated: true)
    }

    /// Renders the list — telling a discover page first whether the set is
    /// whole, which is what lets its last mosaic slice be placed: an
    /// undecided slice holds back everything after it (`MosaicChunkPlanner`).
    private func renderContent() {
        if style == .discover { page.setCorpusComplete(!hasMore) }
        page.render(.content(shownPosts))
        gallery?.render(.content(GalleryFilter.Format.media.filtering(shownPosts)))
    }

    func setPaging(_ paging: Bool) {
        loadViewIfNeeded()
        page.setPaging(paging)
        gallery?.setPaging(paging)
        // A page that ended without growing the list (a failure) is an
        // answer too: the waiting feed hears it and asks again later.
        if !paging { feedContinuation.answered() }
    }

    func setHasMore(_ hasMore: Bool) {
        let changed = hasMore != self.hasMore
        self.hasMore = hasMore
        if !hasMore { feedContinuation.answered() }
        // A discover page told its set is whole places the slice it held back
        // — once every post shown is in. ⚠️ NOT WHILE A PAGE IS STILL BEING
        // HYDRATED: the caller says "no more" in the same turn it hands over
        // the last page's ids, and re-rendering then marked the set whole with
        // the previous page's posts, placed the tail slice early, and the
        // landed page re-planned the list — a reload that jumped the scroll
        // ~490pt under the viewer. The append renders with this answer itself.
        if changed, style == .discover, !shownPosts.isEmpty, shownPosts.count == shownIDs.count {
            renderContent()
        }
    }

    /// The ids after `id` in this surface's order, for a full-screen feed
    /// opened from it (#638) — see `GridFeedContinuation`.
    func postIDs(after id: PostID) async -> [PostID]? {
        await feedContinuation.postIDs(after: id)
    }

    /// The departure, described for the flight machinery.
    ///
    /// ⚠️ THIS IS `PlaceProfileViewController.openTile` WITH THE PLACE TAKEN
    /// OUT, deliberately and almost line for line. That screen is the other
    /// host of these two pages over a fixed set of posts, and every awkward
    /// answer in here was measured there: the card's style is ASKED of the page
    /// rather than assumed to be a tile (a list row's cover is a wide row, not
    /// a square), and the card takes off PLAYING by joining the row's own
    /// surface, because a row under the finger that tapped it is already a
    /// moving picture and carrying the still turns it into a photograph for the
    /// length of the opening.
    ///
    /// ⚠️ THE HANDOFF OPENS BEFORE THE FLIGHT, not after. It stops the page's
    /// own reconcile from starting or stopping the tapped post's player while
    /// that player is in the air — the grid is about to be covered, and its
    /// slots are what the feed needs.
    ///
    /// What is deliberately NOT copied is the place profile's text-post window
    /// and its `tileDeparture` bookkeeping. The window is a caption growing
    /// into a page; it would transfer, since these are the same rows, but it is
    /// a second flight family and this change is about the first one arriving
    /// at all. A text row keeps the plain push here — the honest floor, and
    /// written down so it reads as a choice rather than an omission.
    private func openTile(at index: Int) {
        let posts = page.posts
        // One opening at a time — checked BEFORE the handoff begins, which a
        // refused second tap would otherwise leave open on another tile.
        guard posts.indices.contains(index), let openPost,
              navigationController.map({ FeedFeatureBuilder.canOpen(from: self, on: $0) }) ?? true
        else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = page.hero(for: tapped.id, in: view)
        let appearance = page.heroAppearance(for: tapped.id)

        page.beginPlaybackHandoff(of: tapped.id)

        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: appearance?.style == .listMedia ? .listMedia : .tile,
            frame: { [weak page] space in page?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak page] in page?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak page] concealed in
                page?.setHeroHidden(concealed, for: tapped.id)
            },
            donateLiveMedia: { [weak page] in page?.liveFlightSurface(for: tapped.id) },
            opensComments: false,
            depthView: { [weak page] in page },
            textReveal: nil,
            // On past the window into what this surface holds, then into the
            // caller's next page (#638).
            continuation: { [weak self] after in await self?.postIDs(after: after) }
        )
        openPost(self, origin, stream.map(\.id))
    }

    #if DEBUG
    /// `-search-open-post <index>` taps a tile, which is the only way to reach
    /// the flight offline — the simulator injects no touches. It goes through
    /// `openTile` rather than the opener directly, because everything worth
    /// checking (the handoff, the hero rect, the card's style) is decided in
    /// there.
    private func openTileForQAIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-search-open-post"),
              position + 1 < arguments.count,
              let index = Int(arguments[position + 1]),
              !didOpenForQA
        else { return }
        didOpenForQA = true
        // ⚠️ WAITS FOR THE POSTS, not for 2s. `.posts` arrives with ids only;
        // the page is filled by the hydration below, and on a cold run that
        // took longer than the delay: `openTile` found no posts and returned
        // without a word, and the once-flag was already spent, so nothing ever
        // retried. The 2s stays as the floor (the tab's own settle); past it
        // the tap waits for the tile to exist and says so if it never does.
        let label = "-search-open-post \(index)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            QAWait.until(label, { [weak self] in
                guard let self else { return false }
                return self.page.posts.indices.contains(index) && self.openPost != nil
            }) { [weak self] in
                guard let self else { return }
                print("[qa] \(label): opening \(self.page.posts[index].id) of \(self.page.posts.count)")
                self.openTile(at: index)
            }
        }
    }

    /// ⚠️ ONCE. `show` is called on every republication and BOTH post tabs get
    /// it, so an unguarded hook would stage a flight per call and per tab.
    /// Set when the hook ARMS: the wait above then covers a slow hydration
    /// (and gives up out loud), so a republication never stacks a second tap.
    private var didOpenForQA = false
    #endif

    /// ⚠️ THE PAGE PLAYS NOTHING UNTIL IT IS TOLD IT IS VISIBLE, and handing it
    /// the pool is not that. `ForYouGridPage` gates its whole autoplay
    /// reconcile behind `setAutoplayActive` — measured before this existed: the
    /// grids had the pool, sat on screen, and every clip was a still, because
    /// nothing had ever said they were being looked at. For You drives the same
    /// call from its own appearance and from its pager's settle, and only for
    /// the page at the active index.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        closeOpeningRoundTrip()
    }

    func setPlaybackActive(_ active: Bool) {
        loadViewIfNeeded()
        isPlaybackActive = active
        // Not while a push or pop is still running: the handoff belongs to the
        // flight until it lands, and appearance closes it then.
        if active, navigationController?.transitionCoordinator == nil { closeOpeningRoundTrip() }
        page.setAutoplayActive(active)
        rails?.setAutoplayActive(active)
    }

    /// ⚠️ THE HANDOFF A TAP OPENED ENDS WHEN THIS SCREEN IS BACK, the sweep
    /// Discover and the post list make in `viewDidAppear`. This screen began
    /// one on every open and never ended it: the tapped post stayed out of the
    /// grid's ranking and out of its stop loop, so it kept its player frozen
    /// on the frame the feed paused and never autoplayed again. Idempotent,
    /// and asked from both doors back (appearance, and the host saying this
    /// grid is the visible one again), because either can come first.
    private func closeOpeningRoundTrip() {
        page.clearRevealConcealment()
        page.clearHeroConcealment()
        page.endPlaybackHandoff()
        // The rows' card too — active first, then the handoff closed, for the
        // reason `ForYouViewController.viewDidAppear` gives.
        guard let rails else { return }
        rails.clearConcealments()
        if isPlaybackActive {
            page.setAutoplayActive(true)
            rails.setAutoplayActive(true)
        }
        rails.endPlaybackHandoff()
    }

    /// ⚠️ REMEMBERED, BECAUSE VISIBILITY ARRIVES BEFORE THE CONTENT DOES.
    /// The screen appears, says "you are the visible tab", and at that moment
    /// this page has no posts — the answer is still being hydrated. Measured:
    ///
    ///     [autoplay-probe] active=true posts=0 videos=0
    ///
    /// `setAutoplayActive(true)` on an empty page reconciles nothing and is
    /// never asked again, so every clip stayed a still on a screen that had
    /// been told twice over that it was visible. The flag is kept and
    /// re-asserted the moment there is something to reconcile.
    private var isPlaybackActive = false

    func show(_ state: PostSetSurfaceState) {
        loadViewIfNeeded()
        // Whatever the answer, a feed waiting on the next page hears it — it
        // re-reads `shownIDs`, which is set below before it gets to run.
        defer { feedContinuation.answered() }
        switch state {
        case .loading:
            shownIDs = []
            shownPosts = []
            page.render(.loading)

        case .posts(let ids):
            #if DEBUG
            openTileForQAIfRequested()
            #endif
            // ⚠️ AN IDENTICAL SET IS NOT A RELOAD. Both post tabs are shown the
            // same answer, and the screen re-publishes whenever anything about
            // it changes — without this, one search would hydrate the same ids
            // four times over.
            guard ids != shownIDs else { return }
            // A list that EXTENDS the one shown is the caller's next page
            // (#579): only the new posts are hydrated, and they are appended
            // — no skeleton, nothing already on screen moves.
            if !shownIDs.isEmpty, ids.count > shownIDs.count, ids.starts(with: shownIDs) {
                append(Array(ids.dropFirst(shownIDs.count)), completing: ids)
                return
            }
            shownIDs = ids
            shownPosts = []
            guard !ids.isEmpty else {
                page.render(.content([]))
                return
            }
            page.render(.loading)
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                let posts = await self.hydrate(ids)
                guard !Task.isCancelled, self.shownIDs.starts(with: ids) else { return }
                // ⚠️ RE-ORDERED BACK INTO THE ANSWER'S ORDER. The hydration
                // reads a timeline, which returns what it returns; the ranking
                // the viewer picked lives in the id list, and handing the page
                // the provider's order would quietly replace their sort.
                let byID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.shownPosts = ids.compactMap { byID[$0] }
                self.renderContent()
                // ⚠️ RE-ASSERTED AFTER THE RENDER. See `isPlaybackActive`.
                // ⚠️ AFTER A LAYOUT PASS, not just after the snapshot. The
                // page's autoplay reconcile asks the collection view which
                // cells are VISIBLE, and a snapshot applied this turn has none
                // until the next pass. Measured, straight after the apply:
                //
                //     straightAfterSnapshot visible=0
                //     afterLayoutIfNeeded   visible=2
                //
                // So `setAutoplayActive(true)` here would walk an empty list
                // over a page holding 71 posts, 23 of them video. The layout
                // and the hop are what turn a correct call into an effective
                // one.
                guard self.isPlaybackActive else { return }
                self.page.layoutIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isPlaybackActive else { return }
                    self.page.setAutoplayActive(true)
                }
            }

        case .empty(let message):
            shownIDs = []
            shownPosts = []
            loadTask?.cancel()
            page.render(.content([]))
            _ = message

        case .failed(let message):
            shownIDs = []
            shownPosts = []
            loadTask?.cancel()
            page.render(.failed(message: message))
        }
    }

    /// Hydrates `added` and appends it to what is shown, after whatever load
    /// is still running — so pages land in order, each on the last.
    private func append(_ added: [PostID], completing ids: [PostID]) {
        shownIDs = ids
        let previous = loadTask
        loadTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let posts = await self.hydrate(added)
            // Still this list, or one that extends it further.
            guard !Task.isCancelled, self.shownIDs.starts(with: ids) else { return }
            let byID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let known = Set(self.shownPosts.map(\.id))
            self.shownPosts += added.compactMap { known.contains($0) ? nil : byID[$0] }
            self.renderContent()
        }
    }
}
