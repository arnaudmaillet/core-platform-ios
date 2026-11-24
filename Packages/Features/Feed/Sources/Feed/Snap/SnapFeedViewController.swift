import CoreImage
import CoreStorage
import MediaCore
import CoreModels
import CoreNavigation
import Transitions
import DesignSystem
import EmoteKit
import EntityStore
import FeedInterface
import MediaPlayback
import MediaUI
import PostGrid
import PostSurfaces
import ShareSheet
import ThreadKit
import UIKit
import VoiceKitUI
import LaunchArguments

/// The full-screen, page-snapping timeline. Drives the *same* `FeedViewModel`
/// as the classic feed — pagination, likes, realtime, compose hand-off all come
/// for free; only the presentation differs. Its one net-new responsibility is
/// the active-page lifecycle (`SnapCellLifecycle`), the seam Phase 2's video
/// player plugs into.
final class SnapFeedViewController: UIViewController {
    private enum Section { case main }

    /// Internal (not private) only for the +QA hooks.
    let viewModel: FeedViewModel
    let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?

    /// Internal (not private) only for the +QA hooks.
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, PostID>!
    /// The timeline's empty and failed states (#797).
    private let statusView = EmptyStateView()

    /// The comments' Popular | Recent selector (#2007), beside the leading
    /// item while a thread that has the tabs holds the engaged chrome — bound
    /// to that thread's panel.
    let commentTabs = CommentTabsSelector()
    /// The back chevron's and the comments exit's identities (#1679): two
    /// items for UIKit, so the swap is its morph between them.
    static let backItemIdentifier = "feed.snap.back"

    /// The viewer's balance, closing the trailing run on its left —
    /// [‹ back] … [🪙 solde] [author pill] — so a spend made on this very
    /// screen is visibly paid for. DISPLAY-ONLY here: the map's badge is
    /// the claim entry point, this one just watches the store (same shared
    /// instance) and re-renders. Built only when a wallet is injected; a
    /// nil-wallet feed keeps its historical author-only run.
    let walletBadge = WalletBadgeButton()
    /// The nav bar's LEADING item at rest: the back arrow, when the feed was
    /// opened onto a stack it can leave (never on the tab root). Built on
    /// first appearance, when the stack relationship is finally knowable.
    private(set) var backItem: UIBarButtonItem?
    /// The viewer's saved pile.
    ///
    /// It used to be a `Set` on this screen, which meant a save survived
    /// exactly as long as the feed did and was visible to nothing else. The BFF
    /// still exposes no save API — but the profile now has a Saved tab, and two
    /// surfaces reading one list is precisely what a store is for. See
    /// `PostBookmarkStore` for what a client-owned list can and cannot claim.
    /// The app's one pile outside tests (#2376).
    let bookmarks: PostBookmarkStore
    /// The sounds the viewer saved, for the sound sheet (#2376).
    private let savedSounds: SavedSoundStore
    /// Keeps the save glyph on the saved fact of the post it draws (#1067):
    /// a save or unsave made on another surface — a card, a grid behind a
    /// sheet, the post's "..." elsewhere — writes the EntityStore's fact
    /// (`PostBookmarkStore`), and the glyph draws it at once: the cards'
    /// mechanism (`PostCardStaking`). One observation for the screen's life,
    /// filtered to `bookmarkGlyphPostID`: it ends with the screen, and a page
    /// paged away from is never the one it re-draws.
    private var savedObservation: EntityObservation?

    /// The viewer's point balance, spent by the rail's boost anchor.
    ///
    /// INJECTED, not created in place like `bookmarks`, because the map
    /// toolbar's currency badge watches the same instance — a spend here must
    /// move that number, and `WalletStore`'s change post is scoped to the
    /// instance that changed (see its doc). Nil (an unwired surface, or a
    /// unit-tested one) leaves the boost anchor visible but inert.
    private let wallet: (any WalletStaking)?
    /// Whether the bar wears the balance: not for a guest (#1146). The wallet
    /// still backs the rail's like, and its observer keeps the boost
    /// controls true once a guest signs up here.
    private let showsBalance: Bool
    /// Vends the wallet/claim sheet the header's balance badge presents —
    /// the SAME shell-owned sheet the map's badge opens, injected so the
    /// two entries can never diverge. Nil keeps the badge display-only.
    let makeWalletSheet: (@MainActor () -> UIViewController)?
    /// The stakes every like on this screen spends through (#2532): the
    /// pages' pills, the text page's footer like and the comments panels it
    /// embeds. Nil without a wallet: the likes stay visible but inert.
    let stakes: StakeSession?

    /// id → display model; lookups only, never measurement.
    /// The colour this screen wears while it has NO PAGES.
    ///
    /// ⚠️ A PROPERTY OF THE SCREEN, not a loan from the transition — and that
    /// distinction is the whole fix. A reveal already lends the page the tone
    /// of the card it opened from (`setRevealGroundTint`), but that loan is
    /// routed to `activeSnapCell?`, and on a cold open there IS no cell: a feed
    /// whose corpus missed the synchronous seed is pushed with zero items, so
    /// the write goes nowhere and the window opens onto the two literal blacks
    /// this screen used to paint at construction. Filmed from a map text pin as
    /// a black flash between the marker's face and the post, on the FIRST open
    /// of a pin and never on the second — because the first is what populates
    /// the cache the seed reads.
    ///
    /// And re-routing the loan would not have been enough: the transition hands
    /// the ground BACK (`setDestinationGround(nil)`) from inside the opening
    /// spring, so a borrowed colour is returned mid-window. What `nil` resolves
    /// to has to be right on its own, and with no data there is no format to
    /// derive it from. Hence a stored default, set from the route that opened
    /// this screen, before anything is known about what it will show.
    ///
    /// `.black` by default, so every route that does not lend one is byte for
    /// byte what it was.
    private var emptyGround: UIColor = .black
    private(set) var modelsByID: [PostID: FeedItemDisplayModel] = [:]
    /// Internal (not private) only for the +QA hooks.
    private(set) var orderedIDs: [PostID] = []

    private(set) var lifecycle = SnapLifecycleDispatcher()
    /// The post the active page shows — what a reorder must not re-activate
    /// (#1580, `updateActiveItem`).
    private var lifecycleActiveID: PostID?
    /// The items are being swapped under the post on show (`render`): the
    /// pager's index means nothing until it is re-placed on that post.
    private(set) var isReplacingItems = false
    /// The post on show and the surface its clip drew on as the items were
    /// swapped — for the page that shows it next to adopt (#1580).
    private(set) var reorderHeld: (id: PostID, surface: VideoRenderView?)?
    /// The cell that showed the post on show as the items were swapped: it
    /// kept its comment surfaces running for it (#1798).
    weak var reorderHeldCell: SnapFeedCell?
    /// The flight flags, and what derives from them (`SnapFlightPhase`):
    /// re-stated on every present, because this controller is reused.
    var flight = SnapFlightPhase() {
        didSet {
            // The flight is over, one way or another: a text page that stood
            // on its placeholder gets its real panel now (charter PR 5b).
            if !flight.isAwaitingZoomPresentation, oldValue.isAwaitingZoomPresentation {
                commentsCoordinator.landDeferredRestingComments()
            }
        }
    }

    /// `-defer-resting-comments` (DEBUG): a text page arriving by a flight
    /// shows a placeholder where its comments panel will be, and mounts the
    /// panel once the flight has landed — instead of building a whole
    /// `PostDetailViewController` inside the turn that sets the flight up.
    /// Off by default until the film and the number say otherwise.
    static var defersRestingCommentsForFlight: Bool {
        #if DEBUG
        LaunchArgument.deferRestingComments.isPassed()
        #else
        false
        #endif
    }

    /// A text reveal is about to push this screen (`SnapFlightPhase`).
    /// Internal for tests.
    var isAwaitingRevealPresentation: Bool { flight.isAwaitingRevealPresentation }

    public func beginRevealPresentation() {
        // ⚠️ AN OPENING ONLY. The installer that calls this also builds every
        // card-shaped CLOSE's geometry, and a close is staged while this screen
        // is on screen. Raised there, nothing lowered it (the feed never
        // reappears after a committed close), and For You reuses this
        // controller: the next opening replayed the comment band's entrance,
        // deferred the author pill and skipped the comments prewarm. An
        // opening is the one case where the screen is not yet in a window.
        guard viewIfLoaded?.window == nil else { return }
        flight.isAwaitingRevealPresentation = true
    }

    /// Set by whoever pushes this screen, on both paths (`SnapFlightPhase`).
    public var zoomOwnsInteractiveDismissal: Bool {
        get { flight.zoomOwnsInteractiveDismissal }
        set { flight.zoomOwnsInteractiveDismissal = newValue }
    }

    /// The two facts whose AND is the surface's visibility.
    private(set) var isOnScreen = false
    /// What is heard, the song, the records' spin, the share of the screen,
    /// Background Play and Picture in Picture (`SnapSoundPlayback`). Built on
    /// first use; building it does nothing else.
    private(set) lazy var soundPlayback = SnapSoundPlayback(
        host: self, videoPlayback: videoPlayback, imagePipeline: imagePipeline, soundState: soundState
    )
    /// Whether the pages' lifecycle counts the screen as watched — what lets
    /// the post on show play. Internal for tests.
    var debugIsWatchedByLifecycle: Bool { lifecycle.isVisible }
    /// Unregisters its notification tokens when this VC (and thus the bag) is
    /// released — a nonisolated deinit can't touch the VC's main-actor state.
    private let appObservers = NotificationTokens()
    /// Builds the comments panel's content (the comments-only detail) for a
    /// post — injected by the feature builder so this VC needs none of the
    /// detail's dependencies. Nil disables the comments engagement.
    let makeCommentsPanelContent: ((PostID) -> UIViewController)?
    /// The panel for a TEXT page's resting interface: the day pills and the
    /// lifted menu belong to text posts only. Nil — the default, and every
    /// test host — means text pages build `makeCommentsPanelContent`.
    let makeRestingCommentsPanelContent: ((PostID) -> UIViewController)?
    /// The post whose comments engagement is active, nil when disengaged.
    /// Owns the paging veto: the pager is frozen while the mutated layout
    /// (a per-cell state) is on screen.
    /// Turns the stack's own edge recognizer OFF while this screen is up, and
    /// puts it back exactly as it was on the way out.
    ///
    /// ⚠️ REFUSING a recognizer is not the same as disabling it, and the
    /// difference is a whole gesture.
    ///
    /// `NativePopPolicy` already answers "no" for this screen — it owns its
    /// dismissal — so the native pop never pops. But a refused
    /// `UIScreenEdgePanGestureRecognizer` is still armed: it takes the touches
    /// in the leading strip while it decides, and the grab's own pan is never
    /// consulted. Measured with `-grab-log`: a drag from x=12 produced no begin
    /// decision at all, while the same drag at x=200 produced one. On a post
    /// with no carousel as well as on a collection — the strip has never worked
    /// on this screen, which is why the first attempt at this bug was aimed at
    /// the carousel and changed nothing.
    ///
    /// Restored rather than assigned back to `true`: the stack's gesture is not
    /// ours, and whatever pushed us may have had its own opinion.
    private func setNativePopSuppressed(_ suppressed: Bool) {
        guard let pop = navigationController?.interactivePopGestureRecognizer else { return }
        if suppressed {
            guard restoredPopGestureEnabled == nil else { return }
            restoredPopGestureEnabled = pop.isEnabled
            pop.isEnabled = false
        } else if let restored = restoredPopGestureEnabled {
            pop.isEnabled = restored
            restoredPopGestureEnabled = nil
        }
    }

    /// What the stack's edge recognizer was before this screen turned it off.
    private var restoredPopGestureEnabled: Bool?

    /// The viewer paged a post's collection.
    ///
    /// Reported OUT so the surface that opened this feed can follow. It is what
    /// keeps the dismissal honest: the flight home departs from the post's
    /// CURRENT photograph and lands on the card's media rect, so a card still
    /// showing page one would land photograph B on photograph A's frame — the
    /// wrong image swapping for the right one at the last frame, which is the
    /// same class of defect as a stale stand-in.
    public var onMediaPageChanged: ((PostID, Int) -> Void)?

    /// The side list (#1425): nil on a screen that opted out.
    private(set) var sideList: SnapSideListController?
    /// The screen's horizontal swipe chain (#1525) — see `swipeStage`.
    private(set) var swipeArbiter: SwipeStageArbiter?
    /// A pull past either end of the side list closes it (#1580).
    private(set) var sideListEdgePull: SnapSideListEdgePull?
    #if DEBUG
    /// Every post activated, in order. Tests.
    var debugActivations: [PostID] = []
    #endif
    /// Whether this screen installs the side list — every vertical feed does
    /// (#1473); a test sets its own before the view loads.
    var installsSideList = true
    /// The current posts the side list samples from (#1425). Nil: an empty
    /// list.
    public var sideListEntries: (@MainActor () async -> [FeedEntry])?
    /// The share sheet's quick-send row (#1710): the people the viewer can
    /// send a post to — the profile sheet's own source, handed in.
    var shareTargeting: (any ShareTargeting)?
    /// The one owner of the pager's `isScrollEnabled`: the sheet, the
    /// resting panel and a dismissal grab each hold it for a reason of their
    /// own (`SnapPagerScrollLock`). Built on first use.
    private(set) lazy var pagerScrollLock = SnapPagerScrollLock { [weak self] in self?.collectionView }
    /// Every page whose media carousel the content freeze holds (#1738).
    let carouselFreeze = CarouselFreezeLedger<SnapFeedCell>()
    /// The page drive and the pull to go back (`SnapPagerDrive`). Built on
    /// first use; building it does nothing else.
    private(set) lazy var pagerDrive = SnapPagerDrive(host: self)
    /// The resting panel, the warms, the loading page and the sheet's launch
    /// (`SnapCommentsCoordinator`). Built on first use; building it does
    /// nothing else.
    private(set) lazy var commentsCoordinator = SnapCommentsCoordinator(host: self)
    /// The hero destination: the flight's replica, the lent live surface,
    /// the grab, the landing and the dismissal gates (`SnapZoomDestination`).
    /// Built on first use; building it does nothing else.
    private(set) lazy var zoomDestination = SnapZoomDestination(host: self)
    /// The bottom toolbar: its one set of items, their faces for the page in
    /// front and the bar's presence (`SnapToolbarComposer`), the only writer of
    /// `toolbarItems`. Built on first use; building it does nothing else.
    private(set) lazy var toolbarComposer = SnapToolbarComposer(host: self)
    /// The author pill: the pill itself, its landing install, the follow,
    /// both bars' pill widths and the comments' day (`SnapAuthorBar`). Built
    /// on first use; building it does nothing else.
    private(set) lazy var authorBar = SnapAuthorBar(host: self)
    /// What the bars and the page's chrome wear for the settled page
    /// (`SnapSettledPageChrome`). Built on first use; building it does
    /// nothing else.
    private(set) lazy var settledPageChrome = SnapSettledPageChrome(host: self, soundState: soundState)
    /// The device's appearance heard on the window, for the text pages built
    /// ahead (`SnapDeviceAppearanceWatch`). Built on first use; building it
    /// does nothing else.
    private(set) lazy var deviceAppearanceWatch = SnapDeviceAppearanceWatch(host: self)
    /// How far the pager may go: page readiness and the ceiling
    /// (`SnapPageReadiness`). Built on first use; building it does nothing
    /// else.
    private(set) lazy var pageReadiness = SnapPageReadiness(host: self)
    /// The no-post loader and the paging footer (`SnapPageLoaders`). Built on
    /// first use; building it does nothing else.
    private(set) lazy var pageLoaders = SnapPageLoaders(host: self)
    /// The text reveal's veil and borrowed author band (`SnapRevealScenery`).
    /// Built on first use; building it does nothing else.
    private(set) lazy var revealScenery = SnapRevealScenery(host: self)
    /// The opener's one-shot requests: a carousel's page, the comments open
    /// (`SnapOpeningRequests`). Built on first use; building it does nothing
    /// else.
    private(set) lazy var openingRequests = SnapOpeningRequests(host: self)
    /// The navigation bar: its appearance, both runs, the engaged chrome's
    /// switch and the sort's availability (`SnapNavigationBarComposer`), the
    /// only writer of the navigation items. Built on first use; building it
    /// does nothing else.
    private(set) lazy var navigationBarComposer = SnapNavigationBarComposer(
        host: self, wallet: wallet, showsBalance: showsBalance
    )
    /// The side list's session and the swipe chain (`SnapSideListSession`).
    /// Built on first use; building it does nothing else.
    private(set) lazy var sideListSession = SnapSideListSession(host: self, videoPlayback: videoPlayback)
    /// The share sheet and its chips: Repost, Not interested, Report
    /// (`SnapPostActions`). Built on first use; building it does nothing
    /// else.
    private(set) lazy var postActions = SnapPostActions(host: self, reporting: reporting)
    /// The warms around the settled page, and what is let go while the feed
    /// is not watched (`SnapWarmPlanner`). Built on first use; building it
    /// does nothing else.
    private(set) lazy var warmPlanner = SnapWarmPlanner(host: self, videoPlayback: videoPlayback)
    /// The page's theme lent to the shared bars and blurs, and handed back on
    /// the way out (`SnapChromeThemeLender`). Built on first use; building it
    /// does nothing else.
    private(set) lazy var chromeThemeLender = SnapChromeThemeLender(host: self)
    /// The sound sheet: its sections and tiles, what it covers and pauses,
    /// and the post a tile brings to the screen (`SnapSoundSheetPresenter`).
    /// Built on first use; building it does nothing else.
    private(set) lazy var soundSheetPresenter = SnapSoundSheetPresenter(
        host: self, soundState: soundState, savedSounds: savedSounds, videoPlayback: videoPlayback,
        useSound: useSound, openFeedHero: openFeedHero, galleryPost: galleryPost, prewarmPosts: prewarmPosts
    )
    #if DEBUG
    /// The launch-argument hooks `viewDidAppear` arms (`SnapFeedDebugHooks`).
    /// Built on first use; building it does nothing else.
    private(set) lazy var debugHooks = SnapFeedDebugHooks(host: self)
    #endif

