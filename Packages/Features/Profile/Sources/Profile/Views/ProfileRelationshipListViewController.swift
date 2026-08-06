import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One relationship list — Followers, or Following, or Friends — as a page in
/// the pager `ProfileRelationshipsViewController` hosts.
///
/// **Why three controllers rather than one list that swaps its contents.** The
/// screen used to be a single collection view re-snapshotted whenever the
/// segmented control changed, which is the right shape when only one list can
/// be on screen at a time. A pager makes that false: during a swipe two lists
/// are visible at once, and each has to be showing its own rows, its own empty
/// state, and its own scroll position. Those are exactly the things a view
/// controller owns, so each list gets one — including its own
/// `contentUnavailableConfiguration`, which is per-controller by construction.
///
/// The view model stays shared. All three pages read the same
/// `ProfileRelationshipsViewModel`, addressed by `direction`; a follow toggled
/// on one page is the same person on another, and the model already keeps
/// per-direction state for exactly that reason.
final class ProfileRelationshipListViewController: UIViewController {
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

    let direction: RelationshipDirection

    private let viewModel: ProfileRelationshipsViewModel
    private let imagePipeline: ImagePipeline?

    private var collectionView: UICollectionView!
    private let refreshControl = UIRefreshControl()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rowsByID: [ProfileID: ProfileRelationshipsViewModel.Row] = [:]
    private var phase: ProfileRelationshipsViewModel.Phase = .loading
    private var hasRenderedContent = false

    init(
        direction: RelationshipDirection,
        viewModel: ProfileRelationshipsViewModel,
        imagePipeline: ImagePipeline?
    ) {
        self.direction = direction
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        render(viewModel.phase(for: direction))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The skeleton runs to the bottom edge, and how many rows that takes
        // is a function of the viewport — which is not known until now.
        if case .loading = phase { render(phase) }
    }

    // MARK: - Setup

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
        // The pager owns horizontal motion; this list owns vertical. Stated so
        // a list that happens to be narrower than its content cannot start
        // competing for the pan that pages.
        collectionView.alwaysBounceHorizontal = false
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

    func render(_ phase: ProfileRelationshipsViewModel.Phase) {
        self.phase = phase
        guard isViewLoaded else { return }
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

extension ProfileRelationshipListViewController: UICollectionViewDelegate {
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
            guard let self else { return }
            self.viewModel.loadNextPageIfNeeded(for: self.direction)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .person(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.rowTapped(id)
    }
}
