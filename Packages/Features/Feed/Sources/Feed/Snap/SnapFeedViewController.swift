import MediaCore
import CoreModels
import CoreNavigation
import DesignSystem
import MediaPlayback
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
    private let refreshControl = UIRefreshControl()
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
    /// The two faces of the one living toolbar (keep-and-stack): built
    /// once, swapped via `setToolbarItems(_:animated:)` on the engagement
    /// seams — the leading attribution shared between both, so only the
    /// trailing platters morph.
    private var defaultToolbarItems: [UIBarButtonItem] = []
    private var engagedToolbarItems: [UIBarButtonItem] = []
    /// Session-local optimistic bookmark state: the BFF exposes no save/
    /// bookmark API yet (dev/BACKEND_GAPS.md), so the toggle lives here until
    /// a real seam exists on `FeedViewModel` — swap this set for it.
    private var bookmarkedPostIDs: Set<PostID> = []

    /// id → display model; lookups only, never measurement.
    private var modelsByID: [PostID: FeedItemDisplayModel] = [:]
    private var orderedIDs: [PostID] = []

    private var lifecycle = SnapLifecycleDispatcher()
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
    private var commentsEngagedID: PostID?
    /// The engaged comments UI — a child of THIS controller (thread data,
    /// scroll position, and reply drafts must never live in a recycled
    /// cell); the cell only hosts its view while engaged.
    private var commentsContentVC: UIViewController?
    /// Whether the active engagement is a text page's RESTING interface —
    /// PRE-RENDERED on visibility (as the cell scrolls in, fully formed,
    /// no reveal spring), then LOCKED at settle. The two phases are split
    /// so the interface slides in complete while the incoming scroll is
    /// never aborted (the pager lock can only land once the page has
    /// settled — disabling it mid-drag would freeze the user's scroll).
    private var commentsEngagementIsResting = false
    /// Whether the resting engagement's settle-time lock (pager freeze +
    /// engaged toolbar context) has been applied — set when the page
    /// activates, so a pre-render that never settles never locks.
    private var restingLockApplied = false
    /// The pager's `contentOffset.y` captured when an interactive page-swipe
    /// begins — the datum the drive offsets from. Nil when no drive is
    /// live. The drive hand-moves `contentOffset` while the pager's own pan
    /// stays disabled (the dead-end lock is untouched), so the finger
    /// drives the leaving page directly and the engaged layer (all in the
    /// cell) rides for free.
    private var pageDriveStartOffset: CGFloat?

    init(
        viewModel: FeedViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeCommentsPanelContent: ((PostID) -> UIViewController)? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        self.makeCommentsPanelContent = makeCommentsPanelContent
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
        if isClosable, navigationItem.leftBarButtonItem == nil {
            let back = SnapNavControls.makeBackButton()
            back.addAction(UIAction { [weak self] _ in self?.closeFeed() }, for: .primaryActionTriggered)
            navigationItem.leftBarButtonItem = UIBarButtonItem(customView: back)
        }
        presentToolbar()
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
    private func runDebugAppearanceHooks() {
        if ProcessInfo.processInfo.arguments.contains("-snap-auto-dismiss"), isClosable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.closeFeed()
            }
        }
        let arguments = ProcessInfo.processInfo.arguments
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
    }

    // MARK: - Setup

    /// The system bars are the interaction zone's structural bounds: when
    /// they actually change (the toolbar presents/conceals with the push,
    /// rotation, Dynamic Island class changes), push the new thresholds
    /// into every live cell. Page transitions never fire this — this view
    /// does not move with them, which is precisely why its safe area is
    /// the authority and the cells' ambient one is not.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let collectionView else { return }
        for cell in collectionView.visibleCells {
            (cell as? SnapFeedCell)?.applyChromeInsets(view.safeAreaInsets)
        }
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

        refreshControl.tintColor = .white
        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl

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
                    videoPlayback: self.videoPlayback
                )
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
                cell.onRequestCommentsPageDrive = { [weak self] phase, translation, velocity in
                    self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
                }
            }
            return cell
        }
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
        // cross-fade inside it, never re-negotiating bar layout. It is the
        // bar's ONLY trailing item — the feed's chrome is identical on every
        // entry path (menu push and pin flight), so nothing may install
        // extra items, here or from outside.
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: authorIdentityView)]
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
        bookmarkButton.addAction(UIAction { [weak self] _ in
            guard let self, let model = self.activeModel else { return }
            self.toggleBookmark(for: model.id)
        }, for: .primaryActionTriggered)

        let share = SnapNavControls.makeToolbarActionButton(systemName: "square.and.arrow.up")
        share.addAction(UIAction { [weak self] _ in
            guard let self, let model = self.activeModel else { return }
            self.presentShareSheet(for: model.id)
        }, for: .primaryActionTriggered)

        // One glass capsule, two 36pt slots: the stack is the item's custom
        // view, so the system wraps the pair in a single bubble — bookmark
        // leading, share keeping its slot beside the more bubble.
        let shareCluster = UIStackView(arrangedSubviews: [bookmarkButton, share])
        shareCluster.axis = .horizontal

        let more = SnapNavControls.makeToolbarActionButton(systemName: "ellipsis")
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let model = self.activeModel else { return completion([]) }
                completion(self.moreMenuActions(for: model.id))
            }
        ])

        // TWO item sets over one living bar (keep-and-stack): the audio
        // attribution ANCHORS the leading slot and the more (…) bubble
        // ANCHORS the far right in BOTH — the same item instances in both
        // arrays, so their platters never move — while the territory
        // between swaps via `setToolbarItems(_:animated:)` (the system's
        // own platter morph, the same choreography a push uses): the
        // bookmark/share cluster for the feed, the comments sort selector
        // while engaged (bookmark and the post metrics already live in
        // the engaged card — the band carries no duplicates).
        let leading: [UIBarButtonItem] = [
            UIBarButtonItem(customView: mediaAttributionView),
            .flexibleSpace(),
        ]
        let moreItem = UIBarButtonItem(customView: more)
        defaultToolbarItems = leading + [
            UIBarButtonItem(customView: shareCluster),
            .fixedSpace(Spacing.sm),
            moreItem,
        ]
        engagedToolbarItems = leading + [
            UIBarButtonItem(customView: commentSortButton),
            .fixedSpace(Spacing.sm),
            moreItem,
        ]
        toolbarItems = defaultToolbarItems
    }

    /// Optimistic local toggle (no backend seam yet — see the set's comment);
    /// the glyph flips immediately, scoped to the acted-on post.
    private func toggleBookmark(for id: PostID) {
        if !bookmarkedPostIDs.insert(id).inserted {
            bookmarkedPostIDs.remove(id)
        }
        refreshBookmarkGlyph(for: id)
    }

    /// Points the bookmark glyph at `id`'s state — called on toggle and when
    /// the active page changes.
    private func refreshBookmarkGlyph(for id: PostID) {
        let saved = bookmarkedPostIDs.contains(id)
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

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
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
        // The keyboard-session rail yield: the engaged composer rises into
        // the rail's column, and the rail concedes the band while typing —
        // zPosition cannot lift the bar over chrome across subtrees (CA
        // reorders siblings only), so the chrome steps back instead. Alpha
        // also retires the rail from hit-testing, so the risen bar owns
        // its whole band. Engagement-gated in the cell; restored on hide
        // and at disengage teardown.
        appObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setEngagedRailConcealed(true) }
        })
        appObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setEngagedRailConcealed(false) }
        })
    }

    private func setEngagedRailConcealed(_ concealed: Bool) {
        guard commentsEngagedID != nil || !concealed else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.engagedCell()?.setRailConcealed(concealed)
        }
    }

    private func setForeground(_ foreground: Bool) {
        isForeground = foreground
        refreshVisibility()
    }

    // MARK: - Rendering

    private func render(_ state: FeedViewModel.RenderState) {
        refreshControl.endRefreshing()

        orderedIDs = state.items.map(\.id)
        modelsByID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, PostID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(orderedIDs)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.updateActiveItem()
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
    private func presentComments(for id: PostID) {
        guard commentsEngagedID == nil, commentsContentVC == nil,
              let makeCommentsPanelContent,
              let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell
        else { return }

        let content = makeCommentsPanelContent(id)
        content.view.backgroundColor = .clear
        content.overrideUserInterfaceStyle = .dark
        commentsEngagedID = id
        commentsContentVC = content
        // FOOTER CROSSFADE, zero layout churn BY CONSTRUCTION: the native
        // toolbar is NEVER structurally concealed — it stays fully present
        // in the hierarchy for the whole engagement, so the safe area
        // cannot move at any point (structural hide/show was the root
        // cause of every footer jump: it forces an immediate safe-area
        // layout pass). Its PIXELS crossfade against the composer — which
        // anchors to the window's home-indicator inset, not the safe area,
        // so it occupies the toolbar's exact band while both coexist —
        // inside the one spring. Alpha < 0.01 also removes the invisible
        // toolbar from hit-testing, so its buttons can't be tapped blind.
        // TOTAL DEAD-END for vertical scrolling: the pager is disabled for
        // the engagement's whole lifetime. This is the structural answer
        // to UIKit's nested-scroll chaining — outer and inner scroll pans
        // recognize simultaneously by design, and boundary excess hands
        // off to the outer the moment the inner pins to an edge; no
        // begin-time veto can prevent a handoff on a pan that already
        // began. A disabled pan cannot receive the handoff, full stop.
        // The inner list keeps its rubber-band (alwaysBounceVertical), and
        // the exits all survive the lock: taps (✕, docked media) don't
        // need the pager, and the footer's swipe exit is the bar's OWN
        // pan driving a PROGRAMMATIC scrollToItem — which works on a
        // scroll-disabled pager.
        collectionView.isScrollEnabled = false
        addChild(content)
        cell.installComments(content.view)
        content.didMove(toParent: self)
        let detail = content as? PostDetailViewController
        // The stream rests below the frosted strip (full-height scroll,
        // inset content) and its rows end where the rail's column begins.
        detail?.setEngagedInsets(
            top: SnapCommentsLayout.stripBottom(topInset: view.safeAreaInsets.top),
            trailing: cell.commentsRailExclusionWidth,
            // KEEP-AND-STACK: the composer's rest band clears the NATIVE
            // TOOLBAR, not just the home indicator — the feed's own
            // settled safe-area bottom is exactly that threshold (the bar
            // is structurally present in both states, so this value is
            // stable; same frozen-threshold doctrine as the chrome's top).
            bottomInset: view.safeAreaInsets.bottom
        )
        if modelsByID[id]?.mediaURL != nil {
            // Media pages wire the ✕ (and with it the composer's
            // close/send toggle). TEXT-ONLY pages don't: their engagement
            // is the permanent resting state — nothing to dismiss to —
            // so the trailing slot stays a permanent send and the only
            // way off the post is paging.
            detail?.setEngagedCloseHandler { [weak self] in self?.dismissComments() }
        }
        detail?.setEngagedPageSwipeHandler { [weak self] phase, translation, velocity in
            self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
        }
        // ONE unified motion profile: the composer starts offstage (alpha
        // 0, slight downward offset) and physically slides into its
        // STACKED seat — above the native toolbar, which stays exactly
        // where it is (keep-and-stack: the bar is never faded, never
        // touched; transitions remain the system's alone).
        detail?.setComposerEntranceState(offstage: true)
        // The living bar changes CONTEXT, not presence: the trailing
        // action cluster yields its territory to the comments sort
        // selector through the system's own item morph, on the spring's
        // beat — the audio attribution stays anchored on the left. Sort
        // is engagement-scoped — every fresh engagement starts at Recent,
        // and the selection drives the STREAM: the detail's view model
        // re-ranks and the diffable snapshot animates the moves.
        commentSortButton.reset()
        commentSortButton.onOrderChange = { [weak detail] order in
            detail?.setCommentSortOrder(order)
        }
        setToolbarItems(engagedToolbarItems, animated: true)
        UIView.animate(
            withDuration: SnapCommentsLayout.engageDuration, delay: 0,
            usingSpringWithDamping: 1, initialSpringVelocity: 0
        ) {
            cell.setCommentsEngaged(true)
            cell.contentView.layoutIfNeeded()
            detail?.setComposerEntranceState(offstage: false)
        }
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
    private func presentRestingComments(for id: PostID, host cell: SnapFeedCell) {
        guard commentsEngagedID == nil, commentsContentVC == nil,
              let makeCommentsPanelContent else { return }

        let content = makeCommentsPanelContent(id)
        content.view.backgroundColor = .clear
        content.overrideUserInterfaceStyle = .dark
        commentsEngagedID = id
        commentsContentVC = content
        commentsEngagementIsResting = true
        restingLockApplied = false

        addChild(content)
        cell.installComments(content.view)
        content.didMove(toParent: self)
        let detail = content as? PostDetailViewController
        detail?.setEngagedInsets(
            top: SnapCommentsLayout.stripBottom(topInset: view.safeAreaInsets.top),
            trailing: cell.commentsRailExclusionWidth,
            bottomInset: view.safeAreaInsets.bottom
        )
        // No close handler — a resting page is undismissable; the swipe
        // handler pages the feed (the only way off a text post).
        detail?.setEngagedPageSwipeHandler { [weak self] phase, translation, velocity in
            self?.drivePageSwipe(phase, translation: translation, velocity: velocity)
        }
        // INSTANT: composer already onstage, cell engaged synchronously —
        // no spring, no offstage→onstage slide. The interface simply IS,
        // frame one, so scrolling it into view reveals it already formed.
        detail?.setComposerEntranceState(offstage: false)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
    }

    /// The TEXT page's resting engagement, PHASE 2 (settle lock): once the
    /// page has locked into place, freeze the pager (the dead-end doctrine
    /// — over-scroll never chains to a page change) and swap in the
    /// engaged toolbar context. Deferred out of the pre-render so neither
    /// touches the still-in-flight scroll. Runs once per engagement.
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
        setToolbarItems(engagedToolbarItems, animated: true)
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
        // The mirror morph: the action cluster takes its territory back.
        setToolbarItems(defaultToolbarItems, animated: true)
        UIView.animate(withDuration: SnapCommentsLayout.disengageDuration, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0) { [weak self] in
            self?.engagedCell()?.setCommentsEngaged(false)
            detail?.setComposerEntranceState(offstage: true)
        } completion: { [weak self] _ in
            self?.finishCommentsDisengagement()
        }
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
        collectionView.contentOffset.y = rubberBandedOffset(start - dy)
    }

    private func endPageDrive(translation dy: CGFloat, velocity vy: CGFloat) {
        guard let start = pageDriveStartOffset else { return }
        pageDriveStartOffset = nil
        let page = collectionView.bounds.height
        guard page > 0 else { return }
        let startIndex = Int((start / page).rounded())
        // Commit on a decisive drag OR a fling; the projected motion (drag +
        // a slice of velocity) picks the direction — up pages next.
        let committed = abs(dy) > page * 0.18 || abs(vy) > 500
        let step = committed ? ((dy + vy * 0.2) < 0 ? 1 : -1) : 0
        let target = max(0, min(orderedIDs.count - 1, startIndex + step))
        let targetOffset = CGFloat(target) * page
        let distance = abs(collectionView.contentOffset.y - targetOffset)
        let springVelocity = distance > 0 ? min(3, abs(vy) / distance) : 0
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: springVelocity,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.collectionView.contentOffset.y = targetOffset
        } completion: { [weak self] finished in
            guard finished else { return }
            // Now the target page is settled: recompute the active item,
            // which fires the resign→teardown / activate legs (the landed
            // page auto-engages if it's a text post; the old engagement is
            // torn down as it resigns).
            self?.updateActiveItem()
        }
    }

    /// UIScrollView-style rubber-band past the first/last page: the drive
    /// resists beyond the ends so you cannot fling off the feed.
    private func rubberBandedOffset(_ offset: CGFloat) -> CGFloat {
        let page = collectionView.bounds.height
        guard page > 0 else { return offset }
        let maxOffset = CGFloat(max(0, orderedIDs.count - 1)) * page
        if offset < 0 { return -Self.rubberBand(-offset, dimension: page) }
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
        // A keyboard-session rail yield must never outlive the engagement.
        cell?.setRailConcealed(false)
        cell?.setCommentsEngaged(false)
        if let content = commentsContentVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        cell?.clearComments()
        commentsContentVC = nil
        commentsEngagedID = nil
        commentsEngagementIsResting = false
        restingLockApplied = false
        collectionView.isScrollEnabled = true
        // The bar's pixels were never touched (keep-and-stack), but its
        // ITEMS are engagement context — settle them for the paths that
        // never ran the animated mirror (orphaned teardown, instant
        // cleanup). Identity-compare first: after a normal dismiss the
        // swap already landed, and re-setting identical items would only
        // churn the bar's layout.
        if toolbarItems ?? [] != defaultToolbarItems, !defaultToolbarItems.isEmpty {
            setToolbarItems(defaultToolbarItems, animated: false)
        }
    }

    // MARK: - Active-item lifecycle

    private func refreshVisibility() {
        apply(lifecycle.setVisible(isOnScreen && isForeground))
    }

    private func updateActiveItem() {
        let index = SnapActiveItemTracker.activeIndex(
            contentOffsetY: collectionView.contentOffset.y,
            pageHeight: collectionView.bounds.height,
            itemCount: orderedIDs.count
        )
        apply(lifecycle.setPageIndex(index))
    }

    private func apply(_ transition: SnapLifecycleDispatcher.Transition) {
        if let resign = transition.resign {
            lifecycleCell(at: resign)?.didResignActive()
            // An engagement is PAGE-SCOPED: the engaged page resigning
            // retires it instantly (a belt for interrupted teardowns —
            // the animated dismiss normally lands before any page change,
            // since the pager is locked for the engagement's lifetime).
            if let engaged = commentsEngagedID, orderedIDs.indices.contains(resign),
               engaged == orderedIDs[resign] {
                finishCommentsDisengagement()
            }
        }
        if let activate = transition.activate {
            lifecycleCell(at: activate)?.willBecomeActive()
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
                    if commentsEngagedID == nil,
                       let cell = collectionView.cellForItem(at: IndexPath(item: activate, section: 0)) as? SnapFeedCell {
                        presentRestingComments(for: id, host: cell)
                    }
                    if commentsEngagedID == id, commentsEngagementIsResting {
                        lockRestingEngagement()
                    }
                }
            }
        }
    }

    private func updateBarChrome(at index: Int) {
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        authorIdentityView.setAuthor(model, pipeline: imagePipeline)
        mediaAttributionView.setPost(model, pipeline: imagePipeline)
        refreshBookmarkGlyph(for: model.id)
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
    private func moreMenuActions(for id: PostID) -> [UIMenuElement] {
        [
            UIAction(title: "View comments", image: UIImage(systemName: "bubble.right")) { [weak self] _ in
                self?.viewModel.didTapComments(id)
            },
            UIAction(title: "View profile", image: UIImage(systemName: "person.circle")) { [weak self] _ in
                guard let model = self?.modelsByID[id] else { return }
                self?.viewModel.didTapAuthor(model.authorID)
            },
        ]
    }

    private func lifecycleCell(at index: Int) -> SnapCellLifecycle? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapCellLifecycle
    }

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
            if let model = modelsByID[id], model.mediaURL == nil, commentsEngagedID == nil {
                presentRestingComments(for: id, host: snapCell)
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
        (cell as? SnapCellLifecycle)?.didResignActive()
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
           lifecycle.activeIndex != indexPath.item {
            finishCommentsDisengagement()
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

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateActiveItem()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateActiveItem() }
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
    public func setZoomContentHidden(_ hidden: Bool) {
        view.alpha = hidden ? 0 : 1
    }

    public func zoomTransitionDidEnd() {
        flightChrome = nil
        // A flight card may have mirrored the active cell's player; with the
        // card gone, the cell reclaims the render slot (only the most
        // recently attached layer of a shared player is guaranteed to
        // display). Harmless when nothing was mirrored.
        activeSnapCell?.reclaimPlayback()
    }

    /// The hero transition's dismiss-leg live seam: mirrors the active cell's
    /// playing video onto the flight card's render surface, so the card flies
    /// the same frames the page was showing instead of a frozen cover.
    public func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
        guard let renderView = surface as? VideoRenderView,
              let cell = activeSnapCell else { return false }
        return cell.mirrorPlayback(to: renderView)
    }

    private var activeSnapCell: SnapFeedCell? {
        guard let index = lifecycle.activeIndex else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
    }

    /// Configures the replica from the page the card flies to/from: the active
    /// page if one is settled, else the first post (a map tap's feed opens on
    /// its tapped post). No-op until that model exists.
    private func configureFlightChrome(_ chrome: SnapChromeView) {
        let index = lifecycle.activeIndex ?? 0
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        chrome.configure(with: model)
    }

    /// A rightward grab may begin from any page — the horizontal axis is free
    /// (paging and pull-to-refresh are both vertical) — but not mid-fling,
    /// where the user's intent is still vertical and freezing the pager would
    /// strand it between pages.
    public var isReadyForInteractiveDismissal: Bool {
        !collectionView.isDecelerating
    }

    public func setContentScrollEnabled(_ enabled: Bool) {
        collectionView.isScrollEnabled = enabled
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
        let urls = prefetchURLs(for: indexPaths)
        let pipeline = imagePipeline
        Task { await pipeline.prefetch(urls) }
        // Warm the synthesizer/asset for upcoming video pages so their play is
        // instant when they snap into view.
        for indexPath in indexPaths where orderedIDs.indices.contains(indexPath.item) {
            let model = modelsByID[orderedIDs[indexPath.item]]
            if let model, model.mediaKind == .video, let url = model.mediaURL {
                videoPlayback?.preroll(url)
            }
            // Comment streams too: loaded before the page scrolls in, so its
            // band enters the viewport already streaming (subtitles wait for
            // settle regardless — their gate is activation, not content).
            if let model {
                viewModel.ensureCommentStreams(for: model.id)
            }
        }
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
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
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
            if current is SnapShortcutRailView || current is SnapRailComposeButton
                || current is SnapCommentsContainerView {
                return true
            }
        }
        return false
    }
}
