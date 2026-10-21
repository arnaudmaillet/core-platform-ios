import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import EntityStore
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The For You tab root: ONE page (2026-09-29) — Discover's list, led by two
/// rows, with a tap anywhere opening the full-screen feed.
///
/// ```
///   [bell]                              [coins][search]
///     Friends 3 ›                                ← stories: a tap flies
///   ◉ ◉ ◉ ○ ○ ○                                            that friend's posts
///     Following 5 ›                              ← cards: a tap flies
///   ┌────┐ ┌────┐ ┌──                                      the row's posts
///   └────┘ └────┘ └──
///   ── Discover: cards, with mosaic chunks and "View all" ──
/// ```
///
/// **No tabs any more.** The screen used to page between Discover and
/// Following under a tab capsule; Following is now a ROW (the people the
/// viewer follows who are not friends, as cards) whose header pushes the
/// whole list, and the viewer's friends have a row of their own, as stories,
/// whose header pushes theirs. The rows are the list's leading header
/// (`FriendsStoriesRow` and `PostShelfSection` in a `GridLeadStack`, hosted by
/// `ForYouGridPage.setLead`), so they scroll
/// with it and none of the list's index arithmetic moves.
///
/// **Three ways into the snap feed, two flights.** A list post flies with this
/// screen's own machinery (`openFeed`: the hero out of the card or tile, the
/// text window, the card close riding along). A story and a card fly through
/// the builder's shared flight (`presentSnapFeedHero`) — the one the pushed
/// lists, the place page and the search results use — because a row's source
/// is a disc or a card in a horizontal scroller, not a cell of the page this
/// screen's machinery is keyed to. The close lands where the flight left: on
/// the friend's face, on the card.
///
/// **The bar reads `[bell] … [coins][search]`.** The bell and the balance are
/// the shell's (`HeaderAccessoryHosting`); search is this screen's, through
/// `AppRoute.search`. The content contexts that stood beside the bell (a lens
/// menu: For You / Entertainment / Work / Focus / Gaming) are gone (#1423, the
/// owner 2026-10-19): For You always shows everything.
///
/// ⚠️ **`DiscoverySource` (Trending / Recent) has no UI entry point any more.**
/// The ordering still applies — everything is served under `.trending` — but
/// nothing on screen can change it; it is reachable from a debug argument
/// only.
///
/// This is a **tab root**, so the tab bar stays — it is how the viewer leaves.
/// The screens it pushes hide it (`hidesBottomBarWhenPushed`) and wear
/// `[‹] ———— [points][search]` (`PushedScreenHeader`).
final class ForYouViewController: UIViewController, HeaderAccessoryHosting {
    private let viewModel: ForYouViewModel
    /// Discover's list — the whole screen, below the rows.
    ///
    /// Internal (not private) only for the +QA hooks.
    let page: ForYouGridPage
    /// The Friends row and the shelf of the people the viewer follows,
    /// leading the list (#1271): `lead` stacks them over "For you".
    ///
    /// Internal (not private) only for the +QA hooks.
    let friendsRow: FriendsStoriesRow
    let shelf: PostShelfSection
    let lead: GridLeadStack
    /// The cards' stakes — see `PostCardStaking`.
    private let staking: PostCardStaking?
    /// The feed over a window of posts and, with a continuation, past it.
    private let makeSnapFeed: ([PostID], SnapFeedContinuation?) -> UIViewController
    /// The builder's shared flight (`presentSnapFeedHero`): the rows' opens,
    /// and the pushed screens' — Discover's whole mosaic and the two lists.
    /// See `DiscoverGalleryViewController` for why they do not borrow
    /// `openFeed`.
    private let openPostHero: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?
    /// Kept for the pushed screens' own pages, which draw with the same
    /// pipeline and play from the same pool as this one.
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    /// Discover's whole mosaic while it is on the stack — fed every snapshot,
    /// the paging spinner and the refresh from here. Weak: the stack owns it.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) weak var discoverGallery: DiscoverGalleryViewController?
    /// The two rows' whole lists, while they are on the stack — fed the same
    /// way. Weak: the stack owns them.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) weak var followingList: ForYouPostListViewController?
    /// Internal (not private) only for the +QA hooks.
    private(set) weak var friendsList: ForYouPostListViewController?
    /// The last snapshot rendered, so a screen pushed between two publishes
    /// opens on what is loaded rather than on a skeleton.
    private var lastSnapshot: ForYouViewModel.Snapshot?
    private let prewarm: ([PostID]) async -> Void
    /// Loads a post's first page of comments into the panel's synchronous
    /// cache. Optional so the other entry points need not supply one.
    private let prefetchTopComments: ((PostID) async -> Void)?
    /// A text post's prefetched top comments, for its long-press preview (#1498).
    private let cachedTopComments: ((PostID) -> [CommentEntry]?)?
    /// Posts whose first page of comments has been asked for. A set, because
    /// the reconcile that feeds it runs at ~30Hz while a finger is moving and
    /// the same three cards are on screen for most of it.
    private var warmedComments: Set<PostID> = []
    /// How this screen leaves itself. Weak, and held by the composition root —
    /// the screen never builds a destination, it names one.
    private weak var router: (any Router)?
    /// Files a row's Report. Nil withholds the row entirely: an action that
    /// cannot act is not offered.
    private let reporting: (any ContentReporting)?
    /// Unfollows a row's author. Nil withholds that row for the same reason.
    ///
    /// ⚠️ The rows are `timeline.v1.GetFollowingFeed`'s, but Discover reads
    /// its own pool (`GetDiscoveryFeed`) — anyone's posts — so Unfollow is
    /// offered only where `ForYouViewModel.isFollowed` says so.
    private let socialGraph: (any SocialGraphWriting)?
    /// The balance and the sheet behind it, for the header every screen this
    /// one pushes wears (`PushedScreenHeader`). This screen's OWN badge is the
    /// shell's (`setTrailingAccessoryItem`); these reach the pushed ones, which
    /// the shell never sees.
    private let wallet: WalletStore?
    /// Whether a pushed screen's header wears the balance: not for a guest
    /// (#1146), asked as each header is made.
    private let showsBalance: @MainActor () -> Bool
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    // ⚠️ NO TAB BAR COLLAPSE. The bar used to minimize as the list scrolled —
    // it rode the tab strip's accessory, and #312 kept it alive with a claim
    // of its own once the strip was gone. The product call (2026-09-29): with
    // no tabs on the screen there is nothing for the collapse to make room
    // for, so the bar stays put. Nothing arms `tabBarMinimizeBehavior` here.