    /// Files a post's Report. Nil withholds the row entirely: an action that
    /// cannot act is not offered — the grid's card menu follows the same rule.
    private let reporting: (any ContentReporting)?
    /// Where the viewer stands with each author, and the pill's "+" follow —
    /// see `SnapAuthorFollowStore`. Internal for tests.
    let followStore: SnapAuthorFollowStore
    /// Keeps `followStore` agreeing with a follow or unfollow
    /// accepted ANYWHERE — the author's own profile pushed from this pill, a
    /// card's Unfollow — for the screen's life (`FollowGraphEvents`). Nil
    /// without a channel, and then a return re-asks instead.
    private var followSubscription: FollowGraphSubscription?
    /// The page's sound: which sound a post is set to, what it draws, what is
    /// heard, and the sound sheet's inputs (`SnapSoundState`), over
    /// `FeedFeatureBuilder.soundProvider`.
    private let soundState: SnapSoundState
    /// See `FeedFeatureBuilder.useSound`.
    private let useSound: (@MainActor (PostSound) -> Void)?
    /// Opens a new feed with the hero — the sound sheet's grid uses it.
    private let openFeedHero: (@MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    private let galleryPost: (@MainActor (PostID) -> GalleryPost?)?
    /// Loads posts into the repository's cache, after which `galleryPost`
    /// answers for them — the sound sheet's tiles outside this feed.
    private let prewarmPosts: (@Sendable ([PostID]) async -> Void)?
    /// Warms the first comments of the posts this feed lists beside its own:
    /// the side list's, the sound sheet's (#2002).
    var postOpenWarm: PostOpenWarm?

    init(
        viewModel: FeedViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeCommentsPanelContent: ((PostID) -> UIViewController)? = nil,
        makeRestingCommentsPanelContent: ((PostID) -> UIViewController)? = nil,
        wallet: (any WalletStaking)? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        showsBalance: Bool = true,
        reporting: (any ContentReporting)? = nil,
        socialGraph: (any SocialGraphWriting)? = nil,
        followRelations: (any SocialGraphReading)? = nil,
        followEvents: FollowGraphEvents? = nil,
        entities: any EntityReading & EntityWriting = EntityStore(),
        bookmarks: PostBookmarkStore,
        savedSounds: SavedSoundStore,
        viewer: @escaping @MainActor () -> ProfileID?,
        soundProvider: (any PostSoundProviding)? = nil,
        useSound: (@MainActor (PostSound) -> Void)? = nil,
        openFeedHero: (@MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)? = nil,
        galleryPost: (@MainActor (PostID) -> GalleryPost?)? = nil,
        prewarmPosts: (@Sendable ([PostID]) async -> Void)? = nil
    ) {
        self.prewarmPosts = prewarmPosts
        self.soundState = SnapSoundState(provider: soundProvider)
        self.useSound = useSound
        self.openFeedHero = openFeedHero
        self.galleryPost = galleryPost
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.makeCommentsPanelContent = makeCommentsPanelContent
        self.makeRestingCommentsPanelContent = makeRestingCommentsPanelContent
        self.wallet = wallet
        self.stakes = wallet.map { StakeSession(wallet: $0) }
        self.makeWalletSheet = makeWalletSheet
        self.showsBalance = showsBalance
        self.reporting = reporting
        self.followStore = SnapAuthorFollowStore(
            writer: socialGraph, reader: followRelations, entities: entities, viewer: viewer
        )
        self.bookmarks = bookmarks
        self.savedSounds = savedSounds
        super.init(nibName: nil, bundle: nil)
        savedObservation = entities.observePosts { [weak self] change in
            // The footer like's count moves with the store (#1924).
            if let self, let id = self.toolbarComposer.footerLikeFace?.id, change.contains(id) {
                self.toolbarComposer.refreshFooterLike(for: self.modelsByID[id], animated: true)
            }
            guard let self, let id = self.toolbarComposer.bookmarkGlyphPostID, change.contains(id) else { return }
            // The post's counts move here too (a realtime tick): only a
            // changed save re-draws.
            let saved = self.bookmarks.isSaved(id.rawValue)
            guard SnapToolbarComposer.bookmarkSymbol(saved: saved) != self.toolbarComposer.drawnBookmarkSymbol else {
                return
            }
            self.toolbarComposer.refreshBookmarkGlyph(for: id)
        }
        // Every pill showing an author — the page's rows and the bar's —
        // through one binding (#1972).
        followStore.onRelationChange = { [weak self] author in
            self?.authorBar.authorBadges.relationDidChange(for: author)
        }
        followStore.onEveryRelationChange = { [weak self] in
            self?.authorBar.authorBadges.viewerDidChange()
        }
        followSubscription = followEvents?.subscribeOnMain { [weak self] change in
            self?.followStore.graphDidChange(change)
        }
        // The footer like wears the stake too; the pages' pills are bound.
        self.stakes?.onChange = { [weak self] in
            guard let self, isViewLoaded else { return }
            toolbarComposer.refreshFooterLike(for: activeModel, animated: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        LaunchTimeline.mark("snap.viewDidLoad")
        title = "Timeline"
        // The stored value, not a literal: `setEmptyGround` may legitimately
        // arrive BEFORE this runs — the map route loads this view while it
        // builds the dismissal, ahead of the reveal geometry.
        view.backgroundColor = emptyGround
        configureCollectionView()
        #if DEBUG
        // The comments sheet's catalogue checked at launch (#2195 § 5): read
        // here, a broken one fails its assertion before any sheet opens.
        _ = CommentsSheetShape.catalogue
        #endif
        if installsSideList {
            let sideList = SnapSideListController(host: self, imagePipeline: imagePipeline, videoPlayback: videoPlayback)
            sideList.install(in: view)
            self.sideList = sideList
            // The leftward swipe chain (#1525): the side list on a media
            // post, then the shown post's author.
            let arbiter = SwipeStageArbiter(host: self)
            arbiter.install(in: view)
            swipeArbiter = arbiter
            let edgePull = SnapSideListEdgePull(host: self)
            edgePull.install(in: view, pager: collectionView)
            sideListEdgePull = edgePull
        }
        navigationBarComposer.configureNavigationItem()
        toolbarComposer.configureToolbarItems()
        configureStatusLabel()
        observeAppLifecycle()

        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        // A post learnt unavailable on ANOTHER surface leaves this feed's
        // pages too (#2048) — at once, but for the page on show.
        unavailableObservation = viewModel.unavailablePosts.onChange { [weak self] _ in
            guard let self else { return }
            self.viewModel.dropUnavailable(except: self.activePostID)
        }
        // The like pill's count is the post's live one (#896): a like placed
        // on a card, in the comments bar or on this rail, a realtime tick —
        // whoever moved it, the page showing the post re-draws it.
        viewModel.onEngagementChange = { [weak self] id, _ in
            self?.refreshLikeCount(for: id)
        }
        viewModel.onCommentStreamsChange = { [weak self] id, streams in
            self?.updateVisibleStreams(for: id, streams: streams)
        }
        viewModel.onOwnPostInserted = { [weak self] in
            // Reveal the viewer's just-posted item: a prepend on a full-screen
            // pager otherwise shifts it above the viewport. Defer so the
            // snapshot apply lands first.
            //
            // ⚠️ THE SETTLE BELONGS TO THE END OF THE SCROLL, NOT ITS START.
            // Settling straight after an animated `scrollToItem` read the
            // offset the animation had not moved yet: the picture followed
            // the pager to the new post (`scrollViewDidScroll`), and the bar,
            // the ticker and the lifecycle stayed on the page it left until
            // the viewer scrolled by hand. An animated scroll settles in
            // `scrollViewDidEndScrollingAnimation`; one with nothing to move
            // (already on the first page) or off-window settles here.
            DispatchQueue.main.async {
                guard let self, !self.orderedIDs.isEmpty else { return }
                let first = IndexPath(item: 0, section: 0)
                let onFirstPage = SnapActiveItemTracker.activeIndex(
                    contentOffsetY: self.collectionView.contentOffset.y,
                    pageHeight: self.collectionView.bounds.height,
                    itemCount: self.orderedIDs.count
                ) == 0
                if onFirstPage || self.view.window == nil {
                    self.collectionView.scrollToItem(at: first, at: .top, animated: false)
                    self.updateActiveItem()
                } else {
                    self.collectionView.scrollToItem(at: first, at: .top, animated: true)
                }
            }
        }
    }

    private var didStartLoading = false
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sideList?.relayout()
        // The pills' widths are shares of the BARS' widths, and the bars are
        // not guaranteed to have one when the items are first built (nor when
        // a text page's resting engagement mounts from `willDisplay`) — a
        // width computed against zero is no width at all. Re-applied here,
        // where the width is real, and wherever it moves (rotation). Idempotent:
        // an unchanged width writes nothing, so a settled page pays nothing.
        authorBar.applyBarPillWidths()
        // A material arrives through `effect` and cannot be built without a
        // window. This pass runs inside the present animator's own
        // `layoutIfNeeded`, which is the first moment there is one — and still
        // before the opening pose is applied.
        if let frost = commentsCoordinator.loadingPageFrost, frost.effect == nil, view.window != nil {
            frost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
        if !didStartLoading, view.bounds.width > 0 {
            didStartLoading = true
            // The view model says nothing until a page lands: the loader is
            // armed here, for a feed that opens on no post (#1765).
            if orderedIDs.isEmpty { pageLoaders.setFirstPageWaiting(true) }
            viewModel.viewDidLoad()
        }
    }

    /// True when this feed was opened *onto* another surface — pushed above
    /// the map, or presented — rather than being a tab root. That's the case
    /// that owns a back item and can be closed.
    /// Whether this feed has been on screen before — what tells a RETURN to
    /// it from its first arrival.
    private var hasAppeared = false

    /// ⚠️ **A VERTICAL FEED NEVER STANDS OVER THE TAB BAR.**
    ///
    /// Filmed on a device, reproduced on the simulator with chevrons alone:
    /// map → post → its author's profile → one of their posts → back → back.
    /// The feed hides the dock BY HAND (not `hidesBottomBarWhenPushed`, whose
    /// choreography does not scrub with its custom pop), so when the pushed
    /// profile, which does set that flag, is popped, UIKit hands the dock
    /// back to the screen beneath as if it wanted one — and the FIRST feed
    /// stood under the bar with nothing to take it away.
    /// Rather than teach every path that can raise the dock where it is going,
    /// the feed asserts the invariant itself whenever it comes back: the bar
    /// leaves with the transition (scrubbed with an interactive pop, and put
    /// back if the pop is cancelled, since the screen that stays owns it).
    ///
    /// ⚠️ **"CANCELLED" MEANS TWO OPPOSITE THINGS HERE.** UIKit calls this
    /// screen's `viewWillAppear` both when a pop TO it begins (a profile above
    /// it leaving) and when a pop OF it is abandoned (a grab-down released under
    /// the threshold — the feed springs back and "re-appears"). The same
    /// cancelled flag then says "the feed did not come back" in the first case
    /// and "the feed never left" in the second. Reading it as the first in both
    /// is what put the dock back over a feed whose own dismissal had been
    /// abandoned (filmed on a device: page onto a text post, grab down, let go).
    /// So the bar goes back only when the abandoned transition was ARRIVING here.
    private func retireTabBarOnReturn() {
        guard isClosable, !barIsUIKitsByFlag,
              let tabBarController, !tabBarController.isTabBarHidden else { return }
        guard let coordinator = transitionCoordinator else {
            tabBarController.setTabBarHidden(true, animated: false)
            return
        }
        let arriving = coordinator.viewController(forKey: .to) === self
            || coordinator.viewController(forKey: .to) === navigationController
        coordinator.animate(alongsideTransition: { _ in
            tabBarController.setTabBarHidden(true, animated: false)
        }, completion: { context in
            // A return TO the feed that was abandoned: the screen that stays
            // owns the bar. Anything else leaves the feed on screen, bar-less.
            guard context.isCancelled, arriving else { return }
            tabBarController.setTabBarHidden(false, animated: false)
        })
    }

    /// The last word after an ABANDONED dismissal of this feed: once every
    /// party's completion has run (one turn later — theirs are registered on
    /// the same coordinator and can reveal the dock for the screen they
    /// expected to land on), a feed still on top and on screen has no dock.
    private func assertNoTabBarAfterAbandonedDismissal() {
        guard let coordinator = transitionCoordinator,
              coordinator.viewController(forKey: .from) === self
                || coordinator.viewController(forKey: .from) === navigationController else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, isClosable, !barIsUIKitsByFlag, view.window != nil,
                      navigationController?.topViewController === self,
                      let tabBarController else { return }
                // Through UIKit, on its animation: native chrome is never
                // hidden by hand (see `TabBarRevealPolicy`).
                tabBarController.hideTabBarNatively()
            }
        }
    }

    /// A screen beneath this feed was pushed with `hidesBottomBarWhenPushed`
    /// (a profile over a conversation): the bar is UIKit's, and an explicit
    /// hide here would outlive every pop back to the tab's root (#769).
    private var barIsUIKitsByFlag: Bool {
        navigationController?.flagHidesAppTabBar(at: self) ?? false
    }

    var isClosable: Bool {
        if presentingViewController != nil { return true }
        guard let nav = navigationController else { return false }
        return nav.viewControllers.first !== self
    }

    /// The chevron is about to close this screen.
    ///
    /// ⚠️ A TAP HAS NO "BEGIN". A dragged close announces itself through the
    /// dismissal's `onWillBeginPop`, and owners use that moment to restage
    /// things while nothing is in flight. That hook has a single caller,
    /// `beginSwipe`, so the chevron reached none of it and the same work
    /// landed inside the transition instead, where it does not take. This is
    /// the tap's equivalent, and it runs at the same point in the story.
    var onWillCloseFeed: (() -> Void)?

    /// Leaves the feed the way it arrived: pop when pushed (runs the
    /// interactive-capable zoom-out on the map's stack), dismiss when
    /// presented.
    func closeFeed() {
        #if DEBUG
        // `-grab-log`: a chevron tap, and whether the stack could act on it —
        // a pop asked for while a transition is still running is dropped by
        // UIKit without a word, which reads as "the chevron needed two taps".
        if LaunchArgument.grabLog.isPassed() {
            print(String(format: "[close] %.3f chevron top=%@ coordinator=%@", CACurrentMediaTime(),
                         navigationController?.topViewController === self ? "self" : "other",
                         navigationController?.transitionCoordinator == nil ? "none" : "LIVE"))
        }
        #endif
        // ⚠️ NOT WHILE A TRANSITION RUNS. UIKit drops a pop requested
        // mid-transition, silently, but everything before it here already ran:
        // the dock rose for a close that never happened (and stayed over the
        // feed when it was the present still landing), and the owner restaged
        // for it. The chevron is simply not live until the stack is at rest —
        // nor while the arbiter's own close of it is landing: a double tap's
        // second half, a turn before any coordinator exists (#1144).
        if let nav = navigationController, nav.isTransitioningItsStack || nav.arbiter.isPending { return }
        onWillCloseFeed?()
        if let nav = navigationController, nav.viewControllers.first !== self {
            revealDockBeforePop(on: nav)
            nav.arbiter.close(self)
        } else {
            closePresentation()
        }
    }

    // MARK: - The dock, on the way out

    /// ⚠️ **A CLOSE OF THIS FEED BRINGS THE DOCK BACK, AND THE FEED SAYS SO
    /// ITSELF — THROUGH UIKIT.** Native chrome is UIKit's (see
    /// `TabBarRevealPolicy`): the bar is shown with `setTabBarHidden(false,
    /// animated: true)` and UIKit animates it, alongside the return; nobody
    /// writes its alpha, and it is no longer held back for the landing. It
    /// used to be — restored at alpha 0 before the pop by each of five owners
    /// (For You, the profile's and the place page's builder, the map, the
    /// window) and flipped to 1 at their landings, which is what the viewer
    /// saw arrive late (video 3 of 2026-09-28, Activity → post → close).
    ///
    /// Owned here rather than by each screen that opens a post, because every
    /// one of those closes is a close of THIS screen, and a surface that forgot
    /// to wire it was a surface with no dock. The owners keep their idempotent
    /// landing backstops.
    ///
    /// Two moments, because a close is committed at two different times:
    /// - a TAP (`closeFeed`) is committed the moment it happens, so the bar
    ///   comes back BEFORE the pop is triggered — outside any transition. A bar
    ///   un-hidden inside a button-driven pop comes back as a state every API
    ///   reports as shown and nothing draws (measured on For You, the map and
    ///   the place page);
    /// - a DRAG is a question until the finger lifts: the bar comes back at a
    ///   COMMITTED release (`revealDockWhenCloseCommits`), and never for one
    ///   that springs back.
    ///
    /// ⚠️ NOT WHEN UIKIT OWNS IT. A feed pushed with `hidesBottomBarWhenPushed`
    /// (a routed feed, the map's defensive plain push) gets its dock back from
    /// UIKit's own pop; a landing that shows no dock (another feed, a pushed
    /// profile) gets none — `UINavigationController.showsAppTabBar(for:)`.
    func revealDockBeforePop(on nav: UINavigationController) {
        guard !hidesBottomBarWhenPushed, nav.topViewController === self,
              let index = nav.viewControllers.firstIndex(of: self), index > 0,
              nav.showsAppTabBar(for: nav.viewControllers[index - 1])
        else { return }
        tabBarController?.showTabBarNatively()
    }

    /// The DRAG's half of `revealDockBeforePop`, registered from
    /// `viewWillDisappear` — which UIKit runs at the pop's begin for every
    /// driver (the flight's grab, a window's drag, a slide), with the pop's
    /// coordinator in hand. A tap's pop reaches here too, already revealed; a
    /// pop nobody announced (a route, a scripted pop) gets its dock after the
    /// landing, through the coordinator's completion.
    private func revealDockWhenCloseCommits() {
        guard !hidesBottomBarWhenPushed, isMovingFromParent,
              let coordinator = transitionCoordinator,
              let nav = navigationController,
              nav.showsAppTabBar(for: coordinator.viewController(forKey: .to))
        else { return }
        let tabs = tabBarController
        coordinator.whenCommitted { [weak tabs] in
            tabs?.showTabBarNatively()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // On screen again (a return, a cancelled grab): the bars may be lent.
        chromeThemeLender.resumeLending()
        // A RETURN (a pop back from a profile, a sheet gone), never the first
        // arrival: that one is the opening's, whose owner hides the dock
        // through UIKit as it pushes.
        if hasAppeared { retireTabBarOnReturn() }
        // A return may follow a follow made elsewhere — on the author's own
        // profile, pushed from this pill. With the channel wired that change
        // has already been HEARD (`SnapAuthorFollowStore.graphDidChange`); without one, ask
        // again for the author on the pill. Either answer lands through the
        // landing install.
        if hasAppeared, followSubscription == nil, let author = authorIdentityView.shownAuthor?.authorID {
            followStore.resolve(for: author, refresh: true)
        }
        // The back item exists only when there is somewhere to go back to — a
        // map-opened feed, not the Timeline tab root — and the stack/
        // presentation relationship is known only here, not at viewDidLoad.
        if isClosable, backItem == nil {
            backItem = BarItems.icon(
                id: Self.backItemIdentifier, image: UIImage(systemName: "chevron.backward"), label: "Back"
            ) { [weak self] in self?.closeFeed() }
        }
        // Install through the same resolver the engagement uses, so
        // re-appearing under a text page's engagement keeps its sort.
        navigationBarComposer.applyLeadingNavItem(engaged: commentsEngagedID != nil, hasMedia: false, animated: false)
        toolbarComposer.presentToolbar()
        // Re-borrow the bars for whatever page is settled: they are shared,
        // and anything pushed on top has since reset them.
        //
        // ⚠️ THE ARRIVING PAGE, NOT ONLY THE ACTIVE ONE (the owner, on a
        // device, 2026-10-15): a feed pushed fresh with a seed — a For You
        // rail card's hero — has no active page until its first layout, so
        // the bars flew in LIGHT over a media post and turned dark after.
        // The seed says what arrives; a media page wears dark bars from the
        // push's first frame, a text page the page's.
        if let model = arrivalModel {
            applyChromeTheme(hasMedia: model.mediaURL != nil)
            // Again inside the push, once UIKit has hosted the toolbar's
            // items: their glass container did not exist a moment ago.
            transitionCoordinator?.animate(alongsideTransition: { [weak self] _ in
                guard let self, let model = self.arrivalModel else { return }
                self.applyChromeTheme(hasMedia: model.mediaURL != nil)
            })
        }
        // Returning from a pushed screen with engagement state:
        // `presentToolbar` just re-lit the shared bar, so the engagement's
        // claim on the footer band must be re-arbitrated — enforce or
        // finish, never assume (see syncEngagementAfterAppearance).
        // Mirrored in viewDidAppear: during willAppear the floating-bar
        // containers may not have re-attached to the window yet.
        syncEngagementAfterAppearance()
        // Coming back from under a screen popped off it (#1914): the share
        // rises with the pop, and the clip resumes at half. Arriving on its
        // own (a push, a presentation, a flight), it owns the whole screen.
        if let coordinator = transitionCoordinator, !isMovingToParent, !isBeingPresented,
           navigationController?.isBeingPresented != true, !flight.isAwaitingAnyFlight,
           let cover = ViewportShare.cover(of: coordinator, .from) {
            soundPlayback.viewportShare.track(coordinator, cover: cover, coversAtEnd: false)
        } else {
            soundPlayback.viewportShare.report(1)
        }
        isOnScreen = true
        refreshVisibility()
        authorBar.authorPillAwaitsLandingInstall = true
        #if DEBUG
        if LaunchArgument.pillProbe.isPassed() {
            authorIdentityView.debugProbe("willAppear")
            DispatchQueue.main.async { [weak self] in self?.authorIdentityView.debugProbe("willAppear+turn") }
        }
        #endif
    }

    /// Reconciles VC-side engagement state with cell-side reality after
    /// this screen re-appears. Two legitimate outcomes:
    /// - The engaged layout SURVIVED (cell still on screen, still engaged,
    ///   child view still hosted): re-enforce the footer offstage
    ///   instantly, because `presentToolbar` re-lit the shared bar over
    ///   the composer.
    /// - The engaged cell was RECYCLED while the feed was covered (a
    ///   transition's offset clamp, a reload): `prepareForReuse` already
    ///   tore down the cell half, leaving the VC half orphaned — blindly
    ///   enforcing offstage here is exactly the "invisible footer on a
    ///   disengaged feed" bug. Finish the disengagement instead: state
    ///   cleared, child reclaimed, footer restored.
    private func syncEngagementAfterAppearance() {
        guard commentsEngagedID != nil else { return }
        let engagedLayoutAlive = commentsCoordinator.engagedCell()?.isCommentsEngaged == true
            && commentsContentVC?.view.superview != nil
        if engagedLayoutAlive {
            // KEEP-AND-STACK: the native toolbar stays onstage through the
            // engagement (the composer stacks ABOVE it, anchored past the
            // toolbar-inflated safe area), so there is no footer state to
            // re-arbitrate — transitions are the system's alone. Only the
            // composer's pose needs re-seating (idempotent; also
            // re-materializes the footer frost — its window guard makes
            // the willAppear call a no-op and the didAppear pass the one
            // that lands).
            (commentsContentVC as? PostDetailViewController)?
                .setComposerEntranceState(offstage: false)
            // The docked media's geometry gets re-asserted AFTER a forced
            // layout pass: anything that disturbed the tile while the
            // feed was covered (the Ken Burns stop once stranded it as a
            // frozen center crop) snaps back onto the card's slot.
            commentsCoordinator.engagedCell()?.reassertEngagedGeometry()
        } else {
            commentsCoordinator.finishCommentsDisengagement()
        }
    }

    /// Laid out, its bar items hosted, before the push's first frame: the
    /// toolbar's glass container now exists (`toolbarGlassHost`), and the
    /// arriving page's theme reaches it here rather than at `viewDidAppear`
    /// — filmed, a media post's toolbar flew in light for 0.3s without this.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if let model = arrivalModel { applyChromeTheme(hasMedia: model.mediaURL != nil) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        publishViewportProbe()
        #endif
        // …and play again on a return to an open list (#1509).
        if let sideList, sideList.isOpen { sideList.listView.setPlaying(true) }
        #if DEBUG
        // `-snap-side-list-open` (QA, #1509): the side list opens a beat
        // after the feed lands, to film or measure its open pose.
        if LaunchArgument.snapSideListOpen.isPassed(), let sideList, !sideList.isEngaged {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sideList?.debugOpen()
            }
        }
        #endif
        // The backstop, on a return only: whatever a transition left, a feed
        // on screen has no dock under it.
        //
        // On UIKit's own animation: this is reached on a REVERSED close, where
        // the chevron raised the dock before the pop and the flight was caught
        // and thrown back. Hidden without animation, the dock that had been
        // rising over the returning feed vanished in a single frame.
        if hasAppeared, isClosable, !barIsUIKitsByFlag,
           let tabBarController, !tabBarController.isTabBarHidden {
            tabBarController.hideTabBarNatively()
        }
        #if DEBUG
        if LaunchArgument.pillProbe.isPassed() { authorIdentityView.debugProbe("didAppear") }
        #endif
        hasAppeared = true
        deviceAppearanceWatch.observeDeviceAppearance()
        // Again now that the toolbar's items are hosted: during a presentation
        // their glass container may not have existed yet (`toolbarGlassHost`).
        if let model = arrivalModel { applyChromeTheme(hasMedia: model.mediaURL != nil) }
        // The willAppear reconciliation's landing half — by now the bar's
        // containers are in the window and the walk-up reaches them.
        syncEngagementAfterAppearance()
        setNativePopSuppressed(true)
        // The no-flight route into an opening request: a text row has no hero
        // to land, and an ordinary push has no transition at all, so neither
        // reaches `zoomTransitionDidEnd`. Guarded on the flight rather than on
        // the route, because on the hero path this fires WITH the transition
        // and would spend the engagement's layout inside the flight's last
        // frames — the one place this screen refuses to spend it.
        if flight.isAwaitingRevealPresentation {
            // The reveal's landing: the deferred panel goes in BEFORE the
            // pending comments are applied, so a card opened on its comments
            // finds its panel exactly as it would have without the deferral.
            flight.isAwaitingRevealPresentation = false
            commentsCoordinator.landDeferredRestingComments()
            // The reveal held no chrome, so the band's train was laid during
            // the flight, unseen behind the replica: it enters now.
            activeSnapCell?.replayCommentBandEntrance()
        }
        // A zoom flight lands in `zoomTransitionDidEnd`; this is every other
        // path's landing (the guard inside waits for the flight).
        authorBar.installAuthorPillAfterLanding()
        // An author that arrived under the push swaps in now (#1791); one a
        // flight is still holding waits for its landing.
        authorBar.showPendingAuthor()
        if !flight.isAwaitingZoomPresentation { applyPendingComments(animated: true) }
        #if DEBUG
        debugHooks.runDebugAppearanceHooks()
        #endif
    }

