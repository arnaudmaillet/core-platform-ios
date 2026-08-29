import CoreStorage
import MediaCore
import CoreModels
import CoreNavigation
import DesignSystem
import MediaPlayback
import PostGrid
import UIKit

/// The full-screen, page-snapping timeline. Drives the *same* `FeedViewModel`
/// as the classic feed — pagination, likes, realtime, compose hand-off all come
/// for free; only the presentation differs. Its one net-new responsibility is
/// the active-page lifecycle (`SnapCellLifecycle`), the seam Phase 2's video
/// player plugs into.
final class SnapFeedViewController: UIViewController {
    private enum Section { case main }

    private let viewModel: FeedViewModel
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, PostID>!
    private let statusLabel = UILabel()
    /// The author identity, hosted as the trailing bar item's custom view —
    /// content-hugging, so the system glass pill wraps it flush. Content
    /// follows the active page via the lifecycle seam.
    private let authorIdentityView = SnapAuthorIdentityView()
    /// The media attribution (cover + author + audio line), hosted as the
    /// native bottom toolbar's leading item. Same stable-custom-view contract
    /// as the identity pill: installed once, content follows the active page.
    private let mediaAttributionView = SnapMediaAttributionView()
    /// The navigation controller whose toolbar this feed is showing — held
    /// weakly across its own pop, when `navigationController` is already nil
    /// but the toolbar bookkeeping must still be settled (`viewDidDisappear`).
    private weak var toolbarHost: UINavigationController?
    /// The share bubble's bookmark action; a property because its glyph
    /// (bookmark / bookmark.fill) follows the active page's saved state.
    private let bookmarkButton = SnapNavControls.makeToolbarActionButton(systemName: "bookmark")

    /// The engaged toolbar's trailing item: the comments sort selector,
    /// occupying the action territory while comments are engaged (the
    /// bookmark/share/more cluster yields — those live in the engaged
    /// card; the audio attribution stays anchored on the left).
    private let commentSortButton = SnapCommentSortButton()
    /// The one living toolbar's items (keep-and-stack): built once and never
    /// swapped. The engagement no longer touches the footer — see
    /// `configureToolbarItems` for why the trailing ✕ left it.
    private var defaultToolbarItems: [UIBarButtonItem] = []
    /// The nav bar's two trailing items, held so comment mode can add the
    /// sort selector beside the author pill and take it away again.
    private var authorItem = UIBarButtonItem()
    private var sortItem = UIBarButtonItem()
    /// The viewer's balance, closing the trailing run on its left —
    /// [‹ back] … [🪙 solde] [author pill] — so a spend made on this very
    /// screen is visibly paid for. DISPLAY-ONLY here: the map's badge is
    /// the claim entry point, this one just watches the store (same shared
    /// instance) and re-renders. Built only when a wallet is injected; a
    /// nil-wallet feed keeps its historical author-only run.
    private let walletBadge = WalletBadgeButton()
    private var walletBadgeItem: UIBarButtonItem?
    /// The nav bar's LEADING item at rest: the back arrow, when the feed was
    /// opened onto a stack it can leave (never on the tab root). Built on
    /// first appearance, when the stack relationship is finally knowable.
    private var backItem: UIBarButtonItem?
    /// The nav bar's LEADING item while a MEDIA post's comments are open: a
    /// ✕ that collapses back to the media layout. It stands in the FOOTER's
    /// trailing corner, taking the ⋯'s bubble while the layout is open, and it
    /// exists independently of `isClosable`: it closes the LAYOUT, not the
    /// screen — which is exactly why the back arrow keeps its own slot.
    private var closeCommentsItem = UIBarButtonItem()
    /// The viewer's saved pile.
    ///
    /// It used to be a `Set` on this screen, which meant a save survived
    /// exactly as long as the feed did and was visible to nothing else. The BFF
    /// still exposes no save API — but the profile now has a Saved tab, and two
    /// surfaces reading one list is precisely what a store is for. See
    /// `PostBookmarkStore` for what a client-owned list can and cannot claim.
    private let bookmarks = PostBookmarkStore()

    /// The viewer's point balance, spent by the rail's boost anchor.
    ///
    /// INJECTED, not created in place like `bookmarks`, because the map
    /// toolbar's currency badge watches the same instance — a spend here must
    /// move that number, and `WalletStore`'s change post is scoped to the
    /// instance that changed (see its doc). Nil (an unwired surface, or a
    /// unit-tested one) leaves the boost anchor visible but inert.
    private let wallet: WalletStore?
    /// Vends the wallet/claim sheet the header's balance badge presents —
    /// the SAME shell-owned sheet the map's badge opens, injected so the
    /// two entries can never diverge. Nil keeps the badge display-only.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    /// id → display model; lookups only, never measurement.
    private var modelsByID: [PostID: FeedItemDisplayModel] = [:]
    private var orderedIDs: [PostID] = []

    private var lifecycle = SnapLifecycleDispatcher()
    /// True between `zoomTransitionWillBegin` and `zoomTransitionDidEnd`. Cells
    /// realized inside that window inherit the playback deferral, so a page
    /// activating mid-flight cannot steal the render slot from the flying card.
    private var isAwaitingZoomPresentation = false
    /// Set by whoever pushes this screen: true when a flight attached a grab to
    /// it, false when it arrived by an ordinary push and the native edge swipe
    /// should work. Written on BOTH paths rather than defaulted, because this
    /// controller is REUSED and a stale answer from the previous presentation
    /// is exactly the bug this would otherwise become.
    public var zoomOwnsInteractiveDismissal = true

    /// The surface currently on loan to a dismissal's flight card, so a
    /// cancelled grab can take it back.
    private var donatedLiveView: VideoRenderView?
    /// The two facts whose AND is the surface's visibility.
    private var isOnScreen = false
    private var isForeground = true
    /// The inert page-chrome replica riding in the hero transition's flying
    /// card. Held weakly for the duration of a flight so a post that hydrates
    /// mid-flight (cold tap) can still fill in the replica's labels; the card
    /// owns the view itself.
    private weak var flightChrome: SnapChromeView?
    /// Unregisters its notification tokens when this VC (and thus the bag) is
    /// released — a nonisolated deinit can't touch the VC's main-actor state.
    private let appObservers = NotificationObserverBag()

    /// Builds the comments panel's content (the comments-only detail) for a
    /// post — injected by the feature builder so this VC needs none of the
    /// detail's dependencies. Nil disables the comments engagement.
    private let makeCommentsPanelContent: ((PostID) -> UIViewController)?
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

    /// The post whose carousel still owes an opening page — see
    /// `openMediaPage(_:for:)`. Stored on the class because an extension
    /// cannot hold state, which is where the seam it belongs to lives.
    private var pendingMediaPage: (id: PostID, page: Int)?
    /// The post that must open ALREADY SHOWING its comments — see
    /// `openComments(for:)`.
    private var pendingCommentsID: PostID?
    /// **OPTION B — `-comments-masked-hero`.** Where the thread's window opens
    /// FROM, in this view's own coordinates. Non-nil only when the opener asked
    /// for the masked variant.
    private var pendingCommentsRevealRect: CGRect?
    private var isMaskedRevealActive = false
    private var isEngagedDismissalActive = false
    private var commentsEngagedID: PostID?
    /// The engaged comments UI — a child of THIS controller (thread data,
    /// scroll position, and reply drafts must never live in a recycled
    /// cell); the cell only hosts its view while engaged.
    private var commentsContentVC: UIViewController?
    /// Transition-scoped: covers what a COLLAPSED card has no room for, for
    /// the length of a reveal. See `installRevealVeil`.
    private var revealVeil: RevealVeilView?
    /// The source row's author band, borrowed for a flight — see
    /// `installRevealAuthorBand`.
    private var revealAuthorBand: PostAuthorBandView?
    /// Whether the active engagement is a text page's RESTING interface —
    /// PRE-RENDERED on visibility (as the cell scrolls in, fully formed,
    /// no reveal spring), then LOCKED at settle. The two phases are split
    /// so the interface slides in complete while the incoming scroll is
    /// never aborted (the pager lock can only land once the page has
    /// settled — disabling it mid-drag would freeze the user's scroll).
    private var commentsEngagementIsResting = false
    /// The page whose comments panel is BUILT but not engaged (the settle
    /// seam's warm). Distinct from `commentsEngagedID`, which means on
    /// screen and interactive.
    private var prewarmedCommentsID: PostID?
    /// The RESTING panel built ahead for a text page — see
    /// `prewarmRestingComments`. Deliberately not the engagement slot.
    private var prewarmedRestingID: PostID?
    private var prewarmedRestingVC: UIViewController?
    /// The panel of a page that is scrolling IN while another still owns the
    /// engagement — see `previewRestingComments`.
    private var previewRestingID: PostID?
    private var previewRestingVC: UIViewController?
    private weak var previewRestingCell: SnapFeedCell?
    /// The cell hosting a warm panel, so it can be cleared when the warm is
    /// discarded without the page still being active.
    private weak var engagedCellForPrewarm: SnapFeedCell?
    /// Whether the resting engagement's settle-time lock (pager freeze +
    /// engaged toolbar context) has been applied — set when the page
    /// activates, so a pre-render that never settles never locks.
    private var restingLockApplied = false
    /// Held for the length of a dismissal gesture, so the release restores the
    /// pager's engagement-owned state instead of enabling it. See `ScrollLock`.
    private var pagerLock = ScrollLock()
    /// The pager's `contentOffset.y` captured when an interactive page-swipe
    /// begins — the datum the drive offsets from. Nil when no drive is
    /// live. The drive hand-moves `contentOffset` while the pager's own pan
    /// stays disabled (the dead-end lock is untouched), so the finger
    /// drives the leaving page directly and the engaged layer (all in the
    /// cell) rides for free.
    private var pageDriveStartOffset: CGFloat?

    /// Files a post's Report. Nil withholds the row entirely: an action that
    /// cannot act is not offered — the grid's card menu follows the same rule.
    private let reporting: (any ContentReporting)?

