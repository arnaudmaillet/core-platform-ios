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

    init(viewModel: FeedViewModel, imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController? = nil) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
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
        viewModel.onEngagementChange = { [weak self] id, state in
            self?.updateVisibleEngagement(for: id, state: state)
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
        isOnScreen = true
        refreshVisibility()
    }

    #if DEBUG
    private var didDebugPause = false
    private var didDebugScroll = false
    /// `-snap-start-paused`: pauses the active cell shortly after appearing so
    /// the pause glyph can be screenshotted (taps can't be injected in the sim).
    /// `-snap-auto-dismiss`: dismisses a presented (map-opened) feed shortly
    /// after it settles, so the zoom-out leg can be recorded in the sim.
    /// `-snap-start-index N`: snaps to page N shortly after appearing (mock:
    /// every index%3==2 is text-only) — deterministic access to a given page
    /// kind without scroll injection.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Unlike the visibility bookkeeping below, the toolbar choreography
        // runs for every disappearance: it registers on the coordinator when
        // one exists (fade, restore-on-cancel) and hides instantly otherwise.
        concealToolbar()
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

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
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
                    engagement: self.viewModel.engagementState(for: id),
                    pipeline: pipeline,
                    videoPlayback: self.videoPlayback
                )
                cell.onLikeTapped = { [weak self] id in self?.viewModel.toggleLike(for: id) }
                cell.onCommentTapped = { [weak self] id in self?.viewModel.didTapComments(id) }
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

        toolbarItems = [
            UIBarButtonItem(customView: mediaAttributionView),
            .flexibleSpace(),
            UIBarButtonItem(customView: shareCluster),
            .fixedSpace(Spacing.sm),
            UIBarButtonItem(customView: more),
        ]
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
        nav.setToolbarHidden(true, animated: false)
        nav.toolbar.alpha = 1
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

    /// Live path: touch only the affected on-screen cell's engagement rail.
    private func updateVisibleEngagement(for id: PostID, state: FeedViewModel.EngagementState) {
        guard let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? SnapFeedCell else { return }
        cell.updateEngagement(state)
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
        if let resign = transition.resign { lifecycleCell(at: resign)?.didResignActive() }
        if let activate = transition.activate {
            lifecycleCell(at: activate)?.willBecomeActive()
            // Same settle-quantized seam that drives playback: both bar
            // surfaces (identity pill above, media attribution below) follow
            // the active page.
            updateBarChrome(at: activate)
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
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Belt-and-suspenders release: a cell scrolled fully off is never active,
        // and this guarantees the resign even if it's recycled before a settle.
        (cell as? SnapCellLifecycle)?.didResignActive()
    }

    // A full-cell tap toggles play/pause (handled by the cell's own gesture),
    // not navigation — so there is no `didSelectItemAt` routing. Comments open
    // via the rail's comment button; the author row opens the profile.

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
    /// page content only (scrim, caption, rail); the navigation bar stays real
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
        chrome.configure(with: model, engagement: viewModel.engagementState(for: model.id))
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
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let urls = prefetchURLs(for: indexPaths)
        let pipeline = imagePipeline
        Task { await pipeline.cancelPrefetch(urls) }
    }
}
