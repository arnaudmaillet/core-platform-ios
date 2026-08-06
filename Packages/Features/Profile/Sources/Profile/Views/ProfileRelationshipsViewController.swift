import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The followers / following screen, pushed from the profile header's counter
/// row.
///
/// One screen, two lists, a `UISegmentedControl` between them — rather than two
/// pushed screens or a swipeable pager. Followers and Following are the same
/// question asked in two directions, and the segmented control is the platform's
/// own answer for that: it keeps one navigation entry, one scroll context per
/// tab, and one back button, and it costs no custom chrome. It sits in the
/// navigation bar's `titleView`, where the system styles and centers it; the
/// back button carries the @handle forward from the profile underneath, so
/// whose lists these are stays legible without a second title line.
final class ProfileRelationshipsViewController: UIViewController {
    private enum Section: Hashable {
        case people
        case skeleton
        case paging
    }

    private enum Item: Hashable {
        case person(ProfileID)
        case placeholder(Int)
        case paging
    }

    private let viewModel: ProfileRelationshipsViewModel
    private let imagePipeline: ImagePipeline?

    /// The direction selector, hosted as the navigation item's `titleView`.
    private let segmentedControl = UISegmentedControl()
    /// Search, collapsed to a magnifier in the bar's trailing slot until
    /// tapped — `.integratedButton`, which is UIKit's own name for exactly
    /// that behaviour.
    private let searchController = UISearchController(searchResultsController: nil)
    private var collectionView: UICollectionView!
    private let refreshControl = UIRefreshControl()

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rowsByID: [ProfileID: ProfileRelationshipsViewModel.Row] = [:]
    private var phase: ProfileRelationshipsViewModel.Phase = .loading
    private var hasRenderedContent = false

    /// Segment order, so index ↔ direction never drifts from the control's
    /// titles.
    /// ⚠️ Must stay in the same order as `ProfileRelationshipsViewModel.segmentTitles`,
    /// which maps `RelationshipDirection.allCases` — the segmented control pairs
    /// title *i* with direction *i* and nothing checks the two agree.
    private static let directions: [RelationshipDirection] = RelationshipDirection.allCases

    init(viewModel: ProfileRelationshipsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        // The profile underneath hides the tab bar on push; this screen is one
        // level deeper and must not bring it back.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureSearch()
        configureNavigationBar()
        configureCollectionView()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onDirectionChange = { [weak self] direction in
            guard let index = Self.directions.firstIndex(of: direction) else { return }
            self?.segmentedControl.selectedSegmentIndex = index
        }
        viewModel.onActionResult = { [weak self] result in self?.render(result) }

        render(.loading)
        viewModel.viewDidLoad()
        applySearchAvailability()
    }

    /// Whether the search affordance should be withheld.
    ///
    /// Reads the view model's `access` as well as the rendered phase, and that
    /// ordering is what lets the search bar be installed at the *top* of
    /// `viewDidLoad`: `access` is resolved from the seeded subject at init, so
    /// privacy is knowable before anything has rendered. The phase is the
    /// second source only for the case privacy can't predict — a backend
    /// refusal arriving later.
    private var isRestricted: Bool {
        if viewModel.access == .private { return true }
        if case .restricted = phase { return true }
        return false
    }

    /// Shows or withholds the search field according to privacy.
    ///
    /// Only the field is withheld — the selector stays, so the viewer can still
    /// switch direction. Restriction is not always symmetric: a backend refusal
    /// applies per tab, so one list can be locked while the other reads fine.
    ///
    /// Idempotent; re-run on every phase change.
    private func applySearchAvailability() {
        guard isRestricted else {
            guard navigationItem.searchController == nil else { return }
            navigationItem.searchController = searchController
            // The proposal's shape, expressed as the one enum value UIKit
            // provides for it: inactive search is a magnifier button in the
            // trailing slot, tapping expands it into a field, cancelling
            // collapses it back — all system-driven.
            navigationItem.preferredSearchBarPlacement = .integratedButton
            // No toolbar hand-off: that is what produced the magnifying-glass
            // FLASH during the push in an earlier iteration. Here the magnifier
            // is a deliberate, permanent affordance instead.
            navigationItem.searchBarPlacementAllowsToolbarIntegration = false
            return
        }
        guard navigationItem.searchController != nil else { return }
        searchController.isActive = false
        navigationItem.searchController = nil
    }