    init(
        viewModel: FeedViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeCommentsPanelContent: ((PostID) -> UIViewController)? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        reporting: (any ContentReporting)? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.makeCommentsPanelContent = makeCommentsPanelContent
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.reporting = reporting
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Timeline"
        view.backgroundColor = .black
        configureCollectionView()
        configureNavigationItem()
        configureToolbarItems()
        configureStatusLabel()
        observeAppLifecycle()

        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        // No onEngagementChange subscription: the page shows no like/comment
        // affordances this iteration (the engagement rail was removed; the
        // view-model seam stays for their return).
        viewModel.onCommentStreamsChange = { [weak self] id, streams in
            self?.updateVisibleStreams(for: id, streams: streams)
        }
        viewModel.onOwnPostInserted = { [weak self] in
            // Reveal the viewer's just-posted item: a prepend on a full-screen
            // pager otherwise shifts it above the viewport. Defer so the
            // snapshot apply lands first.
            DispatchQueue.main.async {
                guard let self, !self.orderedIDs.isEmpty else { return }
                self.collectionView.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: true)
                self.updateActiveItem()
            }
        }
    }

    private var didStartLoading = false
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didStartLoading, view.bounds.width > 0 {
            didStartLoading = true
            viewModel.viewDidLoad()
        }
        // The author pill's budget is a share of the NAVIGATION BAR's width,
        // and the bar is not guaranteed to have one when the engagement
        // mounts — a text page's resting engagement can be applied from
        // `willDisplay`, before the bar has laid out, and a budget computed
        // against a zero width is no budget at all. The pill then keeps its
        // full cap, the trailing run does not fit, and the whole item
        // disappears into a `•••` menu — which is precisely the failure this
        // budget exists to prevent, arriving through the back door.
        //
        // Re-applied here, where the width is real. Idempotent (the setter
        // no-ops on an unchanged cap), so a settled page pays nothing.
        //
        // The RESTING run has the same hole since the wallet badge joined
        // it: its budget is bar-width arithmetic too (the badge is the
        // PRIORITY item — the author is what truncates), and a budget
        // computed at zero width is nil, an uncapped pill, and the same
        // `•••` failure on narrow bars.
        if commentsEngagedID != nil {
            applyEngagedTrailingRunFit()
        } else {
            authorIdentityView.setWidthBudget(restingAuthorBudget())
        }
    }

    /// True when this feed was opened *onto* another surface — pushed above
    /// the map, or presented — rather than being a tab root. That's the case
    /// that owns a back item and can be closed.
    private var isClosable: Bool {
        if presentingViewController != nil { return true }
        guard let nav = navigationController else { return false }
        return nav.viewControllers.first !== self
    }

    /// Leaves the feed the way it arrived: pop when pushed (runs the
    /// interactive-capable zoom-out on the map's stack), dismiss when
    /// presented.
    private func closeFeed() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The back item exists only when there is somewhere to go back to — a
        // map-opened feed, not the Timeline tab root — and the stack/
        // presentation relationship is known only here, not at viewDidLoad.
        if isClosable, backItem == nil {
            let back = SnapNavControls.makeBackButton()
            back.addAction(UIAction { [weak self] _ in self?.closeFeed() }, for: .primaryActionTriggered)
            backItem = UIBarButtonItem(customView: back)
        }
        // Install through the same resolver the engagement uses, so
        // re-appearing under a LIVE engagement (returning from a pushed
        // profile with a media post's comments still open) restores the ✕
        // rather than stamping the back arrow over it.
        applyLeadingNavItem(
            engaged: commentsEngagedID != nil,
            hasMedia: !commentsEngagementIsResting,
            animated: false
        )
        presentToolbar()
        // Re-borrow the bars for whatever page is settled: they are shared,
        // and anything pushed on top has since reset them.
        if let model = activeModel { applyChromeTheme(hasMedia: model.mediaURL != nil) }
        // Returning from a pushed screen with engagement state:
        // `presentToolbar` just re-lit the shared bar, so the engagement's
        // claim on the footer band must be re-arbitrated — enforce or
        // finish, never assume (see syncEngagementAfterAppearance).
        // Mirrored in viewDidAppear: during willAppear the floating-bar
        // containers may not have re-attached to the window yet.
        syncEngagementAfterAppearance()
        isOnScreen = true
        refreshVisibility()
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
        let engagedLayoutAlive = engagedCell()?.isCommentsEngaged == true
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
            engagedCell()?.reassertEngagedGeometry()
        } else {
            finishCommentsDisengagement()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        if !isAwaitingZoomPresentation { applyPendingComments(animated: true) }
        #if DEBUG
        runDebugAppearanceHooks()
        #endif
    }

    #if DEBUG
    private var didDebugPause = false
    private var didDebugScroll = false
    private var didDebugScrollDemo = false
    private var didDebugCommentsDemo = false
    /// `-snap-start-paused`: pauses the active cell shortly after appearing so
    /// the pause glyph can be screenshotted (taps can't be injected in the sim).
    /// `-snap-auto-dismiss`: dismisses a presented (map-opened) feed shortly
    /// after it settles, so the zoom-out leg can be recorded in the sim.
    /// `-snap-start-index N`: snaps to page N shortly after appearing (mock:
    /// every index%3==2 is text-only) — deterministic access to a given page
    /// kind without scroll injection.
    private var didDebugPageSwipe = false
    private var didDebugFling = false

    private func runDebugAppearanceHooks() {
        if ProcessInfo.processInfo.arguments.contains("-snap-auto-dismiss"), isClosable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.closeFeed()
            }
        }
        let arguments = ProcessInfo.processInfo.arguments
        // `-snap-page-demo [delay]`: drive the page swipe once the feed has
        // settled, so the animated page change can be filmed.
        if !didDebugPageSwipe, let position = arguments.firstIndex(of: "-snap-page-demo") {
            didDebugPageSwipe = true
            let delay = arguments.indices.contains(position + 1)
                ? (Double(arguments[position + 1]) ?? 3.0) : 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.debugDrivePageSwipe()
            }
        }
        // `-snap-fling [pages]`: scrolls the pager one page at a time the way a
        // FLICK does — a stream of small offset changes, each with its own
        // delegate callback, then a settle.
        //
        // Nothing before this could exercise a scroll at all. `-snap-page-demo`
        // drives the text page's own swipe gesture, and `-snap-start-index`
        // teleports; both reach the settle without ever passing through the
        // middle of the screen, which is exactly where the picture now changes
        // hands (`updateViewportPlayback`). Read the run with `-media-log`: a
        // `[page-play]` between `[fling] begin` and `[fling] settle` is the
        // clip starting mid-scroll, which is the whole claim.
        if !didDebugFling, let position = arguments.firstIndex(of: "-snap-fling") {
            didDebugFling = true
            let pages = arguments.indices.contains(position + 1)
                ? (Int(arguments[position + 1]) ?? 1) : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.debugFlingPages(pages)
            }
        }
        if !didDebugScroll,
           let flagIndex = arguments.firstIndex(of: "-snap-start-index"),
           arguments.indices.contains(flagIndex + 1),
           let target = Int(arguments[flagIndex + 1]) {
            didDebugScroll = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.orderedIDs.indices.contains(target) else { return }
                self.collectionView.scrollToItem(at: IndexPath(item: target, section: 0), at: .top, animated: false)
                self.updateActiveItem()
            }
        }
        // `-feed-open-wallet`: presents the wallet sheet over the feed ~2s
        // after settle — the header badge opens it on tap, which the sim
        // can't deliver. The map's `-open-wallet` stays separate: both
        // firing at once would race two presentations of one sheet.
        if arguments.contains("-feed-open-wallet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.presentWalletSheet()
            }
        }
        // `-wallet-demo-boost [amount]`: boosts the ACTIVE post through the
        // real spend path (wallet debit → haptic → "+N" float) shortly after
        // settle — the rail anchor opens it on tap, which the sim can't
        // deliver. Pair with `-wallet-log` for the ledger line and
        // `-wallet-balance 0` for the denied shake.
        if arguments.contains("-wallet-demo-boost") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                let index = self.lifecycle.activeIndex ?? 0
                guard self.orderedIDs.indices.contains(index) else { return }
                let amount: Int
                if let flagIndex = arguments.firstIndex(of: "-wallet-demo-boost"),
                   arguments.indices.contains(flagIndex + 1),
                   let chosen = Int(arguments[flagIndex + 1]) {
                    amount = chosen
                } else {
                    amount = WalletStore.Policy.tapBoostAmount
                }
                let cell = self.collectionView.visibleCells
                    .compactMap { $0 as? SnapFeedCell }.first
                self.performBoost(on: self.orderedIDs[index], amount: amount, feedbackCell: cell)
            }
        }
        // `-wallet-demo-undo`: takes back the active post's session boosts
        // ~2s after `-wallet-demo-boost` landed them — the menu's Undo
        // entry, minus the long-press the sim can't deliver. The pair
        // exercises the full loop: spend, receipt face, refund, glyph face.
        if arguments.contains("-wallet-demo-undo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self else { return }
                let index = self.lifecycle.activeIndex ?? 0
                guard self.orderedIDs.indices.contains(index) else { return }
                let cell = self.collectionView.visibleCells
                    .compactMap { $0 as? SnapFeedCell }.first
                self.performBoostUndo(on: self.orderedIDs[index], feedbackCell: cell)
            }
        }
        // `-snap-scroll-demo`: animated-scrolls one page forward shortly
        // after settle, so a page *transition* can be recorded in the sim
        // (scroll gestures can't be injected) — the comment ticker must be
        // flowing on both pages during the motion, not pop in at rest.
        if !didDebugScrollDemo, arguments.contains("-snap-scroll-demo") {
            didDebugScrollDemo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }
                let target = (self.lifecycle.activeIndex ?? 0) + 1
                guard self.orderedIDs.indices.contains(target) else { return }
                self.collectionView.scrollToItem(at: IndexPath(item: target, section: 0), at: .top, animated: true)
                // Animated scrolls end in scrollViewDidEndScrollingAnimation,
                // which this VC doesn't observe (finger scrolls don't emit
                // it); settle the active page manually like the jump arg.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.updateActiveItem() }
            }
        }
        // `-snap-comments-demo`: opens the comments engagement on the active
        // page ~2.5s after appear (after any `-snap-start-index` jump at
        // 1.5s settles) — the mutated layout can be screenshotted without
        // tap injection.
        if !didDebugCommentsDemo, arguments.contains("-snap-comments-demo") {
            didDebugCommentsDemo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let index = self.lifecycle.activeIndex,
                      self.orderedIDs.indices.contains(index) else { return }
                self.presentComments(for: self.orderedIDs[index])
                // `-snap-comments-close N`: dismisses the engagement N
                // seconds after it opens, landing the page back at rest.
                // The RETURN leg is a state change of its own — the page's
                // chrome comes back and the empty state re-reads its words
                // — and it was the one leg no launch arg could reach, so it
                // could only be reasoned about. Chained off the open rather
                // than scheduled from appear, so the delay means what it
                // says whatever the open cost.
                guard let flag = arguments.firstIndex(of: "-snap-comments-close"),
                      arguments.indices.contains(flag + 1),
                      let after = Double(arguments[flag + 1]) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                    self?.dismissComments()
                    // `-snap-comments-reopen N`: taps the entry point again N
                    // seconds after the close. The REOPEN is what a broken
                    // teardown kills — the page still looks right, and every
                    // comment surface is simply dead — so the QA path has to
                    // go all the way round.
                    guard let flag = arguments.firstIndex(of: "-snap-comments-reopen"),
                          arguments.indices.contains(flag + 1),
                          let reopenAfter = Double(arguments[flag + 1]) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + reopenAfter) { [weak self] in
                        guard let self, let index = self.lifecycle.activeIndex,
                              self.orderedIDs.indices.contains(index) else { return }
                        self.presentComments(for: self.orderedIDs[index])
                    }
                }
            }
        }
        // `-dump-bars`: prints the navigation view hierarchy (class, frame,
        // alpha, hidden) plus each toolbar item's superview chain ~5s after
        // appear — the tool that pins down WHERE iOS 26 hosts the Liquid
        // Glass item platters (they are not in the toolbar's subtree).
        if arguments.contains("-dump-bars") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.dumpBarHierarchy()
            }
        }
        guard !didDebugPause,
              ProcessInfo.processInfo.arguments.contains("-snap-start-paused") else { return }
        didDebugPause = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let index = self.lifecycle.activeIndex,
                  let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
            else { return }
            cell.togglePlayback()
        }
    }
    #endif

    #if DEBUG
    private func dumpBarHierarchy() {
        guard let nav = navigationController else { return }
        func walk(_ view: UIView, _ depth: Int) {
            let f = view.frame
            print("BARDUMP:\(String(repeating: "  ", count: depth))\(type(of: view)) "
                + "frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))) "
                + "alpha=\(String(format: "%.2f", view.alpha))\(view.isHidden ? " HIDDEN" : "")")
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(nav.view, 0)
        func chainDescription(from view: UIView?) -> String {
            var chain: [String] = []
            var current: UIView? = view
            while let view = current {
                let id = String(UInt(bitPattern: ObjectIdentifier(view).hashValue) % 0xFFFF, radix: 16)
                chain.append("\(type(of: view))#\(id)")
                current = view.superview
            }
            return chain.joined(separator: " -> ")
        }
        for (index, item) in (toolbarItems ?? []).enumerated() where item.customView != nil {
            print("BARDUMP:CHAIN toolbarItem[\(index)]: " + chainDescription(from: item.customView))
        }
        print("BARDUMP:CHAIN navTrailing: " + chainDescription(from: navigationItem.rightBarButtonItem?.customView))
        print("BARDUMP:CHAIN navLeading: " + chainDescription(from: navigationItem.leftBarButtonItem?.customView))
    }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setNativePopSuppressed(false)
        // Hand the shared bars back on the way out (see `releaseChromeTheme`).
        releaseChromeTheme()
        // Unlike the visibility bookkeeping below, the toolbar choreography
        // runs for every disappearance: it registers on the coordinator when
        // one exists (fade, restore-on-cancel) and hides instantly otherwise.
        concealToolbar()
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
        guard transitionCoordinator == nil else { return }
        isOnScreen = false
        refreshVisibility()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        settleToolbarAfterDisappearance()
        isOnScreen = false
        refreshVisibility()
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
        // Leaving the screen finalizes the session's boosts, same as paging
        // away — "undo until you move on", and you just moved on. (The
        // retained timeline can come back to the same post; the spend is
        // still final: the window is the visit, not the post.)
        sessionBoostID = nil
        sessionBoostAmount = 0
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
    private func reapplyEngagedInsets() {
        guard let detail = commentsContentVC as? PostDetailViewController,
              let cell = engagedCell()
        else { return }
        detail.setEngagedInsets(
            top: cell.engagedCommentsTopInset(safeAreaTop: view.safeAreaInsets.top),
            bottomInset: view.safeAreaInsets.bottom
        )
    }

    private func configureCollectionView() {
        collectionView = SnapFeedCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .black
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

        // No pull-to-refresh: the feed is FORWARD-ONLY (cluster-gallery
        // milestone) — the whole downward direction belongs to the dismissal
        // hero, so there is no top overscroll left to hang a refresh on.
        // Refresh lives on the source surfaces (the grids), which own their
        // own vertical axis.

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
                // Paging this post's collection travels back to whoever opened
                // the feed — see `onMediaPageChanged`.
                cell.onMediaPageChanged = { [weak self] page in
                    self?.onMediaPageChanged?(id, page)
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
                for pan in self.view.gestureRecognizers ?? []
                where pan is UIPanGestureRecognizer && pan !== cell.mediaScrubGesture {
                    pan.require(toFail: cell.mediaScrubGesture)
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
                cell.onRequestComments = { [weak self] id in self?.presentComments(for: id) }
                cell.onRequestCommentsClose = { [weak self] in self?.dismissComments() }
                // The boost spend: wallet verdict here (the cell holds no
                // balance), theatre back on the cell that asked.
                cell.onRequestBoost = { [weak self, weak cell] id, amount in
                    self?.performBoost(on: id, amount: amount, feedbackCell: cell)
                }
                cell.onRequestBoostUndo = { [weak self, weak cell] id in
                    self?.performBoostUndo(on: id, feedbackCell: cell)
                }
                // The anchor's number face and wallet context: what this
                // viewer has already put on this post (the ledger), what
                // the balance can still afford, and whether any of it is
                // still session-undoable — a recycled cell for a boosted
                // post gets its receipt back.
                if let wallet = self.wallet {
                    cell.setBoostTotal(wallet.boostTotal(forTarget: id.rawValue))
                    cell.setBoostContext(
                        balance: wallet.balance,
                        undoable: self.sessionBoostID == id ? self.sessionBoostAmount : 0
                    )
                }
                cell.onRequestCommentsPageDrive = { [weak self] phase, translation, velocity in
                    self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
                }
            }
            return cell
        }
    }

    /// Puts the screen chrome into (or out of) comment mode, both bars at
    /// once — they are one state, and splitting them across call sites is
    /// how a half-engaged bar happens.
    ///
    ///   resting          NAV [‹ back] … [🪙 solde] [author pill]
    ///   comments (media) NAV [✕]      … [🪙 solde] [⇅ sort] [author pill]
    ///   comments (text)  NAV [‹ back] … [🪙 solde] [⇅ sort] [author pill]
    ///   TOOLBAR          [♫ attribution] … [🔖 ⬆︎] [⋯]   — in every state
    ///
    /// (The wallet badge appears only when a wallet is injected; a
    /// nil-wallet feed keeps the historical runs without it.)
    ///
    /// `hasMedia` picks the LEADING slot: a media post can collapse back to
    /// its layout, a text post has none to collapse to. (It used to pick the
    /// toolbar's trailing slot instead; the footer is invariant now.)
    ///
    /// Internal, not private, so the bar contracts are unit-testable without
    /// driving a whole engagement — which needs a live cell, a hosted child,
    /// and a spring to settle.
    func setEngagedChrome(_ engaged: Bool, hasMedia: Bool, animated: Bool) {
        // `rightBarButtonItems` reads RIGHT TO LEFT: index 0 is the
        // rightmost, so the sort lands just LEFT of the author pill.
        //
        // The FIXED SPACE between them is not cosmetic — it is what makes
        // them two pills. iOS 26 groups ADJACENT bar items into one shared
        // glass platter, so `[author, sort]` rendered as a single capsule
        // with the sort swallowed into the author's pill; a spacer item
        // breaks the run and each custom view gets its own floating
        // background, its own padding, and its own tap target.
        //
        // SET, don't ASSIGN. `navigationItem.rightBarButtonItems = …` is a
        // plain property write: the bar has no transition to run, so the
        // pill popped in on a hard crossfade. The `setRightBarButtonItems(
        // _:animated:)` form is the one that hands the change to the
        // navigation bar's own item animator — the same slide-and-fade the
        // system uses for a push — so the sort pill morphs in beside the
        // author instead of appearing on top of it.
        // ONE author pill, identical in both states: same component, same
        // platter, same handle-and-age line, same follow button.
        //
        // It used to shrink to a name-only COMPACT form for the engagement,
        // because at full size the two-pill run once overflowed and the
        // system's answer to an overflow is to hide the whole item behind a
        // `•••` menu. That was measured against the bar as it stood then —
        // the toolbar has since become state-invariant and the leading slot
        // is a single 36pt bubble — and re-measured now the run fits with
        // room to spare on the narrowest device the app targets. So the
        // pill stops changing identity halfway through a state it is
        // supposed to persist across.
        //
        // The run's width budget is REAL, though, and it is paid in width
        // rather than in layout: the pill keeps every part of itself and
        // truncates a long name earlier while the sort pill is beside it —
        // which is what a long name already does at rest. Measured on the
        // narrowest device: a full-width pill DID overflow the whole item
        // into a `•••` menu, and losing the author entirely is worse than
        // any truncation.
        authorIdentityView.setCompact(false, animated: animated)
        if engaged {
            applyEngagedTrailingRunFit()
        } else {
            // Nil (no cap) without a wallet badge, as before; with one the
            // author gives up the badge's footprint the same way it gives
            // up the sort pill's — overflow hides the WHOLE item behind a
            // `•••`, so the cap must be arithmetic, not hope.
            authorIdentityView.setWidthBudget(restingAuthorBudget())
            commentSortButton.setTitleHidden(false)
        }

        var navItems: [UIBarButtonItem] = engaged
            ? [authorItem, .fixedSpace(Spacing.sm), sortItem]
            : [authorItem]
        // The wallet badge closes the run's left in BOTH states — the same
        // fixed-space idiom that keeps the sort and author two pills.
        if let walletBadgeItem {
            navItems += [.fixedSpace(Spacing.sm), walletBadgeItem]
        }
        applyTrailingNavItems(navItems, animated: animated)

        applyLeadingNavItem(engaged: engaged, hasMedia: hasMedia, animated: animated)
        applyToolbarExit(engaged: engaged, hasMedia: hasMedia, animated: animated)
        // The toolbar is state-invariant now; nothing to swap.
    }

    /// Fits the trailing run to the bar, giving way in a fixed order.
    ///
    /// The system does not negotiate here: the instant the run does not fit
    /// it hides the whole item behind a `•••` menu, and the author vanishes
    /// rather than shrinking. So the fitting is arithmetic done up front,
    /// and what gives way gives way in the order that costs the reader
    /// least:
    ///
    ///   1. the display NAME truncates (`SnapAuthorIdentityView`'s
    ///      compression priorities — the handle outranks the name)
    ///   2. the SORT PILL drops its word and keeps its glyph
    ///   3. the HANDLE truncates, once the pill is narrower still
    ///
    /// Rungs 1 and 3 are the same mechanism at two depths: cap the pill and
    /// Auto Layout spends the name first, the handle only when the name is
    /// exhausted. Rung 2 is the one explicit switch, taken when the cap
    /// would otherwise fall below what a pill can usefully show.
    ///
    /// `itemPlatterPadding` is the glass wrapper UIKit puts around every
    /// custom bar item. It is not published, so it is MEASURED: on a 390pt
    /// bar an author view of 170 fits beside an 88pt sort pill and 195 does
    /// not, which puts the per-item padding at ~18 and is what these
    /// numbers are calibrated against.
    private static let itemPlatterPadding: CGFloat = 18
    private static let barSideMargin: CGFloat = 16
    private static let leadingItemWidth: CGFloat = 36
    private func applyEngagedTrailingRunFit() {
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }

        func authorBudget(sortWidth: CGFloat) -> CGFloat {
            let pad = Self.itemPlatterPadding
            return bar
                - Self.barSideMargin * 2
                - (Self.leadingItemWidth + pad)
                - (sortWidth + pad)
                - Spacing.sm
                - pad
                - walletItemFootprint()
        }
        func sortWidth() -> CGFloat {
            commentSortButton.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }

        // Rung 1: the name truncates inside whatever the run can spare.
        commentSortButton.setTitleHidden(false)
        var budget = authorBudget(sortWidth: sortWidth())
        // Rung 2: the name alone cannot absorb it — the HANDLE would start
        // truncating next, so the sort pill gives up its word first and the
        // width it frees goes to the author.
        if budget < authorIdentityView.widthKeepingHandleWhole {
            commentSortButton.setTitleHidden(true)
            budget = authorBudget(sortWidth: sortWidth())
        }
        // Rung 3 needs no branch: if it is STILL below that threshold the
        // handle truncates on its own, because the name has nothing left.
        authorIdentityView.setWidthBudget(budget)
    }

    /// What the wallet badge takes from the trailing run: its fitted width,
    /// its glass platter, and the spacer that keeps it its own pill. Zero
    /// when no wallet is wired — the run is then exactly its historical
    /// shape and the historical (nil) budgets stay right.
    private func walletItemFootprint() -> CGFloat {
        guard walletBadgeItem != nil else { return 0 }
        let width = walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        return width + Self.itemPlatterPadding + Spacing.sm
    }

    /// The resting run's items: the author pill alone (no wallet), or the
    /// pill with the badge to its left, spacer-separated so iOS 26 never
    /// fuses them into one platter.
    private func restingTrailingItems() -> [UIBarButtonItem] {
        guard let walletBadgeItem else { return [authorItem] }
        return [authorItem, .fixedSpace(Spacing.sm), walletBadgeItem]
    }

    /// The resting author cap: nil (uncapped, the historical contract)
    /// without a wallet badge; with one, the bar minus everything that
    /// isn't the author — the engaged fit's arithmetic minus the sort pill.
    private func restingAuthorBudget() -> CGFloat? {
        guard walletBadgeItem != nil else { return nil }
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return nil }
        let pad = Self.itemPlatterPadding
        return bar
            - Self.barSideMargin * 2
            - (Self.leadingItemWidth + pad)
            - pad
            - walletItemFootprint()
    }

    /// The leading slot's two faces:
    ///
    ///   media comments open → ✕ (collapse to the media layout)
    ///   anything else       → the back arrow, if there is one
    ///
    /// TEXT POSTS KEEP THE BACK ARROW. Their engagement is the page's
    /// permanent resting state, so a ✕ would promise a media layout that
    /// does not exist — the same asymmetry that used to live in the
    /// toolbar's trailing slot, now expressed in the slot where it reads as
    /// a navigation choice instead of an action.
    ///
    /// A tab-root feed has no back arrow at rest, and gains a ✕ all the
    /// same: the two answer different questions (leave the screen vs. leave
    /// the layout), and only the second is always available.
    ///
    /// SET, don't ASSIGN — same reason as the trailing items: the animated
    /// form hands the change to the bar's own item animator, so the ✕ morphs
    /// into the arrow's place instead of popping over it.
    /// ⚠️ THE ARROW STAYS, in every state.
    ///
    /// The comments exit used to take this slot on a media post, on the reading
    /// that it means the same kind of thing one level in — leave what is open.
    /// It cost the screen its way OUT while the layout was open: the arrow was
    /// gone, so leaving the post meant closing the comments first and then
    /// going back, two gestures for one intention. The exit moved to the
    /// footer's trailing corner instead (see `applyToolbarExit`), where it
    /// stands in the ⋯'s own bubble.
    private func applyLeadingNavItem(engaged: Bool, hasMedia: Bool, animated: Bool) {
        let items = [backItem].compactMap { $0 }
        guard navigationItem.leftBarButtonItems ?? [] != items else { return }
        navigationItem.setLeftBarButtonItems(items, animated: animated)
    }

    /// The footer's trailing corner: ⋯ at rest, ✕ while a media post's comments
    /// are open.
    ///
    /// ⚠️ THE CORNER IS NOT STATE-INVARIANT ANY MORE, and that was a deliberate
    /// property once: the toolbar carried three item sets whose only difference
    /// was this slot, and collapsing them to one was what stopped a text
    /// engagement and a media engagement disagreeing about what the corner
    /// meant. Two things have changed since. The ⋯ has its own platter now, so
    /// the swap is one bubble changing its glyph rather than a run
    /// re-composing; and a TEXT page never swaps at all — its comments are the
    /// page, so there is nothing to close and its corner stays ⋯. The corner
    /// therefore reads the same way everywhere it can be read: it closes what
    /// is open, or folds away what else there is.
    private func applyToolbarExit(engaged: Bool, hasMedia: Bool, animated: Bool) {
        guard !defaultToolbarItems.isEmpty else { return }
        let exit = engaged && hasMedia
        let items = exit
            ? defaultToolbarItems.dropLast() + [closeCommentsItem]
            : defaultToolbarItems
        guard toolbarItems ?? [] != Array(items) else { return }
        setToolbarItems(Array(items), animated: animated)
    }

    private func applyTrailingNavItems(_ items: [UIBarButtonItem], animated: Bool) {
        guard navigationItem.rightBarButtonItems ?? [] != items else { return }
        navigationItem.setRightBarButtonItems(items, animated: animated)
    }


    private func configureNavigationItem() {
        // Fully transparent bar over the full-bleed media, identical for every
        // bar state so no scroll-edge transition ever fires. Set per-item (not
        // on the bar) so pushed screens keep their normal bars with zero
        // restore choreography.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        // The author identity rides the *trailing* bar item (right-aligned,
        // like a system floating action), not the centered titleView. One
        // stable custom view, installed exactly once: author changes
        // cross-fade inside it, never re-negotiating bar layout. The run is
        // closed on its left by the wallet badge (when a wallet is wired) —
        // the feed's chrome stays identical on every entry path (menu push
        // and pin flight), so nothing else may install items, here or from
        // outside.
        authorItem = UIBarButtonItem(customView: authorIdentityView)
        sortItem = UIBarButtonItem(customView: commentSortButton)
        if wallet != nil {
            // Tappable exactly when a sheet is wired: the badge opens the
            // same claim sheet the map's does, from any post. Without one
            // it stays display-only and must not swallow taps meant for
            // the page.
            walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
            if makeWalletSheet != nil {
                walletBadge.addAction(
                    UIAction { [weak self] _ in self?.presentWalletSheet() },
                    for: .primaryActionTriggered
                )
            }
            walletBadgeItem = UIBarButtonItem(customView: walletBadge)
            // A grown count needs a re-measured wrapper, and the wrapper
            // belongs to the ITEM: re-adding the same item hands the bar
            // the same wrapper with the same frozen size (measured in-sim).
            // A FRESH item is the only thing the bar measures anew.
            walletBadge.onFittedWidthChange = { [weak self] in
                guard let self, let old = self.walletBadgeItem,
                      var items = self.navigationItem.rightBarButtonItems,
                      let index = items.firstIndex(of: old) else { return }
                let fresh = UIBarButtonItem(customView: self.walletBadge)
                self.walletBadgeItem = fresh
                items[index] = fresh
                self.navigationItem.rightBarButtonItems = items
                // The badge is the run's PRIORITY member: when it grows,
                // the author's budget shrinks by the same points — re-fit
                // now, or the run overflows into a `•••` on narrow bars.
                if self.commentsEngagedID != nil {
                    self.applyEngagedTrailingRunFit()
                } else {
                    self.authorIdentityView.setWidthBudget(self.restingAuthorBudget())
                }
            }
            refreshWalletBadge()
            // The badge (and every visible boost control) re-renders on
            // every store change — a rail spend, a comments-bar spend, or a
            // claim taken on the map while this screen sits in the stack
            // below.
            appObservers.add(NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshWalletBadge()
                    self.refreshVisibleBoostControls()
                }
            })
        }
        navigationItem.rightBarButtonItems = restingTrailingItems()

        // The comments exit, built once and held: it takes the FOOTER's
        // trailing bubble whenever a media post's comments are open.
        //
        // UNTINTED, and now for a better reason than before. It carried
        // `.systemRed` when it sat in a capsule beside three controls that act
        // ON the post, where the exit had to be told apart from them; that
        // capsule holds two controls now and the ⋯ has a bubble of its own, so
        // the exit arrives ALONE in it. Being the only thing in its own bubble
        // is what says what it is.
        //
        // Note for anyone re-reaching for a colour: a Liquid Glass platter
        // renders its own adaptive glyph colour and ignores
        // `baseForegroundColor` outright (measured in the nav bar — the ✕ came
        // out #06123D against a request for red). Baking the colour into the
        // image with `.alwaysOriginal` does defeat it, at the cost of resolving
        // the dynamic colour once at build time.
        let close = SnapNavControls.makeToolbarActionButton(systemName: "xmark")
        close.accessibilityLabel = "Close comments"
        close.addAction(UIAction { [weak self] _ in self?.dismissComments() }, for: .primaryActionTriggered)
        closeCommentsItem = UIBarButtonItem(customView: close)
        authorIdentityView.onAuthorTapped = { [weak self] id in self?.viewModel.didTapAuthor(id) }
        // The feed layer has no follow API (follow state/toggling lives in the
        // Profile feature), so the follow affordance routes to the author's
        // profile — the surface that owns the real Follow button. Swap for a
        // one-tap follow once a social seam exists on the feed side.
        authorIdentityView.onFollowTapped = { [weak self] id in self?.viewModel.didTapAuthor(id) }

        // Keep `title` (it feeds pushed screens' back labels) but suppress its
        // centered rendering — the bar's center stays empty by design.
        navigationItem.titleView = UIView()
    }

    /// The native bottom toolbar's content, left to right: the attribution
    /// bubble, the system flexible spacer, the share bubble (bookmark +
    /// share in ONE capsule), a fixed gap, the more bubble. Three *isolated*
    /// glass bubbles by construction — every item is a custom view, and
    /// custom views never join a shared item background — each on the 36pt
    /// bar-bubble invariant the top bar's controls already follow.
    ///
    /// Items are installed exactly once; only the attribution's content and
    /// the bookmark glyph follow the active page (same stable-view contract
    /// as the identity pill). Every action resolves the active post at
    /// action time, so none can act on a page the user has scrolled past.
    private func configureToolbarItems() {
        bookmarkButton.accessibilityLabel = "Save"
        bookmarkButton.addAction(UIAction { [weak self] _ in
            guard let self, let model = self.activeModel else { return }
            self.toggleBookmark(for: model.id)
        }, for: .primaryActionTriggered)

        // ⚠️ REPOST HAS NO ACTION YET, and it is drawn anyway — the same
        // posture the gallery card's band takes for the same glyph, and for the
        // same reason: `CreatePost` carries `parent_id` on the wire and
        // `GalleryPost.isRepost` already reads it (the profile's
        // Posts/Reposts split), but `PostComposer` takes no parent, so there is
        // no client path that publishes one. What it needs is a mutation, not a
        // handler. Pressing it does nothing today, here as there.
        let repost = SnapNavControls.makeToolbarActionButton(systemName: "arrow.2.squarepath")
        repost.accessibilityLabel = "Repost"

        // SHARE LEFT THE BAR. It is in the ⋯ menu now, beside the other things
        // you can do TO a post rather than the two you can do WITH it: save it,
        // and pass it on. Three glyphs of equal weight said the three were
        // equally common, and share is not.

        // TWO bubbles: [🔖 ⇄] and [⋯], held apart by a fixed space — iOS 26
        // groups ADJACENT bar items into one shared platter, so a spacer is
        // the only way to make two.
        //
        // ⚠️ THE COST ARGUMENT DOES NOT DECIDE THIS, and the measurements are
        // the reason. They were merged into one capsule to save a platter,
        // each being its own glass host that UIKit materialises through
        // SwiftUI inside `pushViewController` — the hero flight's stall. Then
        // the arms were measured (the table under `-no-toolbar` below): one
        // platter fewer bought ~2 ms, inside the noise, while the floating bar
        // itself costs ~45 ms cold whatever is in it.
        //
        // So the grouping is a design question again, and the two are not the
        // same kind of thing: the capsule holds what you DO to this post —
        // save it, pass it on — and ⋯ holds what is folded away. A separator
        // between them says which is which; sharing a platter said they were
        // three of a kind.
        let shareCluster = UIStackView(arrangedSubviews: [bookmarkButton, repost])
        shareCluster.axis = .horizontal

        let more = SnapNavControls.makeToolbarActionButton(systemName: "ellipsis")
        // ⚠️ NAMED, all three. Two of these glyphs carried no label at all, so
        // VoiceOver read them as "button" — the composition test needs a handle
        // on them and a reader needs one more.
        more.accessibilityLabel = "More actions"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let model = self.activeModel else { return completion([]) }
                completion(self.moreMenuActions(for: model.id))
            }
        ])

        // ONE item set, for every state:
        //
        //   [♫ attribution] … [🔖 ⇄] [⋯]
        //
        // The toolbar is now STATE-INVARIANT. It used to carry three sets
        // whose only difference was the trailing slot — a red ✕ while a
        // media post's comments were open, ⋯ otherwise — which meant a text
        // engagement and a media engagement disagreed about what that corner
        // meant. The comments exit moved to the navigation bar's LEADING
        // slot, where it replaces the back arrow and reads as "leave this
        // layout" the way a back arrow reads as "leave this screen"; ⋯ keeps
        // the trailing corner in all states, so the footer no longer changes
        // under the engagement at all.
        //
        // The sort selector is not here either — it moved to the nav bar
        // beside the author pill (`setEngagedChrome`).
        let leading: [UIBarButtonItem] = [
            UIBarButtonItem(customView: mediaAttributionView),
            .flexibleSpace(),
        ]
        #if DEBUG
        // `-merge-toolbar-platters`: the A/B's other arm, folding ⋯ back into
        // the actions' capsule so both come from one binary. It was the
        // shipped side once — see the note above for why the numbers no longer
        // argue for it.
        if ProcessInfo.processInfo.arguments.contains("-merge-toolbar-platters") {
            shareCluster.addArrangedSubview(more)
            defaultToolbarItems = leading + [UIBarButtonItem(customView: shareCluster)]
            toolbarItems = defaultToolbarItems
            return
        }
        #endif
        defaultToolbarItems = leading + [
            UIBarButtonItem(customView: shareCluster),
            .fixedSpace(Spacing.sm),
            UIBarButtonItem(customView: more),
        ]
        #if DEBUG
        // `-no-toolbar`: the UPPER BOUND on what trimming the footer can buy,
        // and the probe that settled where the flight's cost actually lives.
        // Not shippable — it is the whole footer — but the numbers redirect
        // the whole question. Push work, 3 runs each:
        //
        //   5 platters (two-bubble run, shipped)  cold 95.4  warm 43.2 / 47.0
        //   4 platters (merged)                    cold 98.5  warm 40.4 / 45.4
        //   4 platters, STANDARD items not custom  cold 103.9 warm 45.9 / 44.8
        //   NO TOOLBAR AT ALL (2 platters)         cold 53.1  warm 32.6 / 31.0
        //
        // So it is not the platter COUNT (one fewer bought ~2 ms, inside the
        // noise) and not the SwiftUI custom-view bridge either (standard items
        // measured the same). It is having a floating bar at all: the
        // `FloatingBarHostingView<FloatingBarContainer>` machinery costs ~45 ms
        // cold and ~14 ms warm on every push, near enough regardless of what
        // is in it.
        //
        // Which means the only real lever left is architectural — a footer the
        // FEED owns, inside its own view, would be laid out by
        // `prepareForHeroPresentation` and hidden with the rest of the content
        // during the flight, and the navigation controller's floating bar
        // would never run during the push. That trades the system's own glass
        // for a hand-rolled one, so it is a product decision, not a cleanup.
        if ProcessInfo.processInfo.arguments.contains("-no-toolbar") {
            defaultToolbarItems = []
        }
        #endif
        toolbarItems = defaultToolbarItems
    }

    /// The INTERACTIVE pull-down dismissal: the comment list's drag drives
    /// the collapse under the finger, and release either finishes it or
    /// springs it back.
    ///
    /// The progress is rendered by the CELL (`setCommentsEngagementProgress`)
    /// — the same interpolatable state the animated engage/disengage moves
    /// between, so a released-and-committed drag simply hands off to
    /// `dismissComments`, whose spring interpolates from wherever the finger
    /// left things. Nothing has to reconcile two descriptions of the state.
    /// The last progress rendered, so a stream scrolling inside its content
    /// (which reports zero on every frame) does no work.
    private var lastPullDismissProgress: CGFloat = 0

    private func drivePullDismiss(
        _ phase: CommentsInputBar.PageSwipePhase, translation: CGFloat, velocity: CGFloat
    ) {
        guard let cell = engagedCell() else { return }
        switch phase {
        case .began:
            break
        case .changed:
            // `translation` is the list's OVERSHOOT past its top, so the
            // rubber band and the fade are one number. No animation block:
            // the layer tracks the content exactly rather than chasing it.
            let progress = SnapCommentsLayout.pullDismissProgress(translation: translation)
            // Scrolling inside the list reports zero every frame; only
            // write when something actually moves.
            guard progress != lastPullDismissProgress else { return }
            lastPullDismissProgress = progress
            cell.setCommentsEngagementProgress(progress)
            // The shrink is the STREAM's own — the composer and the footer
            // band stay put at the screen's edge.
            (commentsContentVC as? PostDetailViewController)?
                .setStreamTransitionProgress(progress)
        case .ended:
            // Only a COMMITTED release arrives here — a pull that falls
            // short simply springs back, and the offset's own animation
            // walks the transition home through `.changed`. There is no
            // cancel branch to write, and none to keep in sync.
            lastPullDismissProgress = 0
            dismissComments()
        }
    }

    /// Optimistic local toggle (no backend seam yet — see the set's comment);
    /// the glyph flips immediately, scoped to the acted-on post.
    private func toggleBookmark(for id: PostID) {
        bookmarks.toggle(id.rawValue)
        refreshBookmarkGlyph(for: id)
    }

    /// Points the bookmark glyph at `id`'s state — called on toggle and when
    /// the active page changes.
    private func refreshBookmarkGlyph(for id: PostID) {
        let saved = bookmarks.isSaved(id.rawValue)
        // The label follows the state, like the glyph: "Save" and "Saved" are
        // different offers, and a reader who cannot see the fill has only this.
        bookmarkButton.accessibilityLabel = saved ? "Saved" : "Save"
        var config = bookmarkButton.configuration
        config?.image = UIImage(systemName: saved ? "bookmark.fill" : "bookmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        bookmarkButton.configuration = config
    }

    // MARK: - Toolbar visibility

    /// The toolbar's push/pop choreography, mirroring the navigation bar's
    /// contract: bar chrome belongs to the navigation controller, ABOVE the
    /// transition container, so it is never part of a flight card or a
    /// sliding view — it cross-fades in place while content transitions
    /// beneath it.
    ///
    /// Shown non-animated so the bottom safe area is final before a zoom
    /// present's `layoutIfNeeded` bakes the flight replica's insets; the
    /// *visual* entrance is an alpha fade registered on the transition
    /// coordinator, which every entry path coordinates (and a cancelled pop,
    /// re-firing this, skips — the toolbar was never hidden).
    private func presentToolbar() {
        guard let nav = navigationController else { return }
        toolbarHost = nav

        // The stack's toolbar is shown by this screen alone, so configuring
        // the shared instance here cannot fight another owner. Transparent
        // for the same reason the navigation bar is: full-bleed media, no
        // scroll-edge darkening, items carry their own legibility.
        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        nav.toolbar.standardAppearance = appearance
        nav.toolbar.compactAppearance = appearance
        nav.toolbar.scrollEdgeAppearance = appearance
        nav.toolbar.tintColor = .white

        let wasHidden = nav.isToolbarHidden
        nav.setToolbarHidden(false, animated: false)
        nav.toolbar.alpha = 1
        if wasHidden, let coordinator = transitionCoordinator {
            nav.toolbar.alpha = 0
            coordinator.animate(alongsideTransition: { _ in
                nav.toolbar.alpha = 1
            }, completion: { _ in
                // A push cannot cancel; pin the end state either way.
                nav.toolbar.alpha = 1
            })
        }
    }

    /// The exit leg. Fades the toolbar alongside whatever transition is
    /// carrying the feed away — the percent-driven timeline slide scrubs it
    /// with the finger; the zoom pop runs it on the transition clock; the
    /// free-floating pin grab (not percent-driven) runs it over the
    /// post-release remainder, exactly like the navigation bar's own item
    /// cross-fade on that leg. Only a *completed* disappearance hides the
    /// bar; a cancelled swipe's completion restores alpha and keeps it.
    private func concealToolbar() {
        guard let nav = navigationController, !nav.isToolbarHidden else { return }
        // Hand the bar over intact when the incoming screen is a toolbar
        // owner too (the profile's filter tray): it adopts the shared
        // instance and reconfigures it in its own viewWillAppear — fading it
        // here would fight that presentation, the flash this rule replaces.
        if successorUsesToolbar(on: nav) { return }
        guard let coordinator = transitionCoordinator else {
            // Instant paths (tab switch): no transition to ride.
            nav.setToolbarHidden(true, animated: false)
            return
        }
        coordinator.animate(alongsideTransition: { _ in
            nav.toolbar.alpha = 0
        }, completion: { context in
            if context.isCancelled {
                nav.toolbar.alpha = 1
            } else {
                nav.setToolbarHidden(true, animated: false)
                nav.toolbar.alpha = 1
            }
        })
    }

    /// Deterministic backstop for the toolbar's hide, in the one callback
    /// that fires only for *completed* disappearances. The interactive pin
    /// grab's coordinator completions can be deferred indefinitely (see
    /// `ZoomDismissInteractionController` — it tears down by wall clock for
    /// the same reason); if the fade above never settled, settle it here so
    /// the map can never inherit a visible empty toolbar.
    private func settleToolbarAfterDisappearance() {
        guard let nav = toolbarHost, !nav.isToolbarHidden,
              nav.topViewController !== self else { return }
        // Same handover rule as concealToolbar: a successor that shows its
        // own toolbar owns the bar now — settling it hidden would strand
        // that screen's chrome.
        if successorUsesToolbar(on: nav) { return }
        nav.setToolbarHidden(true, animated: false)
        nav.toolbar.alpha = 1
    }

    /// Whether the navigation stack's current top — the screen this feed is
    /// disappearing underneath or popping back to — presents toolbar items of
    /// its own. `topViewController` is already the successor by the time the
    /// disappearance callbacks run.
    private func successorUsesToolbar(on nav: UINavigationController) -> Bool {
        guard let top = nav.topViewController, top !== self else { return false }
        return top.toolbarItems?.isEmpty == false
    }

    /// One item == one full screen; a plain vertical layout, paged by
    /// `isPagingEnabled` against the (inset-free) bounds.
    private static func makeLayout() -> UICollectionViewLayout {
        let full = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
        let item = NSCollectionLayoutItem(layoutSize: full)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: full, subitems: [item])
        return UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
    }

    private func configureStatusLabel() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.xl)
        }
    }

    /// Whether a keyboard is currently on screen — see
    /// `zoomVerticalDismissalPermitted`.
    ///
    /// Tracked from the notifications rather than read off
    /// `keyboardLayoutGuide`, because the question is asked at the moment a
    /// GESTURE begins: the guide's frame is animating then, and a guide
    /// halfway down answers neither yes nor no.
    private var isKeyboardOnScreen = false

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
            MainActor.assumeIsolated { self?.setForeground(false) }
        })
        appObservers.add(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(true) }
        })
        // (A keyboard-session rail yield used to live here: the engaged
        // composer rose into the rail's column, so the rail conceded the
        // band while typing. The engagement fades the rail outright now, so
        // there is no overlap left to arbitrate.)
    }

    private func setForeground(_ foreground: Bool) {
        isForeground = foreground
        refreshVisibility()
    }

    // MARK: - Rendering

    private func render(_ state: FeedViewModel.RenderState) {
        let previousModels = modelsByID
        // The viewer's "not interested" applies HERE, one render late by
        // design: the post they were on when they asked stays until they leave
        // it, and never comes back.
        orderedIDs = state.items.map(\.id).filter {
            !notInterestedIDs.contains($0) || $0 == activePostID
        }
        modelsByID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })

        // ⚠️ **A stable id is not an unchanged page** — see
        // `SeededPageReconciliation` for the whole rule and why it is a value.
        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: orderedIDs,
            previous: previousModels,
            current: modelsByID,
            // A RESTING engagement is a text page's ordinary layout, not an open
            // panel — passing it here excluded every text page from ever being
            // repaired. Only the viewer's own mutation is protected.
            engaged: commentsEngagementIsResting ? nil : commentsEngagedID
        )

        #if DEBUG
        // How many pages this feed has, and when. A feed pushed before its
        // items arrive has NOTHING to lay out, so what fills the screen is the
        // cell's black floor — no media card involved, which is why tracing the
        // card showed it holding a poster the whole time. Under injected
        // latency this window is the injected latency long.
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            // `reconfigured` is the half that is otherwise unobservable: a
            // second render with the same ids looks identical from outside, and
            // whether it redrew anything is exactly the question.
            print(String(format: "[media] %.3f feed render items=%d reconfigured=%d",
                         CACurrentMediaTime(), orderedIDs.count, changed.count))
        }
        #endif
        var snapshot = NSDiffableDataSourceSnapshot<Section, PostID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(orderedIDs)
        // Same identity, new content — the one thing appendItems cannot say.
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
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
                updateBarChrome(at: active)
            }
        }

        // A hero flight in progress whose post hydrated just now (cold tap):
        // fill in the flying card's chrome where it is. Its geometry is
        // data-independent, so only the text/avatar fade in.
        if let flightChrome {
            UIView.transition(with: flightChrome, duration: 0.15, options: [.transitionCrossDissolve]) {
                self.configureFlightChrome(flightChrome)
            }
        }

        switch state.phase {
        case .loading, .content:
            statusLabel.isHidden = true
        case .empty:
            statusLabel.text = "Nothing here yet.\nFollow people to fill your timeline."
            statusLabel.isHidden = false
        case .failed(let message):
            statusLabel.text = message
            statusLabel.isHidden = false
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

    /// The active post's UNDOABLE spend: what this screen has boosted onto
    /// it while it stayed the active page. Paging away FINALIZES it — the
    /// lifecycle's resign hook clears the tally — which is the product
    /// rule stated as ownership: the undo window IS the post's time on
    /// screen. One post at a time, because only one post is on screen.
    private var sessionBoostID: PostID?
    private var sessionBoostAmount = 0

    /// One boost spend, wallet-first: the debit lands synchronously (or is
    /// refused) before any pixel moves, so the feedback can never promise a
    /// state the balance doesn't have. Haptics here with the verdict —
    /// constructed inline, the codebase's idiom — visuals on the cell that
    /// asked. A nil wallet (unwired host) drops the tap silently; the mock
    /// store is always wired in the app itself.
    private func performBoost(on id: PostID, amount: Int, feedbackCell: SnapFeedCell?) {
        guard let wallet else { return }
        switch wallet.boost(targetID: id.rawValue, amount: amount) {
        case .boosted(_, let targetTotal, let spent):
            // `spent`, never the request: a near-cap boost is CLAMPED to
            // the remainder, and the tally/float must say what actually
            // left the wallet.
            if sessionBoostID == id {
                sessionBoostAmount += spent
            } else {
                sessionBoostID = id
                sessionBoostAmount = spent
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // Receipt before theatre: the anchor flips to (or grows) its
            // number face, then the "+N" float rises off it.
            feedbackCell?.setBoostTotal(targetTotal)
            feedbackCell?.playBoostConfirmation(amount: spent)
            refreshVisibleBoostControls()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-wallet-log") {
                print("[wallet] boosted post=\(id.rawValue) requested=\(amount) spent=\(spent) targetTotal=\(targetTotal) balance=\(wallet.balance)")
            }
            #endif
        case .insufficientBalance(let balance):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            feedbackCell?.playBoostDenied()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-wallet-log") {
                print("[wallet] boost DENIED post=\(id.rawValue) amount=\(amount) balance=\(balance)")
            }
            #endif
        case .targetCapReached(let targetTotal):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            feedbackCell?.playBoostDenied()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-wallet-log") {
                print("[wallet] boost CAP post=\(id.rawValue) targetTotal=\(targetTotal)")
            }
            #endif
        }
    }

    /// Takes back the whole session spend on `id` — the menu's Undo entry.
    /// Session-scoped by construction: the guard requires the tally to
    /// still name this post, and the tally dies the moment the post resigns
    /// the active page.
    private func performBoostUndo(on id: PostID, feedbackCell: SnapFeedCell?) {
        guard let wallet, sessionBoostID == id, sessionBoostAmount > 0,
              let result = wallet.undoBoost(targetID: id.rawValue, amount: sessionBoostAmount)
        else { return }
        let refunded = sessionBoostAmount
        sessionBoostID = nil
        sessionBoostAmount = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        feedbackCell?.setBoostTotal(result.targetTotal)
        feedbackCell?.playBoostRefund(amount: refunded)
        refreshVisibleBoostControls()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-wallet-log") {
            print("[wallet] boost UNDO post=\(id.rawValue) refunded=\(refunded) targetTotal=\(result.targetTotal) balance=\(result.newBalance)")
        }
        #endif
    }

    /// Renders one wallet snapshot onto the header badge — balance in the
    /// compact spelling, plus the claim-countdown ring (self-animating, so
    /// this only needs to run on store changes, not on a clock). The pulse
    /// rides the sheet's presence: a badge that can open the claim sheet
    /// may advertise a waiting claim; a display-only one must not promise
    /// what it can't deliver.
    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    /// Presents the shell-vended wallet sheet over this screen — the badge's
    /// tap, and the `-feed-open-wallet` hook's shared path.
    private func presentWalletSheet() {
        guard let makeWalletSheet, presentedViewController == nil else { return }
        present(makeWalletSheet(), animated: true)
    }

    /// Pushes the wallet's current answer — affordability and the
    /// session-undoable tally — into every visible cell's boost anchor, so
    /// a spend (or a claim on another screen) enables/disables the control
    /// and updates the menu it will build on its next long-press.
    private func refreshVisibleBoostControls() {
        guard let wallet else { return }
        let balance = wallet.balance
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard orderedIDs.indices.contains(indexPath.item),
                  let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell else { continue }
            let id = orderedIDs[indexPath.item]
            cell.setBoostContext(
                balance: balance,
                undoable: sessionBoostID == id ? sessionBoostAmount : 0
            )
        }
    }

    // MARK: - Comments engagement

    /// The on-post comments mutation, fully in-cell: media docks into the
    /// strip, the caption flies to its side, and the comments UI — a child
    /// controller OWNED HERE, merely hosted by the cell — lifts into the
    /// vacated region. One surface, one spring block, one motion profile
    /// (the sheet and the custom presentation that preceded this each
    /// split the screen into two motion systems). Playback is untouched:
    /// nothing presents, so the cell never resigns. This is the MODAL
    /// path (user taps a comment surface on a media post) — the animated
    /// reveal, the pager lock, and the toolbar swap all fire together;
    /// text pages take the pre-rendered resting path instead.
    private func presentComments(for id: PostID, animated: Bool = true) {
        guard commentsEngagedID == nil,
              let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell
        else { return }

        // THE WORK IS ALREADY DONE, on the settle seam: building this panel
        // and laying it out costs ~115ms of main thread (measured: 18ms to
        // construct the controller, 15ms to load its view, 62ms to install
        // and lay out its tree, and the rest in the entrance poses). Spent
        // at tap time that blocks the CA commit for about seven frames, and
        // a video underneath does not stall so much as stop being SHOWN —
        // which is the micro-pause. Spent on activation it costs nothing
        // visible, because nothing is moving yet.
        //
        // The fallback path still builds here: a tap can outrun the warm
        // (a page tapped before it settled), and a correct-but-hitchy
        // engagement beats a missing one.
        let detail: PostDetailViewController?
        #if DEBUG
        let __engageStart = CACurrentMediaTime()
        beginHitchWatch()
        #endif
        let wasPrewarmed = prewarmedCommentsID == id && commentsContentVC != nil
        if wasPrewarmed, let warmed = commentsContentVC as? PostDetailViewController {
            prewarmedCommentsID = nil
            detail = warmed
        } else {
            discardPrewarmedComments()
            detail = installCommentsPanel(for: id, host: cell)
            guard detail != nil || commentsContentVC != nil else { return }
        }
        commentsEngagedID = id
        // TOTAL DEAD-END for vertical scrolling: the pager is disabled for
        // the engagement's whole lifetime. This is the structural answer
        // to UIKit's nested-scroll chaining — outer and inner scroll pans
        // recognize simultaneously by design, and boundary excess hands
        // off to the outer the moment the inner pins to an edge; no
        // begin-time veto can prevent a handoff on a pan that already
        // began. A disabled pan cannot receive the handoff, full stop.
        collectionView.isScrollEnabled = false
        // Sort is engagement-scoped — every fresh engagement starts at
        // Recent, and the selection drives the STREAM. Already done for a
        // warm panel (see `installCommentsPanel`), so this is the fallback
        // path's copy.
        if !wasPrewarmed {
            commentSortButton.reset()
            commentSortButton.onOrderChange = { [weak detail] order in
                detail?.setCommentSortOrder(order)
            }
        }
        setEngagedChrome(true, hasMedia: true, animated: animated)
        // LAYOUT FIRST, UNANIMATED. Inside the spring, `layoutIfNeeded`
        // turns every frame the layout resolves into an animated property —
        // and the tree under it is the whole comments panel. On a warm panel
        // there is nothing pending anyway; on the fallback path a settled
        // frame is what we want the spring to animate FROM, not something
        // for it to interpolate towards.
        UIView.performWithoutAnimation { cell.contentView.layoutIfNeeded() }
        // ⚠️ NOTHING TO ANIMATE FROM. A post opened AT its comments has never
        // been seen in the other layout, so there is no previous state for a
        // spring to carry the eye between — animating here would show the
        // viewer the arrangement they did not ask for, for a fifth of a second,
        // on their way to the one they did.
        if !animated {
            UIView.performWithoutAnimation {
                cell.setCommentsEngaged(true)
                detail?.animateEngagedTransition(toEngaged: true, duration: 0)
                cell.contentView.layoutIfNeeded()
            }
        } else {
        // ONE MOTION, still — but built out of explicit animations rather
        // than a `UIView.animate` block. The block's own commit was the last
        // thing standing between this transition and a whole frame budget:
        // measured at ~14ms with nothing left inside it to explain, against
        // ~1ms for the same properties animated directly.
        cell.animateCommentsEngaged(true, duration: SnapCommentsLayout.engageDuration)
        detail?.animateEngagedTransition(
            toEngaged: true, duration: SnapCommentsLayout.engageDuration
        )
        }
        #if DEBUG
        // The discriminating measurement: frame gaps once the animation is
        // OVER and the engaged interface is simply sitting there. If it drops
        // frames at rest, the cost is compositing what is on screen, not the
        // work of getting there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.beginHitchWatch("engaged-steady")
        }
        #endif
        #if DEBUG
        // The whole tap-time cost, in one number. It is a hitch budget: any
        // main-thread work here is a frame the video is not shown on.
        if ProcessInfo.processInfo.arguments.contains("-engage-profile") {
            print(String(format: "[engage] TAP→animating %6.2f ms (warm=%@ animated=%@)",
                         (CACurrentMediaTime() - __engageStart) * 1000,
                         wasPrewarmed ? "yes" : "NO",
                         animated ? "yes" : "no"))
        }
        #endif
    }

    /// The TEXT page's resting engagement, PHASE 1 (visual pre-render):
    /// mounts the whole interface — glass card, collapsed slot, frost,
    /// hosted stream, composer onstage — INSTANTLY and on VISIBILITY (the
    /// cell's `willDisplay`, as it scrolls in), so a text page enters the
    /// viewport 100% pre-assembled with zero reveal animation. Two things
    /// the modal `presentComments` does are DEFERRED to settle (phase 2,
    /// `lockRestingEngagement`): the pager freeze (disabling it here would
    /// abort the very scroll bringing the cell in) and the engaged toolbar
    /// swap (nav chrome follows the SETTLED page, not a half-scrolled one).
    /// Idempotent by the slot guard; media pages never take this path.
    /// A text page's interface, built BEFORE its cell exists.
    ///
    /// ⚠️ THE COST IS THE BUILD, NOT THE DATA. The stream is already warm by
    /// the time a page scrolls in (see `warmContent`), and the page still
    /// arrived as a black rectangle that filled itself in a beat later —
    /// because what a text page IS is this panel, and it was constructed at
    /// `willDisplay`, which is the same moment the black is on screen. Roughly
    /// 100ms of layout, spent exactly when nothing can absorb it.
    ///
    /// ⚠️ HELD IN ITS OWN FIELD, and that is not tidiness. The engagement slot
    /// (`commentsContentVC`) is what `presentRestingComments` guards on: a warm
    /// parked there makes the mount decline, and the page then arrives blank
    /// for good rather than late. That exact mistake is on the record; this
    /// holds the built panel to one side and hands it over at the mount.
    ///
    /// Never during a flight, for the reason `prewarmComments` gives: this is
    /// layout, and a hero's frame budget is not where it should be paid.
    /// ⚠️ AND IT DOES NOT WAIT FOR THE ENGAGEMENT SLOT TO BE FREE, which the
    /// first version of this did and which made it never run.
    ///
    /// Guarding on `commentsEngagedID`/`commentsContentVC` was copied from the
    /// MOUNT, where those fields mean "something is already installed in a
    /// cell". Building means nothing of the sort: this constructs into its own
    /// field and touches neither. Their two most common values are exactly the
    /// cases that matter — the current page is a text page and is holding the
    /// slot with its own resting panel, or the current media page has had its
    /// tap-to-comments panel warmed into it — so the guard declined precisely
    /// when the next page needed building, and the black rectangle came back
    /// unchanged.
    private func prewarmRestingComments(for id: PostID) {
        guard !isAwaitingZoomPresentation,
              prewarmedRestingID != id,
              modelsByID[id]?.mediaURL == nil,
              let makeCommentsPanelContent else { return }
        discardPrewarmedResting()
        let content = makeCommentsPanelContent(id)
        content.view.backgroundColor = .clear
        // ⚠️ IN THE DEVICE'S THEME, not `.unspecified`.
        //
        // This view controller has no parent yet, so `.unspecified` resolves
        // against nothing and it is laid out and rendered in whatever UIKit
        // defaults to — then it is mounted into a cell and changes theme in
        // front of the viewer. The whole point of building ahead is that
        // nothing about the page changes when it arrives.
        content.overrideUserInterfaceStyle = deviceInterfaceStyle
        // Laid out at the size it will be mounted at, so the mount is a
        // re-parent rather than a first layout. A view built and never measured
        // saves nothing.
        content.view.frame = view.bounds
        content.view.layoutIfNeeded()
        prewarmedRestingID = id
        prewarmedRestingVC = content
        #if DEBUG
        debugPrewarmedRestingID = id
        #endif
    }

    #if DEBUG
    /// The mount and the media warm, reachable without a scroll — the defect
    /// they produce together is an ORDER between two seams, and a test that
    /// could not put them in that order could not see it.
    func debugPrewarmComments(for id: PostID) {
        guard let cell = collectionView.visibleCells.compactMap({ $0 as? SnapFeedCell }).first
        else { return }
        prewarmComments(for: id, host: cell)
    }

    func debugMountRestingComments(for id: PostID) {
        guard let cell = collectionView.visibleCells.compactMap({ $0 as? SnapFeedCell }).first
        else { return }
        presentRestingComments(for: id, host: cell)
    }

    /// A warm with no engagement behind it — the state that blocked the mount.
    var debugHasParkedCommentsWarm: Bool {
        commentsEngagedID == nil && commentsContentVC != nil
    }

    /// Which post the resting panel is standing in for right now.
    var debugRestingCommentsID: PostID? { commentsEngagedID }

    /// And which one is showing a panel WITHOUT owning the engagement.
    var debugPreviewRestingID: PostID? { previewRestingID }

    /// The moment a cell BEGINS displaying, through the delegate the app uses.
    ///
    /// ⚠️ Not `presentRestingComments` directly. The defect this exists for was
    /// a GATE at this call site, so a test that called the method underneath it
    /// proved the method right and the screen blank.
    func debugWillDisplayCell(at item: Int) {
        let path = IndexPath(item: item, section: 0)
        // Half a page in, which is where a real drag realizes it — a cell that
        // has not been built yet cannot be told it is about to display, and a
        // test that skipped that would assert about nothing.
        let page = collectionView.bounds.height
        if collectionView.cellForItem(at: path) == nil, page > 0 {
            collectionView.contentOffset.y = (CGFloat(item) - 0.5) * page
            collectionView.layoutIfNeeded()
        }
        guard let cell = collectionView.cellForItem(at: path) else { return }
        collectionView(collectionView, willDisplay: cell, forItemAt: path)
    }

    /// Walks the page swipe a finger drives on a text page, animated settle
    /// included.
    ///
    /// The only gesture that moves a text page belongs to the composer bar, and
    /// a synthetic drag cannot produce it — so the window that matters most
    /// here, the half-second while the settle animates and the model has
    /// already arrived at the destination, had no scripted route at all. Every
    /// defect reported inside it had to be found by watching a recording.
    func debugDrivePageSwipe(steps: Int = 12, distance: CGFloat = 520) {
        drivePageSwipe(.began, translation: 0, velocity: 0)
        for step in 1...max(1, steps) {
            let dy = -distance * CGFloat(step) / CGFloat(max(1, steps))
            drivePageSwipe(.changed, translation: dy, velocity: -900)
        }
        drivePageSwipe(.ended, translation: -distance, velocity: -900)
    }

    /// Tells the screen about every cell the layout has just realized, the way
    /// a real scroll does.
    ///
    /// A test moves `contentOffset` directly, and UIKit builds the cells but
    /// does not run the delegate's begin-displaying callback for them — which
    /// is where a page decides what to show. Without this a suite can only
    /// observe settled states, and four of the six defects in this area lived
    /// strictly between them.
    /// One page of scroll, in sixtieths of a second — a flick, not a jump.
    ///
    /// Each step is an ordinary offset change followed by the delegate callback
    /// UIKit would have sent, so everything that reacts to scrolling reacts
    /// here: the paging footer, and the page that owns the picture.
    func debugFlingPages(_ remaining: Int) {
        guard remaining > 0 else { return }
        let page = collectionView.bounds.height
        guard page > 0 else { return }
        let start = collectionView.contentOffset.y
        let target = min(start + page, CGFloat(reachableCeiling()) * page)
        let steps = 24
        print("[fling] begin from=\(Int(start)) to=\(Int(target))")
        func step(_ index: Int) {
            guard index <= steps else {
                self.scrollViewDidEndDecelerating(self.collectionView)
                print("[fling] settle offsetY=\(Int(self.collectionView.contentOffset.y))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.debugFlingPages(remaining - 1)
                }
                return
            }
            let progress = CGFloat(index) / CGFloat(steps)
            collectionView.contentOffset.y = start + (target - start) * progress
            scrollViewDidScroll(collectionView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { step(index + 1) }
        }
        step(1)
    }

    func debugRealizeVisibleCells() {
        for path in collectionView.indexPathsForVisibleItems.sorted() {
            guard let cell = collectionView.cellForItem(at: path) else { continue }
            collectionView(collectionView, willDisplay: cell, forItemAt: path)
        }
    }

    /// Pretends a keyboard came up, so the veto below it can be tested without
    /// one — a simulator will not raise a real keyboard for a unit test, and
    /// the rule is about what the veto ANSWERS while one is up.
    func debugSetKeyboardOnScreen(_ onScreen: Bool) { isKeyboardOnScreen = onScreen }

    /// Which posts have a comments panel ON SCREEN right now, asked of the
    /// cells rather than of any bookkeeping.
    ///
    /// A specification for this screen has to be written against what the
    /// viewer sees: every defect here has been a disagreement between a field
    /// and the pixels, so a test that reads the field agrees with the bug.
    var debugPostsShowingComments: Set<PostID> {
        var showing: Set<PostID> = []
        for cell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell),
                  orderedIDs.indices.contains(path.item),
                  let snap = cell as? SnapFeedCell, snap.isShowingComments else { continue }
            showing.insert(orderedIDs[path.item])
        }
        return showing
    }

    /// Whether the pager can be scrolled at all — the state a leaked
    /// engagement used to be able to hold down for the rest of a session.
    var debugPagerIsLocked: Bool { !collectionView.isScrollEnabled }

    /// The ceiling the pager actually clamps to — prepares, then answers.
    func debugReachableCeiling() -> Int { reachableCeiling() }

    /// The moment a page's last pixel leaves — which a unit test's scroll does
    /// not produce, and which is now when a resting page is torn down.
    func debugLeaveCell(at item: Int) {
        let path = IndexPath(item: item, section: 0)
        guard let cell = collectionView.cellForItem(at: path) else { return }
        collectionView(collectionView, didEndDisplaying: cell, forItemAt: path)
    }

    /// Which text page has had its interface built ahead. Kept separately from
    /// the live field so a test can see a warm that was CONSUMED — which is the
    /// half that proves the mount paid nothing.
    private(set) var debugPrewarmedRestingID: PostID?
    #endif

    /// One at a time: the pager moves on and the page two ahead is not worth a
    /// second view controller's memory.
    private func discardPrewarmedResting() {
        prewarmedRestingVC = nil
        prewarmedRestingID = nil
    }

    private func presentRestingComments(for id: PostID, host cell: SnapFeedCell) {
        // ⚠️ A PARKED WARM IS NOT AN ENGAGEMENT, and treating it as one is the
        // black page.
        //
        // The guard below reads `commentsContentVC` as "a panel is installed in
        // a cell". A media page's tap-to-comments WARM sits in that same field
        // with no engagement behind it — so scrolling from a warmed media page
        // onto a text page found the slot taken, declined the mount, and the
        // text page scrolled in as a black rectangle. It then appeared all at
        // once at the settle, where the resign leg discards the warm and the
        // activate leg mounts for real. Measured exactly that way on a
        // recording: black for the whole scroll, complete the instant it
        // stopped.
        //
        // The warm belongs to the page being LEFT and is worth nothing now.
        if commentsEngagedID == nil, prewarmedCommentsID != nil {
            discardPrewarmedComments()
        }
        guard commentsEngagedID == nil, commentsContentVC == nil else {
            // ⚠️ THE SLOT IS HELD BY ANOTHER PAGE'S ENGAGEMENT — text onto
            // text, where the page being left is still on screen and still
            // needs its panel. The incoming page gets a PREVIEW instead: the
            // same panel in the same place, without the engagement's
            // bookkeeping. The settle promotes it once the slot frees.
            previewRestingComments(for: id, host: cell)
            return
        }
        guard let content = restingPanel(for: id) else { return }
        commentsEngagedID = id
        commentsContentVC = content
        commentsEngagementIsResting = true
        restingLockApplied = false
        installRestingPanel(content, for: id, host: cell)
    }

    /// The incoming page's panel, mounted while another page still owns the
    /// engagement.
    ///
    /// ⚠️ EVERYTHING THE VIEWER SEES, NONE OF WHAT THE VIEWER DRIVES.
    ///
    /// The engagement is one slot on purpose: it carries the pager lock, the
    /// composer's ownership and the toolbar's context, and two of those at once
    /// is a contradiction. What is NOT single is the picture — a text page IS
    /// its panel, so a page scrolling in has to show one or it is a black
    /// rectangle until the scroll stops. That is the reported defect for text
    /// onto text, where the page being left still needs its own.
    ///
    /// So the panel is mounted into the incoming cell with no claim on the
    /// slot, and the settle promotes it the moment the page being left
    /// resigns. The promotion is a field assignment: nothing is built twice.
    private func previewRestingComments(for id: PostID, host cell: SnapFeedCell) {
        guard previewRestingID != id, commentsEngagedID != id,
              let content = restingPanel(for: id) else { return }
        discardRestingPreview()
        previewRestingID = id
        previewRestingVC = content
        previewRestingCell = cell
        installRestingPanel(content, for: id, host: cell)
    }

    /// Hands the engagement to a panel that is already on screen. False when
    /// there is nothing to promote, so the caller mounts for real.
    @discardableResult
    private func promoteRestingPreview(for id: PostID) -> Bool {
        guard previewRestingID == id, let content = previewRestingVC,
              commentsEngagedID == nil, commentsContentVC == nil else { return false }
        previewRestingID = nil
        previewRestingVC = nil
        previewRestingCell = nil
        commentsEngagedID = id
        commentsContentVC = content
        commentsEngagementIsResting = true
        restingLockApplied = false
        return true
    }

    private func discardRestingPreview() {
        if let content = previewRestingVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
            previewRestingCell?.setCommentsEngaged(false)
            previewRestingCell?.clearComments()
        }
        previewRestingVC = nil
        previewRestingID = nil
        previewRestingCell = nil
    }

    /// The panel for a post: the one built ahead when it matches, a fresh one
    /// otherwise.
    private func restingPanel(for id: PostID) -> UIViewController? {
        if prewarmedRestingID == id, let warmed = prewarmedRestingVC {
            discardPrewarmedResting()
            return warmed
        }
        return makeCommentsPanelContent?(id)
    }

    /// Everything a resting panel needs once it has a cell — identical whether
    /// it is the engagement or a preview, because what the VIEWER gets must not
    /// depend on which of the two it is.
    private func installRestingPanel(
        _ content: UIViewController, for id: PostID, host cell: SnapFeedCell
    ) {
        content.view.backgroundColor = .clear
        // Inherited, exactly like the media panel — the cell decides.
        content.overrideUserInterfaceStyle = .unspecified
        addChild(content)
        cell.installComments(content.view)
        content.didMove(toParent: self)
        let detail = content as? PostDetailViewController
        detail?.setEngagedInsets(
            top: cell.engagedCommentsTopInset(safeAreaTop: view.safeAreaInsets.top),
            bottomInset: view.safeAreaInsets.bottom
        )
        // The caption the FEED already has, so the row exists while the hero
        // is in the air rather than arriving with the post fetch.
        if let model = modelsByID[id], let caption = model.caption, !caption.isEmpty {
            // The AUTHOR travels with the caption: the row is an avatar beside
            // a bubble for every post now, and this path — the text page's
            // resting interface — is the one that mounts before any fetch, so
            // without it the disc would sit empty for the whole reveal.
            detail?.seedCaption(
                caption,
                timestamp: model.timestampText,
                authorName: model.authorName,
                monogram: CommentsInputBar.monogram(model.authorName),
                avatarURL: model.avatarURL,
                metrics: model.cardMetrics
                    ?? PostCardMetrics(views: nil, reactions: model.likeCount, comments: nil)
            )
        }
        // No close handler — a resting page is undismissable; the swipe
        // handler pages the feed (the only way off a text post).
        detail?.setEngagedPageSwipeHandler { [weak self] phase, translation, velocity in
            self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
        }
        // INSTANT: composer already onstage, cell engaged synchronously —
        // no spring, no offstage→onstage slide. The interface simply IS,
        // frame one, so scrolling it into view reveals it already formed.
        detail?.setComposerEntranceState(offstage: false)
        // ⚠️ AT THE MOUNT TOO, not only at the next settle.
        //
        // The reconcile derives this, but it runs when a page SETTLES — and the
        // composer is on screen, and wrong, for the whole scroll before that.
        // The rule is the same in both places: the ceiling belongs to the page
        // being read, and a page mounting while another is settled is not it.
        detail?.setComposerTracksKeyboard(id == activePostID)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
    }

    #if DEBUG
    private var hitchLink: CADisplayLink?
    private var hitchLast: CFTimeInterval = 0
    private var hitchWorst: CFTimeInterval = 0
    private var hitchDropped = 0
    private var hitchLabel = "transition"

    /// Counts frames the transition misses. `-engage-profile` only.
    ///
    /// The honest measure of "smooth": not how long a function took, but how
    /// long the screen went without an update. A frame is due every ~16.7ms;
    /// anything meaningfully past that is a frame the video was not shown on.
    private func beginHitchWatch(_ label: String = "transition") {
        guard ProcessInfo.processInfo.arguments.contains("-engage-profile") else { return }
        hitchLabel = label
        hitchLink?.invalidate()
        hitchLast = CACurrentMediaTime()
        hitchWorst = 0
        hitchDropped = 0
        let link = CADisplayLink(target: self, selector: #selector(hitchTick))
        link.add(to: .main, forMode: .common)
        hitchLink = link
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.hitchLink?.invalidate()
            self.hitchLink = nil
            print(String(format: "[engage] %-16@ worst gap %5.1f ms, %d dropped (>25ms) in 1.5s",
                         self.hitchLabel, self.hitchWorst * 1000, self.hitchDropped))
        }
    }

    @objc private func hitchTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = now - hitchLast
        hitchLast = now
        hitchWorst = max(hitchWorst, gap)
        if gap > 0.025 { hitchDropped += 1 }
    }
    #endif

    /// Builds the comments panel for `id` and installs it into `cell` in its
    /// FULLY DISMISSED pose — hosted, laid out, and invisible. Shared by the
    /// warm and the tap, so there is one definition of "installed".
    ///
    /// The dismissed pose is not cosmetic: `installComments` unhides the
    /// header frost and leaves the container at alpha 0, and a freshly
    /// installed panel has never been through the engagement's interpolator,
    /// so without `setCommentsEngagementProgress(1)` the frost band would sit
    /// visible over a resting page. Alpha 0 also keeps the full-cell
    /// container out of hit-testing, so a warm panel cannot eat the page's
    /// taps.
    @discardableResult
    private func installCommentsPanel(
        for id: PostID, host cell: SnapFeedCell
    ) -> PostDetailViewController? {
        guard commentsContentVC == nil, let makeCommentsPanelContent else { return nil }
        let content = makeCommentsPanelContent(id)
        content.view.backgroundColor = .clear
        // No style of its own: the panel is hosted INSIDE the cell and
        // inherits the page's theme from it (see `SnapChromeTheme`).
        content.overrideUserInterfaceStyle = .unspecified
        commentsContentVC = content
        addChild(content)
        cell.installComments(content.view)
        content.didMove(toParent: self)
        let detail = content as? PostDetailViewController
        detail?.setEngagedInsets(
            top: cell.engagedCommentsTopInset(safeAreaTop: view.safeAreaInsets.top),
            // KEEP-AND-STACK: the composer's rest band clears the NATIVE
            // TOOLBAR, not just the home indicator.
            bottomInset: view.safeAreaInsets.bottom
        )
        // Dragging the list down from its top collapses back to media — the
        // sheet gesture. MEDIA pages only: a text engagement is the page's
        // permanent resting state, so there is nothing to collapse to.
        if modelsByID[id]?.mediaURL != nil {
            detail?.setPullDismissDriveHandler { [weak self] phase, translation, velocity in
                self?.drivePullDismiss(phase, translation: translation, velocity: velocity)
            }
        }
        detail?.setEngagedPageSwipeHandler { [weak self] phase, translation, velocity in
            self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
        }
        detail?.setComposerEntranceState(offstage: true)
        detail?.setStreamTransitionProgress(1)
        cell.setCommentsEngagementProgress(1)
        // EVERYTHING THE TAP WOULD OTHERWISE PAY FOR, paid here instead.
        //
        // Both blur bands materialize now (ordered after the offstage pose,
        // which nils the composer's), and the sort menu is built now — a
        // `UIMenu` with its actions is an allocation the tap does not need to
        // make. All three are invisible or inert in the dismissed pose, and
        // all three are idempotent, so the engagement's own attempts find
        // the work already done.
        cell.prematerializeEngagedChrome()
        detail?.prematerializeComposerChrome()
        commentSortButton.reset()
        commentSortButton.onOrderChange = { [weak detail] order in
            detail?.setCommentSortOrder(order)
        }
        return detail
    }

    /// Builds a MEDIA page's comments panel on the settle seam, so the tap
    /// that opens it has nothing left to build. The text pages' resting
    /// pre-render doctrine, applied to the cost rather than to the layout:
    /// one page at a time, discarded when it resigns.
    private func prewarmComments(for id: PostID, host cell: SnapFeedCell) {
        // NEVER DURING A FLIGHT. This is ~100ms of layout, and `willDisplay`
        // fires inside the hero transition's own `container.layoutIfNeeded` —
        // so warming here paid for the comments panel out of the FLIGHT's
        // frame budget. Measured: the present leg's first layout went from
        // 36–64ms to 139–145ms with this running, which is the same mistake
        // the warm exists to fix, moved to a worse place. Playback is deferred
        // across the flight for exactly this reason; so is this now, and
        // `zoomTransitionDidEnd` picks it up on landing.
        guard !isAwaitingZoomPresentation else { return }
        guard commentsEngagedID == nil, commentsContentVC == nil,
              prewarmedCommentsID == nil,
              modelsByID[id]?.mediaURL != nil else { return }
        prewarmedCommentsID = id
        engagedCellForPrewarm = cell
        installCommentsPanel(for: id, host: cell)
    }

    /// How long after a transition the warm waits for genuine idle.
    ///
    /// Long enough to clear the flight (0.45s) and the settle behind it. The
    /// warm costs nothing in hit rate for waiting: engaging the comments is a
    /// deliberate act that arrives seconds later, not frames.
    private static let idleWarmDelay: TimeInterval = 0.6

    /// Warms the active page's comments once the screen has actually gone
    /// quiet, re-checking on arrival — the page may have moved on, or the
    /// viewer may have engaged already, in which case there is nothing to do.
    private func scheduleIdleCommentsWarm() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleWarmDelay) { [weak self] in
            self?.rewarmActivePageComments()
        }
    }

    /// Warms the page that is active RIGHT NOW — the disengagement's tail,
    /// where the settle seam has long since passed.
    private func rewarmActivePageComments() {
        guard let index = lifecycle.activeIndex, orderedIDs.indices.contains(index),
              let cell = collectionView.cellForItem(
                  at: IndexPath(item: index, section: 0)
              ) as? SnapFeedCell else { return }
        prewarmComments(for: orderedIDs[index], host: cell)
    }

    /// Drops a warm panel that was never engaged — the page moved on, or its
    /// cell is being recycled underneath it.
    private func discardPrewarmedComments() {
        guard prewarmedCommentsID != nil, commentsEngagedID == nil else { return }
        prewarmedCommentsID = nil
        if let content = commentsContentVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        commentsContentVC = nil
        engagedCellForPrewarm?.clearComments()
        engagedCellForPrewarm = nil
    }

    /// The TEXT page's resting engagement, PHASE 2 (settle lock): once the
    /// page has locked into place, freeze the pager (the dead-end doctrine
    /// — over-scroll never chains to a page change) and swap in the
    /// engaged toolbar context. Deferred out of the pre-render so neither
    /// touches the still-in-flight scroll. Runs once per engagement.
    /// Makes the screen match the page it is actually on.
    ///
    /// ⚠️ DERIVED, NOT MAINTAINED — and every leak in this file came from the
    /// difference.
    ///
    /// The resting interface and the pager's lock used to be moved by
    /// TRANSITIONS: mounted here, torn down there, unlocked in a teardown. Each
    /// of those runs only if its callback does, and the callbacks are not
    /// guaranteed — a cell recycled without an end-display, a resign leg that
    /// defers to one, a promotion waiting for a slot nobody freed. Any single
    /// miss leaves the screen describing a page the viewer left: measured as
    /// `settled=1 engaged=post-new-07 scrollEnabled=false`, two pages later,
    /// with the pager locked for a post no longer on screen. Nothing could
    /// scroll and nothing in the trace said why.
    ///
    /// A reconcile cannot leak. It asks what is true NOW — which page is
    /// settled, whether the old one is still visible — and makes the screen
    /// agree. A missed callback costs one settle's delay instead of the rest of
    /// the session.
    private func reconcileRestingInterface(activeIndex: Int) {
        let activeID = orderedIDs.indices.contains(activeIndex) ? orderedIDs[activeIndex] : nil
        let activeIsText = activeID.flatMap { modelsByID[$0]?.mediaURL == nil } ?? false
        #if DEBUG
        // `-grab-log`: what the reconcile saw. An interface that survives its
        // page is invisible in every other line — the screen looks settled and
        // the pager is simply dead.
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[reconcile] active=\(activeID?.rawValue ?? "nil") text=\(activeIsText)"
                + " engaged=\(commentsEngagedID?.rawValue ?? "nil")"
                + " resting=\(commentsEngagementIsResting)"
                + " engagedOnScreen=\(commentsEngagedID.map(isPostOnScreen) ?? false)")
        }
        #endif

        // An engagement belonging to a page that has LEFT is over, whatever
        // failed to say so. Still-visible pages keep theirs: that is what stops
        // the page being left from emptying while the settle animates.
        if let engaged = commentsEngagedID, commentsEngagementIsResting,
           engaged != activeID, !isPostOnScreen(engaged) {
            finishCommentsDisengagement()
        }
        // The settled text page owns the interface: promote what is already
        // mounted, or mount it.
        if activeIsText, let activeID, !promoteRestingPreview(for: activeID),
           commentsEngagedID == nil,
           let cell = collectionView.cellForItem(
               at: IndexPath(item: activeIndex, section: 0)
           ) as? SnapFeedCell {
            presentRestingComments(for: activeID, host: cell)
        }
        // ⚠️ AND SO DOES THE COMPOSER'S KEYBOARD CEILING.
        //
        // That ceiling is anchored in WINDOW space, so a panel whose cell still
        // hangs below the screen has its composer clamped to the screen's edge
        // instead of travelling with its page — two composers at once, one
        // moving and one stuck.
        //
        // Granting it at the MOUNT was the first attempt and it only covered
        // the page that arrives while another holds the slot. A page arriving
        // from a media post takes the slot outright, mounts as the engagement,
        // and kept the ceiling — which is why it went wrong "sometimes".
        // Derived from the settled page, like everything else here, it cannot
        // depend on which route the panel took.
        (commentsContentVC as? PostDetailViewController)?
            .setComposerTracksKeyboard(commentsEngagedID == activeID)
        (previewRestingVC as? PostDetailViewController)?.setComposerTracksKeyboard(false)
        // ⚠️ AND SO DOES THE GROUND BEHIND THE PAGES.
        //
        // The pager's own background is what shows through any strip a page has
        // not covered — and there is always such a strip for a frame or two: a
        // cell is recycled the moment the model says it has left, while the
        // pixels of the settle are still arriving. Black behind a light page
        // makes that frame a BLACK BAND across the top of the screen, which is
        // what "the post goes black on the way out" was. Measured on a
        // recording: one frame in a hundred and six, top-of-screen brightness
        // 12 against 90 for every other frame.
        //
        // Matching the ground to the settled page does not fix the timing — it
        // makes the timing invisible, which is better: no amount of care about
        // when a cell is recycled can guarantee the frame, and this needs no
        // guarantee.
        collectionView.backgroundColor = activeIsText ? .systemBackground : .black
        // ⚠️ AND THE LOCK FOLLOWS THE SETTLED PAGE, not the engagement.
        //
        // A text page disables the pager because its own scroll view would
        // chain with it. That is a fact about the page on screen, so it is read
        // off the page on screen — an engagement that outlived its page cannot
        // take the pager down with it.
        collectionView.isScrollEnabled = !activeIsText
    }

    /// Whether the post still has PIXELS on screen.
    ///
    /// ⚠️ GEOMETRY, AND FROM THE PRESENTATION LAYER — asking UIKit which cells
    /// are visible answers about the MODEL, and during a settle the model is
    /// already at the destination while the pixels are still travelling. A page
    /// half on screen therefore reported itself gone, its interface was torn
    /// down under the viewer, and what was left was the bare cell: a white
    /// strip with an orphaned composer bar, then the black media floor as it
    /// slid away. Reported twice, and both halves are this one line.
    private func isPostOnScreen(_ id: PostID) -> Bool {
        guard let index = orderedIDs.firstIndex(of: id) else { return false }
        let page = collectionView.bounds.height
        guard page > 0 else { return false }
        let top = CGFloat(index) * page
        // ⚠️ THE MODEL, WIDENED BY A SETTLE THAT IS STILL RUNNING.
        //
        // The presentation layer was tried and is not an answer: it reports a
        // stale offset when nothing is animating, so a page two positions back
        // read as on-screen for the rest of the session — measured as
        // `active=post-new-06 engaged=post-new-07 engagedOnScreen=true`, with
        // the pager locked for a post nobody could see.
        //
        // Our own settle is the ONE case where the model has arrived and the
        // pixels have not, and we start that animation ourselves, so its span
        // is known rather than inferred. Everywhere else — a finger, UIKit's
        // deceleration — the model IS where the pixels are.
        let live = collectionView.contentOffset.y
        let lower = min(live, settleFromOffset ?? live)
        let upper = max(live, settleFromOffset ?? live)
        return top < upper + page && top + page > lower
    }

    /// Where a page-change animation started, for as long as it is running.
    /// Nil at rest — see `isPostOnScreen`.
    private var settleFromOffset: CGFloat?

    private func lockRestingEngagement() {
        guard commentsEngagementIsResting, !restingLockApplied,
              commentsEngagedID != nil else { return }
        restingLockApplied = true
        collectionView.isScrollEnabled = false
        let detail = commentsContentVC as? PostDetailViewController
        commentSortButton.reset()
        commentSortButton.onOrderChange = { [weak detail] order in
            detail?.setCommentSortOrder(order)
        }
        setEngagedChrome(true, hasMedia: false, animated: true)
    }

    /// Reverse mutation (strip tap, entry-surface re-tap): the comments
    /// region settles out, the media expands back, the chrome returns, and
    /// the composer slides back offstage — the mirror image of the engage
    /// leg, all in the same spring. The native toolbar was onstage the
    /// whole time; nothing structural moves in either direction.
    private func dismissComments() {
        guard let engagedID = commentsEngagedID else { return }
        // BELT: a text-only post's engagement is undismissable (the
        // permanent resting state — collapsing it would strand the page
        // on its empty shell). No UI path should reach here for text
        // (the ✕ is unwired, the card gestures unarmed, the strip tap
        // gated), but any future caller meets the same wall.
        if modelsByID[engagedID]?.mediaURL == nil { return }
        // The keyboard rides down with the collapse, not after it.
        commentsContentVC?.view.endEditing(true)
        let detail = commentsContentVC as? PostDetailViewController
        // The mirror morph: the overflow menu takes its slot back and the
        // sort selector leaves the nav bar.
        setEngagedChrome(false, hasMedia: true, animated: true)
        // The mirror of the entrance, same machinery: explicit animations in
        // one transaction, whose completion is the teardown. Starting from
        // `presentation()` matters most on THIS leg — a committed pull-down
        // arrives here already part-way dismissed, and the exit has to carry
        // on from where the finger left it rather than restart.
        // The teardown rides the CELL's animation, and it is scoped to THIS
        // dismissal: an interrupted exit fires the delegate too, and by then a
        // fresh engagement may own the slot — tearing that one down would be
        // worse than not tearing this one down.
        engagedCell()?.animateCommentsEngaged(
            false, duration: SnapCommentsLayout.disengageDuration
        ) { [weak self] in
            guard let self, self.commentsEngagedID == engagedID else { return }
            self.finishCommentsDisengagement()
        }
        detail?.animateEngagedTransition(
            toEngaged: false, duration: SnapCommentsLayout.disengageDuration
        )
    }


    /// The INTERACTIVE page-swipe drive (bar-owned pan → this). The finger
    /// hand-moves the pager's `contentOffset` in real time, so the leaving
    /// page — and the whole engaged layer riding inside its cell (docked
    /// media card, comments, composer) — follows the drag exactly as if the
    /// user were swiping the feed itself. The pager's OWN pan stays disabled
    /// throughout (the dead-end lock is preserved: the comments list still
    /// cannot chain), because programmatic `contentOffset` ignores
    /// `isScrollEnabled`. On release the drive settles to the target page;
    /// the page change tears the old engagement down via the resign leg.
    private func drivePageSwipe(
        _ phase: CommentsInputBar.PageSwipePhase, translation dy: CGFloat, velocity vy: CGFloat
    ) {
        #if DEBUG
        // `-grab-log`: the ONLY gesture that pages a text post, and its ceiling.
        //
        // A text page disables the pager outright, so nothing else on that
        // screen can move it. When it does not move, the question is whether
        // this ran at all and what it was allowed to reach — two answers no
        // other trace carries.
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[drive] \(phase) dy=\(Int(dy)) ceiling=\(reachableCeiling())"
                + " settled=\(settledPageIndex) engaged=\(commentsEngagedID?.rawValue ?? "nil")")
        }
        #endif
        switch phase {
        case .began: beginPageDrive()
        case .changed: updatePageDrive(translation: dy)
        case .ended: endPageDrive(translation: dy, velocity: vy)
        }
    }

    private func beginPageDrive() {
        guard commentsEngagedID != nil else { return }
        // Interrupt any in-flight settle: seize the CURRENT on-screen offset
        // (presentation layer) so a re-grab mid-settle doesn't jump.
        let live = collectionView.layer.presentation()?.bounds.origin.y ?? collectionView.contentOffset.y
        collectionView.layer.removeAllAnimations()
        collectionView.contentOffset.y = live
        pageDriveStartOffset = live
    }

    private func updatePageDrive(translation dy: CGFloat) {
        guard let start = pageDriveStartOffset else { return }
        // Drag up (dy < 0) advances toward the next post (offset grows).
        // FORWARD-ONLY: downward travel rubber-bands against the drive's own
        // origin page rather than previewing the previous post — the floor is
        // the page this drive would settle back to, so a re-grab mid-settle
        // can still be dragged home, but never past it.
        let page = collectionView.bounds.height
        let floor = page > 0 ? (start / page).rounded() * page : 0
        collectionView.contentOffset.y = rubberBandedOffset(start - dy, floor: floor)
    }

    private func endPageDrive(translation dy: CGFloat, velocity vy: CGFloat) {
        guard let start = pageDriveStartOffset else { return }
        pageDriveStartOffset = nil
        let page = collectionView.bounds.height
        guard page > 0 else { return }
        let startIndex = Int((start / page).rounded())
        let step = Self.pageDriveStep(translation: dy, velocity: vy, page: page)
        let target = max(0, min(orderedIDs.count - 1, startIndex + step))
        let targetOffset = CGFloat(target) * page
        // FOOTER MORPH, timed with the settle: if this drive commits to a
        // page that will NOT re-engage into the sort toolbar — i.e. a media
        // post (text posts auto-engage and keep the engaged items) — the
        // engaged→default toolbar swap must animate HERE, concurrently with
        // the page slide, exactly as `dismissComments` does. Otherwise the
        // only teardown swap is `finishCommentsDisengagement`'s instant one,
        // which snaps (visible only forward, Text→Media). Its identity-
        // compare then no-ops once this animated swap has landed default.
        let changesPage = step != 0 && target != startIndex
        let targetReEngages = orderedIDs.indices.contains(target)
            && modelsByID[orderedIDs[target]]?.mediaURL == nil
        if changesPage && !targetReEngages {
            setEngagedChrome(false, hasMedia: true, animated: true)
        }
        #if DEBUG
        // `-grab-log`: what the drive resolved to, and what the scroll view
        // will actually accept. A committed step that never moves the page is
        // either a target nobody applied or an offset something else is
        // holding, and the two look identical from outside.
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[drive] commit start=\(Int(start)) step=\(step) target=\(target)"
                + " targetY=\(Int(targetOffset)) offsetY=\(Int(collectionView.contentOffset.y))"
                + " contentH=\(Int(collectionView.contentSize.height))"
                + " pageH=\(Int(page)) scrollEnabled=\(collectionView.isScrollEnabled)")
        }
        #endif
        // The page being left is on screen for the whole of this animation,
        // whatever the model says — see `isPostOnScreen`.
        settleFromOffset = collectionView.contentOffset.y
        let distance = abs(collectionView.contentOffset.y - targetOffset)
        let springVelocity = distance > 0 ? min(3, abs(vy) / distance) : 0
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: springVelocity,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.collectionView.contentOffset.y = targetOffset
        } completion: { [weak self] finished in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-grab-log"), let self {
                print("[drive] settled finished=\(finished)"
                    + " offsetY=\(Int(collectionView.contentOffset.y))")
            }
            #endif
            self?.settleFromOffset = nil
            guard finished else { return }
            // Now the target page is settled: recompute the active item,
            // which fires the resign→teardown / activate legs (the landed
            // page auto-engages if it's a text post; the old engagement is
            // torn down as it resigns).
            self?.updateActiveItem()
        }
    }

    /// The engaged drive's commit rule: a decisive drag OR a fling commits;
    /// the projected motion (drag + a slice of velocity) picks the direction —
    /// up pages next. FORWARD-ONLY: a downward projection settles home (step
    /// 0), never to the previous post. Internal statics for the pure-logic
    /// test, same as `rubberBand`.
    static func pageDriveStep(translation dy: CGFloat, velocity vy: CGFloat, page: CGFloat) -> Int {
        let committed = abs(dy) > page * 0.18 || abs(vy) > 500
        guard committed else { return 0 }
        return (dy + vy * 0.2) < 0 ? 1 : 0
    }

    /// UIScrollView-style rubber-band past `floor`/last page: the drive
    /// resists beyond the ends so you cannot fling off the feed — and, with
    /// the feed forward-only, `floor` is the drive's own origin page rather
    /// than offset zero.
    /// The spinner shown under the last reachable page, exactly as the timeline
    /// shows one at the end of a loaded batch — because to the viewer it is the
    /// same situation: there IS more, and it is not here yet.
    private lazy var pagingFooter: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        return spinner
    }()

    /// Shows the spinner while the viewer is pulling against the readiness
    /// ceiling, and only then.
    ///
    /// Driven from the scroll rather than from the settle: the whole point is
    /// to answer the gesture that is happening now — a viewer who drags past
    /// the last ready page sees why they cannot go further while they are still
    /// pulling, and a settled feed shows nothing.
    private func updatePagingFooter(for scrollView: UIScrollView) {
        let page = scrollView.bounds.height
        guard page > 0, !orderedIDs.isEmpty else { return }
        let ceiling = CGFloat(reachableCeiling()) * page
        let atCorpusEnd = reachableCeiling() >= orderedIDs.count - 1
        let pulling = scrollView.contentOffset.y > ceiling + 1
        if pulling, !atCorpusEnd {
            pagingFooter.startAnimating()
        } else {
            pagingFooter.stopAnimating()
        }
    }

    /// The theme the DEVICE is in, which is not always the theme this screen is
    /// in: the feed pins itself dark while a photograph is settled, so anything
    /// asking `traitCollection` from inside it gets the pin rather than the
    /// device. Read off the window, which no view controller's override reaches.
    private var deviceInterfaceStyle: UIUserInterfaceStyle {
        view.window?.traitCollection.userInterfaceStyle ?? .unspecified
    }

    /// Whether a page can be shown without the viewer watching it assemble.
    ///
    /// A MEDIA page is ready as soon as its model is: the cover arrives into a
    /// laid-out card and the page is legible without it. A TEXT page is not —
    /// what a text page IS is its comments panel, so until that panel is built
    /// the page is a black rectangle, and showing it is the defect this answers.
    ///
    /// ⚠️ A HOST WITH NO PANEL FACTORY HAS READY TEXT PAGES BY DEFINITION.
    /// Without that line every text post would be permanently unreachable on
    /// any surface that does not supply one — a far worse failure than the
    /// pop-in, and silent.
    func isPageReady(_ index: Int) -> Bool {
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return false }
        guard model.mediaURL == nil, makeCommentsPanelContent != nil else { return true }
        // ⚠️ ALL THREE PLACES A PANEL CAN BE, and leaving one out strands the
        // viewer.
        //
        // A panel is built ahead (`prewarmedRestingID`), then MOUNTED into the
        // incoming cell as a preview — which consumes the warm — and only later
        // promoted to the engagement. Counting the first and the last but not
        // the middle meant a page that was already on screen, fully drawn, read
        // as "not ready": the ceiling stopped short of it and the pager refused
        // to advance. Two text posts in a row could not be paged through at
        // all, and the console showed only the hero grab correctly declining an
        // upward drag — nothing about the page that was quietly unreachable.
        return prewarmedRestingID == model.id
            || previewRestingID == model.id
            || commentsEngagedID == model.id
    }

    /// The furthest page the viewer may reach right now.
    ///
    /// Scans forward from where they are and stops at the first page that is
    /// not ready — which for a run of text posts is one at a time, since only
    /// the page immediately ahead is ever built. That is the intent: a page the
    /// viewer cannot reach yet reads exactly like the end of the feed, which is
    /// a state this app already has an answer for, rather than like a post that
    /// renders itself while they look at it.
    ///
    /// Never behind the page they are on: a corpus that changes under a settled
    /// viewer must not push them backwards.
    var lastReachablePage: Int {
        let last = max(0, orderedIDs.count - 1)
        var index = min(settledPageIndex, last)
        while index < last, isPageReady(index + 1) { index += 1 }
        return index
    }

    /// The ceiling the pager actually uses: PREPARE, then allow.
    ///
    /// ⚠️ A GATE THAT CAN STRAND IS WORSE THAN THE POP-IN IT PREVENTS, and this
    /// one stranded twice — each time on a state nobody had thought to count as
    /// "ready", each time reported as the scroll simply not working, with
    /// nothing in the trace to say why. That is the failure mode of asking a
    /// question that can be wrong in a direction with no recovery.
    ///
    /// So the answer is not "is it ready" but "make it ready": the panel is
    /// built synchronously, here, at the moment the viewer asks to move. A page
    /// that can be prepared is reachable BECAUSE it was just prepared, and a
    /// page that cannot be — no factory, no model yet — is reachable anyway,
    /// because being stuck is not an outcome any viewer can act on.
    ///
    /// What remains gated is the only thing a viewer can understand: a page
    /// whose data has not arrived. That is the end of the list, and the loader
    /// says so.
    private func reachableCeiling() -> Int {
        let last = max(0, orderedIDs.count - 1)
        let settled = min(settledPageIndex, last)
        guard settled < last, modelsByID[orderedIDs[settled + 1]] != nil else { return settled }
        // ⚠️ THE NEXT PAGE ONLY, because the warm holds ONE panel.
        //
        // Preparing the whole run forward looked thorough and was
        // self-defeating: each call discards the last one's panel, so walking
        // three pages ahead threw away the warm for the page actually being
        // moved onto and it was built twice. One page is also all a gesture can
        // reach, which is the only page the question is about.
        if !isPageReady(settled + 1) { prewarmRestingComments(for: orderedIDs[settled + 1]) }
        // Past it, the only question left is whether the data has arrived.
        var ceiling = settled + 1
        while ceiling < last, modelsByID[orderedIDs[ceiling + 1]] != nil { ceiling += 1 }
        return ceiling
    }

    private func rubberBandedOffset(_ offset: CGFloat, floor: CGFloat) -> CGFloat {
        let page = collectionView.bounds.height
        guard page > 0 else { return offset }
        let maxOffset = CGFloat(reachableCeiling()) * page
        if offset < floor { return floor - Self.rubberBand(floor - offset, dimension: page) }
        if offset > maxOffset { return maxOffset + Self.rubberBand(offset - maxOffset, dimension: page) }
        return offset
    }

    /// The standard iOS rubber-band curve: `(1 − 1/(x·c/d + 1))·d`. It maps
    /// [0, ∞) into [0, d) — monotonically increasing, always resisting (the
    /// mapped excess is strictly less than the raw excess), zero at zero.
    /// Internal for the pure-logic test.
    static func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        (1 - 1 / (x * 0.55 / d + 1)) * d
    }

    private func engagedCell() -> SnapFeedCell? {
        guard let id = commentsEngagedID,
              let indexPath = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: indexPath) as? SnapFeedCell
    }

    private func finishCommentsDisengagement() {
        // Idempotent: teardown reaches here from several paths (animated
        // dismiss completion, resign leg, didEndDisplaying belt), and a
        // resting pre-render can be torn down by more than one — a second
        // call must be a clean no-op.
        guard commentsEngagedID != nil else { return }
        // Belt and braces for non-animated/interrupted paths.
        let cell = engagedCell()
        cell?.setCommentsEngaged(false)
        if let content = commentsContentVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        cell?.clearComments()
        commentsContentVC = nil
        commentsEngagedID = nil
        prewarmedCommentsID = nil
        engagedCellForPrewarm = nil
        commentsEngagementIsResting = false
        restingLockApplied = false
        collectionView.isScrollEnabled = true
        // REOPENING must be as cheap as opening. The warm is consumed by the
        // engagement, and no further activation is coming for a page that
        // never moved — so without this, engage → close → engage pays the
        // full ~115ms on the second tap.
        rewarmActivePageComments()
        // The bar's pixels were never touched (keep-and-stack), but its
        // ITEMS are engagement context — settle them for the paths that
        // never ran the animated mirror (orphaned teardown, instant
        // cleanup). Identity-compare first: after a normal dismiss the
        // swap already landed, and re-setting identical items would only
        // churn the bar's layout.
        if !defaultToolbarItems.isEmpty {
            setEngagedChrome(false, hasMedia: true, animated: false)
        }
    }

    // MARK: - Active-item lifecycle

    private func refreshVisibility() {
        apply(lifecycle.setVisible(isOnScreen && isForeground))
    }

    /// The page playback follows: the one covering most of the screen.
    ///
    /// Deliberately NOT the lifecycle's active index, though the arithmetic is
    /// the same one (`SnapActiveItemTracker.activeIndex` is the page owning the
    /// viewport's midpoint). The difference is WHEN each is consulted: the
    /// lifecycle's is settle-quantized, because everything it drives — chrome,
    /// warm window, resting interface, the pager's lock — must not move under a
    /// finger. Playback is the one thing that should.
    private var playbackOwner: Int?

    /// Hands the picture to whichever page owns the screen, and takes it back
    /// from the one that lost it. Runs on EVERY scroll callback, so it must
    /// stay this cheap: an index, a comparison, and nothing at all when the
    /// answer has not changed.
    private func updateViewportPlayback() {
        let owner = SnapActiveItemTracker.activeIndex(
            contentOffsetY: collectionView.contentOffset.y,
            pageHeight: collectionView.bounds.height,
            itemCount: orderedIDs.count
        )
        guard owner != playbackOwner else { return }
        if let previous = playbackOwner {
            (lifecycleCell(at: previous) as? SnapFeedCell)?.setOwnsViewport(false)
        }
        playbackOwner = owner
        if let owner {
            (lifecycleCell(at: owner) as? SnapFeedCell)?.setOwnsViewport(true)
        }
    }

    #if DEBUG
    /// The post whose clip is running, read off the CELLS rather than from the
    /// index above: a dispatch that never reaches a cell starts nothing, and
    /// asking the bookkeeping would not know the difference.
    var debugPlayingPostID: PostID? {
        for (index, id) in orderedIDs.enumerated() {
            guard let cell = collectionView.cellForItem(
                at: IndexPath(item: index, section: 0)
            ) as? SnapFeedCell else { continue }
            if cell.debugOwnsPlayback { return id }
        }
        return nil
    }
    #endif

    private func updateActiveItem() {
        let index = SnapActiveItemTracker.activeIndex(
            contentOffsetY: collectionView.contentOffset.y,
            pageHeight: collectionView.bounds.height,
            itemCount: orderedIDs.count
        )
        apply(lifecycle.setPageIndex(index))
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
        if let index { reconcileRestingInterface(activeIndex: index) }
    }

    private func apply(_ transition: SnapLifecycleDispatcher.Transition) {
        if let resign = transition.resign {
            // Paging within the feed: the page stays alive and a swipe away, so
            // it keeps its player and simply stops advancing.
            lifecycleCell(at: resign)?.didResignActive(releasingPlayback: false)
            // Paging away FINALIZES the session's boosts: the undo window
            // is the post's time on screen, and it just ended.
            if orderedIDs.indices.contains(resign), sessionBoostID == orderedIDs[resign] {
                sessionBoostID = nil
                sessionBoostAmount = 0
            }
            // An engagement is PAGE-SCOPED: the engaged page resigning
            // retires it instantly (a belt for interrupted teardowns —
            // the animated dismiss normally lands before any page change,
            // since the pager is locked for the engagement's lifetime).
            if let engaged = commentsEngagedID, orderedIDs.indices.contains(resign),
               engaged == orderedIDs[resign] {
                // ⚠️ A RESTING PAGE KEEPS ITS INTERFACE UNTIL ITS LAST PIXEL
                // HAS LEFT.
                //
                // The settle is not the moment the page stops being seen: the
                // scroll releases, the page snaps home, and the page being left
                // is still partly on screen for the length of that animation.
                // Tearing its panel down here emptied it while the viewer could
                // still see it — a text page went to its bare floor for an
                // instant on the way out, which is the same defect as the black
                // arrival, mirrored.
                //
                // `didEndDisplaying` is the honest moment, and it already tears
                // down the case where a page is scrolled past without ever
                // settling. A page that never leaves the viewport keeps its
                // interface, which is what a resting engagement is for.
                if !commentsEngagementIsResting { finishCommentsDisengagement() }
            }
            // A warm panel belongs to the page that was active. Once that
            // page is not, the warm is stale — and holding it would block
            // the next page's.
            if let warm = prewarmedCommentsID, orderedIDs.indices.contains(resign),
               warm == orderedIDs[resign] {
                discardPrewarmedComments()
            }
        }
        if let activate = transition.activate {
            // The cell that will be active almost never exists yet when
            // `zoomTransitionWillBegin` fires — it is realized by the layout
            // pass the presentation itself triggers — so the deferral is
            // stamped here, at the moment it is about to start playing.
            if let snapCell = collectionView.cellForItem(
                at: IndexPath(item: activate, section: 0)
            ) as? SnapFeedCell {
                snapCell.defersPlaybackForFlight = isAwaitingZoomPresentation
            }
            lifecycleCell(at: activate)?.willBecomeActive()
            // The pages either side get ready NOW, at the settle, rather than
            // when UIKit's scroll heuristic happens to ask — see
            // `warmSettledWindow`.
            warmSettledWindow(around: activate)
            // Same settle-quantized seam that drives playback: both bar
            // surfaces (identity pill above, media attribution below) follow
            // the active page.
            updateBarChrome(at: activate)
            // And the comment ticker: activation is what triggers (or
            // re-emits) the page's queue.
            if orderedIDs.indices.contains(activate) {
                let id = orderedIDs[activate]
                viewModel.pageDidBecomeActive(id)
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
                    reconcileRestingInterface(activeIndex: activate)
                    if commentsEngagedID == id, commentsEngagementIsResting {
                        lockRestingEngagement()
                    }
                } else {
                    // A MEDIA page settles too, and the same reconcile is what
                    // releases an interface the page before it left behind and
                    // gives the pager back — the case that locked the feed on a
                    // photograph for a text post two pages ago.
                    reconcileRestingInterface(activeIndex: activate)
                }
                if modelsByID[id]?.mediaURL != nil, let cell = collectionView.cellForItem(
                    at: IndexPath(item: activate, section: 0)
                ) as? SnapFeedCell {
                    // MEDIA pages warm their comments panel here instead of
                    // at tap time — see `prewarmComments`. The settle seam
                    // is where the page has stopped moving and nothing is
                    // animating, which is the only moment ~115ms of layout
                    // is free.
                    prewarmComments(for: id, host: cell)
                }
            }
        }
    }

    private func updateBarChrome(at index: Int) {
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        authorIdentityView.setAuthor(model, pipeline: imagePipeline)
        mediaAttributionView.setPost(model, pipeline: imagePipeline)
        // The bars float over the PAGE, so their text has to know what kind
        // of ground it is floating over. A media page is arbitrary and dark
        // enough to want white-and-shadowed; a text page follows the system
        // appearance, where white text on a white ground is just gone.
        let overMedia = model.mediaURL != nil
        applyChromeTheme(hasMedia: overMedia)
        // The SHADOWS are not a theme question: they exist because the bars
        // float over an arbitrary photo with no background of their own, and
        // a text page's own ground makes them unnecessary. The colours now
        // come from the theme above.
        authorIdentityView.setOverMedia(overMedia)
        mediaAttributionView.setOverMedia(overMedia)
        refreshBookmarkGlyph(for: model.id)
    }

    /// Puts the SCREEN's bars on the page's theme.
    ///
    /// The bars are the half of the page that the cell cannot reach: they
    /// belong to the navigation controller, not to the cell's view tree, so
    /// nothing propagates into them. Overriding the bars themselves — rather
    /// than each item's custom view — is what matters, because the Liquid
    /// Glass PLATTER behind an item is drawn by UIKit from the bar's own
    /// traits. Styling only the contents produced the exact bug this fixes:
    /// white text sitting on a light platter, over a dark page.
    ///
    /// Applied per settled page (`updateBarChrome`) and re-applied on
    /// appearance, since the bars are shared with whatever the feed pushes.
    private func applyChromeTheme(hasMedia: Bool) {
        let style = SnapChromeTheme.style(hasMedia: hasMedia)
        navigationController?.navigationBar.overrideUserInterfaceStyle = style
        navigationController?.toolbar.overrideUserInterfaceStyle = style
        overrideUserInterfaceStyle = style
    }

    /// Hands the shared bars back before anything else uses them.
    ///
    /// The feed does not own the navigation bar or the toolbar — it borrows
    /// them under the keep-and-stack contract. A pushed profile inheriting
    /// a dark-pinned bar because the feed happened to be showing a photo is
    /// exactly the kind of leak that shared chrome invites.
    private func releaseChromeTheme() {
        navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
        navigationController?.toolbar.overrideUserInterfaceStyle = .unspecified
        overrideUserInterfaceStyle = .unspecified
    }

    /// The settled page's model — what the toolbar's share/more act on.
    private var activeModel: FeedItemDisplayModel? {
        guard let index = lifecycle.activeIndex,
              orderedIDs.indices.contains(index) else { return nil }
        return modelsByID[orderedIDs[index]]
    }

    // MARK: - Media toolbar actions

    /// Shares what the model actually carries — the BFF exposes no canonical
    /// post web URL yet, so caption + media URL stand in until it does.
    private func presentShareSheet(for id: PostID) {
        guard let model = modelsByID[id] else { return }
        var items: [Any] = []
        if let caption = model.caption { items.append(caption) }
        if let url = model.mediaURL { items.append(url) }
        if items.isEmpty { items.append(model.authorName) }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        present(activity, animated: true)
    }

    /// The "more" menu routes to existing view-model seams; grow it as
    /// social affordances (save, report) gain real backends.
    /// What ⋯ folds up.
    ///
    /// ⚠️ NOT NAVIGATION. It carried "View comments" and "View profile", and
    /// both were second doors to places the screen already opens with one tap —
    /// the comment count opens the thread, the author pill opens the profile. A
    /// menu of things you can reach anyway is a menu nobody reads, and it
    /// crowded out the things that have nowhere else to live.
    ///
    /// So it is the three that do: pass the post on, ask for less like it, and
    /// report it. Report is destructive and last, which is the ordering the
    /// gallery card's own menu uses.
    private func moreMenuActions(for id: PostID) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.presentShareSheet(for: id)
            },
            UIAction(title: "Not interested", image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
                self?.markNotInterested(id)
            },
        ]
        // Withheld rather than disabled when there is nobody to file with — an
        // action that cannot act is not offered.
        if reporting != nil {
            actions.append(UIAction(
                title: "Report", image: UIImage(systemName: "flag"), attributes: .destructive
            ) { [weak self] _ in
                self?.presentReportReasons(for: id)
            })
        }
        return actions
    }

    /// The posts the viewer has asked not to see again, for as long as this
    /// screen lives.
    ///
    /// ⚠️ THE SESSION, AND NOTHING MORE — and the toast says exactly that.
    /// There is no "not interested" signal anywhere in the contracts: no
    /// ranking feedback in `timeline.v1`, no hide in `post.v1`. What this can
    /// honestly do is stop the post coming back on THIS surface, so that is
    /// what it does and what the confirmation claims. A toast promising a
    /// better feed tomorrow would be the lie.
    private var notInterestedIDs: Set<PostID> = []

    private func markNotInterested(_ id: PostID) {
        notInterestedIDs.insert(id)
        // ⚠️ NOT REMOVED FROM UNDER THE VIEWER. The post is on screen, and
        // pulling the page they are reading out from under their thumb to
        // acknowledge a menu tap is a worse answer than the one they asked for.
        // The next render drops it — see `render(_:)` — so it goes when they
        // move on, which is when "not interested" means anything.
        ToastView.present("Hidden from this feed", symbol: "hand.thumbsdown", in: view)
    }

    private func presentReportReasons(for id: PostID) {
        ReportReasonSheet.present(from: self, subject: "this post", sourceView: view) { [weak self] reason in
            self?.report(id, reason: reason)
        }
    }

    /// Files the report and says which way it went — a report the viewer
    /// believes was filed but wasn't is the worst outcome here.
    private func report(_ id: PostID, reason: ReportReason) {
        guard let reporting else { return }
        Task { [weak self] in
            do {
                // The surface is a triage signal in its own right: the same post
                // reported from the feed and from a profile are different
                // reports.
                try await reporting.report(.post(id), reason: reason, surface: "ios.feed")
                guard let self else { return }
                ToastView.present("Report sent", symbol: "flag.fill", in: view)
            } catch {
                guard let self else { return }
                ToastView.present("Couldn't send this report", symbol: "exclamationmark.triangle", in: view)
            }
        }
    }

    #if DEBUG
    /// The ⋯ menu's rows, as built for `id`. The menu itself is a deferred
    /// element UIKit resolves when it opens, so there is nothing to read off
    /// the button — the composition has to be asked for.
    func debugMoreMenuActions(for id: PostID) -> [UIMenuElement] { moreMenuActions(for: id) }

    func debugMoreMenuTitles(for id: PostID) -> [String] {
        debugMoreMenuActions(for: id).compactMap { ($0 as? UIAction)?.title }
    }
    #endif

    private func lifecycleCell(at index: Int) -> SnapCellLifecycle? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapCellLifecycle
    }

    /// Everything a page needs that is NOT its player: the cover to decode and
    /// the comment stream to fetch.
    ///
    /// Both are cheap and both are what a viewer notices missing — a page that
    /// snaps in and then fills itself in reads as a stutter even when no frame
    /// was dropped.
    func warmContent(at items: [Int]) {
        let ids = items.compactMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil }
        let urls = ids.compactMap { modelsByID[$0] }.flatMap { [$0.avatarURL, $0.mediaURL] }
            .compactMap(\.self)
        let pipeline = imagePipeline
        Task { await pipeline.prefetch(urls) }
        // Loaded before the page scrolls in, so its band enters the viewport
        // already streaming (subtitles still wait for settle — their gate is
        // activation, not content).
        for id in ids where modelsByID[id] != nil {
            viewModel.ensureCommentStreams(for: id)
        }
    }

    /// The players, kept to the immediate neighbours — see `SnapWarmWindow`.
    ///
    /// Deliberately a narrower window than the content's: a player holds a
    /// decoder and the platform caps how many can render at once, so this is
    /// the one warm that has to stay stingy.
    func warmPlayers(at items: [Int]) {
        for item in items where orderedIDs.indices.contains(item) {
            guard let model = modelsByID[orderedIDs[item]],
                  model.mediaKind == .video, let url = model.mediaURL else { continue }
            videoPlayback?.preroll(url)
        }
    }

    /// ⚠️ A DEFINED WINDOW AROUND THE PAGE THE VIEWER SETTLED ON.
    ///
    /// `UICollectionViewDataSourcePrefetching` is UIKit's guess, made from
    /// scroll velocity: it warms nothing at all while the pager is at rest, and
    /// what it warms during a fling is whatever its heuristic reached. A feed
    /// whose whole promise is that the next page is INSTANT cannot be built on
    /// a guess — after every settle the window is stated outright, so the pages
    /// either side are ready whether the viewer arrived by flick, by tap, or by
    /// sitting still for a minute first.
    ///
    /// Kept alongside the prefetch callback rather than replacing it: UIKit's
    /// guess is genuinely good DURING a fast scroll, where it runs ahead of the
    /// settles. The two overlap, and both are idempotent.
    private func warmSettledWindow(around active: Int) {
        let count = orderedIDs.count
        let content = SnapWarmWindow.content(around: active, count: count)
        warmContent(at: content)
        warmPlayers(at: SnapWarmWindow.players(around: active, count: count))
        // ⚠️ AND THE NEXT TEXT PAGE'S INTERFACE, which is the one page whose
        // content is a whole view controller rather than an image. Only the
        // page immediately ahead: it is one view controller's memory, and the
        // page after that is a guess.
        if orderedIDs.indices.contains(active + 1) {
            prewarmRestingComments(for: orderedIDs[active + 1])
        }
        #if DEBUG
        // What the settle actually warmed. The window itself is pure and tested
        // on its own; this is how a test reaches the WIRING — that the settle
        // asks at all, and asks about the page it settled on.
        debugLastWarmedWindow = content
        #endif
    }

    #if DEBUG
    private(set) var debugLastWarmedWindow: [Int] = []
    #endif

    private func prefetchURLs(for indexPaths: [IndexPath]) -> [URL] {
        indexPaths.compactMap { orderedIDs.indices.contains($0.item) ? modelsByID[orderedIDs[$0.item]] : nil }
            .flatMap { [$0.avatarURL, $0.mediaURL] }
            .compactMap(\.self)
    }
}