    #if DEBUG
    /// The sound sheet the last `presentSoundSheet` raised, for the hooks
    /// (`SnapFeedDebugHooks`).
    var debugPresentedSoundSheet: SoundSheetViewController? { soundSheetPresenter.debugPresentedSoundSheet }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[page-play] %.3f screen willDisappear", CACurrentMediaTime()))
        }
        #endif
        // The side list's tiles stop with the screen (#1509).
        sideList?.listView.setPlaying(false)
        assertNoTabBarAfterAbandonedDismissal()
        revealDockWhenCloseCommits()
        setNativePopSuppressed(false)
        // A grab-to-dismiss or a pop is under way: the landing's warm must not
        // build ~100 ms of panel inside it. A cancelled grab lands again, and
        // that landing schedules its own.
        commentsCoordinator.cancelIdleCommentsWarm()
        // Hand the shared bars back on the way out (see `releaseChromeTheme`).
        //
        // ⚠️ BUT NOT THE TOOLBAR'S GLASS UNTIL A GRAB IS DECIDED (#1315). A
        // grab-to-dismiss is a disappearance that may yet come back, and the
        // bottom bar stays on screen through it (`concealToolbar` fades it,
        // and restores it on a cancel): handed back at the grab's first
        // frame, its platters turned LIGHT over the dark media page for the
        // whole grab and after the cancel, until the page re-appeared (filmed
        // by the owner; the top bar rides the card and kept its look). The
        // navigation bar goes now — it is the destination's header — and the
        // toolbar's style follows only once the close commits.
        //
        // ⚠️ AT THE RELEASE, NOT AT THE LANDING (#1510, the owner 2026-10-21):
        // decided from the completion, both bars stayed dark over the
        // shrinking card for the whole close animation and switched at the
        // landing. A committed release is the close; the completion stays as
        // the backstop for a gesture that never reports one. The first report
        // decides.
        if let coordinator = transitionCoordinator, coordinator.isInteractive {
            handBackChromeTheme(interactive: true) { decided in
                let decision = GrabDecision(decided)
                coordinator.notifyWhenInteractionChanges { decision.report(committed: !$0.isCancelled) }
                coordinator.animate(alongsideTransition: nil) { decision.report(committed: !$0.isCancelled) }
            }
        } else {
            handBackChromeTheme(interactive: false) { _ in }
        }
        // Unlike the visibility bookkeeping below, the toolbar choreography
        // runs for every disappearance: it registers on the coordinator when
        // one exists (fade, restore-on-cancel) and hides instantly otherwise.
        toolbarComposer.concealToolbar()
        // Leaving while engaged: the native bar never left (keep-and-stack),
        // so there is no footer handoff — only the keyboard must not
        // outlive the screen it was typing into.
        if commentsEngagedID != nil {
            commentsContentVC?.view.endEditing(true)
        }
        // During any transition (a hero pop, a detail push) the active cell's
        // player must survive to here-and-beyond: the dismissal flight card
        // mirrors that very player, and a cancelled grab rewinds to a page
        // that should still be playing. Resign via viewDidDisappear instead —
        // it only fires for *completed* disappearances. Instant paths (tab
        // switch) have no transition coordinator and resign immediately.
        guard let coordinator = transitionCoordinator else {
            isOnScreen = false
            refreshVisibility()
            return
        }
        // A screen pushed OVER this one (#1914): the clip's sound fades as it
        // slides in, and the clip pauses — never stops — past half. Never this
        // screen's own pop or dismissal: the screen under it is no cover, and
        // a grab carries this very player to its tile.
        if !isMovingFromParent, !isBeingDismissed, navigationController?.isBeingDismissed != true,
           !flight.isAwaitingAnyFlight, let cover = ViewportShare.cover(of: coordinator, .to) {
            soundPlayback.viewportShare.track(coordinator, cover: cover, coversAtEnd: true)
        }
    }

    /// The share now, for tests.
    var debugViewportShare: ViewportShare { soundPlayback.viewportShare }

    #if DEBUG
    /// `-viewport-probe` (#1970): the share's state as an accessibility
    /// probe on the window, over any sheet — what a UI test reads, the way
    /// the hero audit's probe is read. `viewport;plays=1;covered=0;share=1.00`.
    private static let viewportProbe: UIView = {
        let probe = UIView(frame: CGRect(x: 0, y: 120, width: 2, height: 2))
        probe.backgroundColor = .clear
        probe.isAccessibilityElement = true
        probe.accessibilityLabel = "viewport probe"
        return probe
    }()

    func publishViewportProbe() {
        guard LaunchArgument.viewportProbe.isPassed(), let window = view.window else { return }
        let probe = Self.viewportProbe
        if probe.superview !== window { window.addSubview(probe) }
        window.bringSubviewToFront(probe)
        probe.accessibilityIdentifier = String(
            format: "viewport;plays=%d;covered=%d;share=%.2f",
            // From the share: `onChange` is told before `plays` is updated.
            ViewportShare.plays(at: soundPlayback.viewportShare.share) ? 1 : 0,
            soundPlayback.viewportShare.isCovered ? 1 : 0, soundPlayback.viewportShare.share
        )
    }
    #endif

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[page-play] %.3f screen didDisappear", CACurrentMediaTime()))
        }
        #endif
        toolbarComposer.settleToolbarAfterDisappearance()
        isOnScreen = false
        refreshVisibility()
        // ⚠️ DISMISSED, THE LIST CLOSES (#1580, the owner's recording): this
        // screen is kept for the next post opened from the same surface, and
        // a list left open came back open over it. Closed here, unseen, with
        // its session ended and the kept list forgotten — a new post, a new
        // list.
        if isMovingFromParent || isBeingDismissed || navigationController == nil {
            closeSideListForDismissal()
        }
        // ⚠️ HERE, NOT IN `viewWillDisappear`. A cancelled drag-back fires that
        // one, and on a cold open a grab is possible for the whole wait — so
        // tearing down there would strip the skeletons and leave the viewer
        // looking at empty ground, which is the defect this exists to remove.
        // The going-versus-gone distinction the note below draws is the same.
        if isBeingDismissed || isMovingFromParent {
            commentsCoordinator.disarmLoadingPage()
        }
        // ⚠️ GOING versus GONE, and the resign above cannot tell them apart.
        //
        // `refreshVisibility` resigns the active page WITHOUT releasing its
        // playback, which is right for every screen that comes back — a tab
        // switch, a push on top, the app backgrounding. A pop does not come
        // back, and a gallery page resigning that way left its kept neighbours
        // bound to decoders belonging to a controller on its way out. Measured
        // by opening one gallery clip and closing it: the pool never recovered
        // those players, and the next tile tapped was the one that could not get
        // one — which reads on screen as a hero flying a thumbnail.
        //
        // Every visible page, not just the active one: a neighbour cell can
        // hold retained clips of its own, and `didEndDisplaying` only fires for
        // the ones the collection view actually recycles on the way out.
        guard isBeingDismissed || isMovingFromParent else { return }
        for cell in collectionView.visibleCells {
            (cell as? SnapCellLifecycle)?.releaseRetainedNeighbourClips()
        }
        // Leaving the screen: a burst with no toast is sent now; one whose
        // toast is up stays undoable until it ends (#1375).
        stakes?.end()
    }

    // MARK: - Setup

    /// The system bars are the interaction zone's structural bounds: when
    /// they actually change (the toolbar presents/conceals with the push,
    /// rotation, Dynamic Island class changes), push the new thresholds
    /// into every live cell. Page transitions never fire this — this view
    /// does not move with them, which is precisely why its safe area is
    /// the authority and the cells' ambient one is not.
    /// Begins only for a clearly RIGHTWARD, clearly HORIZONTAL drag.
    ///
    /// The comment list scrolls vertically underneath, and a reader's thumb is
    /// never perfectly straight — so a small horizontal tilt inside a vertical
    /// scroll must not read as "go back". Requiring the horizontal component
    /// to dominate is what keeps the two apart, and the recognizer stays
    /// exclusive (no simultaneous recognition) so a swipe that does qualify
    /// cannot also scroll the list.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let collectionView else { return }
        for cell in collectionView.visibleCells {
            (cell as? SnapFeedCell)?.applyChromeInsets(view.safeAreaInsets)
        }
        // ⚠️ THE FLIGHT'S CHROME REPLICA TOO. It takes the insets once, when
        // the animator asks for it; the page's cells take every change. When
        // the safe area moved during the flight (the bar under the presented
        // page going away), the two disagreed by that much at landing — the
        // caption and the rail stepped up ~10pt as the replica faded into
        // the page (filmed on a device, 25 September 2026).
        flight.flightChrome?.setFixedInsets(view.safeAreaInsets)
        // The COMMENT PANEL too, and this is the seam that makes staging work
        // without anyone doing inset arithmetic by hand.
        //
        // `prepareForHeroPresentation` mounts the panel before the push, when
        // this controller is not in a hierarchy and `view.safeAreaInsets` is
        // still zero — so the panel is placed against nothing. UIKit resolves
        // the real insets the moment the transition container adopts the view,
        // which is before the first frame of the flight, and calls this. The
        // panel is simply told the CURRENT insets again.
        //
        // Told, not added to: an earlier attempt passed the window's insets in
        // by hand and preferred them until real ones appeared, which stacked
        // on a REUSED controller — it already had real insets, so the second
        // open was inset twice over. Whatever UIKit currently says is the
        // whole answer.
        reapplyEngagedInsets()
    }

    /// Re-places the mounted comment panel against the CURRENT safe area.
    func reapplyEngagedInsets() {
        // The loading page is staged BEFORE the push, when the insets are still
        // zero — the same problem this method already solves for the
        // hero-staged panel, and the same answer: told the CURRENT insets.
        if let panel = commentsCoordinator.loadingPage {
            let top = SnapCommentsLayout.commentsTopInset(topInset: view.safeAreaInsets.top)
            commentsCoordinator.loadingPageFrost?.frame = CGRect(
                x: 0, y: 0, width: view.bounds.width, height: top
            )
            (panel as? PostDetailViewController)?.setEngagedInsets(
                top: top, bottomInset: view.safeAreaInsets.bottom
            )
        }
        guard let detail = commentsContentVC as? PostDetailViewController,
              let cell = commentsCoordinator.engagedCell()
        else { return }
        detail.setEngagedInsets(
            top: cell.engagedCommentsTopInset(safeAreaTop: view.safeAreaInsets.top),
            bottomInset: view.safeAreaInsets.bottom
        )
    }

    private func configureCollectionView() {
        let pager = SnapFeedCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        // The mirror of the upward grab's gate (#628): the pager gives up an
        // upward touch exactly where the grab may take it — the true end, at
        // rest — so one side claims it, never both and never neither.
        pager.yieldsUpwardTouch = { [weak self, weak pager] location in
            guard let self, let pager, self.isReadyForInteractiveDismissal else { return false }
            return self.zoomUpwardDismissalPermitted(at: location, in: pager)
        }
        // A downward touch: the previous post on a later page, the dismissal
        // on the first (#2057) — the router both sides ask.
        pager.ownsDownwardTouch = { [weak self] in
            self?.downwardDragOwner == .pager
        }
        collectionView = pager
        collectionView.backgroundColor = emptyGround
        collectionView.isPagingEnabled = true
        collectionView.allowsSelection = false // taps toggle playback, not selection
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // No system scroll-edge darkening under the transparent bars: the media
        // stays unmasked to the top edge (bar) and bottom edge (toolbar); the
        // glass bar items carry their own legibility backing.
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.isPrefetchingEnabled = true
        // Interactive chrome lives INSIDE cells (the shortcut rail, the
        // ticker scrub): deliver touches to them immediately instead of
        // holding every touch-down ~150ms to see if it's a page scroll.
        // The pager still cancels content touches when it legitimately
        // wins a drag (canCancelContentTouches stays true).
        collectionView.delaysContentTouches = false
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(SnapFeedCell.self, forCellWithReuseIdentifier: SnapFeedCell.reuseIdentifier)
        collectionView.pin(to: view)

        // No pull-to-refresh: on the first post the downward direction belongs
        // to the dismissal (cluster-gallery milestone), on any later post to
        // paging back (#2056) — there is no top overscroll left to hang a
        // refresh on. Refresh lives on the source surfaces (the grids), which
        // own their own vertical axis.

        let pipeline = imagePipeline
        dataSource = UICollectionViewDiffableDataSource<Section, PostID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SnapFeedCell.reuseIdentifier,
                for: indexPath
            ) as! SnapFeedCell
            if let self, let model = self.modelsByID[id] {
                cell.configure(
                    with: model,
                    pipeline: pipeline,
                    videoPlayback: self.videoPlayback,
                    // A collection opened from a card that had been paged lands
                    // on that page — the flight is carrying that photograph, and
                    // a destination on page one would land it on a different
                    // one. Consumed here, so it applies to this configure and
                    // no later one.
                    initialMediaPage: self.consumeInitialMediaPage(for: id)
                )
                // The live count, not the one the page was loaded with.
                cell.setPostLikeCount(self.viewModel.visibleLikeCount(for: model))
                // A post learnt unavailable stays so on every page it lands
                // on (#1409) — paging away and back included.
                cell.setPostUnavailable(self.unavailablePostIDs.contains(id))
                // Paging this post's collection travels back to whoever opened
                // the feed — see `onMediaPageChanged`.
                cell.onMediaPageChanged = { [weak self, weak cell] page in
                    self?.onMediaPageChanged?(id, page)
                    // A carousel paused by a tap plays again on its next page,
                    // as the arriving clip does: the track with it (#1849).
                    if let self, self.soundPlayback.songPausedFor == id, SnapSoundState.isCarousel(model) {
                        self.soundPlayback.songPausedFor = nil
                        cell?.setPausedMarkVisible(false)
                    }
                    // A collection's pages are clips and photographs: turning
                    // one changes what there is to hear, and what it is called.
                    self?.soundPlayback.refreshAudibleSurface()
                    if let self, let index = self.lifecycle.activeIndex,
                       self.orderedIDs.indices.contains(index), self.orderedIDs[index] == id {
                        self.settledPageChrome.updateBarChrome(at: index)
                    }
                }
                // ⚠️ THE DISMISSAL STANDS DOWN FOR A SCRUB.
                //
                // Both are horizontal-ish drags on the same pixels, and the
                // dismissal's pan lives on this screen's own view — an ancestor
                // — so no amount of `cancelsTouchesInView` on the chip can stop
                // it seeing the touch first. It has to be told, and told for
                // every cell, because the chip is a different object each time
                // one is configured. Reported as scrubbing the indicator
                // dismissing the post instead of paging it.
                //
                // `require(toFail:)` and not a delegate: a delegate would let
                // both run and the dismissal would still move the screen.
                // The same for the caption's slide (#2269): on a post with a
                // strip, a horizontal slide on the caption is the strip's.
                // Without one the slide never begins, so it fails at once
                // and the screen's pans go on as before.
                for pan in self.view.gestureRecognizers ?? []
                where pan is UIPanGestureRecognizer && pan !== cell.mediaScrubGesture
                    && pan !== cell.captionSlideGesture {
                    pan.require(toFail: cell.mediaScrubGesture)
                    pan.require(toFail: cell.captionSlideGesture)
                }
                // The post's interaction zone is bounded by the SCREEN's
                // header/footer thresholds (nav bar bottom, toolbar top),
                // not by the cell's ambient safe area: this view's insets
                // are the stable authority — a cell mid-page-transition
                // re-derives ambient insets every frame, which is exactly
                // the geometry churn that destabilized the shortcut rail.
                // Same frozen-inset doctrine as the flight replica.
                cell.applyChromeInsets(self.view.safeAreaInsets)
                // Pull side of the comments seam: a recycled cell for an
                // already-visited post gets its streams back immediately;
                // async arrivals ride `onCommentStreamsChange` instead.
                cell.updateCommentStreams(self.viewModel.commentStreams(for: id))
                // The comments engagement's two verbs, cell → screen: the
                // pill opens the panel, a strip tap while engaged closes it.
                cell.onRequestComments = { [weak self] id in self?.commentsCoordinator.presentComments(for: id) }
                cell.onReactionsRunningLow = { [weak self] id in self?.viewModel.bandRanLow(for: id) }
                // With the side list open, a tap on the card closes it
                // (#1550): the clip pauses from its tile instead.
                cell.mediaTaps.interceptsMediaTap = { [weak self] in
                    guard let sideList = self?.sideList, sideList.isOpen, !sideList.isSettling else { return false }
                    sideList.settle(open: false)
                    return true
                }
                // A carousel's track (#1849): a tap or a hold on any of its
                // pages acts on the post's sound with the clip on screen.
                if SnapSoundState.isCarousel(model) {
                    cell.mediaTaps.onPostTrackTap = { [weak self, weak cell] in
                        guard let self, let cell else { return }
                        self.soundPlayback.togglePostTrack(on: cell, id: id)
                    }
                    cell.mediaTaps.onPostTrackHold = { [weak self] held in self?.soundPlayback.holdPostTrack(held) }
                } else {
                    cell.mediaTaps.onPostTrackTap = nil
                    cell.mediaTaps.onPostTrackHold = nil
                }
                // The like spends through the screen's stakes, which play
                // the receipts back on the cell that asked; bound, the cell
                // wears the post's stake (a recycled cell gets it back).
                cell.onRequestBoost = { [weak self, weak cell] id, spend in
                    self?.performBoost(on: id, spend: spend, from: cell)
                }
                cell.onRequestBoostUndo = { [weak self, weak cell] id in
                    self?.performBoostUndo(on: id, from: cell)
                }
                self.stakes?.bind(cell, to: id)
                cell.onRequestCommentsPageDrive = { [weak self] phase, translation, velocity in
                    self?.pagerDrive.drivePageSwipe(phase, translation: translation, velocity: velocity)
                }
                // The sound bubble (#671): its face, and its tap. No hold since
                // #1931: the sound follows the device.
                cell.setSoundFace(self.soundFace(for: model))
                cell.setSlotSharesPost(true, holdArmsShare: self.slotHoldArmsShare(model))
                cell.onRequestSoundSheet = { [weak self] in self?.presentSoundSheet() }
                // Its way back, while the comments are scrolled away (#1929).
                cell.onRequestSoundReturn = { [weak self, weak cell] in
                    guard let id = cell?.representedPostID else { return }
                    self?.commentsPanel(for: id)?.scrollToStart(animated: true)
                }
                // A text page's like, in the footer when there is one (#1924).
                cell.setLikeInFooter(self.toolbarComposer.footerCarriesTextLike)
                // The sound bubble's Share (#1999).
                cell.onRequestShare = { [weak self] in self?.presentShareSheet(for: id) }
            }
            return cell
        }
    }

    /// The navigation bar (`SnapNavigationBarComposer`), answered where the
    /// author bar, the comments, the page drive and the tests ask the screen.
    func setEngagedChrome(_ engaged: Bool, hasMedia: Bool, animated: Bool) {
        navigationBarComposer.setEngagedChrome(engaged, hasMedia: hasMedia, animated: animated)
    }

    func engagedTrailingItems() -> [UIBarButtonItem] { navigationBarComposer.engagedTrailingItems() }

    func applyTrailingNavItems(_ items: [UIBarButtonItem], animated: Bool) {
        navigationBarComposer.applyTrailingNavItems(items, animated: animated)
    }

    var walletBadgeItem: UIBarButtonItem? { navigationBarComposer.walletBadgeItem }

    var isCommentSortAvailable: Bool { navigationBarComposer.isCommentSortAvailable }

    var engagedChromeOnBar: Bool {
        get { navigationBarComposer.engagedChromeOnBar }
        set { navigationBarComposer.engagedChromeOnBar = newValue }
    }

    var engagedChromeHasMedia: Bool { navigationBarComposer.engagedChromeHasMedia }

    func setCommentTabsAvailable(_ available: Bool, animated: Bool = false) {
        navigationBarComposer.setCommentTabsAvailable(available, animated: animated)
    }

    func syncCommentSortAvailability() { navigationBarComposer.syncCommentSortAvailability() }

    func observeCommentCount(of detail: PostDetailViewController?) {
        navigationBarComposer.observeCommentCount(of: detail)
    }

    /// The day pill on the bar, if any. Tests.
    var debugCommentsDayPill: SnapBarDayPill? { authorBar.commentsDayItem?.customView as? SnapBarDayPill }
    /// The trailing run as it stands. Tests.
    var debugTrailingItems: [UIBarButtonItem] { navigationItem.rightBarButtonItems ?? [] }

    #if DEBUG
    var debugBackItem: UIBarButtonItem? { backItem }
    #endif

    /// Whether a bar-item change may animate now: on screen, and not inside a
    /// presentation's transition, whose own bar animation already owns the
    /// items (a morph started under it lands in the flight's first frames).
    var canAnimateBarItems: Bool {
        view.window != nil && transitionCoordinator == nil && !flight.isAwaitingAnyFlight
    }


    #if DEBUG
    /// The save glyph as drawn: its symbol and its spoken label.
    var debugBookmarkGlyph: (symbol: String, label: String?) {
        (toolbarComposer.drawnBookmarkSymbol, toolbarComposer.bookmarkItem.accessibilityLabel)
    }
    #endif

    /// One item == one full screen; a plain vertical layout, paged by
    /// `isPagingEnabled` against the (inset-free) bounds.
    private static func makeLayout() -> UICollectionViewLayout {
        let full = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
        let item = NSCollectionLayoutItem(layoutSize: full)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: full, subitems: [item])
        return UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
    }

    private func configureStatusLabel() {
        // The shared empty state's ink follows the trait; over the default
        // black ground it is forced dark (`render`), so it reads in light mode.
        statusView.isHidden = true
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
    }

    /// Whether a keyboard is currently on screen — see
    /// `zoomVerticalDismissalPermitted`.
    ///
    /// Tracked from the notifications rather than read off
    /// `keyboardLayoutGuide`, because the question is asked at the moment a
    /// GESTURE begins: the guide's frame is animating then, and a guide
    /// halfway down answers neither yes nor no.
    private(set) var isKeyboardOnScreen = false

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        appObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isKeyboardOnScreen = true }
        })
        appObservers.add(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isKeyboardOnScreen = false }
        })
        appObservers.add(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.soundPlayback.setForeground(false) }
        })
        appObservers.add(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.soundPlayback.setForeground(true) }
        })
        // ⚠️ THE FLOATING WINDOW IS CLOSED ONCE THE APP IS ACTIVE (#483). Asked
        // as the app only enters the foreground (the app's icon tapped), the
        // system kept the window up over the app, and the page showed its
        // "playing in Picture in Picture" placeholder (the owner's device,
        // 2026-11-06).
        appObservers.add(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.videoPlayback?.stopPictureInPicture() }
        })
        // The sound turned on, or off by the silent switch (#1931), or the
        // switch moved while it follows the device (#483): Background Play and
        // Picture in Picture follow it.
        // A voice post or a voice message holding the floor silences the
        // feed until it lets go (#2207).
        FeedSoundSession.shared.followVoiceFloor()
        for name in [FeedSoundSession.didTurnOn, FeedSoundSession.didTurnOff, FeedSoundSession.audibilityDidChange] {
            appObservers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.soundPlayback.refreshAudibleSurface() }
            })
        }
        // (A keyboard-session rail yield used to live here: the engaged
        // composer rose into the rail's column, so the rail conceded the
        // band while typing. The engagement fades the rail outright now, so
        // there is no overlap left to arbitrate.)
    }

    // MARK: - Rendering

    func render(_ state: FeedViewModel.RenderState) {
        lastRenderState = state
        let previousModels = modelsByID
        // The post on show, to keep on show through a reorder (#1580) — the
        // ACTIVE post by identity: read off an index, a render nested in
        // another's layout named whichever post the old items had there.
        let held = lifecycle.activeIndex != nil ? lifecycleActiveID : nil
        // The viewer's "not interested" applies HERE, one render late by
        // design: the post they were on when they asked stays until they leave
        // it, and never comes back.
        let previousOrder = orderedIDs
        var ids = state.items.map(\.id).filter {
            !postActions.notInterestedIDs.contains($0) || $0 == activePostID
        }
        var models = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
        // ⚠️ THE POST IN FRONT, GONE FROM THE SERVER, GIVES WAY WITH A WORD
        // (#2048, the owner 2026-11-05). A window that came back without it
        // used to hand its index to the next post silently, and that was not
        // a page change: the departed post's clip kept playing under another's
        // caption, the bar kept its author, and a text post that took its
        // place rested in its comments over the video. Now the next post (the
        // previous one at the end) takes the page AS a page change, below,
        // and a toast says why. Only a post with nothing else to show stays,
        // unavailable (#1409) — a post opened alone, from a link.
        var keptUnavailable: PostID?
        var skippedUnavailable = false
        if let held, models[held] == nil, let model = previousModels[held],
           viewModel.unavailablePosts.contains(held) || unavailablePostIDs.contains(held) {
            if ids.isEmpty {
                ids = [held]
                models[held] = model
                keptUnavailable = held
                keptUnavailableID = held
            } else {
                skippedUnavailable = true
            }
        }
        orderedIDs = ids
        modelsByID = models
        // ⚠️ BEFORE `dataSource.apply`. `willDisplay` fires inside the apply's
        // own layout pass and asks for a resting panel, so the parked one has
        // to already be in the slot by then.
        commentsCoordinator.retireLoadingPage()

        // ⚠️ **A stable id is not an unchanged page** — see
        // `SeededPageReconciliation` for the whole rule and why it is a value.
        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: orderedIDs,
            previous: previousModels,
            current: modelsByID,
            // The only engagement left is a text page's resting one, its
            // ordinary layout, not an open panel: nothing to protect.
            engaged: nil
        )

        #if DEBUG
        // How many pages this feed has, and when. A feed pushed before its
        // items arrive has NOTHING to lay out, so what fills the screen is the
        // cell's black floor — no media card involved, which is why tracing the
        // card showed it holding a poster the whole time. Under injected
        // latency this window is the injected latency long.
        if LaunchArgument.mediaLog.isPassed() {
            // `reconfigured` is the half that is otherwise unobservable: a
            // second render with the same ids looks identical from outside, and
            // whether it redrew anything is exactly the question.
            print(String(format: "[media] %.3f feed render items=%d reconfigured=%d ground=%@",
                         CACurrentMediaTime(), orderedIDs.count, changed.count,
                         resolvedGround() == .black ? "black" : "\(resolvedGround())"))
        }
        #endif
        var snapshot = NSDiffableDataSourceSnapshot<Section, PostID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(orderedIDs)
        // Same identity, new content — the one thing appendItems cannot say.
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        // A reorder under the post on show (#1580): no page is activated
        // from the pager's index until it is back on that post.
        let reorders = held.map { id in orderedIDs.contains(id) && orderedIDs.firstIndex(of: id) != lifecycle.pageIndex } ?? false
        if reorders, let held {
            // No page reads the pager's index, and the post on show's page
            // keeps its clip for the next one to adopt, until the pager is
            // back on that post (`handOverReorderedPlayback`).
            isReplacingItems = true
            reorderHeld = (held, settledSnapCell?.liveVideoSurface)
        }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            // ⚠️ HERE, not only at a settle. This is what takes a LENT ground
            // back: a feed opened from a marker wears the marker's tone with no
            // pages, and the first render carrying a media model must return it
            // to black without waiting for a settle that may be a frame away.
            applyGrounds()
            commentsCoordinator.finishLoadingPageHandover()
            // ⚠️ ANOTHER POST AT THE INDEX ON SHOW IS A PAGE CHANGE (#2048).
            // The tracker follows the INDEX, so a post that replaced the one on
            // show (a refresh, a window without it) was never activated: the
            // page kept the departed post's clip and the bar its author. The
            // page is resigned here so the next line activates the new one.
            if let held, lifecycle.activeIndex != nil, !orderedIDs.contains(held) {
                apply(lifecycle.setPageIndex(nil))
                lifecycleActiveID = nil
                // The last page gone: the one before it takes the screen.
                let page = Int((collectionView.contentOffset.y / max(collectionView.bounds.height, 1)).rounded())
                if page >= orderedIDs.count, !orderedIDs.isEmpty {
                    collectionView.setContentOffset(
                        CGPoint(x: 0, y: CGFloat(orderedIDs.count - 1) * collectionView.bounds.height), animated: false
                    )
                }
            }
            if skippedUnavailable { showPostUnavailableToast() }
            // ⚠️ NOT `keepOnShow(held)` here: this completion can run late,
            // after a later render, and a post captured then is stale (#1580).
            updateActiveItem()
            // ⚠️ **The bars are not in the cell**, and `updateActiveItem` only
            // speaks when the active INDEX moves.
            //
            // The author capsule and the attribution pill are this screen's own
            // chrome, refreshed from `updateBarChrome` on a page CHANGE — and a
            // page whose model was just replaced under a stable id is not a page
            // change. `SnapActiveItemTracker.diff` returns `.none`, nothing
            // asks, and the two most identity-bearing things on screen keep the
            // projection while the cell behind them shows the real entry.
            //
            // That asymmetry is what survived the cell-level fix and had to be
            // measured to find: `reconfigured=3` and `page CONFIGURE author=yes`
            // in the same frame as a capsule still reading nobody.
            if let active = lifecycle.activeIndex,
               orderedIDs.indices.contains(active),
               changed.contains(orderedIDs[active]) {
                settledPageChrome.updateBarChrome(at: active)
            }
        }
        // Turned unavailable in place, now that its page is in the items.
        if let keptUnavailable { markPostUnavailable(keptUnavailable, recording: false) }
        // The new items are in (the apply is synchronous here): the pager
        // back on the post on show, then the settle it was held from.
        if reorders {
            isReplacingItems = false
            keepOnShow(held)
            handOverReorderedPlayback()
            updateActiveItem()
        }

        // A hero flight in progress whose post hydrated just now (cold tap):
        // fill in the flying card's chrome where it is. Its geometry is
        // data-independent, so only the text/avatar fade in.
        if let flightChrome = flight.flightChrome {
            UIView.transition(with: flightChrome, duration: 0.15, options: [.transitionCrossDissolve]) {
                self.zoomDestination.configureFlightChrome(flightChrome)
            }
        }

        // ⚠️ BLACK INK ON BLACK in light mode otherwise: the empty ground is
        // black unless a tapped card lent its tone.
        statusView.overrideUserInterfaceStyle = emptyGround == .black ? .dark : .unspecified
        // The centred loader while there is no post to show at all (#1765):
        // a first launch on Shots — no page on the device yet — sat on a
        // blank black page until the network answered.
        pageLoaders.setFirstPageWaiting(state.phase == .loading && state.items.isEmpty)
        switch state.phase {
        case .loading, .content:
            statusView.isHidden = true
        case .empty:
            statusView.configure(
                symbolName: "person.2", title: "Nothing here yet", subtitle: "Follow people to fill your timeline."
            )
            statusView.isHidden = false
        case .failed(let message):
            // ⚠️ A WAY OUT (#797): this screen has no pull, so "Pull to
            // retry" was a promise it could not keep.
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in
                    self?.statusView.setActionBusy(true)
                    self?.viewModel.refresh()
                }
            )
            statusView.isHidden = false
        }
    }

    /// Comment streams land on exactly the cell showing that post; each
    /// surface applies its own gate from there. A cell that's gone by now
    /// re-pulls at reconfigure.
    private func updateVisibleStreams(for id: PostID, streams: FeedViewModel.CommentStreams) {
        guard let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell else { return }
        cell.updateCommentStreams(streams)
    }

    // MARK: - Boost

    /// One stake on `id`, from `source` (the page's cell, the footer): none
    /// on a post the viewer may no longer see (#1409), a tap that finished a
    /// member gate after it turned unavailable.
    func performBoost(on id: PostID, spend: WalletStakeSpend, from source: UIResponder?) {
        stakes?.stake(spend, on: id, from: source ?? self, lands: { [weak self] in
            self.map { !$0.unavailablePostIDs.contains(id) } ?? false
        })
    }

    /// Takes back the live burst on `id`: the menu's Undo.
    func performBoostUndo(on id: PostID, from source: UIResponder?) {
        stakes?.undo(on: id, from: source)
    }

    // MARK: - Unavailable posts (#1409)

    /// Posts the server shows the viewer no more (#447: taken down, deleted,
    /// withheld), learnt while this screen is up — today from a comments
    /// panel whose revalidation answered not-found (`onPostUnavailable`).
    /// Their pages read "This post isn't available" with nothing to act on,
    /// on every page they land on; other posts are untouched.
    private(set) var unavailablePostIDs: Set<PostID> = []
    /// The page in front that the server's answer no longer carries, kept
    /// until the viewer leaves it (`render`, #2048).
    private var keptUnavailableID: PostID?
    /// The last state rendered — rendered again when the kept page goes.
    private var lastRenderState: FeedViewModel.RenderState?
    /// Hears posts learnt unavailable on other surfaces (#2048).
    private var unavailableObservation: ViewerEventSubscription?
    #if DEBUG
    /// "This post isn't available" toasts shown (#2048).
    private(set) var debugUnavailableToastsShown = 0
    #endif

    /// Takes `id`'s actions away, in place: its page, its bars when it is
    /// the page in front, what it plays, and the like still inside its undo
    /// window, which goes back to the wallet. A burst its toast has already
    /// sent comes back through the outbox: the server refuses the stake and
    /// its answer refunds it (`WalletStore.settleCommittedStake`, #676).
    ///
    /// Recorded for every surface (#2048): it leaves this feed's pages not
    /// on show, the other feeds' and the For You grid. `recording: false`
    /// for a post the record already holds (`render`).
    func markPostUnavailable(_ id: PostID, recording: Bool = true) {
        if recording {
            // The page in front gives way to the next at once (#2048), unless
            // its comments are open over it — the viewer is reading them —
            // or it is the only post: then it stays, as the block, until left.
            let givesWay = id == activePostID && presentedViewController == nil && orderedIDs.count > 1
            viewModel.postBecameUnavailable(id, onShow: givesWay ? nil : activePostID)
        }
        guard unavailablePostIDs.insert(id).inserted else { return }
        stakes?.takeBack(id)
        // On screen now; a page already dequeued but not yet shown is told
        // at `willDisplay`, every later one at configure.
        snapCell(for: id)?.setPostUnavailable(true)
        if activeModel?.id == id { toolbarComposer.applyToolbarPostActions(for: id) }
        soundPlayback.refreshAudibleSurface()
    }

    #if DEBUG
    /// The toolbar's post actions, for a test: save, repost, the sound.
    var debugToolbarPostActions: [UIBarButtonItem] {
        let toolbar = toolbarComposer
        return [toolbar.bookmarkItem, toolbar.repostToolbarItem, toolbar.footerSoundItem].compactMap { $0 }
    }

    /// The footer's like, nil off a text page (#1924).
    var debugFooterLikeItem: UIBarButtonItem? { toolbarComposer.footerLikeItem }

    /// A tap on the footer's like, through the screen's own path.
    func debugTapFooterLike() { toolbarComposer.likeFromFooter() }

    /// A like staked through the screen's stakes as a tap's spend lands —
    /// without the toast (from no screen), whose one undo slot is shared by
    /// the whole process.
    func debugStake(_ spend: WalletStakeSpend, on id: PostID) {
        stakes?.stake(spend, on: id, from: UIView())
    }

    /// A tap on the page's like, through the screen's own path.
    func debugTapBoost(on id: PostID, spend: WalletStakeSpend) {
        snapCell(for: id)?.onRequestBoost?(id, spend)
    }

    #endif

    func snapCell(for id: PostID) -> SnapFeedCell? {
        guard let indexPath = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: indexPath) as? SnapFeedCell
    }

    /// Renders one wallet snapshot onto the header badge — balance in the
    /// compact spelling, plus the claim-countdown ring (self-animating, so
    /// this only needs to run on store changes, not on a clock). The pulse
    /// rides the sheet's presence: a badge that can open the claim sheet
    /// may advertise a waiting claim; a display-only one must not promise
    /// what it can't deliver.
    func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        // The page's badge, and the comments sheet's while one is up (#2087).
        for badge in [walletBadge, commentsSheet?.content.walletBadge].compactMap({ $0 }) {
            badge.update(
                balance: snapshot.balance,
                claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
                claimProgress: snapshot.claimCountdown.map {
                    WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
                }
            )
        }
    }

    /// Presents the shell-vended wallet sheet over this screen — the badge's
    /// tap, and the `-feed-open-wallet` hook's shared path.
    func presentWalletSheet() {
        guard let makeWalletSheet, presentedViewController == nil else { return }
        present(makeWalletSheet(), animated: true)
    }

    /// What the sound bubble and the composer's rail slot draw for `model`
    /// (#671) — see `SnapSoundState.face`.
    func soundFace(for model: FeedItemDisplayModel) -> SnapSoundFace? {
        guard var face = soundState.face(for: model) else { return nil }
        face.pipeline = imagePipeline
        return face
    }

    /// Every visible sound bubble, and the open panel's rail slot, after the
    /// sound changed (#671).
    private func refreshVisibleSoundFaces() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard orderedIDs.indices.contains(indexPath.item),
                  let model = modelsByID[orderedIDs[indexPath.item]],
                  let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell else { continue }
            cell.setSoundFace(soundFace(for: model))
            cell.setSlotSharesPost(true, holdArmsShare: slotHoldArmsShare(model))
        }
        if let model = activeModel { toolbarComposer.refreshFooterSound(for: model) }
        applyRailSlot(to: commentsContentVC)
        applyRailSlot(to: previewRestingVC)
    }

    /// Whether the way back's hold over Share arms it (#1999): a media
    /// page's — "a hold arms its own action" (#1929). A text page's arms
    /// nothing, as before.
    func slotHoldArmsShare(_ model: FeedItemDisplayModel) -> Bool {
        !SnapSoundState.isText(model)
    }

    /// The composer's rail slot, decided in one place (#1999): Share on every
    /// page — a text page never its sound, and a media page's moves to the
    /// footer. Internal for tests.
    func applyRailSlot(to panel: UIViewController?, hostedByPage: Bool = true) {
        guard let detail = panel as? PostDetailViewController else { return }
        // Every panel this screen mounts passes here: the one place it learns
        // that the panel's post turned out unavailable (#1409).
        detail.onPostUnavailable = { [weak self] id in self?.markPostUnavailable(id) }
        guard let id = detail.postID, let model = modelsByID[id] else { return }
        // A panel inside a page sits under that page's action column (#695);
        // the loading page has no page above it and keeps its own.
        // A media page folds its column into the sound while its comments
        // are up (#1872): the composer keeps the slot alone (#1923).
        // A text page's like stands in the footer (#1924): its column is the
        // sound alone too.
        detail.setActionColumnHostedByPage(
            hostedByPage, foldsIntoSlot: model.mediaURL != nil || toolbarComposer.footerCarriesTextLike
        )
        // ⚠️ THE SLOT'S ONE DECISION (#1999), for every page:
        //   - a page, text or media: Share, the toolbar's old action;
        //     a media page's sound moves to the footer's trailing item;
        //   - scrolled away, any: the way back (#1929), the panel's call.
        let face = soundFace(for: model)
        detail.setRailShare({ [weak self] in self?.presentShareSheet(for: id) }, holdArms: slotHoldArmsShare(model))
        detail.setRailSoundFace(face)
        // The composer on the page's breath (#1716, #1722).
        detail.setComposerLift(SnapActionColumn.bottomBreath)
        // A remote cover loads in the rail's own slot (#1772).
        // A tap opens the sound sheet — the bubble's (#683). No hold since
        // #1931: no in-app mute.
        detail.setRailSoundActions(tap: { [weak self] in self?.presentSoundSheet() }, hold: nil)
        // Scrolled away from the text, the page's sound bubble offers the way
        // back (#1929) — the composer's own slot does, on the loading page.
        detail.onScrollAwayChange = hostedByPage ? { [weak self, weak detail] shows in
            self?.setSoundShowsReturn(shows, down: detail?.scrollAwayReturnsDown ?? false, for: id)
        } : nil
        if hostedByPage {
            setSoundShowsReturn(detail.showsScrollAwayReturn, down: detail.scrollAwayReturnsDown, for: id)
        }
    }

    /// The open comments panel showing `id`: the engagement's, or the
    /// incoming page's preview.
    private func commentsPanel(for id: PostID) -> PostDetailViewController? {
        [commentsContentVC, previewRestingVC].lazy
            .compactMap { $0 as? PostDetailViewController }
            .first { $0.postID == id }
    }

    /// The way back on every visible page showing `id` (#1929).
    private func setSoundShowsReturn(_ shows: Bool, down: Bool = false, for id: PostID) {
        for case let cell as SnapFeedCell in collectionView.visibleCells where cell.representedPostID == id {
            cell.setSoundShowsReturn(shows, down: down)
        }
    }

    /// Re-draws the like count of the visible page showing `id`.
    private func refreshLikeCount(for id: PostID) {
        guard let model = modelsByID[id] else { return }
        for case let cell as SnapFeedCell in collectionView.visibleCells where cell.representedPostID == id {
            cell.setPostLikeCount(viewModel.visibleLikeCount(for: model))
        }
    }

    // MARK: - Comments engagement

    #if DEBUG
    /// The mount and the media warm, reachable without a scroll — the defect
    /// they produce together is an ORDER between two seams, and a test that
    /// could not put them in that order could not see it.
    func debugPrewarmComments(for id: PostID) {
        guard collectionView.visibleCells.contains(where: { $0 is SnapFeedCell }),
              !flight.isAwaitingZoomPresentation else { return }
        // The whole warm at once: the turns the app spreads it over (#2136)
        // are `RunLoopTurn`'s, not this test seam's.
        commentsCoordinator.prewarmCommentsSheet(for: id)
    }

    func debugMountRestingComments(for id: PostID) {
        guard let cell = collectionView.visibleCells.compactMap({ $0 as? SnapFeedCell }).first
        else { return }
        commentsCoordinator.presentRestingComments(for: id, host: cell)
    }

    /// A warm with no engagement behind it — the state that blocked the mount.
    var debugHasParkedCommentsWarm: Bool {
        commentsEngagedID == nil && commentsContentVC != nil
    }

    /// Which post the resting panel is standing in for right now.
    var debugRestingCommentsID: PostID? { commentsEngagedID }
    /// A comments request not yet engaged (#1577's routes).
    var debugPendingCommentsID: PostID? { pendingCommentsID }

    /// And which one is showing a panel WITHOUT owning the engagement.
    var debugPreviewRestingID: PostID? { previewRestingID }

    /// Pretends a keyboard came up, so the veto below it can be tested without
    /// one — a simulator will not raise a real keyboard for a unit test, and
    /// the rule is about what the veto ANSWERS while one is up.
    func debugSetKeyboardOnScreen(_ onScreen: Bool) { isKeyboardOnScreen = onScreen }

    /// Walks the page swipe a finger drives on a text page, animated settle
    /// included.
    ///
    /// The only gesture that moves a text page belongs to the composer bar, and
    /// a synthetic drag cannot produce it — so the window that matters most
    /// here, the half-second while the settle animates and the model has
    /// already arrived at the destination, had no scripted route at all. Every
    /// defect reported inside it had to be found by watching a recording.
    /// A positive `distance` drives up (the next post); a negative one
    /// drives down (the previous post, #2058).
    func debugDrivePageSwipe(steps: Int = 12, distance: CGFloat = 520) {
        let velocity: CGFloat = distance >= 0 ? -900 : 900
        pagerDrive.drivePageSwipe(.began, translation: 0, velocity: 0)
        for step in 1...max(1, steps) {
            let dy = -distance * CGFloat(step) / CGFloat(max(1, steps))
            pagerDrive.drivePageSwipe(.changed, translation: dy, velocity: velocity)
        }
        pagerDrive.drivePageSwipe(.ended, translation: -distance, velocity: velocity)
    }

    /// The ceiling the pager actually clamps to — prepares, then answers.
    func debugReachableCeiling() -> Int { reachableCeiling() }

    /// The ⋯ menu's rows, as built for `id`. The menu itself is a deferred
    /// element UIKit resolves when it opens, so there is nothing to read off
    /// the button — the composition has to be asked for.

    /// Which text page has had its interface built ahead. Kept separately from
    /// the live field so a test can see a warm that was CONSUMED — which is the
    /// half that proves the mount paid nothing.
    var debugPrewarmedRestingID: PostID? { commentsCoordinator.debugPrewarmedRestingID }

    /// Refused-follow toasts shown (#1979), counted by `SnapAuthorBar`.
    var debugFollowFailureToastsShown: Int { authorBar.debugFollowFailureToastsShown }
    #endif

    #if DEBUG
    var debugLoadingPanel: UIViewController? { commentsCoordinator.loadingPage }
    var debugShowsLoadingPage: Bool { commentsCoordinator.loadingPage != nil }
    #endif

    #if DEBUG
    /// Whether the no-post loader is up (`SnapPageLoaders`).
    var debugShowsFirstPageLoader: Bool { pageLoaders.debugShowsFirstPageLoader }
    #endif

    /// The theme the DEVICE is in, which is not always the theme this screen is
    /// in: the feed pins itself dark while a photograph is settled, so anything
    /// asking `traitCollection` from inside it gets the pin rather than the
    /// device. Read off the window, which no view controller's override reaches.
    var deviceInterfaceStyle: UIUserInterfaceStyle {
        view.window?.traitCollection.userInterfaceStyle ?? .unspecified
    }

    /// How far the pager may go (`SnapPageReadiness`), answered where the
    /// page drive, the warm planner, the loaders, the scroll and the tests
    /// ask the screen.
    func isPageReady(_ index: Int) -> Bool { pageReadiness.isPageReady(index) }

    var lastReachablePage: Int { pageReadiness.lastReachablePage }

    func reachableCeiling() -> Int { pageReadiness.reachableCeiling() }

    // MARK: - Active-item lifecycle

    func refreshVisibility() {
        // A screen pushed over this one past half the viewport pauses it, and
        // its pop gives it back at half (#1914, `viewportShare`).
        let isWatched = isOnScreen && soundPlayback.isForeground
            && ViewportShare.plays(at: soundPlayback.viewportShare.share)
        warmPlanner.followVisibility(isWatched: isWatched)
        apply(lifecycle.setVisible(isWatched))
        lifecycleActiveID = lifecycle.activeIndex.flatMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil }
        soundPlayback.refreshAudibleSurface()
        soundPlayback.setCoverSpinWatch(isWatched)
    }

    /// The page playback follows: the one covering most of the screen.
    ///
    /// Deliberately NOT the lifecycle's active index, though the arithmetic is
    /// the same one (`SnapActiveItemTracker.activeIndex` is the page owning the
    /// viewport's midpoint). The difference is WHEN each is consulted: the
    /// lifecycle's is settle-quantized, because everything it drives — chrome,
    /// warm window, resting interface, the pager's lock — must not move under a
    /// finger. Playback is the one thing that should.
    private(set) var playbackOwner: Int?

    /// Hands the picture to whichever page owns the screen, and takes it back
    /// from the one that lost it. Runs on EVERY scroll callback, so it must
    /// stay this cheap: an index, a comparison, and nothing at all when the
    /// answer has not changed.
    func updateViewportPlayback() {
        let owner = SnapActiveItemTracker.activeIndex(
            contentOffsetY: collectionView.contentOffset.y,
            pageHeight: collectionView.bounds.height,
            itemCount: orderedIDs.count
        )
        guard owner != playbackOwner else { return }
        if let previous = playbackOwner {
            (lifecycleCell(at: previous) as? SnapFeedCell)?.clipStart.setOwnsViewport(false)
        }
        playbackOwner = owner
        if let owner {
            (lifecycleCell(at: owner) as? SnapFeedCell)?.clipStart.setOwnsViewport(true)
        }
        // The sound changes hands in this same turn (#1791).
        soundPlayback.refreshAudibleSurface()
        // The pill changes owner with the picture (#1791): one rule — the
        // page covering most of the screen — so the author and the clip
        // change hands on the same frame, in either direction. ⚠️ AND A TEXT
        // PAGE'S FOOTER LIKE WITH THEM (the owner's device, 2026-11-01): it
        // waited for the settle, a beat after the author beside it. Drawn
        // first, so the author's swap re-installs into the bar it set.
        if let owner, orderedIDs.indices.contains(owner), let model = modelsByID[orderedIDs[owner]] {
            toolbarComposer.refreshFooterLike(for: model, animated: true)
            authorBar.showAuthor(model)
        }
    }

    func updateActiveItem() {
        guard !isReplacingItems else { return }
        let index = SnapActiveItemTracker.activeIndex(
            contentOffsetY: collectionView.contentOffset.y,
            pageHeight: collectionView.bounds.height,
            itemCount: orderedIDs.count
        )
        // The same post at a new index — the items reordered under it (the
        // side list opening or closing, #1580): re-placed, never resigned
        // and re-activated, which restarted its clip or its song.
        if let index, lifecycle.activeIndex != nil, index != lifecycle.pageIndex,
           let held = lifecycleActiveID, orderedIDs.indices.contains(index), orderedIDs[index] == held {
            lifecycle.rebase(to: index)
        } else {
            apply(lifecycle.setPageIndex(index))
        }
        lifecycleActiveID = lifecycle.activeIndex.flatMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil }
        // The settled page owns the screen by definition, so the two agree
        // here — and a settle that arrives without any scroll callback (a
        // programmatic jump, a landing) is the only way the picture would
        // otherwise be missed.
        updateViewportPlayback()
        // ⚠️ AT EVERY SETTLE, not only when the page CHANGED.
        //
        // The reconcile used to live inside the activation branch, so it ran
        // only when the dispatcher reported a new page — and a settle that
        // reports nothing is exactly the case where something was missed. A
        // programmatic jump settles before the cell exists, the activation is
        // dropped, and the screen keeps describing the page before it:
        // measured as `settled=1 engaged=post-new-07`, an interface belonging
        // to a page two positions back, with the pager locked for it.
        //
        // Cleaning up only when something changed means never cleaning up
        // after the change that went missing.
        if let index { commentsCoordinator.reconcileRestingInterface(activeIndex: index) }
        sideList?.activePostDidChange(activePostID)
        sideListSession.activePostDidChange()
    }

    // MARK: - Viewing history (#1344)

    /// Where every post the viewer opens or swipes onto is recorded — the
    /// profile's History tab (#1344). Nil records nothing (tests, previews);
    /// the app's feeds get the app's one pile from the builder (#2376).
    ///
    /// ⚠️ ON ACTIVATION, NO DWELL (the owner, 2026-10-17: "tous les posts
    /// consultés/ouverts, comme Instagram ou TikTok"). A 2 s dwell missed
    /// the posts swiped through, and every TEXT post: one opens in the
    /// comments layout, which resigned the page before the dwell ran out.
    var viewHistory: PostViewHistoryStore?

    func apply(_ transition: SnapLifecycleDispatcher.Transition) {
        if let resign = transition.resign {
            // Paging within the feed: the page stays alive and a swipe away, so
            // it keeps its player and simply stops advancing.
            lifecycleCell(at: resign)?.didResignActive(releasingPlayback: false)
            // Paging away leaves the stakes alone: a burst stays undoable
            // while its toast is up, and its toast's end sends it (#2532).
            // A text page's resting engagement is not retired here: it keeps
            // its interface until its last pixel has left (`didEndDisplaying`).
        }
        if let activate = transition.activate {
            // The cell that will be active almost never exists yet when
            // `zoomTransitionWillBegin` fires — it is realized by the layout
            // pass the presentation itself triggers — so the deferral is
            // stamped here, at the moment it is about to start playing.
            if let snapCell = collectionView.cellForItem(
                at: IndexPath(item: activate, section: 0)
            ) as? SnapFeedCell {
                snapCell.defersPlaybackForFlight = flight.defersPlaybackForStagingFlight
                zoomDestination.stampFlightMediaStart(on: snapCell)
                // The chrome's hold takes the same net, for the same reason:
                // stamped on `activeSnapCell` alone it reached nobody, and
                // the ticker laid its train unheld, off-window, mid-flight
                // (see `willDisplay`).
                if flight.isAwaitingZoomPresentation { snapCell.setChromeHeldForFlight(true) }
            }
            lifecycleCell(at: activate)?.willBecomeActive()
            #if DEBUG
            if orderedIDs.indices.contains(activate) { debugActivations.append(orderedIDs[activate]) }
            #endif
            // The pages either side get ready NOW, at the settle, rather than
            // when UIKit's scroll heuristic happens to ask — see
            // `warmSettledWindow`.
            warmPlanner.warmSettledWindow(around: activate)
            // Same settle-quantized seam that drives playback: both bar
            // surfaces (identity pill above, media attribution below) follow
            // the active page.
            settledPageChrome.updateBarChrome(at: activate)
            // And the comment ticker: activation is what triggers (or
            // re-emits) the page's queue.
            if orderedIDs.indices.contains(activate) {
                let id = orderedIDs[activate]
                viewModel.pageDidBecomeActive(id)
                // The posts the server withholds leave once the viewer is off
                // them (#2048) — a turn later, outside this activation: the
                // ones the items hold, and the page kept on show (`render`).
                let leavesKept = keptUnavailableID.map { $0 != id } ?? false
                if leavesKept || viewModel.holdsUnavailable(except: id) {
                    if leavesKept { keptUnavailableID = nil }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if !viewModel.dropUnavailable(except: activePostID), let state = lastRenderState {
                            render(state)
                        }
                    }
                }
                viewHistory?.record(id.rawValue)
                // Text-only pages REST in the comments layout — the format
                // itself is the trigger, no user gesture. The VISUAL
                // interface was already pre-rendered on visibility (as the
                // cell scrolled in); settling only applies phase 2, the
                // pager lock + toolbar context. The pre-render here is a
                // BELT for the start-index landing, where a cell can be
                // active before its `willDisplay` pre-render ran. Model
                // presence REQUIRED — a not-yet-hydrated page reads as
                // "unknown", never "text-only".
                if let model = modelsByID[id], model.mediaURL == nil {
                    // Mounting, promoting, releasing a page that has gone and
                    // the pager's own lock are ONE decision now — see
                    // `reconcileRestingInterface`.
                    commentsCoordinator.reconcileRestingInterface(activeIndex: activate)
                    if commentsEngagedID == id, commentsEngagementIsResting {
                        commentsCoordinator.lockRestingEngagement()
                    }
                } else {
                    // A MEDIA page settles too, and the same reconcile is what
                    // releases an interface the page before it left behind and
                    // gives the pager back — the case that locked the feed on a
                    // photograph for a text post two pages ago.
                    commentsCoordinator.reconcileRestingInterface(activeIndex: activate)
                }
                if modelsByID[id]?.mediaURL != nil, let cell = collectionView.cellForItem(
                    at: IndexPath(item: activate, section: 0)
                ) as? SnapFeedCell {
                    // MEDIA pages warm their comments panel here instead of
                    // at tap time — see `prewarmComments`. The settle seam
                    // is where the page has stopped moving and nothing is
                    // animating, which is the only moment ~115ms of layout
                    // is free.
                    commentsCoordinator.prewarmComments(for: id, host: cell)
                }
            }
        }
    }

    // MARK: - Sound sheet

    /// The attribution's tap: the sound the page is set to, in a sheet
    /// (`SnapSoundSheetPresenter`).
    func presentSoundSheet() { soundSheetPresenter.presentSoundSheet() }

    /// The posts the sound sheet leaves out (`SnapSoundSheetPresenter`), for
    /// tests.
    nonisolated static func soundSheetExclusions(
        _ posts: Set<PostID>, current: PostID, droppingUnknown: Bool, isMedia: (PostID) -> Bool?
    ) -> Set<PostID> {
        SnapSoundSheetPresenter.soundSheetExclusions(
            posts, current: current, droppingUnknown: droppingUnknown, isMedia: isMedia
        )
    }

    /// Puts the SCREEN's bars on the page's theme (`SnapChromeThemeLender`).
    func applyChromeTheme(hasMedia: Bool) {
        chromeThemeLender.applyChromeTheme(hasMedia: hasMedia)
    }

    /// Hands the shared bars back (`SnapChromeThemeLender`). Internal so a
    /// test can decide.
    func handBackChromeTheme(interactive: Bool, whenDecided: (@escaping (Bool) -> Void) -> Void) {
        chromeThemeLender.handBackChromeTheme(interactive: interactive, whenDecided: whenDecided)
    }

    /// A grab's outcome, reported by the first of its release and its
    /// completion (#1510) — once.
    @MainActor
    final class GrabDecision {
        private var decided: ((Bool) -> Void)?
        init(_ decided: @escaping (Bool) -> Void) { self.decided = decided }
        func report(committed: Bool) {
            let decided = self.decided
            self.decided = nil
            decided?(committed)
        }
    }

    /// A grab is undecided: nothing re-themes or hands back meanwhile
    /// (`SnapChromeThemeLender`).
    var isHandingChromeBack: Bool { chromeThemeLender.isHandingChromeBack }

    /// Hands every lent style back — to `nav`'s bars, or the stack's
    /// (`SnapChromeThemeLender`).
    func releaseChromeTheme(from nav: UINavigationController? = nil) {
        chromeThemeLender.releaseChromeTheme(from: nav)
    }

    /// The settled page's model — what the toolbar's share/more act on.
    var activeModel: FeedItemDisplayModel? {
        guard let index = lifecycle.activeIndex,
              orderedIDs.indices.contains(index) else { return nil }
        return modelsByID[orderedIDs[index]]
    }

    /// The page the screen shows or is about to: the active one, or — before
    /// the first layout has made one active — the page it will open on (its
    /// remembered index, or the seed's first). What the bars' theme is
    /// decided from at arrival (`applyChromeTheme`).
    var arrivalModel: FeedItemDisplayModel? {
        if let activeModel { return activeModel }
        let index = lifecycle.pageIndex ?? 0
        guard orderedIDs.indices.contains(index) else { return nil }
        return modelsByID[orderedIDs[index]]
    }

    // MARK: - Media toolbar actions

    /// The post's share sheet (`SnapPostActions`).
    func presentShareSheet(for id: PostID) { postActions.presentShareSheet(for: id) }

    /// The post sheet's own chips (`SnapPostActions`), for tests.
    func shareSheetActions(for id: PostID) -> [ShareSheetAction] { postActions.shareSheetActions(for: id) }

    func lifecycleCell(at index: Int) -> SnapCellLifecycle? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapCellLifecycle
    }

    #if DEBUG
    /// What the last settle warmed (`SnapWarmPlanner`), for tests.
    var debugLastWarmedWindow: [Int] { warmPlanner.debugLastWarmedWindow }
    #endif

}