    #if DEBUG
    /// Continues the search QA sequence after typing: optionally clear, then
    /// optionally cancel. The clear step goes through the text field's own
    /// `editingChanged` — the same notification the system's clear glyph
    /// raises — so it exercises the real path back to `updateSearchResults`
    /// rather than calling the updater directly.
    private func qaContinueSearchSequence(_ arguments: [String]) {
        let clears = arguments.contains("-profile-relationships-search-clear")
        let cancels = arguments.contains("-profile-relationships-search-cancel")
        guard clears || cancels else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if clears {
                let field = self.searchController.searchBar.searchTextField
                print("PROFILE-SEARCH-QA clearButtonMode=\(field.clearButtonMode.rawValue) "
                    + "autoCancel=\(self.searchController.automaticallyShowsCancelButton)")
                field.text = ""
                field.sendActions(for: .editingChanged)
            }
            guard cancels else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.searchController.isActive = false
            }
        }
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // Dev convenience: `-profile-relationships-tab following|friends` opens
        // on that tab, and `-profile-relationships-action` fires the first row's
        // trailing button — neither is reachable in the simulator, which can
        // deliver no taps.
        if let index = arguments.firstIndex(of: "-profile-relationships-tab") {
            switch arguments.dropFirst(index + 1).first {
            case "following": viewModel.qaSelectDirection(.following)
            case "friends": viewModel.qaSelectDirection(.friends)
            default: break
            }
        }
        if arguments.contains("-profile-relationships-action") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.viewModel.qaActivateFirstRowAction()
            }
        }
        // Dev convenience: `-profile-relationships-open-self` taps the viewer's
        // own "(Me)" row — the route that must land on the personal profile
        // directly, with no stranger-profile frame in between.
        if arguments.contains("-profile-relationships-open-self") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.viewModel.qaOpenSelfRow()
            }
        }
        // Dev convenience: `-profile-relationships-search <text>` types into
        // the pinned header's field ~1.5s in, through its own `query` setter so
        // the real change path runs — rather than poking the view model, which
        // would prove only that the filter compiles.
        if let index = arguments.firstIndex(of: "-profile-relationships-search"),
           let text = arguments.dropFirst(index + 1).first, !text.hasPrefix("-") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // Activate exactly as a tap on the magnifier would, then type.
                self.searchController.isActive = true
                self.searchController.searchBar.text = text
                self.updateSearchResults(for: self.searchController)
                self.qaContinueSearchSequence(arguments)
            }
        }
        // Dev convenience: `-profile-relationships-pop` pops back to the
        // profile ~2s in. The app-level `-auto-pop` fires at a fixed 2.5s,
        // which is before this screen has even been pushed; this one is
        // anchored to its own appearance, so the pop transition is recordable.
        if arguments.contains("-profile-relationships-pop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }
        }
        #endif
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        applySegmentTitles(viewModel.segmentTitles)
        segmentedControl.selectedSegmentIndex =
            Self.directions.firstIndex(of: viewModel.direction) ?? 0
        segmentedControl.addAction(
            UIAction { [weak self] _ in
                guard let self,
                      let direction = Self.directions[safe: self.segmentedControl.selectedSegmentIndex]
                else { return }
                self.viewModel.selectDirection(direction)
            },
            for: .valueChanged
        )
        navigationItem.titleView = segmentedControl
        navigationItem.backButtonTitle = "Back"
        navigationItem.accessibilityLabel = viewModel.title
    }

    /// Retitles the segments in place; replacing them would drop the selection
    /// and replay the control's entrance, and this fires while the screen is up.
    private func applySegmentTitles(_ titles: [String]) {
        for (index, title) in titles.enumerated() {
            if index < segmentedControl.numberOfSegments {
                guard segmentedControl.titleForSegment(at: index) != title else { continue }
                segmentedControl.setTitle(title, forSegmentAt: index)
            } else {
                segmentedControl.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
    }

    /// The search controller itself; where its bar goes is `applySearchAvailability`'s job.
    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search"
        searchController.searchBar.autocapitalizationType = .none
        searchController.hidesNavigationBarDuringPresentation = false
        // Stated rather than inherited. The clear glyph is the system's own —
        // clearing through it routes back out via `searchBar(_:textDidChange:)`
        // to `updateSearchResults`, so an emptied field restores the full list
        // by the same path typing narrows it.
        searchController.searchBar.searchTextField.clearButtonMode = .whileEditing
        // Left to UIKit deliberately. `automaticallyShowsCancelButton` defaults
        // to YES, and touching `searchBar.showsCancelButton` would flip it to
        // NO and hand us the job of showing and hiding it — which is exactly
        // the standard behaviour we want to keep. Note the affordance renders
        // as an ✕ glyph rather than the word "Cancel" under `.integratedButton`
        // placement; that is the native look for a bar-integrated search, not a
        // missing button.
        searchController.automaticallyShowsCancelButton = true
        definesPresentationContext = true
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        // No hairlines, matching every other people list in the app. The rows
        // already read as separate objects — a 48pt disc, a name, a handle —
        // and the rules were drawing a grid around content that did not need
        // one. `RelationshipListCell` keeps its own separator inset logic for
        // whenever a list here does want them back.
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.pin(to: view)

        refreshControl.addAction(
            UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged
        )
        collectionView.refreshControl = refreshControl

        let rowRegistration = UICollectionView.CellRegistration<RelationshipListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let row = self.rowsByID[id] else { return }
            cell.configure(with: row, imagePipeline: self.imagePipeline)
            cell.loadAvatar(row.avatarURL)
            cell.onAction = { [weak self] in
                guard let self else { return }
                switch row.action {
                case .remove: self.confirmRemoveFollower(row)
                case .follow, .following: self.viewModel.toggleFollow(id)
                case .inert: break
                }
            }
        }

        let skeletonRegistration = UICollectionView.CellRegistration<RelationshipSkeletonCell, Int> {
            cell, _, index in
            cell.configure(at: index)
        }

        let pagingRegistration = UICollectionView.CellRegistration<RelationshipPagingCell, Int> {
            cell, _, _ in
            cell.startAnimating()
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .person(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: rowRegistration, for: indexPath, item: id
                )
            case .placeholder(let index):
                collectionView.dequeueConfiguredReusableCell(
                    using: skeletonRegistration, for: indexPath, item: index
                )
            case .paging:
                collectionView.dequeueConfiguredReusableCell(
                    using: pagingRegistration, for: indexPath, item: 0
                )
            }
        }
    }

    // MARK: - Render

    private func render(_ phase: ProfileRelationshipsViewModel.Phase) {
        self.phase = phase
        switch phase {
        case .loading:
            apply(rows: [], placeholders: placeholderCount(after: 0), isAppending: false)

        case .content(let rows, let isAppending):
            refreshControl.endRefreshing()
            apply(rows: rows, placeholders: 0, isAppending: isAppending)

        case .empty, .restricted, .failed:
            refreshControl.endRefreshing()
            apply(rows: [], placeholders: 0, isAppending: false)
        }
        // The empty / private / failure states are the platform's own, not a
        // hand-built column: `UIContentUnavailableConfiguration` supplies the
        // symbol, the type ladder, the centring, and the cross-fade between
        // states, and it stays correct across Dynamic Type and future OS
        // revisions in a way a bespoke stack would not.
        setNeedsUpdateContentUnavailableConfiguration()
        // The toolbar follows the phase: a tab that turns out to be restricted
        // (the backend refused, or the viewer switched to a locked direction)
        // gives its search bar up, and one that turns out not to be gets it
        // back. Skipped before first appearance — `viewWillAppear` owns the
        // opening state, and running here first would fight the transition.
        applySearchAvailability()
    }

    override func updateContentUnavailableConfiguration(
        using state: UIContentUnavailableConfigurationState
    ) {
        var configuration: UIContentUnavailableConfiguration?
        switch phase {
        case .loading, .content:
            configuration = nil

        case .empty(let title, let message):
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "person.2")
            empty.text = title
            empty.secondaryText = message
            configuration = empty

        case .restricted(let title, let message):
            var restricted = UIContentUnavailableConfiguration.empty()
            restricted.image = UIImage(systemName: "lock")
            restricted.text = title
            restricted.secondaryText = message
            configuration = restricted

        case .failed(let message):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = "Couldn't Load"
            failed.secondaryText = message
            var button = UIButton.Configuration.borderless()
            button.title = "Try Again"
            failed.button = button
            failed.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.viewModel.refresh()
            }
            configuration = failed
        }
        contentUnavailableConfiguration = configuration
    }

    /// A failed row mutation. A toast, not an alert: the row has already
    /// rolled back to its previous state, so there is nothing for the user to
    /// dismiss or decide.
    private func render(_ result: ProfileRelationshipsViewModel.ActionResult) {
        switch result {
        case .failed(let message):
            ToastView.present(message, symbol: "exclamationmark.triangle", in: view)
        }
    }

    private func apply(
        rows: [ProfileRelationshipsViewModel.Row],
        placeholders: Int,
        isAppending: Bool
    ) {
        rowsByID = rows.reduce(into: [:]) { models, row in models[row.id] = row }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !rows.isEmpty {
            snapshot.appendSections([.people])
            snapshot.appendItems(rows.map { Item.person($0.id) }, toSection: .people)
        }
        if placeholders > 0 {
            snapshot.appendSections([.skeleton])
            snapshot.appendItems((0..<placeholders).map(Item.placeholder), toSection: .skeleton)
        }
        if isAppending {
            snapshot.appendSections([.paging])
            snapshot.appendItems([.paging], toSection: .paging)
        }

        // Animate only once there is something to animate *from*, and only
        // while on screen — an off-screen apply replays its animation the next
        // time the screen is pushed.
        dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
        hasRenderedContent = true

        // Rows already on screen keep their old closure and display model after
        // an in-place change (a follow toggle mutates the row, not the item id),
        // so the visible ones are re-configured explicitly.
        reconfigureVisibleRows(in: snapshot)
    }

    /// Re-applies the current display model to rows whose *identity* didn't
    /// change. A diffable snapshot compares item identifiers, and a row's
    /// identifier is its profile id — so a Follow→Following flip is invisible
    /// to the diff and would otherwise leave the old button on screen.
    private func reconfigureVisibleRows(in snapshot: NSDiffableDataSourceSnapshot<Section, Item>) {
        let visible = collectionView.indexPathsForVisibleItems.compactMap {
            dataSource.itemIdentifier(for: $0)
        }
        let refreshable = visible.filter { item in
            guard case .person = item else { return false }
            return snapshot.indexOfItem(item) != nil
        }
        guard !refreshable.isEmpty else { return }
        var updated = dataSource.snapshot()
        updated.reconfigureItems(refreshable)
        dataSource.apply(updated, animatingDifferences: false)
    }

    /// Removing a follower is destructive and silent on the other side, so it
    /// asks first and names the person — the same standard the profile's block
    /// action holds itself to.
    private func confirmRemoveFollower(_ row: ProfileRelationshipsViewModel.Row) {
        let sheet = UIAlertController(
            title: "Remove \(row.handle)?",
            message: "They'll stop following you. They aren't notified, and they can follow you again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.viewModel.removeFollower(row.id)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad: anchor to the row that spawned it.
        if let index = dataSource.indexPath(for: .person(row.id)),
           let cell = collectionView.cellForItem(at: index) {
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    /// How many loading rows it takes to reach the bottom of the screen from
    /// where the loaded ones stop — derived from the viewport rather than a
    /// fixed tally, so the shimmer runs to the bottom edge on every device.
    private func placeholderCount(after loadedRows: Int) -> Int {
        let viewport = collectionView.bounds.height - collectionView.adjustedContentInset.top
        return max(0, RelationshipSkeletonCell.rowsToFill(viewport) - loadedRows)
    }
}

extension ProfileRelationshipsViewController: UICollectionViewDelegate {
    /// Asks for the next page as the end of the list comes into view. Three
    /// rows of runway, so the page is usually in hand by the time the viewer
    /// arrives and the list simply continues; the view model absorbs the repeat
    /// calls this fires on every bounce.
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard case .person = dataSource.itemIdentifier(for: indexPath) else { return }
        let rowsInSection = collectionView.numberOfItems(inSection: indexPath.section)
        guard indexPath.item >= rowsInSection - 3 else { return }
        // Deferred by a runloop turn on purpose: asking here would land the
        // paging spinner's snapshot apply *inside* `willDisplay`, which UIKit
        // does not support — the collection view is mid-layout for the very
        // cell being handed to us.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.loadNextPageIfNeeded()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .person(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.rowTapped(id)
    }
}

private extension Array {
    /// A segmented control's selected index can be `NSNotFound` between
    /// configuration and first layout.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension ProfileRelationshipsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.searchQueryChanged(searchController.searchBar.text ?? "")
    }
}