// MARK: - Delegates

extension SnapFeedViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        viewModel.willDisplayItem(at: indexPath.item)
        // Recompute the active index (a new page may have become active), then —
        // crucially — activate THIS cell if it's the active one. The dispatcher
        // records the active index the instant a scroll settles or content
        // loads, which can be before the cell exists; without this net that
        // activation would be lost, since the index never changes again.
        updateActiveItem()
        // Stamp the flight deferral BEFORE any activation on this path. There
        // are two activation sites — the settle-quantized one in `apply` and
        // this net for cells that did not exist at settle time — and a present
        // leg always takes THIS one, because the cell is realized by the very
        // layout pass the presentation triggers. Stamping only in `apply` left
        // the flag false exactly when it mattered.
        (cell as? SnapFeedCell)?.defersPlaybackForFlight = isAwaitingZoomPresentation
        // The same net, for the picture: a page can be handed the screen while
        // it is still being realized, and the hand-over reaches nothing. The
        // page that owns the viewport is a fact about the SCROLL, so it is
        // re-stated to every cell as it appears.
        (cell as? SnapFeedCell)?.setOwnsViewport(playbackOwner == indexPath.item)
        if lifecycle.activeIndex == indexPath.item {
            (cell as? SnapCellLifecycle)?.willBecomeActive()
        }
        // A text page's resting interface PRE-RENDERS on visibility (not
        // the settle-quantized active seam): the instant its cell begins
        // displaying — while it is still scrolling in — its full engaged
        // layout is mounted, so it slides into the viewport already
        // formed instead of popping in at rest. This is the same
        // visibility doctrine the ticker/subtitle surfaces below follow;
        // the pager lock alone waits for settle (`lockRestingEngagement`).
        // Slot-guarded (one engagement at a time), model presence REQUIRED
        // (a missing model reads as "unknown", never "text-only").
        if let snapCell = cell as? SnapFeedCell, orderedIDs.indices.contains(indexPath.item) {
            let id = orderedIDs[indexPath.item]
            // ⚠️ NOT GATED ON THE SLOT BEING FREE, and that gate is what made
            // the arriving page blank.
            //
            // It reads as a guard against mounting twice, and it was — until
            // the page being left began keeping its interface until its last
            // pixel has gone. From then on the slot is ALWAYS held while the
            // next page scrolls in, so this declined every time and the one
            // path that mounts a preview was unreachable from the only place
            // that calls it.
            //
            // What arrives is a text page with no panel: on a text post the
            // caption lives INSIDE the panel, so the page is not merely
            // undecorated, it is empty — white, no caption, no comments, just
            // chrome. `presentRestingComments` makes this decision properly:
            // engagement if the slot is free, preview if it is not.
            if let model = modelsByID[id], model.mediaURL == nil {
                presentRestingComments(for: id, host: snapCell)
            }
            // PHASE 2, when this cell is ALREADY the active page.
            //
            // The settle path normally applies the lock, and normally it
            // runs after the cell exists. A programmatic jump inverts that:
            // `-snap-start-index` scrolls and settles in one turn, so the
            // activation lands before the layout has realized the cell, the
            // settle path finds nothing to mount, and the pre-render above
            // arrives here afterwards — with no further activation coming,
            // because the dispatcher is already on this page. The page kept
            // the RESTING chrome for its whole life: no sort pill, and a
            // caption cell measured under bars it no longer had.
            //
            // The active-index test is what keeps this phase 2 and not a
            // second pre-render: a cell scrolling in normally is not the
            // active page yet, so it falls through to the settle path
            // exactly as before, and the pager is never locked mid-scroll.
            // (Same test the `willBecomeActive` call above uses.)
            if lifecycle.activeIndex == indexPath.item,
               commentsEngagedID == id, commentsEngagementIsResting {
                lockRestingEngagement()
            }
            // And a MEDIA page warms its comments panel here for the same
            // reason the lock above lands here: on a programmatic jump the
            // settle runs before the layout has realized the cell, so the
            // settle's own warm found nothing to host. Gated on being the
            // ACTIVE page, so a page merely scrolling past never pays for a
            // panel it will not open.
            if lifecycle.activeIndex == indexPath.item,
               let model = modelsByID[id], model.mediaURL != nil {
                prewarmComments(for: id, host: snapCell)
                #if DEBUG
                // `-engage-baseline`: run the frame-gap watch on a RESTING
                // page instead of a transition, to learn what the floor is.
                if ProcessInfo.processInfo.arguments.contains("-engage-baseline") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.beginHitchWatch()
                    }
                }
                #endif
            }
        }
        // Re-pull the cached streams BEFORE raising the visibility gate: a
        // cell configured while the prefetch load was still in flight
        // pulled `.empty` at dequeue, and the async push only reaches
        // visible cells — this cell missed it. Synchronous on a cache hit,
        // so the surfaces own their content when activation lands and the
        // subtitle zone takes its INSTANT entrance (riding the swipe like
        // static chrome) instead of the content-arrival fade after settle.
        // (`updateCommentStreams` no-ops on identical content; still-
        // uncached posts stay empty here and fade in when the push lands.)
        if let snapCell = cell as? SnapFeedCell, orderedIDs.indices.contains(indexPath.item) {
            snapCell.updateCommentStreams(viewModel.commentStreams(for: orderedIDs[indexPath.item]))
        }
        // Both comment surfaces render on VISIBILITY, not on the settle-
        // quantized active seam: a page dragged partway in must already
        // show its band flowing and its subtitle pill pinned, not pop them
        // in at rest. (Video stays settle-gated — an AVPlayer per
        // half-visible page is real cost; text layers aren't.)
        (cell as? SnapFeedCell)?.setTickerStreaming(true)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Belt-and-suspenders release: a cell scrolled fully off is never active,
        // and this guarantees the resign even if it's recycled before a settle.
        // Fully off screen: the loan goes back, because the grid behind is
        // waiting for it and nothing here is going to draw again.
        (cell as? SnapCellLifecycle)?.didResignActive(releasingPlayback: true)
        // The resign above no-ops for a cell that was displayed but never
        // became active (a swiped-past page); its ticker must still stop.
        (cell as? SnapFeedCell)?.setTickerStreaming(false)
        // Free the resting engagement's slot when its pre-rendered cell
        // leaves WITHOUT settling — a text page scrolled in (pre-rendered
        // on visibility) then scrolled back out never activates, so the
        // `apply` resign leg never fires for it; without this the slot
        // stays stuck on an off-screen cell and the next text page can't
        // pre-render. Never tears down the SETTLED engaged page (it stays
        // put until a real page change).
        if let engagedID = commentsEngagedID, commentsEngagementIsResting,
           orderedIDs.indices.contains(indexPath.item),
           orderedIDs[indexPath.item] == engagedID,
           lifecycle.activeIndex != indexPath.item,
           // UIKit calls this when the cell leaves the MODEL's viewport, which
           // during a settle is a moment too early — see `isPostOnScreen`.
           !isPostOnScreen(engagedID) {
            finishCommentsDisengagement()
            // The slot is free at last — and the page that is now active may
            // have been showing a PREVIEW since it scrolled in, waiting for
            // exactly this. Promoting is a field assignment; without it the
            // preview would stay one for ever and its page would never own its
            // own pager lock.
            if let active = activePostID { promoteRestingPreview(for: active) }
        }
    }

    // A full-cell tap toggles play/pause (handled by the cell's own gesture),
    // not navigation — so there is no `didSelectItemAt` routing. Comments open
    // via the toolbar's more menu; the identity pill opens the profile.

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Unreachable while engaged (the pager is disabled — the total
        // dead-end doctrine; the swipe exit is bar-owned and pages
        // programmatically). Kept as belt and braces: if any future path
        // lets a page drag begin under an engaged cell, the mutation must
        // ride down with the leaving page, never strand a hosted comments
        // view in a recycled cell.
        if commentsEngagedID != nil {
            dismissComments()
        }
    }

    /// ⚠️ THE FLICK STOPS AT THE LAST PAGE THAT IS READY.
    ///
    /// The pager's own paging is what carries a media page, and it will happily
    /// land on a post whose interface has not been built — which is the black
    /// rectangle that fills itself in. Clamping the TARGET rather than the live
    /// offset keeps the drag itself free: the viewer can pull the next page
    /// into view and see the loader under it, and the release settles back.
    ///
    /// A page that is not ready reads as the end of the feed, because that is
    /// what it is for the moment: more is coming and it is not here yet.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let page = scrollView.bounds.height
        guard page > 0 else { return }
        let ceiling = CGFloat(reachableCeiling()) * page
        if targetContentOffset.pointee.y > ceiling {
            targetContentOffset.pointee.y = ceiling
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ NO ACTIVATION HERE. Activating at the halfway mark was tried, to
        // start a video as soon as its page owned most of the screen, and it
        // moved the SCROLL: activation runs the settle's whole choreography —
        // which includes bringing the active page clear of the chrome — so the
        // feed jumped to the next page in the middle of the gesture. Reported
        // as worse than the delay it was meant to fix, and it was.
        //
        // Starting playback early has to be a playback-only path, not a second
        // caller of the seam that owns everything else — which is exactly what
        // `updateViewportPlayback` is: it moves the picture and touches
        // nothing else on the screen.
        updateViewportPlayback()
        updatePagingFooter(for: scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateActiveItem()
        updatePagingFooter(for: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateActiveItem() }
        updatePagingFooter(for: scrollView)
    }
}