// MARK: - ZoomTransitionDestination

extension SnapFeedViewController: ZoomTransitionDestination {
    /// A full-bleed feed covers the tab bar.
    public var concealsAppTabBar: Bool { true }

    // MARK: The hero's requirements, forwarded (#2387)

    // ⚠️ EVERY REQUIREMENT THIS SCREEN ANSWERS, ANSWERED HERE, one line each,
    // by `SnapZoomDestination`. The engine casts THIS controller, not the
    // collaborator, and a requirement dropped from this list does not fail to
    // compile: the protocol's default answers instead, silently — a grab that
    // takes any vertical drag, a landing that never waits for a picture, a
    // donated surface nobody takes back. `SnapZoomForwardingTests` holds the
    // list against the protocol.

    public func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect {
        zoomDestination.zoomTargetFrame(in: container)
    }

    public func zoomPageFraming(sourcePicture: UIImage?) -> ZoomPageFraming? {
        zoomDestination.zoomPageFraming(sourcePicture: sourcePicture)
    }

    public func zoomFlightChrome() -> UIView? {
        zoomDestination.zoomFlightChrome()
    }

    public var zoomDestinationContentIsReady: Bool {
        zoomDestination.zoomDestinationContentIsReady
    }

    public var zoomDestinationMediaIsRendering: Bool {
        zoomDestination.zoomDestinationMediaIsRendering
    }

