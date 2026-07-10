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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The back item exists only when there is somewhere to go back to — a
        // presented (map-opened) feed, not the Timeline tab root — and the
        // presentation relationship is known only here, not at viewDidLoad.
        // Dismissing runs the interactive-capable zoom-out.
        if presentingViewController != nil, navigationItem.leftBarButtonItem == nil {
            let back = SnapNavControls.makeBackButton()
            back.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
            navigationItem.leftBarButtonItem = UIBarButtonItem(customView: back)
        }
        isOnScreen = true
        refreshVisibility()
    }

    #if DEBUG
    private var didDebugPause = false
    /// `-snap-start-paused`: pauses the active cell shortly after appearing so
    /// the pause glyph can be screenshotted (taps can't be injected in the sim).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        // No system scroll-edge darkening under the transparent bar: the media
        // stays unmasked to the top edge; the glass bar items carry their own
        // legibility backing.
        collectionView.topEdgeEffect.isHidden = true
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
        // cross-fade inside it, never re-negotiating bar layout. Prepend to
        // whatever the shell already installed (the Timeline tab's compose
        // item) — items are ordered trailing-first, so identity hugs the edge.
        let identityItem = UIBarButtonItem(customView: authorIdentityView)
        navigationItem.rightBarButtonItems = [identityItem] + (navigationItem.rightBarButtonItems ?? [])
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
            // Same settle-quantized seam that drives playback: the bar's
            // author titleView follows the active page.
            updateIdentityAuthor(at: activate)
        }
    }

    private func updateIdentityAuthor(at index: Int) {
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        authorIdentityView.setAuthor(model, pipeline: imagePipeline)
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

    public func zoomTransitionDidEnd() { flightChrome = nil }

    /// Configures the replica from the page the card flies to/from: the active
    /// page if one is settled, else the first post (a map tap's feed opens on
    /// its tapped post). No-op until that model exists.
    private func configureFlightChrome(_ chrome: SnapChromeView) {
        let index = lifecycle.activeIndex ?? 0
        guard orderedIDs.indices.contains(index),
              let model = modelsByID[orderedIDs[index]] else { return }
        chrome.configure(with: model, engagement: viewModel.engagementState(for: model.id))
    }

    /// Dismissal may begin only at the very top of the feed (the first page
    /// pulled past its top boundary) — an unambiguous, no-scroll region — so a
    /// downward drag mid-feed keeps paging instead of dismissing.
    public var isReadyForInteractiveDismissal: Bool {
        collectionView.contentOffset.y <= 0.5
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