// MARK: - ZoomTransitionDestination

extension SnapFeedViewController: ZoomTransitionDestination {
    public func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect {
        view.convert(view.bounds, to: container)
    }

    /// A fresh inert replica of the active page's chrome for the flying card —
    /// page content only (scrim, caption); the navigation bar stays real
    /// and static above the flight. Configured now if the post is already
    /// loaded; otherwise `render(_:)` fills it in when the data lands
    /// mid-flight — the scaffold's geometry is data-independent, so late text
    /// never moves anything.
    public func zoomFlightChrome() -> UIView? {
        // A TEXT page has no resting chrome to replicate, because it is never
        // at rest: it mounts its comment layout on `willDisplay` and stays
        // there (`presentRestingComments`). The replica below is configured at
        // REST, so a text post's flight crossfaded INTO the media layout —
        // rail, subtitle zone, the empty media card — and the comment layout
        // only appeared when the card was removed. That is the reported "wrong
        // mode for the whole flight, snapping at the last frame", and it is
        // the replica's doing: the destination itself is already engaged
        // before the push (`destinationEngaged=true` at flight-build time).
        //
        // ⚠️ AN ENGAGED PAGE GETS NO REPLICA, and the reason is written out in
        // `RevealTransition` — which is where this should have been read first.
        //
        // A post opened from its COMMENT COUNT engages before the push. The
        // replica, built from the RESTING arrangement, then flew the caption,
        // the rail and the page dots for the whole flight and swapped to the
        // thread as the card was removed: half a second of the layout the
        // viewer had chosen not to open.
        //
        // ❌ A STILL OF THE ENGAGED PAGE was tried in its place and is reverted.
        // It is the sixth instance of a mistake this codebase has already
        // catalogued: "every previous attempt at a text hero flew a replica of
        // the row and made it impersonate the destination, and all five of them
        // died of the same thing — a text page IS its comment stream, a hosted
        // child controller with its own self-sizing layout, and no stand-in can
        // be that. The artifacts were the symptoms (A SKELETON IN THE
        // PHOTOGRAPHED STILL, a blank card, the wrong safe area, two captions);
        // impersonation was the disease."
        //
        // Every one of those symptoms turned up again, in order: the caption's
        // glass missing because a lens has nothing to sample when detached,
        // then the whole panel frozen mid-skeleton on two runs in three,
        // because the still races a fetch it cannot outrun. A still that shows
        // the WRONG content is worse than a landing that is merely late.
        //
        // What the text page does instead is show the REAL page through a
        // mask that opens from the row's rect. That is the shape of the answer
        // here too, and it is not a line of code — see the notes on this
        // commit.
        if commentsEngagedID != nil, !commentsEngagementIsResting { return nil }
        let chrome = SnapChromeView()
        chrome.isUserInteractionEnabled = false
        // Captured, not ambient: the replica must render at the live cell's
        // exact insets even though it lives in the transition container.
        chrome.setFixedInsets(view.safeAreaInsets)
        configureFlightChrome(chrome)
        flightChrome = chrome
        return chrome
    }