    public func zoomPrepareForPresentation(in bounds: CGRect) {
        zoomDestination.zoomPrepareForPresentation(in: bounds)
    }

    /// Pays this page's first layout and raster before the flight
    /// (`SnapZoomDestination.prepareForHeroPresentation`).
    public func prepareForHeroPresentation(in bounds: CGRect) {
        zoomDestination.prepareForHeroPresentation(in: bounds)
    }

    public func setZoomContentHidden(_ hidden: Bool) {
        zoomDestination.setZoomContentHidden(hidden)
    }

    public var zoomGrabCarriesLiveInterface: Bool {
        zoomDestination.zoomGrabCarriesLiveInterface
    }

    public func setZoomDismissState(_ state: ZoomDismissState) {
        zoomDestination.setZoomDismissState(state)
    }

    public func zoomTransitionWillBegin(flyingLivePlayer: Bool) {
        zoomDestination.zoomTransitionWillBegin(flyingLivePlayer: flyingLivePlayer)
    }

    public func zoomTransitionWillStartMedia(at seconds: TimeInterval) {
        zoomDestination.zoomTransitionWillStartMedia(at: seconds)
    }

    @discardableResult
    public func zoomParkLiveMediaForHandoff() -> Bool {
        zoomDestination.zoomParkLiveMediaForHandoff()
    }

