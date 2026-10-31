import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// The Stakes screen (#1477, wallet structure B, slice 3): every stake,
/// Active or Settled, by UTC day — pushed in the Wallet sheet from its stake
/// headings.
///
/// A row reads like a position: the post leads (thumbnail and caption), the
/// author follows; an active stake's ring fills toward its settlement, and a
/// settled one always carries its outcome as a chip — violet only for gems
/// (`WalletStakeCell`).
///
/// The stakes are the wallet's (`WalletStore.stakes()`, the server's
/// `ListMyStakes` for a member, #903); their posts are looked up as the Wallet sheet
/// looks them up, starting from the ones it already has.
final class WalletStakesViewController: UIViewController {
    enum Segment: Int, CaseIterable {
        case active, settled

        var title: String {
            switch self {
            case .active: "Active"
            case .settled: "Settled"
            }
        }
    }

    private nonisolated enum Section: Hashable {
        case failed
        case day(Date)
        /// The rows' bones while the listing is out (#1494).
        case loading
    }

    private nonisolated enum Item: Hashable {
        case postsFailed
        case stake(String)
        case bone(Int)
    }

    private let wallet: WalletStore
    private let lookUpPosts: WalletSheetViewController.PostLookup?
    private let imagePipeline: ImagePipeline?
    private let openFeedHero: WalletSheetViewController.OpenFeedHero?
    private(set) var segment: Segment
    private let segments = UISegmentedControl(items: Segment.allCases.map(\.title))

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: GalleryPost]
    private var postLoads = WalletStakePostLoads()
    private var countdownTimer: Timer?
    private let walletObservers = WalletObserverTokenBag()
    /// A Try Again on its way.
    private var isRetrying = false

    init(
        wallet: WalletStore, segment: Segment, posts: [PostID: GalleryPost] = [:],
        lookUpPosts: WalletSheetViewController.PostLookup? = nil, imagePipeline: ImagePipeline? = nil,
        openFeedHero: WalletSheetViewController.OpenFeedHero? = nil
    ) {
        self.wallet = wallet
        self.segment = segment
        self.entries = posts
        self.lookUpPosts = lookUpPosts
        self.imagePipeline = imagePipeline
        self.openFeedHero = openFeedHero
        super.init(nibName: nil, bundle: nil)
        title = "Stakes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own ground is the surface (the Wallet sheet's note).
        view.backgroundColor = .clear
        // Large, at the page's leading edge (#1494); collapsed into the bar,
        // still leading, beside the chevron — as Activity's (`.browser`: a
        // navigator item centres it whenever the trailing item leaves room).
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.style = .browser
        // Active | Settled at the bar's trailing end (#1494), the Activity
        // screen's bar, so the Rewards sheet's two lists match.
        segments.selectedSegmentIndex = segment.rawValue
        segments.addAction(UIAction { [weak self] _ in
            guard let self, let next = Segment(rawValue: segments.selectedSegmentIndex) else { return }
            select(next)
        }, for: .valueChanged)
        segments.accessibilityLabel = "Stakes"
        // The control is its own capsule: no bubble in a bubble.
        navigationItem.rightBarButtonItem = BarItems.container(
            id: "wallet.stakes.filter", view: segments, ownBackground: true
        )
        buildCollection()

        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()
        // The server's listing as of now; its change notice redraws.
        Task { [weak self] in await self?.reloadListing() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Shows `next`'s stakes, from the top.
    func select(_ next: Segment) {
        guard next != segment else { return }
        segment = next
        segments.selectedSegmentIndex = next.rawValue
        refresh()
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false
        )
    }

    private func reloadListing() async {
        await wallet.refreshStakesFromServer()
        isRetrying = false
        refresh()
    }

    // MARK: - Layout

    private func buildCollection() {
        // The Activity screen's list (#1494): inset grouped, a day per
        // section under the system's header, its stakes rows of one card.
        // The rows draw their own hairline (`WalletGroupedStakeCell`).
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            // The failed row stands alone, under no day.
            let isDay = if case .day? = self?.dataSource?.sectionIdentifier(for: index) { true } else { false }
            configuration.headerMode = isDay ? .supplementary : .none
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: Spacing.sm, left: 0, bottom: Spacing.lg, right: 0)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.topEdgeEffect.style = .soft
        view.addSubview(collectionView)
        collectionView.pin(to: view)
        setContentScrollView(collectionView, for: .top)

        let stakeRegistration = UICollectionView.CellRegistration<WalletGroupedStakeCell, Item> { [weak self] cell, indexPath, item in
            guard let self, case .stake(let id) = item else { return }
            cell.showsSeparator = indexPath.item > 0
            configure(cell, stakeID: id, animated: false)
        }
        let failedRegistration = UICollectionView.CellRegistration<WalletStakesFailedCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(retrying: postLoads.isRetrying, failedAfterRetry: postLoads.failedAfterRetry)
            cell.onRetry = { [weak self] in self?.retryFailedPosts() }
        }
        let boneRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            cell.contentConfiguration = WalletHistoryViewController.boneRow(thumbnail: true)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .stake:
                collectionView.dequeueConfiguredReusableCell(using: stakeRegistration, for: indexPath, item: item)
            case .postsFailed:
                collectionView.dequeueConfiguredReusableCell(using: failedRegistration, for: indexPath, item: item)
            case .bone:
                collectionView.dequeueConfiguredReusableCell(using: boneRegistration, for: indexPath, item: item)
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.header()
            if case .day(let day)? = self?.dataSource.sectionIdentifier(for: indexPath.section) {
                content.text = Self.dayTitle(for: day)
            }
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    // MARK: - State

    /// This segment's stakes.
    private var shown: [WalletStake] {
        stakes.filter { $0.isSettled == (segment == .settled) }
    }

    private func refresh() {
        stakes = wallet.stakes()
        stakesByID = Dictionary(stakes.map { ($0.targetID, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = lookUpPosts == nil ? [] : postLoads.begin(
            shown.map(\.targetID).filter { entries[PostID($0)] == nil }
        )
        applyList(reconfiguring: Set(shown.map(\.targetID)))
        lookUp(missing)
    }

    /// The stakes by day, under the failed row when a post could not be
    /// loaded; or, with no stake to show, the screen's state.
    private func applyList(reconfiguring stakeIDs: Set<String>) {
        let rows = shown
        var list = NSDiffableDataSourceSnapshot<Section, Item>()
        if rows.contains(where: { postLoads.state(of: $0.targetID) == .failed || postLoads.isRetrying($0.targetID) }) {
            list.appendSections([.failed])
            list.appendItems([.postsFailed], toSection: .failed)
        }
        // Nothing to show yet and the listing on its way: the rows' bones,
        // not a spinner (#1494).
        if isLoading {
            list.appendSections([.loading])
            list.appendItems((0..<WalletHistoryViewController.boneRows).map(Item.bone), toSection: .loading)
        }
        for day in WalletStakeDays.group(rows) {
            list.appendSections([.day(day.start)])
            list.appendItems(day.stakes.map { .stake($0.targetID) }, toSection: .day(day.start))
        }
        let before = dataSource.snapshot()
        let previous = Set(before.itemIdentifiers)
        list.reconfigureItems(list.itemIdentifiers.filter {
            switch $0 {
            // A row's hairline follows its place in its day: a row that
            // became, or stopped being, its day's first is redrawn too.
            case .stake(let id):
                previous.contains($0) && (stakeIDs.contains(id) || Self.isFirst($0, in: before) != Self.isFirst($0, in: list))
            case .postsFailed: previous.contains($0)
            case .bone: false
            }
        })
        dataSource.apply(list, animatingDifferences: false)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    /// Whether `item` opens its section in `list`.
    private static func isFirst(_ item: Item, in list: NSDiffableDataSourceSnapshot<Section, Item>) -> Bool {
        guard let section = list.sectionIdentifier(containingItem: item) else { return false }
        return list.itemIdentifiers(inSection: section).first == item
    }

    /// Nothing to show, and the listing on its way.
    private var isLoading: Bool {
        shown.isEmpty && (wallet.awaitsServerStakes || isRetrying)
    }

    /// Failed or empty, over the list (loading is the rows' bones) — nothing
    /// while there are stakes to show.
    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        contentUnavailableConfiguration = isLoading ? nil : Self.unavailable(
            segment: segment, isEmpty: shown.isEmpty, failed: wallet.stakesListingFailed
        ) { [weak self] in
            guard let self else { return }
            isRetrying = true
            refresh()
            Task { [weak self] in await self?.reloadListing() }
        }
    }

    /// The screen's state when it has no row to show and nothing on its way.
    static func unavailable(
        segment: Segment, isEmpty: Bool, failed: Bool, retry: @escaping () -> Void
    ) -> UIContentUnavailableConfiguration? {
        guard isEmpty else { return nil }
        if failed {
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "wifi.exclamationmark")
            content.text = "Couldn't load your stakes"
            content.secondaryText = "Check your connection and try again."
            var button = UIButton.Configuration.bordered()
            button.title = "Try Again"
            content.button = button
            content.buttonProperties.primaryAction = UIAction { _ in retry() }
            return content
        }
        var content = UIContentUnavailableConfiguration.empty()
        content.image = LikesSymbol.glyphImage()
        switch segment {
        case .active:
            content.text = "No active stakes"
            content.secondaryText = "Like a post to stake on it. A stake settles a day later, and pays gems if it turned out right."
        case .settled:
            content.text = "Nothing settled yet"
            content.secondaryText = "Your stakes show here once they settle, with what each one earned."
        }
        return content
    }

    /// "Today", "Yesterday", then the date — of the UTC day, as the stakes
    /// are cut.
    nonisolated static func dayTitle(for day: Date, now: Date = Date()) -> String {
        WalletHistoryViewController.dayTitle(for: day, now: now, calendar: WalletStakeDays.calendar)
    }

    // MARK: - Rows

    private func postPhase(for id: String) -> WalletStakePostLoads.State {
        if entries[PostID(id)] != nil || lookUpPosts == nil { return .loaded }
        return postLoads.state(of: id) ?? .loading
    }

    private func isPressable(stakeID id: String) -> Bool {
        if postPhase(for: id) == .failed { return true }
        return entries[PostID(id)] != nil && openFeedHero != nil
    }

    private func configure(_ cell: WalletStakeCell, stakeID id: String, animated: Bool) {
        guard let stake = stakesByID[id] else { return }
        cell.configure(
            stake: stake, post: entries[PostID(id)], phase: postPhase(for: id),
            now: Date(), imagePipeline: imagePipeline, animated: animated,
            verdictPending: wallet.awaitsServerStakes
        )
    }

    private func stakeCell(for id: String) -> WalletStakeCell? {
        guard let path = dataSource.indexPath(for: .stake(id)) else { return nil }
        return collectionView.cellForItem(at: path) as? WalletStakeCell
    }

    /// Asks for the posts behind `ids` — already marked loading. An empty
    /// answer is an answer: every post it lacks failed (the Wallet sheet's rule).
    private func lookUp(_ ids: [String]) {
        guard let lookUpPosts, !ids.isEmpty else { return }
        Task { [weak self] in
            let found = await lookUpPosts(ids.map { PostID($0) })
            self?.postsArrived(found, requested: ids)
        }
    }

    private func postsArrived(_ found: [PostID: GalleryPost], requested: [String]) {
        entries.merge(found) { _, new in new }
        let retryFailed = postLoads.finish(requested: requested, found: Set(found.keys.map(\.rawValue)))
        if retryFailed, viewIfLoaded?.window != nil {
            Haptics.play(.warning)
        }
        var offscreen: Set<String> = []
        for id in requested {
            if let cell = stakeCell(for: id) {
                configure(cell, stakeID: id, animated: true)
            } else {
                offscreen.insert(id)
            }
        }
        applyList(reconfiguring: offscreen)
    }

    private func retryFailedPosts() {
        let ids = postLoads.retry()
        guard !ids.isEmpty else { return }
        var offscreen: Set<String> = []
        for id in ids {
            if let cell = stakeCell(for: id) {
                configure(cell, stakeID: id, animated: false)
            } else {
                offscreen.insert(id)
            }
        }
        applyList(reconfiguring: offscreen)
        lookUp(ids)
    }

    private func openFeed(fromStake id: String) {
        guard let openFeedHero else { return }
        let order = dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
            if case .stake(let stake) = item { stake } else { nil }
        }
        WalletStakeHero.open(
            stake: id, order: order, posts: entries, from: self, list: collectionView,
            cell: { [weak self] id in self?.stakeCell(for: id) }, openFeedHero: openFeedHero
        )
    }

    // MARK: - Clock

    /// Once a second: the active rows' rings and "settles in" lines. A stake
    /// that has just settled moves to Settled.
    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        let now = Date()
        if stakes.contains(where: { !$0.isSettled && $0.settlesAt <= now }) {
            refresh()
            return
        }
        guard segment == .active else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? WalletStakeCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  case .stake(let id) = dataSource.itemIdentifier(for: indexPath),
                  let stake = stakesByID[id], !stake.isSettled else { continue }
            cell.applyStatus(stake: stake, now: now)
        }
    }
}

extension WalletStakesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return isPressable(stakeID: id)
    }

    /// UIKit's own highlight (#1494), only where a tap does something.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        if postPhase(for: id) == .failed {
            retryFailedPosts()
        } else {
            openFeed(fromStake: id)
        }
    }
}

// MARK: - How it is left (#1144)

extension WalletStakesViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