    /// Hides only the feed's own view: the navigation bar above it (owned by
    /// the wrapping navigation controller) keeps rendering natively while the
    /// flying card impersonates the page underneath it.
    /// The feed has something to show once it has pages. Pushed cold it has
    /// none until its first `render`, which under injected latency arrived
    /// 2.18s after the flight began — against a 0.42s flight, so the card was
    /// removed over an empty screen and the cell's black floor was what showed.
    /// Renders a projection the opener already has, before this screen's own
    /// fetch returns — so the page configures at push time instead of ~0.7s
    /// later. Additive: a real page replaces it, and a seed arriving after one
    /// is ignored.
    public func seedProjection(_ models: [FeedItemDisplayModel]) {
        loadViewIfNeeded()
        viewModel.seed(models)
    }

    /// Opens one post's carousel on a page other than its first.
    ///
    /// A ONE-SHOT instruction rather than a stored preference, and the
    /// distinction matters on a feed the viewer scrolls: it applies to the
    /// first configure of that post and is then forgotten, so paging back to
    /// the post later — or a cell recycling onto it — starts where a fresh open
    /// starts. A remembered page would make the same post open differently
    /// depending on history nobody can see.
    public func openMediaPage(_ page: Int, for id: PostID) {
        pendingMediaPage = (id, page)
        // ⚠️ AND APPLIED NOW IF THERE IS ANYTHING TO APPLY IT TO.
        //
        // The pending value is consumed by the data source's cell provider,
        // which only runs when a cell is CONFIGURED. That covers the first
        // open and nothing else: this screen is reused, so opening the same
        // post again reaches a cell that is already built and still sitting on
        // the page the viewer left it on. The instruction was then recorded and
        // never read.
        //
        // What that looked like, measured with the page traced at activation:
        // `card asked page=9` immediately followed by `cell activate page=4
        // url=trailer.mp4`. The page displayed page 9 while warming page FOUR's
        // clip — so it arrived showing page 9's poster, and the dismissal
        // donated the surface it had warmed, sending the card home carrying the
        // PREVIOUS clip. Reported precisely: "B arrives on the thumbnail, and
        // the dismiss shows A".
        //
        // Cleared on success so the configure path cannot apply it a second
        // time, and left pending when the cell is not realized yet — which is
        // the first-open case the provider already handles.
        guard let index = orderedIDs.firstIndex(of: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
                  as? SnapFeedCell
        else { return }
        cell.showMediaPage(page)
        pendingMediaPage = nil
    }

    /// Opens a post with its comments already engaged.
    ///
    /// A ONE-SHOT instruction, on the same terms as `openMediaPage(_:for:)` and
    /// for the same reason: the feed is scrolled, and a remembered preference
    /// would make paging back to this post — or a cell recycling onto it —
    /// behave differently from a fresh open, on history nobody can see.
    ///
    /// ⚠️ APPLIED ON LANDING, never at push time. The engagement is ~115ms of
    /// layout, and the flight is the one stretch of this screen's life where
    /// that cost is visible: `prewarmComments` refuses to run during a
    /// transition for exactly this reason, having measured the present leg's
    /// first layout go from 36–64ms to 139–145ms. So the post arrives, and then
    /// its comments come up — which is also the honest reading of the gesture,
    /// since the card the viewer pressed is what the flight is carrying.
    public func openComments(for id: PostID, revealingFrom rect: CGRect? = nil) {
        pendingCommentsID = id
        pendingCommentsRevealRect = rect
        // ⚠️ NOW, IF THERE IS ANYTHING TO DO IT TO — before the push, not after
        // the landing.
        //
        // Applied on landing, the viewer watched the post arrive in its ordinary
        // layout and THEN rearrange itself into the thread: two screens for one
        // press. The engagement has to be the state the page is already in when
        // it becomes visible, which means it has to happen before the flight
        // starts, because during the flight is the one window this screen
        // refuses to spend layout in.
        //
        // The cost is real and it moves rather than disappears: the delay now
        // sits between the finger lifting and the card leaving, where it reads
        // as latency, instead of inside the animation, where it reads as jank.
        // Of the two that is the one to take — and there is nothing to animate
        // yet, so the engagement is applied UNANIMATED and simply is the layout
        // the page opens in.
        loadViewIfNeeded()
        // One layout pass, to give the request a cell to engage.
        //
        // ⚠️ WHERE THIS OPENING'S COST ACTUALLY IS, because two plausible
        // answers were measured and are both wrong.
        //
        // Filmed against the same post opened the ordinary way: 350ms
        // tap-to-settled, against 650–800ms here. The extra is NOT this call
        // (57ms) and NOT an unresolved layout — a second `layoutIfNeeded` after
        // the engagement measures 0.02ms, so `presentComments` has already
        // resolved the tree. It is a stall of ~270–300ms at the LANDING, which
        // shows up as the flight card sitting at full size for a quarter of a
        // second before the thread appears under it.
        //
        // `syncEngagementAfterAppearance` is where that work is: at
        // `viewDidAppear` it re-seats the composer and re-materializes its
        // frost, saying in as many words that the window guard makes every
        // earlier call a no-op and "the didAppear pass the one that lands".
        // Moving the header frost AND the composer's into
        // `zoomTransitionWillBegin` — the first moment there is a window and
        // the last one where the card still hides everything — did not move the
        // number, so the cost is not the materials alone. Both attempts were
        // reverted rather than kept on a story.
        view.layoutIfNeeded()
        #if DEBUG
        let __engaged = CACurrentMediaTime()
        #endif
        applyPendingComments(animated: false)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-engage-profile") {
            print(String(format: "[engage] pre-push engage %6.2f ms",
                         (CACurrentMediaTime() - __engaged) * 1000))
        }
        #endif
    }