    public func zoomDonateLiveMediaView() -> UIView? {
        zoomDestination.zoomDonateLiveMediaView()
    }

    public func zoomAdoptLiveMediaView(_ view: UIView) {
        zoomDestination.zoomAdoptLiveMediaView(view)
    }

    public func zoomReclaimLiveMediaView(_ view: UIView) {
        zoomDestination.zoomReclaimLiveMediaView(view)
    }

    public func zoomTransitionWillDepart() {
        zoomDestination.zoomTransitionWillDepart()
    }

    public func zoomTransitionDidEnd() {
        zoomDestination.zoomTransitionDidEnd()
    }

    public func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
        zoomDestination.zoomMirrorLiveMedia(onto: surface)
    }

    public var isReadyForInteractiveDismissal: Bool {
        zoomDestination.isReadyForInteractiveDismissal
    }

    public var zoomDismissalKind: ZoomDismissalKind {
        zoomDestination.zoomDismissalKind
    }

    public func zoomVerticalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        zoomDestination.zoomVerticalDismissalPermitted(at: location, in: view)
    }

    public func zoomUpwardDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        zoomDestination.zoomUpwardDismissalPermitted(at: location, in: view)
    }

    public func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        zoomDestination.zoomHorizontalDismissalPermitted(at: location, in: view)
    }

    public func setContentScrollEnabled(_ enabled: Bool) {
        zoomDestination.setContentScrollEnabled(enabled)
    }

    /// Renders a projection the opener already has, before this screen's own
    /// fetch returns — so the page configures at push time instead of ~0.7s
    /// later. Additive: a real page replaces it, and a seed arriving after one
    /// is ignored.
    ///
    /// A seed may be PARTIAL (#1863): the members of a set the app holds, as
    /// long as the opening post is one of them. The rest are not seeded later
    /// (a second seed is ignored): the screen's own first page brings the
    /// whole set, replaces the seed, and the late members arrive in their
    /// places through the snapshot.
    public func seedProjection(_ models: [FeedItemDisplayModel]) {
        loadViewIfNeeded()
        viewModel.seed(models)
    }

    /// `models` of the first one's kind — media (a picture, a video, a
    /// carousel) or text: what a one-kind feed (#1421) is seeded with, as its
    /// provider's pages are filtered, so a page the viewer reaches before the
    /// fetch lands is never one the fetch then takes away. The home timeline
    /// stays mixed and is not seeded through this.
    static func keepingOpeningKind(_ models: [FeedItemDisplayModel]) -> [FeedItemDisplayModel] {
        guard let opening = models.first else { return models }
        let isMedia = opening.mediaURL != nil
        return models.filter { ($0.mediaURL != nil) == isMedia }
    }

    /// The opening's one-shot requests (`SnapOpeningRequests`), answered
    /// where the builder, the landing, the cell provider and the tests ask.
    public func openMediaPage(_ page: Int, for id: PostID) { openingRequests.openMediaPage(page, for: id) }

    public func openComments(for id: PostID, revealingFrom rect: CGRect? = nil) {
        openingRequests.openComments(for: id, revealingFrom: rect)
    }

    func applyPendingComments(animated: Bool) { openingRequests.applyPendingComments(animated: animated) }

    func consumeInitialMediaPage(for id: PostID) -> Int? { openingRequests.consumeInitialMediaPage(for: id) }

    var pendingCommentsID: PostID? { openingRequests.pendingCommentsID }


    /// **THE TEXT REVEAL**. Where the active TEXT page draws its
    /// caption bubble, in `space` — the anchor a clip-window reveal matches to
    /// the row it opened from.
    ///
    /// Answered off the resting engagement's own child controller, which is
    /// the only thing that knows: a text page's caption is the first ROW of
    /// its comment stream (`CaptionBubbleCell`), not a view this screen owns a
    /// reference to. Nil for a media page, and for a text page whose stream
    /// has not been mounted — both want the plain reveal, which needs no
    /// anchor.
    public func revealCaptionAnchor(in space: UICoordinateSpace) -> CGRect? {
        (commentsContentVC as? PostDetailViewController)?.revealCaptionAnchor(in: space)
    }

    /// The text reveal's veil and borrowed author band (`SnapRevealScenery`),
    /// answered where the reveal's installer and its flight ask the screen.
    public func installRevealVeil(below cut: CGFloat?, tint: UIColor?) {
        revealScenery.installRevealVeil(below: cut, tint: tint)
    }

    public func setRevealVeilOpacity(_ alpha: CGFloat) { revealScenery.setRevealVeilOpacity(alpha) }

    public func installRevealAuthorBand(
        in rect: CGRect?, model: PostAuthorBandView.Model?, pipeline: ImagePipeline?
    ) {
        revealScenery.installRevealAuthorBand(in: rect, model: model, pipeline: pipeline)
    }

    public func setRevealAuthorBandOpacity(_ alpha: CGFloat) { revealScenery.setRevealAuthorBandOpacity(alpha) }


    /// **THE TEXT REVEAL**. Lends the active page a ground for the
    /// length of a reveal — see `SnapFeedCell.setRevealGroundTint`.
    ///
    /// Aimed at the ACTIVE cell only. A reveal opens onto one page, and the
    /// pages either side of it are off screen behind the mask; tinting them
    /// too would mean colours to hand back for cells the transition never
    /// touched.
    public func setRevealGroundTint(_ color: UIColor?) {
        activeSnapCell?.setRevealGroundTint(color)
    }

    /// The post whose loading state stands in until the corpus arrives.
    /// Recorded only — `presentLoadingPage` is what draws, so a hero route that
    /// never reaches the text-reveal installer is never given comment bones.
    public func armLoadingPage(for id: PostID) { commentsCoordinator.armLoadingPage(for: id) }

    /// Draws the arrival screen's loading state on this screen's own view — the
    /// host `installRevealVeil` uses, and for the same reason: it has to cover
    /// the whole page, and the page has no cell yet.
    public func presentLoadingPage() {
        loadViewIfNeeded()
        commentsCoordinator.presentLoadingPage()
    }

    /// The tone to wear before there is anything to show — the fill of the
    /// thing the viewer just tapped. See `emptyGround`.
    public func setEmptyGround(_ color: UIColor) {
        loadViewIfNeeded()
        emptyGround = color
        applyGrounds()
    }

    /// What both floors should be right now: the lent tone while there are no
    /// pages, and afterwards the settled page's own ground.
    ///
    /// One resolver, because the two floors disagreed. The pager followed the
    /// format at every settle while the root view was assigned a literal black
    /// in four places, so a text page sat on a light pager over a black root.
    private func resolvedGround() -> UIColor {
        guard !orderedIDs.isEmpty else { return emptyGround }
        let activeID = activeSnapCell.flatMap { cell in
            collectionView.indexPath(for: cell).map { orderedIDs[$0.item] }
        } ?? orderedIDs.first
        return isTextPage(activeID) ? .systemBackground : .black
    }

    /// "This post isn't available", for the page that just gave way (#2048).
    private func showPostUnavailableToast() {
        #if DEBUG
        debugUnavailableToastsShown += 1
        #endif
        Feedback.info("This post isn't available", symbol: "eye.slash", from: self, id: "post-unavailable")
    }

    /// Whether `id`'s page is a TEXT page — false while its model is unknown
    /// (#2048). `modelsByID[id]?.mediaURL == nil` reads a missing model as
    /// text: a post that had left was rested in its comments panel, on a
    /// white ground, over the clip still on screen. A source guard refuses
    /// that spelling in this file (`SnapUnknownIsNeverTextTests`).
    func isTextPage(_ id: PostID?) -> Bool {
        guard let id, let model = modelsByID[id] else { return false }
        return model.mediaURL == nil
    }

    /// ⚠️ GUARDED, because a flight needs both floors CLEAR. A masked reveal
    /// and an engaged dismissal draw the card over this screen, and an opaque
    /// ground between the two shuts the card out — the defect the note in
    /// `reconcileRestingInterface` records. Those two paths restore the floors
    /// themselves, through here, once their flag is down.
    func applyGrounds() {
        guard !flight.isEngagedDismissalActive else { return }
        let ground = resolvedGround()
        view.backgroundColor = ground
        collectionView.backgroundColor = ground
    }

    /// Aims an ALREADY-BUILT feed at a different window of posts, so a second
    /// hero push can reuse this controller instead of constructing one.
    ///
    /// Rebuilding is what the push was paying for. A fresh controller means
    /// fresh bar items, and iOS 26 materialises their glass inside
    /// `pushViewController` where it is the flight's stall — a cost that
    /// cannot be pre-paid from outside the bar, only avoided by not incurring
    /// it (see `ZoomFlightProfiler`). A reused
    /// controller keeps its bar, its layout, and its cells.
    ///
    /// Reuse is only sound if NOTHING survives that describes the old window,
    /// so this is deliberately a hard reset rather than a diff: an open
    /// engagement is torn down, a warm panel is dropped, the pager returns to
    /// the top, and the flight flags are cleared in case a previous flight
    /// ended somewhere other than its landing. The corpus itself is the view
    /// model's to replace.
    ///
    /// Returns false if this controller is not in a reusable state, so the
    /// caller can build a fresh one rather than push a controller that is
    /// still on screen.
    @discardableResult
    public func repoint(to ids: [PostID], continuation: SnapFeedContinuation? = nil) -> Bool {
        guard navigationController == nil, parent == nil else { return false }
        loadViewIfNeeded()

        // The engagement first: it owns a child controller and a cell's
        // interior, and both must be gone before the corpus underneath them
        // changes. This is the same teardown the animated dismiss lands on,
        // taken synchronously.
        commentsCoordinator.finishCommentsDisengagement()
        // …including whatever that teardown just re-warmed for the OLD active
        // page, which is about to stop existing.
        commentsCoordinator.discardPrewarmedComments()
        // A repoint is a SECOND cold window: it resets the items and goes back
        // to `.loading` without emitting. Drop the old page and re-arm for the
        // next one — the next `TextRevealInstaller.geometry` is what draws.
        commentsCoordinator.rearmLoadingPage(for: ids.first)

        // Flight state, in case a flight ended anywhere other than its
        // landing — a cancelled push leaves these set, and a reused
        // controller would then start its next flight already believing it is
        // in one.
        flight.isAwaitingZoomPresentation = false
        // A reused screen starts its next visit with no flight pending and
        // nothing hidden, whatever the last visit's flight left behind.
        flight.isAwaitingRevealPresentation = false
        view.alpha = 1
        // And nothing the last visit's landing parked over it.
        ZoomLandingLeftovers.clear(over: view)
        zoomDestination.donatedLiveView = nil
        flight.flightChrome = nil
        pagerDrive.dropPageDrive()

        // The tapped post is always the head of the window, so the pager goes
        // back to the top. Done BEFORE the new items land, so the first
        // snapshot applies against a settled offset rather than scrolling
        // under one.
        collectionView.setContentOffset(.zero, animated: false)

        viewModel.repoint(to: ids, continuation: continuation)
        return true
    }

    #if DEBUG
    /// Arms the engaged dismissal WITHOUT a real engagement, so a test can
    /// pin the ordering rule the flag exists for.
    ///
    /// The rule is about two public entry points meeting in the wrong order —
    /// the hide is deferred by a commit and a display tick, so it lands after
    /// the grab has begun — and the engagement itself is not what is under
    /// test. This flips the flag and nothing else.
    func debugArmEngagedDismissal() {
        flight.isEngagedDismissalActive = true
    }
    #endif

    var activeSnapCell: SnapFeedCell? {
        guard let index = lifecycle.activeIndex else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
    }

    /// The post currently filling the screen — what a hero dismissal should
    /// land on, which after any paging is not the post that opened the feed.
    /// Falls back to the first post before a page has settled, matching
    /// `configureFlightChrome`'s rule so the card's chrome and its landing
    /// target can never describe different posts.
    var activePostID: PostID? {
        let index = settledPageIndex
        return orderedIDs.indices.contains(index) ? orderedIDs[index] : nil
    }

    /// Which page of the active post's collection is on screen — what a close
    /// has to put the row it lands on onto.
    ///
    /// Read off the SETTLED page's cell for the same reason `activePostID` is:
    /// the screen is already reporting itself invisible by the time a close
    /// asks, so anything gated on visibility answers about the wrong post.
    public var settledMediaPage: Int? { activeMediaPage }

    var activeMediaPage: Int? {
        let index = settledPageIndex
        return (collectionView.cellForItem(at: IndexPath(item: index, section: 0))
            as? SnapFeedCell)?.currentMediaPage
    }

    /// The page this screen is ON, which is NOT the same as the page it is
    /// actively playing.
    ///
    /// ⚠️ `activeIndex` GOES NIL THE MOMENT THE SCREEN STOPS BEING VISIBLE, and
    /// a dismissal is exactly that moment: `viewWillDisappear` reports the
    /// surface down, and every question asked afterwards — which post is this,
    /// what does it travel as, where does it land — fell back to page ZERO, the
    /// post the viewer opened with.
    ///
    /// Measured on a back-button close from page 11 of a text post: the pop
    /// asked and was told `.hero`, because post ZERO is a photograph. The card
    /// close had already adopted and CONCEALED the landed row, the flight it
    /// was handed to could not land on a text row, and the feed came back with
    /// a hole where the post should have been.
    ///
    /// Visibility is the right gate for PLAYBACK — nothing off screen should
    /// hold a player — and the wrong one for identity. The snapped page is a
    /// fact about the scroll position, and it survives the screen going away.
    var settledPageIndex: Int { lifecycle.pageIndex ?? 0 }

    // MARK: - Side list (#1425)

    /// The side list's session and the swipe chain (`SnapSideListSession`),
    /// answered where the arbiter, the side list, its edge pull and the tests
    /// ask the screen.
    func isInTrailingEdge(_ origin: CGPoint) -> Bool { sideListSession.isInTrailingEdge(origin) }

    func isOnTrailingColumn(_ origin: CGPoint) -> Bool { sideListSession.isOnTrailingColumn(origin) }

    func swipeStage(for direction: SwipeDirection, at origin: CGPoint) -> SwipeStage? {
        sideListSession.swipeStage(for: direction, at: origin)
    }

    func swipePushDidEnd(committed: Bool) { sideListSession.swipePushDidEnd(committed: committed) }

    func swipePushWillBegin() { sideListSession.swipePushWillBegin() }

    func sideListCandidates() async -> [FeedEntry] { await sideListSession.sideListCandidates() }

    var isSideListSessionActive: Bool { sideListSession.isSideListSessionActive }

    func beginSideListSessionIfNeeded() { sideListSession.beginSideListSessionIfNeeded() }

    func liveVideoSurface(for id: PostID) -> VideoRenderView? { sideListSession.liveVideoSurface(for: id) }

    func closeSideListForDismissal() { sideListSession.closeSideListForDismissal() }

    var sideListResumeAnchor: PostID? { sideListSession.sideListResumeAnchor }

    func settlePager(onIndex index: Int) { sideListSession.settlePager(onIndex: index) }

    func showSideListEntry(_ entry: FeedEntry) { sideListSession.showSideListEntry(entry) }

    func sideListPoseDidChange(progress: CGFloat) { sideListSession.sideListPoseDidChange(progress: progress) }

    var sideListEdgePulls: SnapSideListEdgePull.Directions { sideListSession.sideListEdgePulls }

    var sideListBars: UIEdgeInsets { sideListSession.sideListBars }

    func setSideListOverlayOffset(_ offset: CGFloat) { sideListSession.setSideListOverlayOffset(offset) }

    func sideListDidSettle(open: Bool) { sideListSession.sideListDidSettle(open: open) }

    var sideListPausedPost: PostID? {
        get { sideListSession.sideListPausedPost }
        set { sideListSession.sideListPausedPost = newValue }
    }

    // MARK: - The swipe chain (#1525)

    var swipeNavigationController: UINavigationController? { navigationController }

    /// ⚠️ THE POST ON SHOW STAYS ON SHOW THROUGH A REORDER (#1580, the
    /// owner's device check): the side list opening or closing swaps the
    /// pager's items, and the post on show changes INDEX — unless it is the
    /// list's source, at 0 both ways. Read by index, the screen briefly sat
    /// on whichever post took the old index, resigned the post on show and
    /// re-activated it a moment later: its clip or its song jumped, every
    /// time but on the source post. The pager follows the post instead, and
    /// the activation, which never changed post, is not replayed.
    private func keepOnShow(_ held: PostID?) {
        guard let held, let index = orderedIDs.firstIndex(of: held), index != lifecycle.pageIndex else { return }
        let page = collectionView.bounds.height
        guard page > 0 else { return }
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * page), animated: false)
            collectionView.layoutIfNeeded()
        }
        lifecycle.rebase(to: index)
    }

    /// ⚠️ THE POST ON SHOW KEEPS ITS PLAYER THROUGH THE ITEMS' SWAP (#1580,
    /// measured with `-carousel-audit` and a stop's stack): opening and
    /// closing the side list swap the pager's items, and UIKit's update lays
    /// the OLD items out at the NEW offset — the post's cell leaves the
    /// screen for a moment and is recycled. Its player used to go with it,
    /// and the page showing the post again started a fresh one from the last
    /// filed second: the jump the owner saw at every open and close. Now the
    /// departing page keeps its clip (`resignKeepingPlayback`) and the
    /// arriving one takes the same player over — bound alongside, then
    /// adopted — so the clip never stops.
    func handOverReorderedPlayback() {
        let keptSurfaces = reorderHeldCell
        defer {
            reorderHeld = nil
            reorderHeldCell = nil
        }
        // The cell that kept the band and the pill running for the post on
        // show stands them down unless it shows that post still (#1798).
        if let keptSurfaces, keptSurfaces !== settledSnapCell || activePostID != reorderHeld?.id {
            keptSurfaces.standDownCommentSurfaces()
        }
        guard let held = reorderHeld, activePostID == held.id, let cell = settledSnapCell else { return }
        if let old = held.surface, let surface = cell.liveVideoSurface, surface !== old,
           let videoPlayback, videoPlayback.hasPlayer(in: old) {
            if videoPlayback.attachSurface(surface, alongsideSurface: old),
               videoPlayback.adoptSurface(surface, replacing: old) {
                videoPlayback.detachSurface(old, reason: "reorder handover")
                surface.revealOnFirstFrame()
            } else {
                // Refused: the departing page kept its clip for nobody —
                // returned now, and the arriving page starts its own.
                videoPlayback.stop(old)
            }
        }
        if !cell.isLifecycleActive { cell.willBecomeActive() }
    }

    /// The settled page's cell — the post on show's, whether or not its
    /// activation has run (the side list's marks ask it at rest).
    var settledSnapCell: SnapFeedCell? {
        collectionView.cellForItem(at: IndexPath(item: settledPageIndex, section: 0)) as? SnapFeedCell
    }

    #if DEBUG
    /// The settled page's cell. Tests.
    var debugSettledSnapCell: SnapFeedCell? { settledSnapCell }
    #endif

    // MARK: - The downward drag (#2056, #2057)

    /// Where the feed stands, for `SnapVerticalDragRouter`.
    var downwardDragSituation: SnapVerticalDragRouter.Situation {
        let index = settledPageIndex
        let page = collectionView?.bounds.height ?? 0
        let atRest = page > 0 && abs((collectionView?.contentOffset.y ?? 0) - CGFloat(index) * page) < 0.5
        return SnapVerticalDragRouter.Situation(
            settledIndex: index,
            isAtRestOnPage: atRest,
            sideListOpen: sideList?.isOpen == true,
            // The pager pages a media page; the drive, a page whose comments
            // hold the scroll — a text page, an open panel (#2058).
            pagerPagesHere: collectionView?.isScrollEnabled == true,
            drivePagesHere: commentsEngagedID != nil
        )
    }

    /// Who owns a downward drag beginning now: the pager or the dismissal.
    var downwardDragOwner: SnapVerticalDragRouter.DownwardOwner {
        SnapVerticalDragRouter.downwardOwner(downwardDragSituation)
    }

    /// Whether the viewer is on the list's last post (#628, #761): the settled
    /// page is the last one loaded, and no page is on its way.
    ///
    /// ⚠️ ON EVERY FULL-SCREEN FEED, NOT ONLY A FINISHED SOURCE (#761, the
    /// owner's call 2026-10-10). It used to need the source to have SAID
    /// nothing follows (`FeedViewModel.isSourceExhausted`) — which only the
    /// map's routes ever did: For You's window and a profile's paged gallery
    /// never reached "the end", so their last post never let the grab close.
    var isAtEndOfSource: Bool {
        !viewModel.isLoadingNextPage && !orderedIDs.isEmpty && settledPageIndex == orderedIDs.count - 1
    }
}