    /// Search. The trailing EDGE item — an action, so a plain glyph with a
    /// target and no menu.
    ///
    /// It stands where a context glyph used to, because the bar's detached
    /// trailing item was taken — by a camera first, by the "+" menu (Camera,
    /// Upload Media, Text Post) since — and search had to land somewhere it is
    /// actually wanted. The header "+" that used to hold the leading corner is
    /// gone with the compose screen it opened; making a post starts from the
    /// bar's "+" now.
    private lazy var searchItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in self?.router?.route(to: .search) }
        )
        item.accessibilityLabel = "Search"
        // Shared with the screens this one pushes, so iOS 26 keeps search in
        // place across the push rather than cross-fading two copies — see
        // `PushedScreenHeader`.
        item.identifier = PushedScreenHeader.searchItemIdentifier
        return item
    }()

    /// Reports how the app's own tab item should read — see
    /// `ForYouTabPresentation`.
    var onTabPresentationChange: ((ForYouTabPresentation) -> Void)?

    /// The flight in progress, held for its life (the stack holds its
    /// delegate weakly). Its close-out is the session's (`HeroPushSession`).
    private var activeSession: HeroPushSession?
    /// The "one flight at a time" latch every open checks.
    private var activeTransition: ZoomTransitionController? { activeSession?.controller }

    /// The flight attached to a screen that was opened as a WINDOW, held only
    /// so it outlives this function.
    ///
    /// ⚠️ NOT `activeTransition`, and the distinction is a bug I shipped for
    /// one commit. That property is the guard on `openFeed` — "one flight at a
    /// time" — and is cleared by the flight's own completion hooks. A window
    /// opening has no such completion, so storing this one there left it set
    /// for ever: every later tile tap returned at the guard and did nothing.
    /// Reported as the screen breaking after a few open/close cycles.
    private var cardPathFlight: HeroPushSession?

    /// How many posts a tile tap hands the feed, counting from the tapped one.
    ///
    /// `FixedPostsFeedProvider` hydrates its whole set in ONE concurrent
    /// fan-out, so an uncapped deep grid would fire hundreds of `GetPost`
    /// calls on a single tap. The consequence is stated rather than hidden:
    /// one feed session reaches at most this many posts, and paging on through
    /// the grid's own cursor is a follow-up.
    private static let seedWindow = 40

    init(
        viewModel: ForYouViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeSnapFeed: @escaping ([PostID], SnapFeedContinuation?) -> UIViewController,
        openPostHero: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)? = nil,
        prewarm: @escaping ([PostID]) async -> Void,
        prefetchTopComments: ((PostID) async -> Void)? = nil,
        cachedTopComments: ((PostID) -> [CommentEntry]?)? = nil,
        router: (any Router)? = nil,
        reporting: (any ContentReporting)? = nil,
        socialGraph: (any SocialGraphWriting)? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        showsBalance: @escaping @MainActor () -> Bool = { true },
        entities: EntityStore? = nil
    ) {
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.showsBalance = showsBalance
        self.viewModel = viewModel
        self.makeSnapFeed = makeSnapFeed
        self.openPostHero = openPostHero
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.prewarm = prewarm
        self.prefetchTopComments = prefetchTopComments
        self.cachedTopComments = cachedTopComments
        self.router = router
        self.reporting = reporting
        self.socialGraph = socialGraph
        page = ForYouGridPage(imagePipeline: imagePipeline, style: .discover, videoPlayback: videoPlayback)
        friendsRow = FriendsStoriesRow(imagePipeline: imagePipeline)
        friendsRow.videoPlayback = videoPlayback
        shelf = PostShelfSection(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        lead = GridLeadStack(sections: [friendsRow, shelf])
        // The cards' counts are the posts' live ones (#896): a like in the
        // vertical feed is on the tile it opened from.
        staking = wallet.map { PostCardStaking(wallet: $0, entities: entities) }
        super.init(nibName: nil, bundle: nil)
        page.staking = staking
        shelf.staking = staking
        // Its title over skeleton cards until the first snapshot (#1296).
        shelf.apply(.init(title: "Following", posts: [], isLoading: true))
        shelf.titleAccessibilityHint = "Shows posts from people you follow"
        // "For you" names the list under the rows and pushes Discover's whole
        // mosaic — the screen a chunk's "View all" pushes.
        lead.listTitle = "For you"
        lead.listTitleAccessibilityHint = "Shows every post in Discover's mosaic"
        // The chunks' large tiles wear their author and caption start
        // (`PostTileInfo`) — the Discover gallery's too.
        page.showsTileInfo = true
        // NOT hidesBottomBarWhenPushed: this is a tab root, and the bar is how
        // the viewer leaves it.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// An item the SHELL owns, standing inboard of this screen's own —
    /// the viewer's point balance today, the same badge the Explore header and
    /// the post screen wear.
    ///
    /// Injected rather than built here, and that is the whole design: three
    /// screens show one number, so one object owns the wallet, the claim
    /// countdown and the sheet, and the screens promise only to keep the item
    /// in their trailing run. This one has to survive `viewDidLoad`'s own
    /// write, which is why it is stored and re-applied rather than assigned.
    private var trailingAccessoryItem: UIBarButtonItem?

    /// Installs (or clears) that item. Safe before the view loads — the write
    /// at `viewDidLoad` composes from the same two places.
    ///
    /// `HeaderAccessoryHosting`, so the shell can hand it over without knowing
    /// this type.
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        trailingAccessoryItem = item
        guard isViewLoaded else { return }
        applyTrailingItems()
    }

    /// ⚠️ `[0]` IS THE SCREEN EDGE. Search keeps the corner and the wallet
    /// badge sits to its left — the same arrangement the Explore header wears
    /// ([coins] [search]). The shell's bell leads alone: `[bell] …
    /// [coins][search]`.
    private func applyTrailingItems() {
        navigationItem.rightBarButtonItems = [searchItem, trailingAccessoryItem].compactMap { $0 }
    }

    /// The shell's item at the head of the leading group — the notifications
    /// bell, the same one every root header leads with. Stored for the same
    /// reason as the trailing one: `viewDidLoad` writes this group itself.
    private var leadingAccessoryItem: UIBarButtonItem?

    /// Installs (or clears) that item. Safe before the view loads.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard isViewLoaded else { return }
        applyLeadingItems()
    }

    /// The bell alone, in its own bubble (it opts out of the shared
    /// background; see `NotificationsBell`).
    private func applyLeadingItems() {
        navigationItem.leftBarButtonItems = [leadingAccessoryItem].compactMap { $0 }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page the cards lie on, a step below them — see `Surface`.
        view.backgroundColor = Surface.page
        // ⚠️ **NO TITLE IN THE BAR.** "For You" was written here (the static
        // word); it went with the map tab's on 2026-09-22 —
        // the two roots' headers carry their controls and nothing else, and the
        // tab bar already says the word.
        // `largeTitleDisplayMode` stays `.never`: the large-title content-area
        // layout is kept out of the hero flight's path, which is a separate
        // reason and still holds.
        navigationItem.largeTitleDisplayMode = .never
        // ⚠️ **AND THE CHEVRON KEEPS ITS SILENCE.** A titled root gives every
        // screen pushed from it a WORDED back button, and two pushed bars were
        // budgeted against a bare 44pt chevron: `SearchResultsViewController`
        // says in as many words that its field would then be "44pt too
        // generous", and the chat thread's identity view is capped at 240pt on
        // the same assumption — 32 margins + 44 chevron + 24 gap + 8 padding +
        // 240 = 348 fits 375, while a "Messages" label (~98pt with its platter)
        // makes it ~402 and does not. `.minimal` keeps the title for this
        // screen and the chevron bare for the next one.
        navigationItem.backButtonDisplayMode = .minimal

        // The bar keeps the bell leading and search + wallet trailing. The
        // centre is empty and stays empty.
        applyLeadingItems()
        applyTrailingItems()

        page.pin(to: view)
        // The rows lead the list, as its header — see `GridLeadStack`.
        shelf.visibleBand = { [weak self] in self?.visibleBand() }
        lead.onHeightChange = { [weak self] in self?.updateLeadHeight() }
        friendsRow.onStoryTapped = { [weak self] story in self?.openStory(story) }
        // A card's flight is the SHELF's (#1271): it builds the origin, this
        // screen presents it.
        shelf.heroContext = .init(
            page: page, host: view, seedWindow: Self.seedWindow, closeStaged: rowCloseStaged
        )
        shelf.shouldOpen = { [weak self] in
            guard let self else { return false }
            return canOpenFromRow && openPostHero != nil
        }
        shelf.onOpen = { [weak self] open in self?.presentCard(open) }
        friendsRow.onTitleTapped = { [weak self] in self?.pushList(.friends) }
        shelf.onTitleTapped = { [weak self] in self?.pushList(.following) }
        // "For you ›" and a chunk's "View all" are one way in to one screen.
        lead.onListTitleTapped = { [weak self] in self?.pushDiscoverGallery() }
        friendsRow.storyMenuElements = { [weak self] story in self?.storyMenuElements(for: story) ?? [] }
        shelf.cardMenuElements = { [weak self] post in self?.cardMenuElements(for: post) ?? [] }
        // A text card is the list's card: its band opens the author and its
        // "..." offers the list's rows.
        shelf.onCardAuthorTapped = { [weak self] post in self?.openAuthor(of: post) }
        shelf.cardAuthorMenuActions = { [weak self] post, anchor in
            guard let self, let authorID = post.authorID else { return [] }
            return authorMenuActions(
                for: ForYouGridPage.AuthorMenuContext(post: post, authorID: authorID, anchor: anchor)
            )
        }
        // The rows' players keep time with the list's: the list's reconcile
        // runs as it scrolls, which is also when a row enters or leaves the
        // band. The rows are reconciled FIRST and the list plays what the
        // pool has left after them (`ForYouGridPage.playerReserve`).
        page.onAutoplayReconcile = { [weak self] allowingStarts in
            // The list scrolled: the Friends row's reach follows it, and the
            // shelf reconciles its players.
            self?.friendsRow.listDidScroll()
            self?.shelf.updateAutoplay(allowingStarts: allowingStarts, notifiesClaimChange: false)
        }
        page.playerReserve = { [weak self] in self?.shelf.claimedPlayers ?? 0 }
        shelf.onPlayerClaimChange = { [weak self] in self?.page.updateAutoplay() }
        // Leaving the APP frees the Friends row to re-sort — see
        // `FriendsStoriesRow.releaseStoryOrder`. (Leaving for another tab is
        // `viewDidDisappear`'s.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )

        // ⚠️ NAMED, not left to UIKit's heuristic search: the list's scroll
        // view is nested in the page, and the search was measured not to find
        // a nested scroller (it missed For You's pages inside the old pager).
        // The bars' scroll-edge treatment follows this one. The tab bar does
        // NOT collapse with it: nothing on this screen arms the minimize.
        setContentScrollView(page.minimizeScrollView, for: .bottom)
        page.onItemTapped = { [weak self] index in
            self?.openFeed(at: index)
        }
        page.onItemCommentsTapped = { [weak self] index in
            self?.openFeed(at: index, showingComments: true)
        }
        page.onWarmRequested = { [weak self] posts in self?.warmVisible(posts) }
        page.onNearEnd = { [weak self] in self?.viewModel.loadNextPageIfNeeded(.discover) }
        page.onWillDisplayPost = { [weak self] id in self?.viewModel.didShow(id) }
        page.onRefresh = { [weak self] in self?.viewModel.refresh() }
        // An ordinary push onto whatever stack this screen is on — the app's
        // one profile destination, reached the way every other author tap
        // reaches it. The screen names the route; it never builds the profile.
        page.onAuthorTapped = { [weak self] post in self?.openAuthor(of: post) }
        // A text card's long press shows its top comments (#1498).
        page.topComments = cachedTopComments
        page.authorMenuActions = { [weak self] context in
            self?.authorMenuActions(for: context) ?? []
        }

        viewModel.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            // BEFORE the render it is for: Discover plans its tail on it.
            page.setCorpusComplete(!viewModel.hasMorePages)
            page.render(snapshot.discover)
            // The vertical feed's own list, read ahead for the next tap (#1343).
            viewModel.ownFeed.prepare()
            // The stories' pictures are the Friends row's lookahead (#970).
            renderLead(snapshot.rails, loading: snapshot.following == .loading)
            lastSnapshot = snapshot
            discoverGallery?.render(snapshot.media)
            followingList?.render(snapshot.following, newPosts: snapshot.followingNew)
            friendsList?.render(snapshot.friends, newPosts: snapshot.friendsUnseen)
            prewarmVisible()
            #if DEBUG
            auditPostMenu()
            #endif
        }
        viewModel.onCorpusReset = { [weak self] in
            self?.page.invalidateIncrementalUpdates()
            self?.followingList?.invalidateIncrementalUpdates()
            self?.friendsList?.invalidateIncrementalUpdates()
            // A new corpus is new posts under old ids' places; what was warmed
            // says nothing about what is on screen now.
            self?.warmedComments.removeAll()
        }
        // A refresh that failed over content the viewer can still see (#798):
        // the content stays, the toast says the refresh did not happen. From
        // the NAVIGATION controller, because the pull may have come from a
        // pushed list (Following, Friends, the gallery) covering this one. The
        // refresh controls end on `onLoadSettled`, which follows.
        viewModel.onRefreshFailed = { [weak self] in
            guard let self else { return }
            Feedback.failure("Couldn't refresh", from: navigationController ?? self)
        }
        viewModel.onLoadSettled = { [weak self] in
            self?.page.endRefreshing()
            self?.discoverGallery?.endRefreshing()
            self?.followingList?.endRefreshing()
            self?.friendsList?.endRefreshing()
        }
        // Each surface's footer follows ITS corpus (#566): Discover's grid and
        // gallery page Discover; the Friends and Following lists the following
        // timeline.
        viewModel.onPagingChange = { [weak self] paging in
            self?.page.setPaging(paging)
            self?.discoverGallery?.setPaging(paging)
        }
        viewModel.onFollowingPagingChange = { [weak self] paging in
            self?.followingList?.setPaging(paging)
            self?.friendsList?.setPaging(paging)
        }
        // Discover's "View all": the whole mosaic, pushed.
        page.onViewAllTapped = { [weak self] in self?.pushDiscoverGallery() }
        // The tab item is a fact about the app's chrome: pushed, not asked.
        viewModel.onNewCountChange = { [weak self] count in
            self?.onTabPresentationChange?(ForYouTabPresentation(badgeCount: count))
        }
        viewModel.viewDidLoad()

        #if DEBUG
        installDebugHooks()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The rows' height depends on the WIDTH (a card is a fraction of it),
        // which is only known once the screen has one.
        updateLeadHeight()
    }

    /// The Friends row and the shelf, from the view model's rows.
    private func renderLead(_ rows: ForYouViewModel.Rails, loading: Bool) {
        friendsRow.render(rows.friends, newCount: rows.friendsBadge)
        if shelf.apply(.init(
            title: "Following", newCount: rows.followingBadge, posts: rows.following, isLoading: loading
        )) {
            #if DEBUG
            // Which `-foryou-open-card` index opens which row's card.
            let cards = shelf.cards
            let text = cards.indices.filter { PostShelfRows.Row(cards[$0]) == .text }
            let media = cards.indices.filter { !text.contains($0) }
            print("[qa] following rows: media=\(media) text=\(text)")
            #endif
        }
    }

    /// The rows' screen is (or is no longer) the viewer's.
    private func setLeadActive(_ active: Bool) {
        friendsRow.setActive(active)
        shelf.setAutoplayActive(active)
    }

    /// Sizes the list's leading header to the rows it holds.
    private func updateLeadHeight() {
        let width = page.bounds.width
        guard width > 0 else { return }
        page.setLead(lead, height: lead.preferredHeight(forWidth: width))
    }

    /// The part of the screen the viewer can see, in the shelf's space: under
    /// the navigation bar and above the tab bar. What a row's card must be
    /// half inside to play — the list's own rule, measured the list's way.
    private func visibleBand() -> CGRect? {
        guard shelf.window != nil, view.window != nil else { return nil }
        let band = view.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 0, bottom: floatingBarCover, right: 0
        ))
        return shelf.convert(band, from: view)
    }

    /// An author tap, from the list or a pushed list: the app's one profile
    /// destination. The stub is what the row already drew, handed forward so
    /// the pushed screen titles itself in the push's own frame.
    private func openAuthor(of post: GalleryPost) {
        guard let id = post.authorID else { return }
        router?.route(to: .profile(id, stub: post.authorIdentityStub))
    }

    /// Opens the full-screen feed on the tapped post, with the hero zoom.
    ///
    /// The feed is seeded from the page's own ordered ids as a SUFFIX starting
    /// at the tap, so swiping down in the feed continues through the grid in
    /// the order the viewer was reading it. This is the Maps pin path's
    /// mechanism end to end — `makeSnapFeedViewController(postIDs:)` over
    /// `FixedPostsFeedProvider`, pushed under a `ZoomTransitionController` —
    /// with a tile as the source instead of a pin.
    /// The feed this grid opens, reused across pushes when it can be.
    ///
    /// Held by THIS controller rather than by the builder on purpose. A single
    /// shared instance would be a bug the moment two tabs want a feed at once
    /// — the Maps pin path pushes onto its own navigation stack and can be on
    /// screen while this one is — so the cache belongs to the call site, and
    /// every other entry point keeps building its own.
    /// The interactive swipe-to-pop for TEXT posts, which push natively.
    ///
    /// The same object the menu-pushed timeline uses, for the same reason: a
    /// page with no hero still needs a way back by hand, and the system's own
    /// gesture is edge-only and disabled by the feed's custom back item. It
    /// scrubs the pop 1:1 and releases on the shared contract, so a text post
    /// and a media post feel the same in the hand even though only one of them
    /// flies.
    private let textSlideDismissal = InteractiveSlideDismissal()

    /// STRONG, and that is the whole mechanism: the reference has to outlive
    /// the pop. Held weakly it would be released the moment the navigation
    /// controller let go, and the next tap would rebuild exactly what this
    /// exists to avoid.
    private var reusableFeed: SnapFeedViewController?

    /// The cache is an OPTIMISATION, not state: under real pressure, give it
    /// back. This is the ONLY thing that drops it — a tab switch does not.
    ///
    /// # Why a cached feed is cheap to keep
    /// The reason to drop it would be the media it holds, except it holds
    /// none. Being popped runs the FEED's own `viewDidDisappear`, which
    /// resigns its active cell and calls `VideoPlaybackController.stop`: the
    /// item is replaced with nil, the renderer is invalidated and unhooked
    /// from the display link, and the `AVPlayer` returns to a pool that is
    /// app-wide rather than this screen's. By the time anything here could
    /// release a player, the players are already gone.
    ///
    /// What is left is a view hierarchy, and that measured as nothing: phys
    /// footprint after a tab-away was 83/75/82 MB holding it against 75/86/74
    /// MB dropping it — fully overlapping, and in both directions. So it is
    /// kept, and the next tap stays a re-point rather than a rebuild. A tab
    /// switch was never the signal that means "give something back"; this is.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        releaseCachedFeed()
    }

    /// Never drops a feed that is still on screen; a detached one costs the
    /// next tap a rebuild and nothing else.
    private func releaseCachedFeed() {
        guard reusableFeed?.navigationController == nil else { return }
        #if DEBUG
        if reusableFeed != nil, ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[feed-reuse] RELEASED cached feed")
        }
        #endif
        reusableFeed = nil
    }

    /// Re-aims the cached feed at this window, or builds one if there is no
    /// usable instance. `repoint` refuses while the controller is still in a
    /// navigation stack, which is the case that must not be reused.
    ///
    /// Internal, not private, so the cache's lifetime is unit-testable without
    /// driving a whole hero flight — the rules that matter (a push must not
    /// drop it, leaving the tab must) are lifecycle-ordering rules, and those
    /// are exactly what a sim run is worst at pinning.
    func snapFeed(for ids: [PostID], continuation: SnapFeedContinuation? = nil) -> UIViewController {
        if let cached = reusableFeed, cached.repoint(to: ids, continuation: continuation) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
                print("[feed-reuse] REPOINTED to \(ids.prefix(3).map(\.rawValue))")
            }
            #endif
            return cached
        }
        let feed = makeSnapFeed(ids, continuation)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[feed-reuse] BUILT fresh for \(ids.prefix(3).map(\.rawValue))")
        }
        #endif
        reusableFeed = feed as? SnapFeedViewController
        return feed
    }

    /// **THE TEXT REVEAL**: opens a text post with a clip-window
    /// reveal instead of UIKit's slide. `-text-reveal-plain` compares the
    /// unmatched variant (the window opens over a page that never moves);
    /// `-text-reveal-log` prints the rects both legs measured.
    ///
    /// ASSIGNED ON EVERY TEXT PUSH, including with `nil`, and that is not
    /// defensive — `textSlideDismissal` is one retained instance shared by
    /// every plain push this screen makes, and the branch it lives in is taken
    /// by more than text rows (a media row scrolled out of the viewport lands
    /// here too). A geometry left over from the previous tap would aim the
    /// next post's reveal at a row that has nothing to do with it.
    ///
    /// Whether a row can be revealed is asked of the GRID, not of the post's
    /// kind: `textRowFrame` answers only for a realized, on-screen text row,
    /// which is the same question the reveal has to answer again at dismissal.
    /// One predicate, so the two legs cannot disagree about whether this
    /// transition exists.
    /// Returns whether the reveal is armed — the caller uses it to leave the
    /// tab bar alone, because a reveal takes the bar down ITSELF.
    ///
    /// The bar FLOATS: it draws over the grid without insetting it (measured on
    /// an iPhone 17 Pro — bar at y 791 height 83, while the grid reserves 34),
    /// so it covers the bottom 26pt of the very row a reveal departs from.
    /// Hidden before the push, as every plain push does it, that 26pt is the
    /// card's whole metric line snapping into existence one frame after the
    /// mask opens: the card the viewer tapped is not the card that starts
    /// growing. Driven by the flight instead, the bar is fully in place on
    /// frame 0 and dissolves as the page grows past it.
    @discardableResult
    /// `presenting` is whether this call is setting up an OPENING. False when a
    /// screen that was opened by a flight rebuilds the geometry at the grab,
    /// for a post it has since paged to — see `attachCardCloseAlongsideFlight`.
    /// A reveal must not claim a push that has already happened.
    private func installTextReveal(
        feed: UIViewController, postID: PostID, presenting: Bool = true
    ) -> Bool {
        let page = self.page
        // Cleared together: a stale geometry from the previous post would be
        // read by the next close, and a stale `revealPresents` would put a
        // reveal over a flight's opening.
        textSlideDismissal.revealGeometry = nil
        textSlideDismissal.revealPresents = false
        // ⚠️ NOT `#if DEBUG`, AND IT WAS — which meant this whole reveal did
        // not exist in a shipping build.
        //
        // The fence was here for the tracing twenty lines down, and it took the
        // geometry with it: outside Debug `installTextReveal` returned false,
        // so every text-post close from this grid was a plain slide onto a
        // concealed row. A Release BUILD passes either way, which is why it
        // survived — only the behaviour differed, and nothing builds Release
        // and then watches it.
        //
        // The fence now sits on the tracing that needed it.
        // ⚠️ THE POST THE CLOSE FLIES TO IS NOT ALWAYS THE ONE THAT OPENED.
        //
        // The feed is a pager: open a post, swipe to the next, and the card the
        // viewer is entitled to land on is the one they ENDED on. Every hook
        // below used to be bound to the id captured at the tap, so a dismissal
        // after any paging flew home to the wrong card — showing another post's
        // words, at another post's height, and revealing a row the viewer had
        // not been reading.
        //
        // The row the window opened from, and the one it closes onto whatever
        // the viewer paged to (#1283): the rect, the stand-in and the
        // concealment all read it.
        let anchorID = postID
        func sourceFrame(_ space: UICoordinateSpace) -> CGRect? {
            page.textRowFrame(for: anchorID, in: space)
        }
        /// The rect this window closes onto — the text row's, and the ROW's
        /// when the anchor turns out not to be a text row at all.
        ///
        /// ⚠️ `textRowFrame` refuses a row with media on purpose (a row with a
        /// hero flies instead of opening as a window), so a window landing on
        /// a media row would be told nil and close into the middle of the
        /// screen: the row's own rect is the floor.
        ///
        /// Deliberately only for the CLOSE: the opening is still gated on a
        /// real text row, which is what decides that this window exists at all.
        func closingFrame(_ space: UICoordinateSpace) -> CGRect? {
            page.textRowFrame(for: anchorID, in: space)
                ?? page.rowFrame(for: anchorID, in: space)
        }
        // ⚠️ EACH LEG ASKS ITS OWN QUESTION, and asking the opening's on a
        // close is why a close could have nowhere to land.
        //
        // An OPENING is gated on a realized TEXT row, because that is what
        // decides a window exists at all rather than a flight (the `!revealing`
        // fork downstream depends on it). A CLOSE is a different question: it
        // already HAS a window in the air, and all it needs to know is whether
        // the row it is aiming at can be found. `closingFrame` answers that for
        // a row of any kind — it is already what the geometry's rect uses, so
        // until now the existence check and the rect disagreed: the guard said
        // "no such transition" about a row `closingFrame` would have found.
        //
        // Filmed as a text page leaving a media row with no hero at all — a
        // plain horizontal slide — because the row it had to land on carried a
        // photograph, and `textRowFrame` refuses those on purpose.
        // ⚠️ A REFUSAL IS INVISIBLE, and that is what makes a missing hero hard
        // to read from a recording: this returns false, the geometry it just
        // cleared stays nil, and the close leaves on the plain slide with
        // nothing anywhere saying why. Each reason is named instead.
        let frame = presenting ? sourceFrame(view) : closingFrame(view)
        guard TextRevealInstaller.isEnabled, frame != nil else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-text-reveal-log") {
                let why: String
                if !TextRevealInstaller.isEnabled { why = "disabled" }
                else { why = presenting ? "no text row (sourceFrame nil)"
                                        : "no landing row (closingFrame nil)" }
                print("[text-reveal] install REFUSED post=\(postID.rawValue)"
                    + " presenting=\(presenting) why=\(why)")
            }
            #endif
            return false
        }
        // The grid's inset state at each stage of a round trip. It exists
        // because a rect alone cannot say why a landing missed, and the first
        // run's did: departure y=741, landing y=625.
        #if DEBUG
        let trace = ProcessInfo.processInfo.arguments.contains("-text-reveal-log")
        #else
        let trace = false
        #endif
        func log(_ stage: String) {
            #if DEBUG
            guard trace else { return }
            print("[text-reveal] \(stage) \(page.debugInsetState)")
            #endif
        }
        log("atTap        ")
        if trace, let rect = sourceFrame(view) {
            // The row's rect BEFORE the push hides the tab bar. Compared with
            // the animator's `source=`, this says whether the grid moved
            // between the tap and the opening — which is what a pre-opening
            // jump would be.
            #if DEBUG
            print("[text-reveal] atTap  row=\(NSCoder.string(for: rect))")
            #endif
        }
        // ⚠️ THE BAR IS NOT TOUCHED AT THE DRAG'S BEGIN any more. It used to be
        // put back here at alpha 0 — geometrically present, visually absent —
        // and shown at the landing. Native chrome is UIKit's (see
        // `TabBarRevealPolicy`): a drag is a question until it is released, so
        // the bar comes back through UIKit when the release commits (the feed's
        // own close and this screen's `viewWillAppear` both ask), and a
        // chevron's before its pop.
        //
        // ⚠️ WATCH THE LANDING. The first run of this close measured its
        // landing at y=625 for a row that had departed from y=741 — 116pt out,
        // this grid's own `adjustedContentInset.top` — and the cure then was
        // the bar's state restored before the pop, with a forced layout. The
        // inset trace below is kept so a regression reads as numbers.
        textSlideDismissal.onWillBeginPop = { _ in
            log("beginPop     ")
        }
        // The GEOMETRY is not built here — see `TextRevealInstaller`. A
        // profile draws the same row and must open it the same way, and two
        // hand-written copies of thirteen fields agree only on the day they
        // are written. What stays is what genuinely differs between the two
        // screens: which chrome comes back, and what has to settle first.
        // The OPENING is the reveal's — see `revealPresents`. Set alongside
        // the geometry rather than derived from it, because a media post will
        // carry a geometry too and must still open with its flight.
        textSlideDismissal.revealPresents = presenting
        // ⚠️ A WINDOW ONTO A TILE IS THE TILE'S SHAPE, not a card's.
        //
        // Discover draws a chunk's posts as bricks, and a brick opened by a
        // flight closes through this window once the viewer has paged onto a
        // text post. Every card-shaped answer below — the row's caption to
        // align to, its borrowed author band, the card's rounding and fill —
        // described a card that is not there: the window closed as a card onto
        // a tile. The tile answers for itself instead, the way a marker does:
        // nothing to align, no band, its own corner and floor. The stand-in is
        // the tile's twin (`ForYouGridPage.makeDismissStandIn`).
        //
        // Stable for the window's life: the anchor never moves (#1283).
        let landsOnTile = page.drawsAsTile(postID)
        let landingPost = page.posts.first { $0.id == postID }
        textSlideDismissal.revealGeometry = TextRevealInstaller.geometry(
            feed: feed,
            origin: TextRevealOrigin(
                rowFrame: { space in closingFrame(space) },
                // Read ONCE, at staging, and deliberately not re-asked at
                // dismissal: `applyPendingReveal` may have scrolled the row,
                // and a row that scrolled out is not realized to answer. The
                // cut is a property of the caption, not of where the row
                // happens to be.
                captionEnd: page.textRowCaptionEnd(for: postID),
                // The gallery recedes; the tray and the title stay grounded —
                // the same view the hero's depth cue rides, for the same
                // reason.
                depthView: { [weak page] in page },
                captionTop: page.textRowCaptionTop(for: postID),
                // Borrowed by the destination for the flight, so the window
                // shows the header the card does instead of a blank strip. A
                // tile shows none, so none is borrowed.
                authorBand: landsOnTile ? nil : page.textRowAuthorBand(for: postID),
                // What the CLOSE carries home. Built from the post rather than
                // read off the page, so a viewer who scrolled the comments
                // still lands on the card they came from — see
                // `RevealDismissCardView`.
                // Playing the tile's parked clip when it has one (#1294).
                makeDismissStandIn: { [weak page] _ in page?.makeWindowStandIn(for: anchorID) },
                // A tile has no caption for the page's to land on — the
                // marker's reason (`TextRevealOrigin.alignsPageToSource`).
                alignsPageToSource: !landsOnTile,
                // ⚠️ THE DEPARTING PAGE TRAVELS TO THE ARRIVAL ROW — see
                // `RevealPageFit.covering`.
                //
                // The legacy `.clipped` swap hands the destination over DURING
                // the drag, which is right when the window is a card-shaped
                // slice of the same post and wrong the moment it is not: after
                // paging, the veil and the borrowed author band are the TAPPED
                // post's, drawn over the post being read. A carrying fit
                // refuses both by construction and the whole transition moves
                // to the release, which is what the viewer asked for and what
                // the marker and the place page already do.
                pageFit: .covering,
                // The tile's own corner and floor; a row keeps the card's.
                cornerRadius: landsOnTile ? page.tileCornerRadius(for: postID) : nil,
                fill: landsOnTile
                    ? landingPost.map(PostGridTileCell.fillColor(for:)) ?? PostGridListRowCell.cardFillColor
                    : PostGridListRowCell.cardFillColor,
                // The reveal's OWN concealment slot, not the hero's — see
                // `ForYouGridPage.revealConcealedPostID`. Applied on every
                // dequeue too, so a row that recycles mid-flight comes back
                // still hidden.
                setConcealed: { [weak page] concealed in
                    page?.setRevealConcealed(concealed, for: anchorID)
                },
                presentationDidEnd: { [weak self] landed in
                    // The bar went down through UIKit with the push. A
                    // REVERSED opening never showed the page, so the bar goes
                    // back to being the grid's — through UIKit again, a turn
                    // after the transition's own bookkeeping.
                    guard !landed else { return }
                    self?.tabBarController?.showTabBarNativelyNextTurn()
                },
                // Pin the grid's inset before the landing rect is read. The pop
                // animates the safe area and this collection view adds it to
                // its own inset, so an unpinned grid keeps drifting under a
                // close that has already measured where it is going.
                willStageDismissal: { [weak self, weak page, weak feed] _ in
                    log("freeze    pre")
                    page?.beginHeroFreeze()
                    // HOME TO THE TAPPED ROW (#1283): the window returns to
                    // the post the opening left from, already concealed by
                    // the opening, and nothing in the list moves to meet it.
                    log("freeze   post")
                },
                dismissalDidEnd: { [weak self, weak page] committed in
                    page?.endHeroFreeze()
                    page?.windowCloseDidEnd(committed, for: anchorID)
                    // ⚠️ NOTHING IS BROUGHT IN HERE any more.
                    //
                    // The card's metric line used to be faded up once the card
                    // was alone, because "the page never had one". That is true
                    // of the reveal's PUSH and irrelevant to this leg: a
                    // dismissal's window carries `RevealDismissCardView`, a
                    // whole row including that line, so the viewer had been
                    // looking at it for the length of the flight. Dropping it
                    // to zero and bringing it back is a blink of something
                    // already on screen — reported exactly that way.
                    // A BACKSTOP for the dock, through UIKit: the commit has
                    // normally shown it already (`viewWillAppear`'s policy),
                    // so this finds nothing to do. A cancelled swipe never
                    // raised it, so there is nothing to put back down.
                    guard committed else { return }
                    self?.tabBarController?.showTabBarNativelyNextTurn()
                }
            ),
            pipeline: page.bandImagePipeline
        )
        return true
    }

    // MARK: - The row's "..."

    /// The rows this screen can service, in the order they read.
    ///
    /// Each is gated on the seam that performs it, so a build wired without a
    /// social graph shows a Report-only menu rather than an Unfollow that
    /// silently does nothing — and a build wired with neither shows no control
    /// at all, because `PostAuthorBandView` hides it on an empty answer.
    private func authorMenuActions(
        for context: ForYouGridPage.AuthorMenuContext
    ) -> [PostCardMenuAction] {
        var actions: [PostCardMenuAction] = []
        // Discover is everyone: Unfollow only for an author the viewer follows.
        if socialGraph != nil, viewModel.isFollowed(context.authorID) {
            let handle = context.post.authorHandle ?? ""
            actions.append(.unfollow { [weak self] in
                // The handle is not in the ROW (the card names its author right
                // above it) but it is in the confirmation, where the card may
                // already be gone from under the viewer's thumb.
                self?.unfollow(context.authorID, handle: handle)
            })
        }
        if reporting != nil {
            actions.append(.report { [weak self] in
                self?.presentReportReasons(for: context)
            })
        }
        return actions
    }

    // MARK: - The rows' long press

    /// What a long press on a Following card offers under its preview, after
    /// the row's own "Open": the author's profile, then the card's "..." rows
    /// (Unfollow, Report) in their own section — the same rows, gated on the
    /// same seams, as the list's cards.
    private func cardMenuElements(for post: GalleryPost) -> [UIMenuElement] {
        guard let authorID = post.authorID else { return [] }
        var elements: [UIMenuElement] = [profileAction { [weak self] in self?.openAuthor(of: post) }]
        let rows = authorMenuActions(
            for: ForYouGridPage.AuthorMenuContext(post: post, authorID: authorID, anchor: shelf)
        )
        if let menu = PostCardMenu.menu(for: rows) {
            elements.append(UIMenu(options: .displayInline, children: menu.children))
        }
        return elements
    }

    /// The same for a friend's face: their profile, and Unfollow. No Report —
    /// a face is a person, not a post, and a post is reported from the post.
    private func storyMenuElements(for story: ForYouViewModel.FriendStory) -> [UIMenuElement] {
        let author = story.authorID
        let stub = ProfileIdentityStub(handle: story.handle, displayName: story.name)
        var elements: [UIMenuElement] = [profileAction { [weak self] in
            self?.router?.route(to: .profile(author, stub: stub))
        }]
        if socialGraph != nil {
            let unfollow = PostCardMenuAction.unfollow { [weak self] in
                self?.unfollow(author, handle: story.handle)
            }
            if let menu = PostCardMenu.menu(for: [unfollow]) {
                elements.append(UIMenu(options: .displayInline, children: menu.children))
            }
        }
        return elements
    }

    private func profileAction(_ handler: @escaping () -> Void) -> UIAction {
        UIAction(title: "View Profile", image: UIImage(systemName: "person.crop.circle")) { _ in handler() }
    }

    /// Unfollows, clears the author off the surface, and says so — with Undo
    /// (#957).
    ///
    /// The rows go only once the graph has ACCEPTED. Removing them optimistically
    /// would mean putting them back on a failure — a list that empties and
    /// refills itself under the reader is worse than one that waits a moment.
    ///
    /// Undo is a COMPENSATING call (the unfollow already went out): follow
    /// again, and the rows come back once that is accepted too. A refused
    /// follow-back is said, and the rows stay as the graph has them.
    private func unfollow(_ id: ProfileID, handle: String) {
        guard let socialGraph else { return }
        Task { [weak self] in
            do {
                try await socialGraph.setFollowing(false, for: id)
                guard let self else { return }
                // Following loses the author — without this the action reads
                // as having failed. Discover keeps them: it is everyone, not
                // the people the viewer follows (`removeAuthor`).
                viewModel.removeAuthor(id)
                let name = handle.isEmpty ? "this author" : "@\(handle)"
                Feedback.undoable(
                    "Unfollowed \(name)", symbol: "person.badge.minus", from: self,
                    commit: {},
                    undo: { [weak self] in self?.followAgain(id, name: name) }
                )
            } catch {
                self?.presentFailure(handle.isEmpty ? "Couldn't unfollow" : "Couldn't unfollow @\(handle)")
            }
        }
    }

    /// The unfollow's Undo: the compensating follow.
    private func followAgain(_ id: ProfileID, name: String) {
        guard let socialGraph else { return }
        Task { [weak self] in
            do {
                try await socialGraph.setFollowing(true, for: id)
                self?.viewModel.restoreAuthor(id)
            } catch {
                self?.presentFailure("Couldn't follow \(name) again")
            }
        }
    }

    private func presentReportReasons(for context: ForYouGridPage.AuthorMenuContext) {
        ReportReasonSheet.present(
            from: self, subject: "this post", sourceView: context.anchor
        ) { [weak self] reason in
            self?.report(context.post.id, reason: reason)
        }
    }

    /// Files the report and reports the outcome EITHER WAY — a report the user
    /// believes was filed but wasn't is the worst outcome here.
    private func report(_ postID: PostID, reason: ReportReason) {
        guard let reporting else { return }
        Task { [weak self] in
            do {
                // The surface names WHERE this was raised, which is a triage
                // signal in its own right: the same post reported from a feed
                // and from a profile are different reports.
                try await reporting.report(.post(postID), reason: reason, surface: "ios.foryou")
                guard let self else { return }
                Feedback.success("Report sent", symbol: "flag.fill", from: self)
            } catch {
                self?.presentFailure("Couldn't send this report")
            }
        }
    }

    #if DEBUG
    /// `-post-menu-audit`: prints the rows a card's "..." would offer here.
    ///
    /// The composition is the thing worth checking and the thing a screenshot
    /// cannot show: a menu is a system surface, and whether a row exists
    /// depends on wiring three packages away. Printing it proves the seams
    /// reached this screen — a missing Unfollow means the composition root
    /// handed over no social graph, not that the menu is broken.
    func auditPostMenu() {
        guard ProcessInfo.processInfo.arguments.contains("-post-menu-audit"),
              let post = page.posts.first(where: { $0.authorID != nil }),
              let authorID = post.authorID
        else { return }
        let rows = authorMenuActions(
            for: ForYouGridPage.AuthorMenuContext(
                post: post, authorID: authorID, anchor: UIView()
            )
        )
        print("[post-menu-audit] foryou rows=\(rows.map(\.title))")
    }
    #endif

    /// A report or an unfollow that did not happen is something the viewer has
    /// to know in order to retry: a failure toast with its error haptic, the
    /// same answer the Snap feed gives the same report (#804) — it used to be
    /// an alert here and a toast there.
    private func presentFailure(_ message: String) {
        Feedback.failure(message, from: self)
    }

    // MARK: - Discover's whole mosaic

    /// "View all" under a chunk, or the "For you" heading over the list:
    /// pushes the mosaic Discover used to be, over the same corpus
    /// (`DiscoverGalleryViewController`).
    ///
    /// Only from rest — this screen on top, no flight of its own in the air —
    /// so a tap landing mid-transition cannot stack a push on a pop.
    func pushDiscoverGallery() {
        guard activeTransition == nil,
              let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil
        else { return }
        let gallery = DiscoverGalleryViewController(
            imagePipeline: imagePipeline, videoPlayback: videoPlayback,
            header: makePushedHeader(),
            staking: staking,
            openPost: openPostHero
        )
        // Its posts open onto the vertical feed's own list too (#1343).
        gallery.ownFeed = viewModel.ownFeed
        gallery.onNearEnd = { [weak self] in self?.viewModel.loadNextPageIfNeeded(.discover) }
        gallery.onWillDisplayPost = { [weak self] id in self?.viewModel.didShow(id) }
        gallery.hasMore = { [weak self] in self?.viewModel.hasMorePages ?? false }
        gallery.onRefresh = { [weak self] in self?.viewModel.refresh() }
        // What is loaded NOW, so the push shows the mosaic rather than a
        // skeleton waiting for the next publish.
        if let lastSnapshot { gallery.render(lastSnapshot.media) }
        discoverGallery = gallery
        navigationController.pushViewController(gallery, animated: true)
    }

    /// The `[‹] ———— [points][search]` header for a screen this one pushes —
    /// one per screen, since a badge is a view and lives in one bar.
    func makePushedHeader() -> PushedScreenHeader {
        PushedScreenHeader(wallet: showsBalance() ? wallet : nil, makeWalletSheet: makeWalletSheet, router: router)
    }

    private func openFeed(at index: Int, showingComments: Bool = false) {
        // One flight at a time: a second tap while a card is in the air would
        // stage a transition over a live one. Same guard as the map's.
        guard activeTransition == nil else { return }
        let page = self.page
        let posts = page.posts
        guard posts.indices.contains(index), let navigationController,
              navigationController.transitionCoordinator == nil
        else { return }
        let tapped = posts[index]
        // ⚠️ ITS OWN LIST (#1343, the owner 2026-10-17): the tapped post, then
        // the vertical feed's own posts — not the grid's list from the tap.
        // Without discovery (or nothing beyond the grid yet) it keeps the
        // grid's window, as before.
        let ownWindow = viewModel.ownFeed.begin(with: tapped)
        let window = ownWindow ?? Array(posts[index...].prefix(Self.seedWindow))
        let ids = window.map(\.id)
        let ownFeed = viewModel.ownFeed
        var continuation: SnapFeedContinuation?
        if ownWindow != nil {
            continuation = { [weak ownFeed] after in await ownFeed?.next(after: after) }
        }

        // Open the handoff scope. Everything else stops — the grid is about to
        // be covered and its slots are what the feed needs — and the tapped
        // post becomes invisible to reconcile, so nothing can restart or stop
        // it while its player is in flight.
        // And park the row's own clip for a close that pages on and comes home
        // to it (#923, `ForYouGridZoomSource`).
        page.beginPlaybackHandoff(of: tapped.id, parkingReturn: true)
        // The rows are covered too, and their one player is not the flight's.
        setLeadActive(false)
        let feed = snapFeed(for: ids, continuation: continuation)
        // ⚠️ NO `onWillCloseFeed` FOR THE DOCK any more. It put the bar's
        // state back at alpha 0 before the chevron's pop, to be shown at the
        // landing. The feed brings the dock back itself, through UIKit, when
        // its close is committed — before the pop for a tap, at the release
        // for a drag (`SnapFeedViewController.revealDockBeforePop`).
        // Hand the feed the projection this grid already holds, so its first
        // page configures at push time rather than when its own fetch returns.
        // Measured at ~0.69s of empty destination without it.
        if let seedable = feed as? SnapFeedViewController {
            // One kind per feed (#1421), as its provider's pages are.
            seedable.seedProjection(SnapFeedViewController.keepingOpeningKind(GalleryPostProjection.seedModels(from: window)))
            // A COLLECTION opens on the page the card was showing.
            //
            // The flight already carries the right photograph — the row's cover
            // and hero rect are the CURRENT page's — so a destination that
            // opened at page one would land the flight on a different image
            // than the one that flew. The card knows the page; nothing
            // downstream can work it out.
            // ⚠️ INCLUDING PAGE ZERO, and the `page > 0` this replaces is the
            // whole of a defect.
            //
            // Zero was treated as "no instruction" on the reasoning that a
            // destination opens at its first page anyway. It does not: the feed
            // controller is REUSED, and its carousel deliberately keeps its page
            // across a re-configure carrying the same attachments — that guard
            // is what stops a second hydration yanking a viewer's carousel back
            // to page one. So a post opened at page two, dismissed, then opened
            // again from page ONE arrived still showing page two.
            //
            // An absent instruction and an instruction to go to zero are
            // different things, and only one of them was expressible.
            if let mediaPage = page.currentMediaPage(atIndex: index) {
                seedable.openMediaPage(mediaPage, for: tapped.id)
                #if DEBUG
                if CarouselPlaybackAudit.isEnabled {
                    print("[sync] card asked page=\(mediaPage)")
                }
                #endif
            }
            // A post opened FROM ITS COMMENT COUNT arrives with the thread
            // already up. Handed over with the page instruction rather than
            // acted on here, for the same reason: this screen knows what was
            // pressed, and only the destination knows when it is safe to spend
            // the engagement's layout.
            if showingComments {
                // WHERE the thread's window opens from: the media rect the
                // flight is about to fly, so the thread is revealed out of the
                // photograph rather than arriving over it.
                seedable.openComments(
                    for: tapped.id,
                    revealingFrom: page.hero(for: tapped.id, in: view)?.frame
                )
            }
            // …and the traffic runs the other way too, live. The card behind
            // follows the post's carousel, which is what makes the dismissal
            // land on the photograph the viewer is actually looking at rather
            // than on the one they opened with.
            seedable.onMediaPageChanged = { [weak page] id, mediaPage in
                page?.setMediaPage(mediaPage, for: id)
            }
        }

        // The feed owns the whole screen: hide the bar with the push. Managed
        // by hand rather than via `hidesBottomBarWhenPushed`, because that
        // flag's choreography does not scrub with a custom interactive pop —
        // the bar arrives at pop-begin and stands over the feed for the length
        // of a grab.
        //
        // Re-tested since, on the plain `UIPercentDrivenInteractiveTransition`
        // the text path uses, on the theory that the earlier verdict came from
        // the pin's free-floating interaction controller and might not survive
        // a percent driver. It survives. Wired up, the bar was at its resting
        // position and fully opaque in the FIRST frame after pop-begin and did
        // not move again while the scrub ran 0.000 → 0.150 — captured
        // composited over the feed's own author pill, mid-drag.
        //
        // The reason is structural, which is why no amount of driving fixes it:
        // the tab bar lives in the TAB BAR CONTROLLER's view, above the
        // navigation controller, so it is not in the transition's container and
        // not on the timeline the percent driver scrubs. UIKit animates it
        // beside the transition, not inside it.
        //
        // Worth recording what it got right, because it is the half this
        // screen had wrong: cancel and commit both settled correctly by
        // themselves. Only the mid-drag frames were unusable.
        // ⚠️ EVERY OPENING, the window's included. A reveal used to keep the
        // bar up and fade its alpha to nothing on its own curve
        // (`RevealPresentAnimator`), so the 26pt of card under the bar was not
        // uncovered one frame in; native chrome is UIKit's now (see
        // `TabBarRevealPolicy`), so the bar leaves on UIKit's own animation here,
        // exactly as it does for a flight.
        // ⚠️ BEFORE THE WINDOW IS BUILT, not after: this clears the geometry,
        // and everything the LAST opening left on a driver that outlives them
        // all — including the flight path's preparation hook, which a window's
        // close would otherwise run and which rebuilds the geometry for another
        // post. See `resetForNewPresentation`.
        textSlideDismissal.resetForNewPresentation()
        // Reduce Motion opens every post with the stack's own push: no window,
        // no flight (`HeroMotionPolicy`).
        let reducesMotion = HeroMotionPolicy.prefersNativePush
        let revealing = !reducesMotion && installTextReveal(feed: feed, postID: tapped.id)
        // ⚠️ NOT REBUILT FOR THE POST THE VIEWER ENDS ON, and NOT adopted into
        // the tapped post's slot. The list keeps its order; the window travels
        // to wherever the arrival row actually is.
        //
        // A rebuild was tried and is the regression it replaced: the geometry's
        // guard is `textRowFrame`, which REFUSES a row carrying media on
        // purpose, so rebuilding for a landed photo or video returned false and
        // cleared the reveal outright — the page then slid out as a strip while
        // a stray card floated over the list. Filmed.
        //
        // Nothing moves instead: the window closes onto the row it opened from
        // (#1283), `closingFrame` finds it whatever kind it is, and
        // `pageFit: .covering` carries the departing page into it — which is
        // also what stops the veil and the borrowed band, both of them the
        // TAPPED post's, from being drawn over a landing that is somebody
        // else's.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-text-reveal-log") {
            // Which driver opened the screen, said once. Everything downstream
            // reads differently depending on this answer.
            //
            // ⚠️ "not the reveal" is TWO outcomes, not one: a flight, and the
            // plain push a row that is not realized falls back to. Printing
            // them as one made a harness run where the row had not been
            // realized look like a text post opening with a hero, which is a
            // defect that does not exist.
            print("[text-reveal] open reveal=\(revealing)"
                + " post=\(tapped.id.rawValue) kind=\(tapped.kind)")
        }
        #endif
        tabBarController?.hideTabBarNatively()

        guard let destination = feed as? any ZoomTransitionDestination,
              // A reveal never also flies a hero. For a TEXT row this changes
              // nothing — it has no hero to fly — and for OPTION A it is what
              // sends a media row down the window's path instead.
              !revealing, !reducesMotion,
              page.hero(for: tapped.id, in: view) != nil
        else {
            // No hero available — a text-only row has no media to fly, and a
            // destination without the seam can't be flown to. A plain push is
            // the honest fallback; it is still the same feed.
            //
            // A full-surface interactive swipe stands in for the flight's
            // grab. It owns the dismissal from here, so the native edge
            // gesture stays out of its way (see `NativePopGestureEnabler`) —
            // the two would otherwise both try to drive one pop.
            (feed as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
            textSlideDismissal.attach(to: feed, axes: [.horizontal, .vertical])
            textSlideDismissal.onFeedPopped = { [weak self] _ in
                // The flight that rode along with this window is over with the
                // screen — released here rather than in one of its own hooks,
                // because it may never have flown anything at all.
                self?.cardPathFlight = nil
                // Completed pops only — a cancelled swipe reports nothing here,
                // which is exactly why this is a safe place to reveal from.
                // `viewWillAppear`'s policy normally gets there first; this is
                // the backstop for the case where its `topViewController`
                // guard declined. Through UIKit, a turn after `didShow`.
                self?.tabBarController?.showTabBarNativelyNextTurn()
                // The mirror of the hero path's backstop: this window may have
                // ended on a MEDIA post, whose close is the flight's, and a
                // flight that was cancelled or superseded leaves its hide
                // behind. Idempotent when nothing is hidden.
                self?.page.clearHeroConcealment()
                // Close the playback handoff opened before the push.
                //
                // On the hero path the transition closes it (`onSourceReturned`
                // / `onPresentationCancelled`), but a plain push has no
                // transition and so had nobody to close it: `handoffID` stayed
                // set for the life of the page, permanently exempting that post
                // from both starting and stopping. Reproduced with
                // `-grid-playback-log` — `handoff=post-new-02` still on the
                // pool three samples after the grid was back.
                //
                // The handoff is still OPENED on this path, deliberately: it is
                // what stops the grid's players while the post covers them
                // (`viewWillDisappear` declines to, since a push must not stop
                // a flight's video). It just has to be closed at the other end.
                //
                // Completed pops only, which is what this callback is: a
                // cancelled swipe leaves the post on screen, where the grid
                // underneath should stay stopped.
                self?.page.endPlaybackHandoff()
            }
            // ⚠️ AND THE FLIGHT RIDES ALONG, for the post this screen may end
            // on — the mirror of `attachCardCloseAlongsideFlight`.
            //
            // A text post opened this feed as a window, and the feed is a
            // PAGER: swipe to a photograph and the post being dismissed has a
            // hero to fly after all. Attached BEFORE the slide installs, so the
            // slide saves this controller as the delegate it displaced and can
            // forward a hero pop straight back to it.
            // Reduce Motion: no flight rides along either, so a media page
            // closes with the window's own slide, not a hero home.
            let alongside = reducesMotion
                ? nil
                : attachFlightAlongsideCardClose(feed: feed, tappedID: tapped.id)
            textSlideDismissal.arbitratesWithHeroGrab = true
            // ⚠️ AND CLAIM THE DRAGS THE HERO DECLINES — asked of the hero's
            // own gate, see `heroLandingArbiter`.
            //
            // This screen opened as a WINDOW on a text row, so on a list its
            // landing IS that text row, whatever the viewer has since paged to.
            // The hero attached alongside refuses a landing it cannot draw;
            // without this line the refusals are symmetric and NEITHER driver
            // claims the drag, which is a plain slide — the failure this whole
            // pairing exists to prevent.
            textSlideDismissal.heroLandingAcceptsHero = Self.heroLandingArbiter(asking: alongside)
            textSlideDismissal.install(on: navigationController)
            navigationController.pushViewController(feed, animated: true)
            #if DEBUG
            // `-text-swipe-demo <peak> [delay]`: walks the exact begin/update/
            // release path a finger drives. The simulator injects no touches, so
            // this is the only way the scrub itself gets exercised — a peak below
            // the release threshold must spring back, above it must pop.
            //
            // ⚠️ THE DELAY IS NOT OPTIONAL DECORATION, and this handler ignoring
            // it hid a whole class of defect. A run that PAGES the feed first
            // (`-snap-fling`, which begins at +3s) cannot be scripted against a
            // hard-coded 1.5s: the swipe fired before the paging, so the harness
            // only ever asked about the post the feed OPENED on — which is the
            // one case where departure and arrival agree and nothing can go
            // wrong. Every report of a paged close came from a real thumb
            // because of this line. Same spelling as `FeedFeatureBuilder`'s, so
            // the two entry points read one argument the same way.
            let arguments = ProcessInfo.processInfo.arguments
            if let position = arguments.firstIndex(of: "-text-swipe-demo"),
               position + 1 < arguments.count,
               let peak = Double(arguments[position + 1]) {
                let delay = position + 2 < arguments.count
                    ? (Double(arguments[position + 2]) ?? 1.5) : 1.5
                Task { @MainActor [textSlideDismissal] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await textSlideDismissal.debugPerformSwipe(peakProgress: CGFloat(peak))
                }
            }
            #endif
            return
        }
        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tapped.id,
            // Injected rather than imported: the source stays a grid concept
            // and never learns what a feed is.
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID },
            // And the post itself, for a landing this page no longer holds.
            activeMediaPage: { [weak feed] in (feed as? SnapFeedViewController)?.activeMediaPage },
            // The gallery recedes; the tray and the title stay grounded.
            depthView: page,
            // What the viewer is looking at, for a close that lands elsewhere —
            // see `ForYouGridZoomSource.settledCover`.
            settledCover: { [weak feed] in
                (feed as? any SnapFeedSettleReporting)?.settledCoverImage
            },
            // No hoist: the hoisted tap-back landing (a host above the
            // navigation controller) restarted the clip whenever its refusal
            // branch dropped the surface, and the grab never needed it. Both
            // dismissals land through `zoomAdoptLiveMediaView`, and the seam
            // itself is gone (hero audit PR F).
            donateLive: { [weak self, weak page] in
                // Under `-avsbdl-render` the card joins the tile's playback as
                // an extra surface instead of taking it over. The tile keeps
                // rendering behind the card, so there is no park, no transfer,
                // and nothing to hand back if the flight is abandoned.
                let attached = VideoRenderFlags.usesSampleBufferLayer
                let surface = attached
                    ? page?.liveFlightSurface(for: tapped.id)
                    : page?.donateLivePlayback(of: tapped.id)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print(String(format: "[zoom-live] %.3f source %@ -> %@",
                                 CACurrentMediaTime(),
                                 attached ? "attach surface" : "donate+park",
                                 surface != nil ? "true" : "false"))
                }
                #endif
                return surface
            }
        )
        // A text visit's close-only flight is over: this opening is a new
        // visit. Left alive (a text visit that ended without `onFeedPopped`),
        // its driver sat on the reused feed beside this one's, and two live
        // zoom drivers both claimed the next drag.
        cardPathFlight?.close(.abandoned)
        cardPathFlight = nil
        let session = HeroPushSession(source: source, destination: destination, on: navigationController)
        let transition = session.controller
        activeSession = session
        // A flight is staging, and it attaches its own grab below — so this
        // screen owns its dismissal and the native edge pop must stay out of
        // its way. Stated rather than left at the default: the controller is
        // reused, and the previous presentation may have said otherwise.
        (feed as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
        // ⚠️ THE BAR IS NOT THE FLIGHT'S, and nothing here writes its alpha.
        // UIKit shows it, on its own animation, once the close is committed:
        // before the pop for a chevron, at the release for a grab — the feed
        // asks for it (`SnapFeedViewController.revealDockBeforePop`), and so
        // does this screen's `viewWillAppear` policy. See `TabBarRevealPolicy`.
        // ONE close-out for every ending (`HeroPushSession.Ending`): a
        // return, a push reversed mid-air (the feed never showed, `didShow`
        // reports nothing — without this the latch made every later tap a
        // silent no-op and the handoff kept the grid's players down), or this
        // screen's own sweep. The session hands the stack's slot back first.
        session.onClose = { [weak self, weak page] ending in
            // A card-shaped close that was cancelled left a row hidden under
            // the page; if the viewer then left by this flight instead, nothing
            // else would put it back. See `clearRevealConcealment`.
            page?.clearRevealConcealment()
            self?.activeSession = nil
            // A BACKSTOP for the dock, through UIKit — normally already up.
            self?.tabBarController?.showTabBarNativelyNextTurn()
            // Close the handoff scope. This is the single act that restores the
            // grid: it clears the flight's state and reconciles once, so every
            // qualifying visible tile gets a slot again rather than whatever
            // subset survived the transition.
            self?.page.endPlaybackHandoff()
            #if DEBUG
            if ending != .reversed { self?.debugAdvanceGrabCycleIfNeeded() }
            #endif
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        transition.attachInteractiveDismissal(to: feed.view) { [weak self] in
            // ⚠️ THE BAR IS NOT PUT BACK HERE any more. Grab-begin used to
            // restore its hidden STATE at alpha 0 — outside the transition,
            // where it paints — and show it at the landing. A grab is a
            // question until it is released: `viewWillAppear` (which UIKit runs
            // inside the pop below) hands the bar to `TabBarRevealPolicy`, and
            // UIKit shows it when the release commits. A cancel never raises it.
            self?.navigationController?.popViewController(animated: true)
        }
        session.takeDelegateSlot()
        // Pay the destination's first layout and raster HERE: in the tap's
        // own frame a stall is invisible; in the flight's first frames it is
        // the pause.
        session.prepareDestination()
        navigationController.pushViewController(feed, animated: true)
        // ⚠️ THE OTHER DRIVER RIDES ALONG, for the post this screen may end on.
        //
        // A flight opened this feed, and the feed is a PAGER: swipe to a
        // text-only post and there is no media left for a hero to carry home.
        // The card-shaped close is attached here so that case has a driver at
        // all — the two grabs gate on `zoomDismissalKind` from opposite sides,
        // so exactly one of them claims any drag.
        //
        // AFTER the push, deliberately: `install` takes the navigation delegate
        // slot, and taking it before would hand this opening's animator to a
        // driver with no flight to offer. Taking it after leaves the flight
        // controller as `savedDelegate`, which is where a hero pop is forwarded
        // back to.
        attachCardCloseAlongsideFlight(feed: feed, departureID: tapped.id, flightSource: source)
        // It holds the slot on the flight's behalf from here.
        session.registerForwarder(textSlideDismissal)
        #if DEBUG
        zoomProfilerNote("push returned")
        #endif

        #if DEBUG
        // `-foryou-demo-grab`: once the feed has landed, drive the grab twice —
        // below the completion threshold (springs back to full screen) and past
        // it (flies home to the tile). The sim injects no pans, so this is the
        // only way to exercise the release contract here.
        // `-text-swipe-demo <peak> [delay]` on the FLIGHT path too, because the
        // close a flight-opened screen ends on is not always a flight: page onto
        // a text post and the card close takes over (`zoomDismissalKind ==
        // .card`), which `-foryou-demo-grab` refuses by design. Without this the
        // only scripted dismissal here was the one the zoom grab accepts, so the
        // card-close leg of this path had never been driven by the harness at
        // all — and that is the leg that was filmed leaving on a plain slide.
        if let position = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-text-swipe-demo"),
           position + 1 < ProcessInfo.processInfo.arguments.count,
           let peak = Double(ProcessInfo.processInfo.arguments[position + 1]) {
            let arguments = ProcessInfo.processInfo.arguments
            let delay = position + 2 < arguments.count
                ? (Double(arguments[position + 2]) ?? 1.5) : 1.5
            Task { @MainActor [textSlideDismissal] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await textSlideDismissal.debugPerformSwipe(peakProgress: CGFloat(peak))
            }
        }
        // `[delay]` for the same reason `-text-swipe-demo` grew one: a run that
        // PAGES the feed first (`-snap-fling`, +3s) cannot be scripted against a
        // hard-coded 1.5s. The grab fired before the paging, so every scripted
        // hero dismiss ever measured here left from the post the feed OPENED on
        // — the one case where departure and arrival agree.
        if let position = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-foryou-demo-grab") {
            let arguments = ProcessInfo.processInfo.arguments
            let delay = position + 1 < arguments.count
                ? (Double(arguments[position + 1]) ?? 1.5) : 1.5
            transition.onDestinationShown = { [weak transition] in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    transition?.debugScriptedGrab()
                }
            }
        }
        // `-foryou-demo-tapback`: pop programmatically instead of grabbing.
        //
        // The two dismissals are SEPARATE implementations —
        // `ZoomDismissInteractionController` for the grab,
        // `ZoomAnimator.dismiss` for the back button — and the harness could
        // only ever drive the first. Every dismiss measurement taken here was
        // therefore of the grab, and said nothing about the button, which is
        // exactly where a defect survived being "verified".
        if ProcessInfo.processInfo.arguments.contains("-foryou-demo-tapback") {
            // ⚠️ EXCLUSIVE WITH `-foryou-demo-grab`, and said so. Both hooks
            // own `onDestinationShown` and both dismiss the feed; this
            // assignment used to replace the grab's handler without a word, so
            // a run passing both measured the back button while believing it
            // had measured the grab. The tap-back still wins, as before.
            if ProcessInfo.processInfo.arguments.contains("-foryou-demo-grab") {
                QAWait.fail("-foryou-demo-grab",
                            "overridden by -foryou-demo-tapback; the two are exclusive, pass one")
            }
            transition.onDestinationShown = { [weak navigationController] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    navigationController?.popViewController(animated: true)
                }
            }
        }
        #endif
    }

    /// Attaches the hero close to a screen that was opened as a WINDOW, for the
    /// case where the viewer pages onto a post that has media.
    ///
    /// The mirror of `attachCardCloseAlongsideFlight`, and it needs no
    /// equivalent of that one's `prepareForSwipe`: a flight resolves everything
    /// it carries through its source, which lands on the tapped tile and
    /// declines a landing it cannot fly to.
    ///
    /// Nothing here touches the opening. The controller is installed as the
    /// navigation delegate and then immediately shadowed by the slide, which is
    /// exactly what makes the window's own push survive — and what leaves this
    /// controller reachable, as `savedDelegate`, when a hero pop is forwarded.
    ///
    /// Returns the flight's source, so the slide can ask the hero's own gate
    /// who takes a drag — see `heroLandingArbiter`.
    @discardableResult
    private func attachFlightAlongsideCardClose(
        feed: UIViewController, tappedID: PostID
    ) -> ForYouGridZoomSource? {
        guard let navigationController,
              let destination = feed as? any ZoomTransitionDestination else { return nil }
        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tappedID,
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID },
            activeMediaPage: { [weak feed] in (feed as? SnapFeedViewController)?.activeMediaPage },
            depthView: page,
            // What the viewer is looking at, for a close that lands elsewhere —
            // see `ForYouGridZoomSource.settledCover`.
            settledCover: { [weak feed] in
                (feed as? any SnapFeedSettleReporting)?.settledCoverImage
            }
        )
        // ⚠️ `presents: false` — this one only ever CLOSES. The feed is already
        // pushed, so announcing a staging here would leave it suppressing its
        // own playback for the rest of its life, with nothing to retract it.
        let session = HeroPushSession(
            source: source, destination: destination, on: navigationController,
            presents: false
        )
        let transition = session.controller
        cardPathFlight = session
        // The same dock rule as the flight path: UIKit shows it once the close
        // is committed (`viewWillAppear`'s policy); this is the backstop, and
        // an abandoned grab never raised it.
        session.onClose = { [weak self] _ in
            self?.tabBarController?.showTabBarNativelyNextTurn()
        }
        session.takeDelegateSlot()
        // The window's slide installs after this and forwards a `.hero` pop
        // to the flight, so it holds the slot on the session's behalf.
        session.registerForwarder(textSlideDismissal)
        #if DEBUG
        // `-foryou-demo-grab [delay]` on the WINDOW path too. This flight is the
        // one a text-opened screen ends on once the viewer pages onto a post
        // with media, and it had no scripted driver at all: `-text-swipe-demo`
        // drives the card close instead, which is a different dismissal that
        // happens to look similar. Every measurement taken here was therefore of
        // the wrong one.
        if let position = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-foryou-demo-grab") {
            let arguments = ProcessInfo.processInfo.arguments
            let delay = position + 1 < arguments.count
                ? (Double(arguments[position + 1]) ?? 1.5) : 1.5
            // ⚠️ TIMED FROM THE LANDING, like the flight path's — not from
            // here. This runs before the window's push is even issued, so a
            // fixed delay from now shrank by however long the push took and, on
            // a cold run, grabbed a screen still sliding in. The landing does
            // reach this controller: the slide captured it as the delegate it
            // displaced and forwards every `didShow` to it unconditionally.
            transition.onDestinationShown = { [weak transition] in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    transition?.debugScriptedGrab()
                }
            }
        }
        #endif
        transition.attachInteractiveDismissal(to: feed.view) { [weak self] in
            // The same bar rule the flight path states: nothing at the begin,
            // UIKit shows it when the release commits.
            self?.navigationController?.popViewController(animated: true)
        }
        return source
    }

    /// The slide's half of the hero/card arbitration, answered BY THE HERO'S
    /// OWN GATE rather than restated beside it.
    ///
    /// Both drivers sit on one screen and each must refuse exactly the drags
    /// the other takes. The slide's refusal therefore has to be the negation of
    /// `ForYouGridZoomSource.zoomLandingAcceptsHero` — and it is read from the
    /// source that flight will actually fly, so the two can no longer drift.
    ///
    /// ⚠️ THEY DID DRIFT, and the drift only showed after paging DEEP. The
    /// flight path's copy asked `heroAppearance` for the post the viewer ENDED
    /// on, which reads a REALIZED CELL — but a tile ~25 posts past the one
    /// tapped has no cell, so the copy answered "the hero cannot land". The slide then claimed the grab, the chevron's pop was no
    /// longer forwarded to the flight, and the feed left on a plain slide to
    /// the right. A shallow close never showed it: the settled tile was still
    /// realized next to the departure.
    ///
    /// No source — nothing to fly — is "no opinion", the protocol's own
    /// default, which is what the slide read before this channel existed.
    static func heroLandingArbiter(asking source: ForYouGridZoomSource?) -> () -> Bool {
        { [weak source] in source?.zoomLandingAcceptsHero ?? true }
    }

    /// Attaches the card-shaped close to a screen that was opened by a FLIGHT,
    /// for the case where the viewer pages onto a post that has no media.
    ///
    /// Nothing here changes an opening: no geometry is built and
    /// `revealPresents` stays false, so the slide has nothing to say about a
    /// push that has already happened. What it gains is a grab that can claim a
    /// drag when the destination says the post on screen travels as a card, and
    /// a hook to build that card's geometry at the moment it does.
    private func attachCardCloseAlongsideFlight(
        feed: UIViewController, departureID: PostID, flightSource: ForYouGridZoomSource
    ) {
        guard let navigationController else { return }
        // ⚠️ THE SHARED RULES FIRST — both axes, arbitrated, staged ONCE and
        // only for a close that carries a card. They are
        // `armAsCardCloseAlongsideFlight`'s now, the same call a profile's and
        // a place page's flights make through `presentSnapFeedHero`, because
        // the copy a profile was missing is the defect that call ended. It
        // also resets whatever the last opening left on this driver.
        textSlideDismissal.armAsCardCloseAlongsideFlight(on: feed) { [weak self] feed in
            guard let self, (feed as? SnapFeedViewController)?.activePostID != nil else { return false }
            stageCardClose(feed: feed, departureID: departureID)
            return true
        }
        // ⚠️ THE MIRROR, ON THIS PATH TOO — and it was set on only one of the
        // two, which is a plain slide.
        //
        // The hero refuses a landing it cannot draw
        // (`ForYouGridZoomSource.zoomLandingAcceptsHero`, false for a row the
        // list has not realized). Left `nil` here, this driver's own gate reads
        // `nil != false` as "the hero is taking it" and refuses as well — so
        // NEITHER claims the drag, no interactive pop is ever started, and the
        // screen leaves on UIKit's own edge-swipe animation. Filmed as the last
        // close of a run having no hero at all.
        //
        // Asked of THIS flight's own gate — see `heroLandingArbiter` for the
        // restatement it replaces, which sent every deep close on a slide.
        textSlideDismissal.heroLandingAcceptsHero = Self.heroLandingArbiter(asking: flightSource)
        // ⚠️ AND WHATEVER ANIMATED THE CLOSE, NO ROW STAYS HIDDEN.
        //
        // The concealment above is paid back by the reveal's own completion —
        // when the reveal is what runs. It is not the only thing that can: this
        // screen is closed by two grabs and by a back button, the preparation
        // above runs for all of them, and a pop that ends up animated by
        // anything else leaves the row it hid with nobody to put it back.
        //
        // Measured on a back-button close from a deep text landing: the row was
        // concealed, the close was animated by something that never ran the
        // reveal's completion, and the feed came back with a HOLE where the
        // post the viewer had just been reading should have been — permanently,
        // since nothing else on this screen ever revisits that flag.
        //
        // This is the backstop, not the mechanism: it fires on completed pops
        // only, by which point the grid is on screen and any row it still holds
        // hidden is a bug by definition.
        textSlideDismissal.onFeedPopped = { [weak self] _ in
            // Both concealments, because a close can be finished by a driver
            // that did not start it: the flight hides the tapped row's media at
            // the push and only its OWN return puts it back, so a visit that
            // ends on a text post — closed by the card driver — leaves that row
            // blank for good. See `clearHeroConcealment`.
            self?.page.clearRevealConcealment()
            self?.page.clearHeroConcealment()
            self?.cardPathFlight = nil
        }
        textSlideDismissal.install(on: navigationController)
    }

    /// Stages a card-shaped close for a feed a FLIGHT opened, once the viewer
    /// has paged onto a post with no media — the host half of
    /// `armAsCardCloseAlongsideFlight`, which has already decided that this is
    /// such a close and that it runs once.
    private func stageCardClose(feed: UIViewController, departureID: PostID) {
        // ⚠️ THE ROW THE WINDOW LANDS ON IS THE DEPARTURE, whatever post the
        // viewer paged to (#1283): a close comes home to the tapped tile, and
        // nothing in the grid moves to meet it.
        let landingID = departureID
        installTextReveal(feed: feed, postID: landingID, presenting: false)
        // ⚠️ AND HIDE THE ROW, which on this path nothing else has.
        //
        // A reveal normally conceals the row it departed from at the
        // OPENING — "the row goes the moment the window takes its place" —
        // and its close only puts it back. This screen was opened by a
        // FLIGHT, so no opening ever hid anything: without this the card
        // flies home over a grid already showing the same card, and the
        // landing has nothing to reveal. Measured as a close whose trace
        // carried a single `conceal=false` and no `conceal=true` at all.
        page.setRevealConcealed(true, for: landingID)
    }

    #if DEBUG
    /// Latches `-foryou-tab-away` (`scheduleTabAwayIfNeeded`) to a single firing.
    /// Internal (not private) only for the +QA hooks.
    var hasScheduledTabAway = false
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back from a post: its own list's session is over; the next opening
        // reads a fresh one (#1343).
        viewModel.ownFeed.end()
        // A tab root always shows the bar (#769).
        ensureAppTabBarAsTabRoot()
        // BELT (#758): no band here, so nothing for the bar's collapse to make
        // room for — whatever arm a screen left behind, the shell's own
        // behaviour comes back.
        SelectorAccessory.reconcileMinimize(in: tabBarController)
        // ⚠️ MEASURED WHILE THE BAR IS UP, because the one moment the reveal
        // needs the number is the one moment it cannot read it: a push takes
        // the bar down, and `applyPendingReveal` runs on the way out.
        tabBarController?.view.layoutIfNeeded()
        page.footChromeCover = floatingBarCover
        sweepAbandonedTransition()
        // ⚠️ NOTHING ON THIS SCREEN MAY BE INVISIBLE ONCE IT IS BACK.
        //
        // The concealments a close uses belong to a transition, and every one
        // of them is put back by the driver that applied it — when that driver
        // is the one that finishes. It often is not: the feed is a PAGER, so a
        // post opened by a FLIGHT (which hides the tapped row's media so the
        // card flies alone) can be closed by the CARD driver, whose return leg
        // knows nothing about a hide it did not make. The row came back with
        // its caption and a blank rectangle where its photograph belonged, and
        // it stayed that way — one more row per round trip that ended on
        // another kind of post. Reported after several iterations, which is
        // exactly how it accumulates.
        //
        // Tied to this moment rather than to a driver's callback because this
        // is the one fact all the paths share: the screen is on display again,
        // so no flight is in the air, so nothing here is legitimately hidden.
        // `viewDidAppear` lands after the transition coordinator has finished,
        // so it cannot race a landing. The rows' face and card included.
        page.clearRevealConcealment()
        page.clearHeroConcealment()
        friendsRow.clearConcealments()
        shelf.clearConcealments()
        // `viewWillAppear` is too early to be the only reconcile: no cell is
        // realized yet. This is the first moment both are true — surface
        // active, cells realized — so the reconcile here cannot be raced.
        page.setAutoplayActive(true)
        setLeadActive(true)
        // A row's flight is over: its card is one among others again.
        //
        // ⚠️ AFTER THE ROW IS ACTIVE, NEVER BEFORE. Closing the handoff
        // reconciles, and a reconcile of a row still inactive (covered since
        // `viewWillDisappear`) stops EVERY card — including the one the close
        // just handed the page's playback to (`adoptLandingPlayback`), which
        // the next line then restarted from its poster: the thumbnail flash,
        // a beat after the landing instead of at it. Active first, the handoff
        // still shields that card while the others start; closed second, the
        // card is simply chosen again and keeps the player it holds.
        shelf.endPlaybackHandoff()
        // ⚠️ THE RING CLEARS HERE, after the close has landed — not at the
        // tap: a close must fly home to the face as it was when it left.
        // Marking the posts seen puts the friend among the ones with nothing
        // unseen in the view model's order, but the row does NOT move them
        // while the viewer is still here (`FriendsStoriesRow.heldStoryOrder`);
        // only the ring goes. The re-sort waits until they leave the screen
        // (`viewDidDisappear`) or the app (`appDidEnterBackground`).
        if let viewed = viewedStoryPosts {
            viewedStoryPosts = nil
            viewModel.markStoryPostsSeen(viewed)
        }
        #if DEBUG
        scheduleTabAwayIfNeeded()
        #endif
    }

    /// The post has finished covering this screen, so anything that would
    /// have been a visible jump can happen now.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Deliberately here rather than at `viewWillDisappear`: that fires as
        // the transition BEGINS, and the list is visible behind an expanding
        // hero card for the whole flight. Moving it then is the jump this
        // avoids — just later in the animation.
        page.applyPendingReveal()
        // The screen left: what its like chips staked is final now, as a
        // post's stakes are once the feed pages away from it.
        staking?.endSession()
        // A story's feed has COVERED the screen — the push landed, so the
        // viewer is watching it. Only now do its posts count as viewed: a
        // push reversed mid-air never reaches here.
        if let opened = openedStoryPosts {
            openedStoryPosts = nil
            viewedStoryPosts = opened
        }
        // Still the top of its stack, so nothing was PUSHED over it: the
        // viewer went to another tab (or something full screen covered the
        // tab bar). They left the screen, so the Friends row may re-sort
        // before they are back. A push — a friend's posts, a list — is not
        // leaving: the row keeps the order they tapped from.
        if navigationController?.topViewController === self {
            friendsRow.releaseStoryOrder()
        }
    }

    @objc private func appDidEnterBackground() {
        friendsRow.releaseStoryOrder()
    }

    /// Suspends the list's and the rows' media when something covers them.
    ///
    /// A push of the FEED from the list keeps the flown post's player up on
    /// purpose (the flight owns it, and the handoff scope already stopped
    /// everything else); a push of anything else — a pushed list, the whole
    /// mosaic, a profile — covers this screen with players of its own that
    /// want the same pool, and nothing is flying. The stack's top separates a
    /// push from a tab switch: on a push it is already the pushed screen.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setLeadActive(false)
        if !(navigationController?.topViewController is any ZoomTransitionDestination) {
            page.setAutoplayActive(false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // No handoff open (a plain push, or an ordinary tab switch): sweep any
        // stranded park. A live transition owns its own scope and closes it in
        // `onSourceReturned`.
        if activeTransition == nil { page.discardPlaybackHandoff() }
        page.setAutoplayActive(true)
        // A row's flight is closing: the close measures where it lands as it
        // begins, and the row may have been scrolled under the open post — so
        // the face or card it flew from is brought back into view first.
        if let story = flyingStory { friendsRow.bringStoryIntoView(story) }
        if let card = flyingCard { shelf.bringCardIntoView(card) }
        // Coming back from the feed: this screen owns the bottom again.
        guard navigationController?.topViewController === self else { return }
        // WHEN is `TabBarRevealPolicy`'s, HOW is UIKit's. A tab switch back or
        // a still screen: now. A scrub — a grab, a swipe, a window's drag,
        // whether or not it closes the feed — runs this at pop-BEGIN, which is
        // a question and not yet an answer: at its release, and only if it
        // committed. A button-driven close of the feed: the feed already
        // showed the bar before its pop (`revealDockBeforePop`), and the
        // policy's after-the-landing answer is the backstop for a pop nobody
        // announced.
        revealBottomChromeWhenAllowed(
            returnsFromFullBleed: activeTransition != nil || isReturningFromDocklessScreen,
            animated: animated
        ) { [weak self] animated in
            self?.revealTabBar(animated: animated)
        }
    }

    /// Reveals the bar through UIKit, idempotently.
    ///
    /// Several owners can reach this on a return — the policy above, the
    /// feed's own close, the flight's and the window's backstops,
    /// `onFeedPopped` — and their order is not guaranteed. Whichever arrives
    /// first shows it; the rest find the bar already shown and do nothing. A
    /// bar stuck hidden is a far worse failure than a redundant call. Never an
    /// alpha.
    private func revealTabBar(animated: Bool) {
        guard let tabBarController, tabBarController.isTabBarHidden else { return }
        if animated {
            tabBarController.showTabBarNatively()
        } else {
            tabBarController.setTabBarHidden(false, animated: false)
        }
    }

    /// Releases a flight that ended by a route it never heard about.
    ///
    /// `activeTransition` is the "one flight at a time" latch `openFeed` checks,
    /// and it is cleared by the flight's own callbacks — `onSourceReturned` and
    /// `onPresentationCancelled`. Neither fires when the feed leaves the stack
    /// some other way: a screen pushed ABOVE it that pops to root, or a
    /// multi-pop that unwinds past it. The latch then stays set forever and
    /// `openFeed` returns early on every future tap.
    ///
    /// What that looks like is not a stuck transition — nothing is animating —
    /// but a list that scrolls perfectly and opens nothing, which is why it
    /// reads as broken selection rather than as navigation state. Found by the
    /// stress harness: after one round trip through a profile, every later
    /// cycle's tap left the stack depth unchanged.
    ///
    /// Safe in `viewDidAppear` specifically: a flight still in progress has not
    /// finished appearing, so reaching here with the latch set and this screen
    /// on top means there is nothing left to finish.
    private func sweepAbandonedTransition() {
        // A row's flight is the builder's, and ends the same way whatever
        // route it took: the screen is back. So is the list's inset, which a
        // row's close pinned (`ForYouRowOrigins`) and its own completion
        // normally hands back — this is the backstop for a close finished by
        // anything else.
        #if DEBUG
        if flyingStory != nil || flyingCard != nil { logRowSource("landed") }
        #endif
        // UNCONDITIONALLY: a grid flight freezes the inset too
        // (`zoomSourceWillStageDismissal`), and only a landing thaws it. A
        // cancelled grab keeps it frozen while the feed stays up — correctly —
        // so a feed that then left by another route (pop-to-root, a multi-pop)
        // left the grid on `.never` insets for good. Idempotent.
        page.endHeroFreeze()
        flyingStory = nil
        flyingCard = nil
        // A text visit's close-only flight ends with the visit, whoever ended it.
        cardPathFlight?.close(.abandoned)
        cardPathFlight = nil
        guard let activeSession, navigationController?.topViewController === self else {
            return
        }
        // The same close-out the flight's own endings run (the dock a turn
        // later, through UIKit: this runs in `viewDidAppear`, where an inline
        // un-hide was measured never to render). The session keeps its objects
        // a turn longer, so the `didShow` still on its way finds them alive and
        // closed rather than freed mid-transition.
        activeSession.close(.abandoned)
    }

    /// How much of this screen's foot the tab bar actually covers.
    ///
    /// The bar FLOATS — it draws over the list without insetting it — so the
    /// safe area understates it by the bar's own height. This file has carried
    /// that measurement in prose for a long time ("bar at y 791 height 83,
    /// while the grid reserves 34"); this is the same fact, asked of the bar
    /// rather than restated as a number that can go stale on the next device.
    private var floatingBarCover: CGFloat {
        guard let bar = tabBarController?.tabBar, !bar.isHidden, let host = bar.superview
        else { return view.safeAreaInsets.bottom }
        let inPage = view.convert(bar.frame, from: host)
        return max(view.safeAreaInsets.bottom, view.bounds.maxY - inPage.minY)
    }

    // MARK: - The rows

    /// The story a flight is carrying, and the card — what the close is
    /// flying home to, brought into view as it begins (`viewWillAppear`).
    private var flyingStory: ProfileID?
    private var flyingCard: PostID?
    /// The posts a story opened, until its feed has covered the screen
    /// (`viewDidDisappear`) — then they are `viewedStoryPosts`, marked seen
    /// once the close has landed (`viewDidAppear`).
    private var openedStoryPosts: [PostID]?
    private var viewedStoryPosts: [PostID]?

    /// Whether a row may open anything now: this screen on top, nothing in the
    /// air — a tap landing mid-transition must not stack a push on a pop.
    private var canOpenFromRow: Bool {
        guard activeTransition == nil, openPostHero != nil,
              let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil
        else { return false }
        return true
    }

    /// A friend's avatar was tapped: their posts, flown out of their FACE.
    ///
    /// ⚠️ A WINDOW, NEVER A FLIGHT (#1356). A face is the friend's avatar,
    /// not their post's picture: a flight cross-dissolved the one into the
    /// other, the avatar seen over the media as it grew. The post opens as a
    /// window out of the face's own outline, the page itself from the first
    /// frame, and closes onto the avatar's picture (`ForYouRowOrigins`).
    func openStory(_ story: ForYouViewModel.FriendStory) {
        guard canOpenFromRow, let openPostHero,
              let origin = ForYouRowOrigins.story(
                  story, friends: friendsRow, page: page, host: view,
                  largerFace: story.avatarURL.map { url in
                      { [imagePipeline] deliver in
                          Task { @MainActor in
                              guard let image = try? await imagePipeline.image(for: url, size: .px512) else { return }
                              deliver(image)
                          }
                      }
                  },
                  closeStaged: rowCloseStaged
              )
        else { return }
        flyingStory = story.authorID
        openedStoryPosts = story.posts.map(\.id)
        // Everything under the feed stops: it is about to be covered.
        page.setAutoplayActive(false)
        setLeadActive(false)
        openPostHero(self, origin, story.posts.map(\.id))
    }

    /// A Following card was tapped: the row's posts from it on, flown out of
    /// the card — a list row's media flight (`.listMedia`, the card's own
    /// corner), wearing the card's caption as furniture that fades as it grows.
    /// A text card opens as a window instead, the pushed lists' way, and every
    /// card carries that window for its close (`ForYouRowOrigins`).
    func openCard(at index: Int) { shelf.openCard(at: index) }

    /// The shelf opened a card: fly it.
    private func presentCard(_ open: PostShelfSection.Open) {
        guard let openPostHero else { return }
        flyingCard = open.post.id
        openPostHero(self, open.origin, open.stream.map(\.id))
    }

    /// What a row's close does once it has staged — nothing, but say where the
    /// item is under `-grab-log`.
    private var rowCloseStaged: () -> Void {
        #if DEBUG
        return { [weak self] in self?.logRowSource("close staged") }
        #else
        return {}
        #endif
    }

    #if DEBUG
    /// `-grab-log`: where the item a row's flight left from is, in the
    /// window — printed as the close is staged and again once it has landed,
    /// so a landing that misses its item reads as two different rects rather
    /// than as a feeling about a video.
    private func logRowSource(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-grab-log"), let window = view.window
        else { return }
        let rect: CGRect?
        let what: String
        if let flyingStory {
            rect = friendsRow.storyFrame(for: flyingStory, in: window)
            what = "story=\(flyingStory.rawValue)"
        } else if let flyingCard {
            rect = shelf.cardFrame(for: flyingCard, in: window)
            what = "card=\(flyingCard.rawValue)"
        } else {
            return
        }
        print("[rows] \(moment) \(what) source=\(rect.map { NSCoder.string(for: $0) } ?? "off screen")"
            + " list=\(page.debugInsetState)")
    }
    #endif

    /// A row's header: its whole list, pushed — Following is the tab it used
    /// to be, Friends the same screen over the friends' posts.
    func pushList(_ kind: ForYouPostListViewController.Kind) {
        guard activeTransition == nil,
              let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil
        else { return }
        let list = ForYouPostListViewController(
            kind: kind, imagePipeline: imagePipeline, videoPlayback: videoPlayback,
            staking: staking, header: makePushedHeader(), openPost: openPostHero
        )
        // The FOLLOWING timeline's next page, never Discover's (#566).
        list.onNearEnd = { [weak self] in self?.viewModel.loadNextPageIfNeeded(.following) }
        list.onWillDisplayPost = { [weak self] id in self?.viewModel.didShow(id) }
        list.hasMore = { [weak self] in self?.viewModel.hasMoreFollowingPages ?? false }
        list.onRefresh = { [weak self] in self?.viewModel.refresh() }
        list.onAuthorTapped = { [weak self] post in self?.openAuthor(of: post) }
        list.onWarmRequested = { [weak self] posts in self?.warmVisible(posts) }
        list.authorMenuActions = { [weak self] context in
            self?.authorMenuActions(for: context) ?? []
        }
        // What is loaded NOW, so the push shows the list rather than a
        // skeleton waiting for the next publish.
        if let lastSnapshot {
            switch kind {
            case .following: list.render(lastSnapshot.following, newPosts: lastSnapshot.followingNew)
            case .friends: list.render(lastSnapshot.friends, newPosts: lastSnapshot.friendsUnseen)
            case .popular: break  // the place page's, never pushed from here
            }
        }
        switch kind {
        case .following:
            followingList = list
            viewModel.followingListOpened()
        case .friends:
            friendsList = list
        case .popular:
            break
        }
        #if DEBUG
        // The two numbers the product rule says are one: the header's badge and
        // the list's "New" (0 when the list is one untitled run).
        if let lastSnapshot {
            let badge = kind == .following ? lastSnapshot.rails.followingBadge : lastSnapshot.rails.friendsBadge
            print("[qa] push-list \(kind.rawValue): badge=\(badge) new=\(list.debugNewSectionCount)"
                + " posts=\(list.posts.count)")
        }
        #endif
        navigationController.pushViewController(list, animated: true)
    }

    /// Warms the top of the corpus into the feed's post cache so a tile tap
    /// opens from memory instead of the network — the same trick Maps uses on
    /// viewport settle.
    private func prewarmVisible() {
        // The PAGE's order — the one the viewer sees and `openFeed` seeds from:
        // a list of every kind, with media pulled into chunks.
        let visible = Array(page.posts.prefix(12))
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        Task { [prewarm] in await prewarm(Array(ids)) }
        // TEXT posts also prefetch their first page of comments, and only text
        // posts do.
        //
        // A text post's page IS its comments — it opens straight into comment
        // layout — so without this the hero flight carries a skeleton and the
        // real rows swap in after landing. A media post opens onto its media
        // and its comments are a secondary surface, so warming those would be
        // a dozen extra requests to remove nothing visible.
        //
        // Before the tap is the only useful moment: the panel mounts during
        // `prepareForHeroPresentation`, in the same turn as the push, so a
        // fetch started there cannot land in time however light it is.
        // The PAGE's list, not the view model's: it is the list `openFeed`
        // indexes into, so warming from it means warming the post that will
        // actually be tapped.
        let onPage = page.posts.prefix(12)
        let textIDs = onPage.filter { $0.kind == .text }.map(\.id)
        guard !textIDs.isEmpty else { return }
        warm(textIDs, immediate: false)
    }

    /// Warms what the viewer can actually see — see
    /// `ForYouGridPage.onWarmRequested`, which decides WHEN by riding the
    /// autoplay reconcile and its fling gate.
    ///
    /// ⚠️ EVERY KIND NOW, not just text. The rule this replaces was sound when
    /// it was written — "a media post opens onto its media and its comments are
    /// a secondary surface, so warming those would be a dozen extra requests to
    /// remove nothing visible" — and the comment count broke it: pressing it
    /// opens a media post STRAIGHT INTO its thread, where an unwarmed page
    /// shows a skeleton for the length of the flight and resolves after it.
    ///
    /// What keeps the request count honest is no longer the kind but the
    /// VISIBILITY: the ahead-of-time pass above still warms text posts down the
    /// page, and everything else is warmed only once its card is on screen and
    /// the feed is not being flung.
    private func warmVisible(_ posts: [GalleryPost]) {
        warm(posts.map(\.id), immediate: true)
    }

    /// ⚠️ TWO QUEUES, AND THE DIFFERENCE IS THE WHOLE FEATURE.
    ///
    /// `immediate` is what the viewer is LOOKING AT: one task per post, started
    /// now. Serial is wrong here — the first version ran every warm through one
    /// `for` loop, so the post whose card filled the screen waited behind
    /// eleven others down the page and was still fetching when the chip was
    /// pressed. The trace says it plainly: `asking [… post-new-04]` with the
    /// opened post LAST.
    ///
    /// Everything else is a queue, and it claims an id only when it REACHES
    /// it. Claiming the whole batch up front is how the ahead-of-time pass
    /// starved the visible one: it had already put its name on every post on
    /// the page, so when a card came into view there was nothing left to ask
    /// for and nothing to jump the queue with.
    private func warm(_ ids: [PostID], immediate: Bool) {
        guard let prefetchTopComments else { return }
        #if DEBUG
        // `-warm-log`: what was asked for and when it answered. It exists to
        // tell "the warm never ran" from "the warm ran and the tap beat it" —
        // two failures that look identical on screen, both a skeleton.
        let trace = ProcessInfo.processInfo.arguments.contains("-warm-log")
        #endif
        guard immediate else {
            let queued = ids.filter { !warmedComments.contains($0) }
            guard !queued.isEmpty else { return }
            Task { @MainActor in
                for id in queued where self.warmedComments.insert(id).inserted {
                    #if DEBUG
                    if trace { print("[warm] queued \(id.rawValue)") }
                    #endif
                    await prefetchTopComments(id)
                }
            }
            return
        }
        for id in ids where warmedComments.insert(id).inserted {
            #if DEBUG
            if trace { print("[warm] asking \(id.rawValue)") }
            #endif
            Task {
                await prefetchTopComments(id)
                #if DEBUG
                if trace { print("[warm] ready \(id.rawValue)") }
                #endif
            }
        }
    }

    #if DEBUG
    /// Remaining automatic open→grab→return cycles for `-foryou-grab-cycles`.
    ///
    /// Internal (not private) only for the +QA hooks.
    static var remainingGrabCycles = 0

    /// `openFeed(at:)`, for the launch-argument hooks (+QA).
    func debugOpenFeed(at index: Int) { openFeed(at: index) }
    /// How much of the page the floating bar covers, for the hooks' insets (+QA).
    var debugFloatingBarCover: CGFloat { floatingBarCover }
    #endif
}

// MARK: - Tab re-tap (#1309)

extension ForYouViewController: TabReselectScrolling {
    /// The page back to its first row — the friends row and the shelves.
    func scrollToTopForTabReselect() {
        guard page.verticalOffset > 0.5 else { return }
        page.setVerticalOffset(0, animated: true)
    }
}