    /// Engages the comments a card asked for, once there is a page to engage
    /// them on. Reading the request clears it, so a dismissal and a second open
    /// start from nothing.
    ///
    /// Silent when the post has no cell yet — a feed pushed cold has no pages
    /// until its first render, and the landing seam is what picks the request up
    /// then. Which is why the request is only cleared once it is USED.
    func applyPendingComments(animated: Bool) {
        guard let id = pendingCommentsID else { return }
        presentComments(for: id, animated: animated)
        // ⚠️ CONSUMED ONLY IF IT LANDED, and the difference is a whole defect.
        //
        // `presentComments` needs a REALIZED CELL, not just a row in the data
        // source — and before the push this screen has been laid out at
        // whatever size it was born with, so on the first open of a process
        // there is often no cell yet. The request was cleared anyway, the
        // engagement bailed silently, and the post opened in its ordinary
        // layout. The SECOND open worked, because the feed controller is
        // reused and by then has both.
        //
        // "I asked" and "it happened" are different facts, and only the second
        // one may clear a one-shot.
        if commentsEngagedID == id { pendingCommentsID = nil }
    }

    /// Takes the pending page for `id`, if there is one. Reading it clears it —
    /// see `openMediaPage`.
    func consumeInitialMediaPage(for id: PostID) -> Int? {
        guard let pending = pendingMediaPage, pending.id == id else { return nil }
        pendingMediaPage = nil
        return pending.page
    }

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