#if DEBUG
extension SnapFeedViewController: ArrivalInvariantReporting {
    /// Every transition-scoped flag is down once a flight has ended on this
    /// screen — the reused-feed defects (a hide never undone, a reveal flag
    /// raised by a close) were all one of these left up.
    public func arrivalFacts() -> [(name: String, holds: Bool)] {
        [
            ("feed.awaitingZoom", !flight.isAwaitingZoomPresentation),
            ("feed.awaitingReveal", !flight.isAwaitingRevealPresentation),
            ("feed.engagedDismissal", !flight.isEngagedDismissalActive),
            ("feed.flightChrome", flight.flightChrome == nil),
            ("feed.departing", !flight.isDepartingWithFlight),
        ]
    }
}
#endif

extension SnapFeedViewController: SwipeStageHosting {}

// MARK: - The full-surface back swipe (#1728)

extension SnapFeedViewController: ContentPopGating {
    /// ⚠️ NOT WHILE THE SIDE LIST IS OPEN OR MOVING (#1728): a rightward drag
    /// then closes the list (the arbiter's panel). With the comments layout
    /// open the stack's full-surface back swipe began alongside it and
    /// closed the whole post — filmed on the simulator. The same rule the
    /// grab follows (`isReadyForInteractiveDismissal`).
    public func allowsContentPop(beginningAt point: CGPoint, in view: UIView) -> Bool {
        !(sideList?.isEngaged ?? false) && !(sideList?.isOpen ?? false)
    }
}

extension SnapFeedViewController: HorizontalDragClaiming {
    /// The side list, open or on its way, is closed by the swipe: every pager
    /// around the page or on it gives the drag away — the comments' tabs
    /// (#2007), as For You's sector did until #2453 (#1703).
    func claimsHorizontalDrag(velocity: CGPoint) -> Bool {
        guard let sideList else { return false }
        return sideList.isOpen || sideList.isEngaged
    }
}

// MARK: - The sound's host (#2387)

extension SnapFeedViewController: SnapSoundPlaybackHost {
    var viewportShareHost: UIView { view }

    func displayModel(for id: PostID) -> FeedItemDisplayModel? { modelsByID[id] }

    func drawSoundSpinning(_ playing: Bool) {
        activeSnapCell?.setSoundSpinning(playing)
        toolbarComposer.footerSoundButton.setSpinning(playing)
        (commentsContentVC as? PostDetailViewController)?.setRailSoundSpinning(playing)
        (previewRestingVC as? PostDetailViewController)?.setRailSoundSpinning(playing)
    }
}

// MARK: - How it is left (#1144)

extension SnapFeedViewController: StackScreen {
    /// Its hero or slide owns the way back when it was opened by one; a plain push goes back natively.
    var leaving: ScreenLeaving { zoomOwnsInteractiveDismissal ? .ownGesture : .nativeBack }
}

// MARK: - The pull to go back (#2045, #2046)

/// On a feed that came in with the native push, a vertical close is a pull:
/// the page drive's other half (`SnapPagerDrive.pullToClose`).
extension SnapFeedViewController: VerticalPullClosing {
    @discardableResult
    func pullToClose(travel: CGFloat, along axis: ZoomDismissAxis) -> CGFloat {
        pagerDrive.pullToClose(travel: travel, along: axis)
    }

    func endPullToClose(commit: Bool) {
        pagerDrive.endPullToClose(commit: commit)
    }

    #if DEBUG
    var debugPullIndicator: PullToGoBackIndicator? { pagerDrive.pullIndicator }
    #endif
}

// MARK: - The page drive's host (#2387)

extension SnapFeedViewController: SnapPagerDriveHost {
    var pager: UIScrollView { collectionView }

    var pagerHostView: UIView { view }

    var pullComposerBar: UIView? { (commentsContentVC as? PostDetailViewController)?.composeBar }
}

// MARK: - The comments' host (#2387)

extension SnapFeedViewController: SnapCommentsCoordinatorHost {
    func pageIndexPath(for id: PostID) -> IndexPath? { dataSource.indexPath(for: id) }
}

// MARK: - The hero destination's host (#2387)

extension SnapFeedViewController: SnapZoomDestinationHost {}

// MARK: - The toolbar's host (#2387)

extension SnapFeedViewController: SnapToolbarComposerHost {
    /// The toolbar's items as built (`SnapToolbarComposer`), read by the
    /// bars' widths and the comments' teardown.
    var defaultToolbarItems: [UIBarButtonItem] { toolbarComposer.defaultToolbarItems }
}

// MARK: - The author bar's host (#2387)

extension SnapFeedViewController: SnapAuthorBarHost {}

// MARK: - The settled page chrome's host (#2514)

extension SnapFeedViewController: SnapSettledPageChromeHost {}

// MARK: - The appearance watch's host (#2514)

extension SnapFeedViewController: SnapDeviceAppearanceWatchHost {}

// MARK: - The page readiness's host (#2514)

extension SnapFeedViewController: SnapPageReadinessHost {}

// MARK: - The loaders' host (#2514)

extension SnapFeedViewController: SnapPageLoadersHost {}

// MARK: - The reveal scenery's host (#2514)

extension SnapFeedViewController: SnapRevealSceneryHost {}

// MARK: - The opening requests' host (#2514)

extension SnapFeedViewController: SnapOpeningRequestsHost {}

// MARK: - The navigation bar's host (#2514)

extension SnapFeedViewController: SnapNavigationBarComposerHost {}

// MARK: - The side list session's host (#2514)

extension SnapFeedViewController: SnapSideListSessionHost {}

// MARK: - The post actions' host (#2514)

extension SnapFeedViewController: SnapPostActionsHost {}

// MARK: - The warm planner's host (#2514)

extension SnapFeedViewController: SnapWarmPlannerHost {}

// MARK: - The chrome theme's host (#2514)

extension SnapFeedViewController: SnapChromeThemeLenderHost {}

// MARK: - The sound sheet's host (#2514)

extension SnapFeedViewController: SnapSoundSheetPresenterHost {}

// MARK: - The QA hooks' host (#2514)

#if DEBUG
extension SnapFeedViewController: SnapFeedDebugHooksHost {}
#endif

/// The author pill, answered where the screen's other collaborators ask the
/// screen for it — the toolbar, the comments, the hero destination
/// (`SnapAuthorBar`).
extension SnapFeedViewController {
    var authorIdentityView: SnapAuthorIdentityView { authorBar.authorIdentityView }

    func applyAuthorWidthBudget(bar: CGFloat?, sortOnBar: Bool?) {
        authorBar.applyAuthorWidthBudget(bar: bar, sortOnBar: sortOnBar)
    }

    func installAuthorPillAfterLanding() {
        authorBar.installAuthorPillAfterLanding()
    }

    func bindCaptionAuthor(of content: UIViewController?, for id: PostID) {
        authorBar.bindCaptionAuthor(of: content, for: id)
    }

    func observeCommentsDay(of detail: PostDetailViewController?) {
        authorBar.observeCommentsDay(of: detail)
    }

    func syncCommentsDay() {
        authorBar.syncCommentsDay()
    }
}

/// The comments' state, read where the screen reads it — the bars, the page
/// drive, the drag router, the sound's spin (`SnapCommentsCoordinator`).
extension SnapFeedViewController {
    var commentsEngagedID: PostID? { commentsCoordinator.commentsEngagedID }
    /// The engaged comments UI — a child of THIS controller; the cell only
    /// hosts its view while engaged.
    var commentsContentVC: UIViewController? { commentsCoordinator.commentsContentVC }
    var commentsEngagementIsResting: Bool { commentsCoordinator.commentsEngagementIsResting }
    var commentsSheet: SnapCommentsSheetSession? { commentsCoordinator.commentsSheet }
    var restingWarm: SnapWarmSlots<PostID, UIViewController> { commentsCoordinator.restingWarm }
    var previewRestingID: PostID? { commentsCoordinator.previewRestingID }
    private var previewRestingVC: UIViewController? { commentsCoordinator.previewRestingVC }

    func prewarmRestingComments(for id: PostID) {
        commentsCoordinator.prewarmRestingComments(for: id)
    }
}