    /// **THE TEXT REVEAL**. Covers everything below `cut` for the
    /// length of a reveal, so a page opened from a COLLAPSED card shows no
    /// more of itself than the card did — see `RevealVeilView`.
    ///
    /// Hosted on this screen's own view rather than on the page cell, because
    /// it has to cover the comment stream and the composer as well, and those
    /// are not the cell's. `nil` takes it away.
    public func installRevealVeil(below cut: CGFloat?, tint: UIColor?) {
        revealVeil?.removeFromSuperview()
        revealVeil = nil
        guard let cut, let tint, cut < view.bounds.height else { return }
        let veil = RevealVeilView(tint: tint)
        // Hung a band ABOVE the cut, so the gradient reaches solid exactly AT
        // it. Starting the ramp at the cut is what let the page's next line
        // ride the whole flight as a grey ghost — see `RevealVeilView`.
        let top = max(0, cut - RevealVeilView.fadeBand)
        veil.frame = CGRect(
            x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top
        )
        veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(veil)
        revealVeil = veil
    }

    /// Driven inside the flight's animation block, so the page unfolds as the
    /// window opens and folds back as it closes — and scrubs with the finger
    /// on a dismissal.
    public func setRevealVeilOpacity(_ alpha: CGFloat) {
        revealVeil?.alpha = alpha
    }

    /// **THE TEXT REVEAL**. Puts the SOURCE row's author band into
    /// this page for the length of a flight, at `top` in this view's own
    /// coordinates — or takes it away with `nil`.
    ///
    /// ## Why the page borrows a header it does not have
    ///
    /// A card names its author above its caption; a page names it in the nav
    /// pill instead, and has nothing in that strip at all. So the window a
    /// viewer holds showed a blank band where the card shows a header, and the
    /// card's own header had to fade in at the landing to cover the difference.
    ///
    /// A fade is the wrong tool twice over here. It is a fade of something
    /// against NOTHING, which works — but it is also a fade at exactly the
    /// moment this transition promises to be invisible, and the strip is the
    /// one part of the window that never matched.
    ///
    /// With the band drawn INTO the page, the window shows what the card shows
    /// from frame 0, and the swap at the landing is the identity rather than a
    /// dissolve. It is scenery: no touches, no follow action, gone the moment
    /// the flight is.
    ///
    /// Hosted on this screen's own view rather than on the page cell, for the
    /// same reason the veil is — and positioned rather than laid out, so the
    /// page's resting layout never learns it exists.
    public func installRevealAuthorBand(
        in rect: CGRect?, model: PostAuthorBandView.Model?, pipeline: ImagePipeline?
    ) {
        revealAuthorBand?.removeFromSuperview()
        revealAuthorBand = nil
        guard let rect, let model else { return }
        let band = PostAuthorBandView()
        band.isUserInteractionEnabled = false
        band.configure(with: model, imagePipeline: pipeline)
        // Scenery, but scenery that has to match: the card this lands on wears
        // a "...", and a control that pops in at the landing is the one frame
        // the reveal exists to make invisible.
        band.showMenuControlAsScenery()
        band.alpha = 0
        band.translatesAutoresizingMaskIntoConstraints = true
        // The rect comes from the CAPTION ROW, already inset from the page's
        // edge, and the band takes the caption's own inset inside it — which is
        // exactly what the card does. Measuring from this view instead was the
        // first version, and it put the band 16pt wider on each side than the
        // card's: the page's caption is inset TWICE, once by the stream's
        // section and once by the row, and only the second of those is the
        // card's own.
        band.frame = rect
        band.autoresizingMask = [.flexibleWidth]
        // ABOVE the veil: the veil covers what the page has too much of, and
        // this is the one thing it has too little of.
        view.addSubview(band)
        revealAuthorBand = band
    }

    /// The prop's opacity, driven on the flight's progress — full when the
    /// window is the card, gone when the page is itself.
    public func setRevealAuthorBandOpacity(_ alpha: CGFloat) {
        revealAuthorBand?.alpha = alpha
    }

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

    public var zoomDestinationContentIsReady: Bool { !orderedIDs.isEmpty }





    /// The render half of landing readiness: the active page's media area is
    /// compositing something (surface or poster). Nil cell — not realized
    /// yet — reports true and falls back to the data-only behaviour.
    public var zoomDestinationMediaIsRendering: Bool {
        let cell = activeSnapCell
        let rendering = cell?.isMediaContentRendering ?? true
        #if DEBUG
        // Why a landing is being held, in the surface's own words — a "no"
        // with every component healthy has already cost one wrong deduction.
        if !rendering, ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f landing NOT rendering: %@",
                         CACurrentMediaTime(), cell?.debugMediaState ?? "no active cell"))
        }
        #endif
        return rendering
    }

    /// Pays this page's first LAYOUT and RASTER before the flight instead of
    /// inside it.
    ///
    /// The hero transition's build lays the destination out (`container
    /// .layoutIfNeeded`), and the commit that follows draws its layer tree for
    /// the first time — text, the rail's bubbles, the media card. Measured on
    /// the present leg: ~55ms of build plus ~100ms before the first frame is
    /// delivered, against ~50ms post-build on the dismiss leg, which flies
    /// home to a grid already drawn. That difference is this page's first
    /// raster, and while the card is flying it is a visible pause.
    ///
    /// It cannot be avoided — the pixels have to be produced once — but it can
    /// be paid while NOTHING IS MOVING. Called just before the push, it lands
    /// in the same frame as the tap, where a dropped frame costs nothing,
    /// rather than in the first frames of the animation.
    ///
    /// `CATransaction.flush()` is the part that matters: `layoutIfNeeded`
    /// settles geometry but does not draw, and `display()` is driven by a
    /// commit. Flushing forces that commit now.
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
    public func repoint(to ids: [PostID]) -> Bool {
        guard navigationController == nil, parent == nil else { return false }
        loadViewIfNeeded()

        // The engagement first: it owns a child controller and a cell's
        // interior, and both must be gone before the corpus underneath them
        // changes. This is the same teardown the animated dismiss lands on,
        // taken synchronously.
        finishCommentsDisengagement()
        // …including whatever that teardown just re-warmed for the OLD active
        // page, which is about to stop existing.
        discardPrewarmedComments()

        // Flight state, in case a flight ended anywhere other than its
        // landing — a cancelled push leaves these set, and a reused
        // controller would then start its next flight already believing it is
        // in one.
        isAwaitingZoomPresentation = false
        donatedLiveView = nil
        flightChrome = nil
        pageDriveStartOffset = nil

        // The tapped post is always the head of the window, so the pager goes
        // back to the top. Done BEFORE the new items land, so the first
        // snapshot applies against a settled offset rather than scrolling
        // under one.
        collectionView.setContentOffset(.zero, animated: false)

        viewModel.repoint(to: ids)
        return true
    }

    public func prepareForHeroPresentation(in bounds: CGRect) {
        view.frame = bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // The flush is cheap insurance rather than the mechanism: measured, it
        // is the LAYOUT above that moves (build 54-75ms → 22ms). Parking the
        // tree in the render hierarchy for one flush — so `display()` actually
        // runs on it — was tried and measured identical, so the destination's
        // view hierarchy is left alone.
        CATransaction.flush()
        // NOT here: pre-sizing the BAR's custom views. Bar items live on the
        // navigation bar rather than in this view, so they are first measured
        // inside `-[UINavigationBar _setItems:transition:]` — synchronously in
        // the push, inside the flight's stack — which makes them look like the
        // obvious next thing to pre-pay. Measured: laying them out and asking
        // for their fitting size here left the stall unchanged (91-101 ms vs
        // 85-108 ms) and added ~7 ms to the build. Their cost is not the
        // MEASURING; it is iOS 26 materialising each platter's glass once the
        // view is inside the bar's own effect host, which nothing outside the
        // bar can trigger early. See `ZoomFlightProfiler` for the sampled
        // attribution.
    }

    public func setZoomContentHidden(_ hidden: Bool) {
        // ⚠️ A MASKED-HERO OPENING STAYS VISIBLE, and that inversion is the
        // whole of option B. The flight hides the destination because the card
        // is its stand-in; here the destination is NOT being stood in for — the
        // real thread is what the window shows, drawn over the card carrying
        // the photograph. Hiding it would leave the window empty.
        //
        // ⚠️ AND THE WINDOW OPENS FROM HERE, not from `zoomTransitionWillBegin`.
        // That hook runs in the transition controller's `init`, BEFORE the push
        // — deliberately, so playback can be suppressed early enough — which is
        // before this screen has laid out or realized the page it is about to
        // show. Asked there, it had no active cell to mask and silently did
        // nothing: the flight carried the photograph correctly and the thread
        // still arrived in one frame at the landing.
        // ⚠️ ON EVERY OPENING, not just the masked one: this is the last seam
        // before the card covers the screen, and the first where the page is
        // real. A request that could not be honoured before the push is
        // honoured here, unanimated, so the post still LANDS in its thread
        // rather than rearranging itself afterwards.
        if hidden { beginMaskedRevealIfRequested() }
        // ⚠️ AN ARMED GRAB REFUSES THE HIDE, and refusing it once is not enough.
        //
        // The hide does not run at the grab's start: it is deferred by a commit
        // and a display tick, so it lands AFTER the first pan events. Arming
        // the dismissal set the page visible once and the hide then arrived and
        // won, which is "the thread disappears the instant I grab" exactly.
        // Declining here is what makes the visibility hold for the length of
        // the gesture.
        guard !isMaskedRevealActive, !isEngagedDismissalActive else {
            return view.alpha = 1
        }
        view.alpha = hidden ? 0 : 1
    }

    /// ⚠️ AN ENGAGED PAGE STAYS VISIBLE THROUGH A DISMISSING GRAB, for the same
    /// reason it does through the opening: the card impersonates the page's
    /// MEDIA, and a thread is not media. Hidden with everything else it
    /// vanished on the grab's second tick, and the viewer pulled a photograph
    /// home from a screen that had already stopped showing what they were
    /// reading.
    ///
    /// ⚠️ ARMED FROM HERE, not from `setZoomContentHidden`, and the difference
    /// is a whole dismissal. Both routes home hide the content — the grab and
    /// the back button — but only the grab drives a progress channel. Arming on
    /// the hide left a back-button dismissal showing a full-screen thread over
    /// a card flying away underneath it, with nothing to ever take it down.
    /// This method is the grab's alone, so it is the honest signal that one is
    /// running.
    #if DEBUG
    /// Arms the engaged dismissal WITHOUT a real engagement, so a test can
    /// pin the ordering rule the flag exists for.
    ///
    /// The rule is about two public entry points meeting in the wrong order —
    /// the hide is deferred by a commit and a display tick, so it lands after
    /// the grab has begun — and the engagement itself is not what is under
    /// test. This flips the flag and nothing else.
    func debugArmEngagedDismissal() {
        isEngagedDismissalActive = true
    }
    #endif

    public func setZoomDismissState(_ state: ZoomDismissState) {
        guard commentsEngagedID != nil, !commentsEngagementIsResting,
              let cell = activeSnapCell
        else { return }
        let progress = state.progress
        if !isEngagedDismissalActive {
            isEngagedDismissalActive = true
            view.alpha = 1
            // The floors between the page and the card go transparent — the
            // page itself stays whole, so what shows around it as it shrinks is
            // the flight, not this screen's black.
            view.backgroundColor = .clear
            collectionView.backgroundColor = .clear
            cell.beginEngagedDismissal()
        }
        // Re-asserted every event, not just at arming: anything that hides the
        // page mid-grab is undone on the next frame the finger produces, so a
        // race can cost one frame instead of the whole gesture.
        view.alpha = 1
        // ⚠️ AND THE NAVIGATION BAR RECEDES WITH IT.
        //
        // The bar is the navigation controller's, above the transition's
        // container — the flight leaves it there deliberately, because on an
        // ordinary dismissal the page underneath is hidden and the bar is
        // simply chrome over a shrinking card. Here the page is VISIBLE and
        // travelling, so a bar pinned to the screen's corners while everything
        // under it moves reads as two layers coming apart. It carries the
        // engaged interface's own controls — the close, the sort, the author —
        // so it belongs to the thread and leaves with it.
        //
        // The toolbar needs nothing: the interaction controller already fades
        // it on this same channel.
        navigationController?.navigationBar.alpha = 1 - min(max(progress, 0), 1)
        // The rect arrives in the CONTAINER's coordinates, which are this
        // view's: both are full-bleed in it. The same assumption the opening
        // makes about the rect it is handed.
        cell.setEngagedDismissal(state.with(card: view.convert(state.card, to: cell.contentView)))
    }

    /// Puts the page back together after a grab, committed or abandoned. Safe
    /// to call when no grab ran: the flag is the whole guard.
    private func endEngagedDismissalIfNeeded() {
        guard isEngagedDismissalActive else { return }
        isEngagedDismissalActive = false
        navigationController?.navigationBar.alpha = 1
        activeSnapCell?.endEngagedDismissal()
        view.backgroundColor = .black
        collectionView.backgroundColor = .black
    }

    /// A presenting flight is staging. The active page must not start its own
    /// playback while the card is flying that player, so the flag is set before
    /// this controller lays out and activates anything.
    public func zoomTransitionWillBegin() {
        isAwaitingZoomPresentation = true
        activeSnapCell?.defersPlaybackForFlight = true
        activeSnapCell?.setChromeHeldForFlight(true)
    }

    /// **OPTION B.** Opens the thread's window on the same spring the card
    /// flies on. Silent unless the opener asked for it and the page is engaged.
    private func beginMaskedRevealIfRequested() {
        // The second attempt at the engagement itself, and for a cold open it
        // is the one that works: by here the destination is in the container
        // at its real size, so the page it is about to show is realized. A
        // no-op when the pre-push attempt already succeeded.
        applyPendingComments(animated: false)
        guard let rect = pendingCommentsRevealRect, let cell = activeSnapCell,
              commentsEngagedID != nil, !commentsEngagementIsResting
        else { return }
        pendingCommentsRevealRect = nil
        isMaskedRevealActive = true
        view.alpha = 1
        // Every floor between the window and the card, for the same reason the
        // cell's own has to go: three opaque blacks stacked between a thread
        // and the photograph it is supposed to be lying on.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        // The rect arrives in the OPENER's view space. Both screens are
        // full-bleed in the same window, so the two spaces differ by nothing —
        // and this one is asked before the destination has a window of its own
        // to convert through.
        cell.beginMaskedRevealForFlight(
            from: view.convert(rect, to: cell.contentView),
            // ⚠️ THE MEDIA'S RADIUS, NOT THE CARD'S. The window opens from the
            // media rect, and the flight card starts at exactly this number
            // (`PostGridFlightCard.Style.listMedia.cornerRadius`). The card's
            // own radius is 26 against the media's 16: close enough to look
            // deliberate and wrong enough that the two silhouettes never sat
            // on each other.
            cornerRadius: PostGridListRowCell.mediaCornerRadius
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[masked-hero] window opens from \(NSCoder.string(for: rect))")
        }
        #endif
    }

    /// Parks the active page's player for the source it is flying home to.
    @discardableResult
    public func zoomParkLiveMediaForHandoff() -> Bool {
        // Already handed over as a donated view, which parks as part of the
        // same step — parking again would retire the player the card is flying.
        guard donatedLiveView == nil else { return true }
        return activeSnapCell?.parkPlayback() ?? false
    }

    /// Hands the active page's rendering surface to a dismissal's flight card.
    ///
    /// ⚠️ A DISMISSAL's. Refused while a present is staging, and that guard is
    /// the whole of a defect.
    ///
    /// `ZoomFlight.build` asks the destination when the source declines, on the
    /// stated assumption that "on a present the destination's page isn't playing
    /// yet and refuses". That held while a post's playback was decided by its
    /// head attachment — a freshly configured page had nothing running.
    ///
    /// A mixed carousel broke it. This controller is REUSED: on a second
    /// present its active cell is still the previous visit's, its carousel is
    /// still on the page that visit left, and its clip is still held — paused
    /// in place, which is deliberate. So it answered yes, and the flight from a
    /// card showing a PHOTOGRAPH carried the video of a page nobody was looking
    /// at. Measured: `source attach surface -> false` (the card correctly
    /// declined) followed by a card reporting `frames=2`.
    public func zoomDonateLiveMediaView() -> UIView? {
        guard !isAwaitingZoomPresentation else { return nil }
        guard let donated = activeSnapCell?.donateLiveRenderView() else { return nil }
        donatedLiveView = donated
        return donated
    }

    /// Takes the card's live surface at landing, so the page renders the frame
    /// the card was showing rather than starting a layer of its own.
    public func zoomAdoptLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        donatedLiveView = nil
        // The page warmed its OWN layer during the flight, so landing is a
        // visibility flip and the card's surface is simply discarded. Only fall
        // back to taking the card's view when there was nothing to warm.
        if activeSnapCell?.revealWarmAttachedSurface() == true { return }
        activeSnapCell?.adoptLiveRenderView(view)
    }

    /// Puts a donated surface back — the abandoned grab, where this page stays
    /// on screen and has to look untouched.
    public func zoomReclaimLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        donatedLiveView = nil
        activeSnapCell?.reclaimDonatedPlayback(view)
    }

    public func zoomTransitionDidEnd() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[feed-reuse] LANDED showing \(activePostID?.rawValue ?? "nil")"
                  + " of \(orderedIDs.prefix(3).map(\.rawValue))")
        }
        #endif
        flightChrome = nil
        isAwaitingZoomPresentation = false
        // The replica is gone; the page's own chrome comes in rather than
        // simply stopping being covered.
        activeSnapCell?.setChromeHeldForFlight(false)
        // A flight card may have mirrored the active cell's player; with the
        // card gone, the cell reclaims the render slot (only the most
        // recently attached layer of a shared player is guaranteed to
        // display). Harmless when nothing was mirrored.
        activeSnapCell?.reclaimPlayback()
        // And the presenting leg's held-back start runs now: the card is gone,
        // so attaching here is the hand-off rather than a theft. Adopts the
        // parked player, so the page resumes instead of restarting.
        activeSnapCell?.startDeferredPlayback()
        // The comments warm was held back across the flight (see
        // `prewarmComments`) — and it does NOT resume here, because "landed"
        // is not yet "idle". Measured: run at this instant it produced a
        // 156ms stall at +776ms from the flight's start, against ~33ms
        // without it. That is the flight's stall moved rather than removed:
        // off the card, but still inside the settle a viewer is watching.
        scheduleIdleCommentsWarm()
        // …unless a card asked to land IN the comments, in which case there is
        // nothing to warm for: the engagement is happening now.
        applyPendingComments(animated: true)
        if isMaskedRevealActive {
            isMaskedRevealActive = false
            activeSnapCell?.endMaskedRevealForFlight()
            view.backgroundColor = .black
            collectionView.backgroundColor = .black
        }
        endEngagedDismissalIfNeeded()
    }

    /// The hero transition's dismiss-leg live seam: mirrors the active cell's
    /// playing video onto the flight card's render surface, so the card flies
    /// the same frames the page was showing instead of a frozen cover.
    public func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
        guard let renderView = surface as? VideoRenderView,
              let cell = activeSnapCell else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] destination mirror refused: activeCell=\(activeSnapCell != nil)")
            }
            #endif
            return false
        }
        let mirrored = cell.mirrorPlayback(to: renderView)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] destination mirror -> \(mirrored)")
        }
        #endif
        return mirrored
    }

    private var activeSnapCell: SnapFeedCell? {
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
    private var settledPageIndex: Int { lifecycle.pageIndex ?? 0 }

    /// Configures the replica from the page the card flies to/from: the active
    /// page if one is settled, else the first post (a map tap's feed opens on
    /// its tapped post). No-op until that model exists.
    private func configureFlightChrome(_ chrome: SnapChromeView) {
        let index = lifecycle.activeIndex ?? 0
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        chrome.configure(with: model)
        chrome.setImagePipeline(imagePipeline)
        // The replica's boost anchor wears the same face as the live one —
        // a boosted post must not flash back to the glyph mid-flight.
        chrome.setBoostTotal(wallet?.boostTotal(forTarget: model.id.rawValue) ?? 0)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[flight-chrome] \(model.id.rawValue) hasMedia=\(model.mediaURL != nil)"
                  + " destinationEngaged=\(activeSnapCell?.isCommentsEngaged.description ?? "no cell")"
                  + " engagedID=\(commentsEngagedID?.rawValue ?? "nil")")
        }
        #endif
    }

    /// A grab may begin from any page — but not mid-fling, where the user's
    /// intent is still vertical and freezing the pager would strand it
    /// between pages.
    public var isReadyForInteractiveDismissal: Bool {
        !collectionView.isDecelerating
    }

    /// ⚠️ THE POST ON SCREEN RIGHT NOW, not the one that opened this screen.
    ///
    /// A text page has no media to fly, so it goes home as a card; anything
    /// with a picture flies that picture. The distinction used to be settled at
    /// the tap, which is correct for a screen that shows one post and wrong for
    /// a PAGER — swipe from a photograph to a text post and the driver chosen
    /// at the tap is the wrong one for the post being dismissed.
    ///
    /// Read from the MODEL rather than from the realized cell: a grab can begin
    /// on a page whose cell is mid-recycle, and the answer must not depend on
    /// what happens to be dequeued. Falls back to `.hero`, the historical
    /// answer, when there is no model to ask.
    public var zoomDismissalKind: ZoomDismissalKind {
        // The SETTLED page, not the active one — see `settledPageIndex`. A pop
        // takes the screen's visibility away before it asks this.
        let index = settledPageIndex
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]]
        else { return .hero }
        return model.mediaURL == nil ? .card : .hero
    }

    /// The vertical grab's extra gate (the horizontal one needs none: the
    /// pager owns no horizontal gestures). Refused while a comments panel is
    /// OPEN — the engaged layer owns the whole vertical axis (page drive,
    /// pull-dismiss), so a downward drag there is never a dismissal. A
    /// RESTING engagement is a text page's ordinary layout, not an open
    /// panel, and stays grabbable — with one nuance below. Also refused over
    /// territory that owns its own vertical gestures (the shortcut rail's
    /// column, the composer).
    public func zoomVerticalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        // ⚠️ AN OPEN KEYBOARD OWNS THE DOWNWARD DRAG.
        //
        // The comments list dismisses the keyboard interactively — drag down
        // over it and the keyboard follows the finger. That gesture and this
        // one are the same drag in the same direction, and the keyboard's is
        // the one the viewer means: they are looking at a keyboard they want
        // gone, not at a post they want closed. Claiming it here closed the
        // post out from under a half-typed comment.
        //
        // Only while the keyboard is actually up, so nothing changes for the
        // rest of the page's life.
        guard !isKeyboardOnScreen else { return false }
        guard commentsEngagedID == nil || commentsEngagementIsResting else { return false }
        let point = collectionView.convert(location, from: view)
        guard let hit = collectionView.hitTest(point, with: nil) else { return true }
        for current in sequence(first: hit, next: { $0.superview }) {
            if current is SnapShortcutRailView || current is SnapRailBoostButton
                || current is CommentsInputBar {
                return false
            }
            if current is SnapCommentsContainerView {
                // A RESTING text page's whole body is this container, which
                // would put the vertical dismissal out of reach on exactly
                // the pages that have no other downward verb. The sheet
                // idiom resolves it: at the stream's TOP a downward drag has
                // nothing left to scroll, so the territory yields to the
                // dismissal precisely there — mid-stream it keeps scrolling,
                // and an OPEN panel never reaches this line (the guard
                // above).
                let stream = commentsContentVC as? PostDetailViewController
                return commentsEngagementIsResting && stream?.streamIsAtTop == true
            }
        }
        return true
    }

    /// The horizontal grab's gate, which exists because a post's media can now
    /// be a carousel.
    ///
    /// Three answers, in order:
    ///
    /// 1. **From the screen's leading edge, always yes.** That strip is the
    ///    system's back gesture and the viewer's muscle memory; a carousel
    ///    borrowing it would make the one gesture that always means "back" mean
    ///    something else on exactly the screens that are hardest to leave.
    /// 2. **On a carousel that has somewhere to go back to, no.** A rightward
    ///    drag there means "previous photo". The carousel is the tenant and it
    ///    wins its own territory.
    /// 3. **On the FIRST page, yes.** The carousel has nothing to the left, so
    ///    holding the gesture would spend it on a rubber-band. It passes
    ///    straight through — which is also what makes leaving a gallery feel
    ///    like leaving anything else once you have paged back to the start.
    public func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        if location.x - view.bounds.minX <= Self.backEdgeZone { return true }
        let point = collectionView.convert(location, from: view)
        guard let hit = collectionView.hitTest(point, with: nil) else { return true }
        for current in sequence(first: hit, next: { $0.superview }) {
            if let carousel = current as? MediaCarouselView {
                return carousel.currentPage == 0
            }
        }
        return true
    }

    /// The system's back-gesture strip. Matched to `HorizontalPagerScrollView`'s
    /// own, which yields the same zone to the same gesture for the same reason.
    private static let backEdgeZone: CGFloat = 20

    public func setContentScrollEnabled(_ enabled: Bool) {
        // Through a lock that RESTORES rather than an assignment that enables.
        //
        // An engaged comments panel disables the pager for the engagement's
        // whole lifetime (see the note at the engage site) — that freeze is
        // what stops the comment stream chaining into the feed. Thawing to
        // `true` handed it back scrollable, and since nothing else re-applies
        // the lock the chaining stayed broken for the rest of that
        // engagement: the comments dragged the feed with them on every
        // subsequent scroll. Reopening the post appeared to fix it, because
        // that rebuilt the engagement.
        if enabled { pagerLock.thaw(collectionView) } else { pagerLock.freeze(collectionView) }
        // The COMMENT STREAM too, and it is the one that was missed.
        //
        // This freezes "the content" for a dismissal swipe, and the pager was
        // all it froze — which is right for a media post, where the pager is
        // the only thing under the finger. A TEXT post opens straight into its
        // comments, so the surface being swiped is a scroll view hosted in the
        // cell, below the pan and recognising alongside it: a swipe with any
        // vertical component scrolled the comments while the page slid away.
        //
        // Reached through the engaged child rather than by walking subviews:
        // the stream is one specific scroll view, and a descendant sweep would
        // also catch the composer's text view and whatever a cell hosts next.
        let stream = commentsContentVC as? PostDetailViewController
        stream?.setStreamScrollEnabled(enabled)
        #if DEBUG
        // `-dismiss-lock-log`: whether the freeze actually REACHED a stream.
        //
        // The conflict this fixes needs a diagonal drag, and the scripted
        // swipe is purely horizontal, so no harness can reproduce it — the
        // one thing a scripted run CAN still establish is that a text post has
        // an engaged panel at swipe time, which is the assumption the forward
        // above rests on. A `stream=nil` here would mean the lock is a no-op.
        if ProcessInfo.processInfo.arguments.contains("-dismiss-lock-log") {
            print("[dismiss-lock] contentScroll=\(enabled ? "on" : "OFF") "
                  + "stream=\(stream == nil ? "nil" : "engaged") "
                  + "pager=\(collectionView.isScrollEnabled ? "SCROLLABLE" : "frozen")")
        }
        #endif
    }
}

/// Holds notification tokens and unregisters them on its own deallocation,
/// which happens when the owning view controller is released. `@unchecked
/// Sendable` so its `deinit` may run off the main actor; `removeObserver` is
/// itself thread-safe, and the tokens are only mutated on the main actor.
private final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

extension SnapFeedViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        warmContent(at: indexPaths.map(\.item))
        warmPlayers(at: indexPaths.map(\.item))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let urls = prefetchURLs(for: indexPaths)
        let pipeline = imagePipeline
        Task { await pipeline.cancelPrefetch(urls) }
    }
}

// MARK: - Geometric touch divorce

/// The feed's collection view, amended with one rule: touches born inside a
/// shortcut rail belong to the rail, so NONE of the pager's own recognizers
/// (its pan, iOS 26's paging swipe) may begin there. This is the inversion
/// that finally made the rail responsive — a scroll view nested in a PAGING
/// scroll view loses UIKit's usual inner-first arbitration (the paging
/// ancestor's recognizers outrank descendants), and every attempt to fight
/// upward from the rail (delegate shadowing, require(toFail:) edges) broke
/// system machinery. Here the pager simply DECLINES, per touch, via the
/// public `gestureRecognizerShouldBegin` seam — the same pattern as the
/// ticker's axis test, with zero edges added to the gesture graph. Left of
/// the rail's column nothing hit-tests into the rail, so the feed is stock.
final class SnapFeedCollectionView: UICollectionView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: self)
        if let hit = hitTest(location, with: nil), Self.claimsTouches(hit) {
            return false
        }
        // FORWARD-ONLY (cluster-gallery milestone): the pager declines any
        // predominantly-downward touch, per touch, via the same public seam as
        // the rail divorce — no gesture-graph edges. One decline kills
        // backward paging, the top rubber-band and pull-to-refresh at once,
        // and leaves the whole downward direction to the dismissal hero's pan
        // (which self-gates on the mirror of this test, so exactly one of the
        // two ever claims a drag).
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           Self.declinesDownwardPagingTouch(velocity: pan.velocity(in: self)) {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// The forward-only axis test, mirrored from the dismissal pan's begin
    /// gate: a downward, predominantly-vertical movement is not the pager's.
    /// Pure so the routing rule is unit-testable.
    static func declinesDownwardPagingTouch(velocity: CGPoint) -> Bool {
        velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    /// The swipe exit's missing half: `UIScrollView` refuses BY DEFAULT to
    /// cancel touches that began on a `UIControl` — and the composer band
    /// is made of controls (the "+", the ✕/send), so a drag born there
    /// could never be taken over by the pager even though the arbitration
    /// allows it. Bar territory explicitly opts INTO cancellation: a
    /// vertical drag on the input band becomes a page change; taps still
    /// land as taps (cancellation only happens once the pan recognizes).
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if sequence(first: view, next: { $0.superview }).contains(where: { $0 is CommentsInputBar }) {
            return true
        }
        return super.touchesShouldCancel(in: view)
    }

    /// Whether the hit view lives inside territory that owns its own
    /// vertical/horizontal gestures, so NONE of the pager's recognizers may
    /// begin there: the shortcut rail (including its fixed compose "+", a
    /// chrome sibling above the rail), and the engaged comments container.
    /// While engaged this is DEFENSE IN DEPTH under the primary rule (the
    /// pager is disabled outright — the total dead-end doctrine); the
    /// composer-band exception is retained but inert, since the bar's own
    /// pan drives the swipe exit programmatically. Pure walk-up so the
    /// routing rule is unit-testable.
    static func claimsTouches(_ view: UIView) -> Bool {
        for current in sequence(first: view, next: { $0.superview }) {
            if current is CommentsInputBar { return false }
            if current is SnapShortcutRailView || current is SnapRailBoostButton
                || current is SnapCommentsContainerView {
                return true
            }
        }
        return false
    }
}
