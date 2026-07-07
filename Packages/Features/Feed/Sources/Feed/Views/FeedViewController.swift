import CoreMedia
import CoreModels
import DesignSystem
import UIKit

final class FeedViewController: UIViewController {
    private enum Section {
        case main
    }

    private let viewModel: FeedViewModel
    private let imagePipeline: ImagePipeline

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, PostID>!
    private let refreshControl = UIRefreshControl()
    private let coldBanner = ColdBannerView()
    private let statusLabel = UILabel()

    /// id → display model; `sizeForItemAt` is a lookup here, never a measurement.
    private var modelsByID: [PostID: FeedItemDisplayModel] = [:]
    private var orderedIDs: [PostID] = []

    init(viewModel: FeedViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Timeline"
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureAuxiliaryViews()

        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    private var didStartLoading = false
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Width is only known here; kick the first load exactly once.
        if !didStartLoading, view.bounds.width > 0 {
            didStartLoading = true
            viewModel.viewDidLoad(layoutWidth: view.bounds.width)
        }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.estimatedItemSize = .zero // sizes come precomputed; never self-size

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.isPrefetchingEnabled = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseIdentifier)
        collectionView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl

        let pipeline = imagePipeline
        dataSource = UICollectionViewDiffableDataSource<Section, PostID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: FeedCell.reuseIdentifier,
                for: indexPath
            ) as! FeedCell
            if let self, let model = self.modelsByID[id] {
                cell.configure(with: model, engagement: self.viewModel.engagementState(for: id), pipeline: pipeline)
                cell.onLikeTapped = { [weak self] id in self?.viewModel.toggleLike(for: id) }
                cell.onAuthorTapped = { [weak self] authorID in self?.viewModel.didTapAuthor(authorID) }
            }
            return cell
        }

        viewModel.onEngagementChange = { [weak self] id, state in
            self?.updateVisibleEngagement(for: id, state: state)
        }
    }

    /// Live path: touch only the affected on-screen cell's engagement bar.
    private func updateVisibleEngagement(for id: PostID, state: FeedViewModel.EngagementState) {
        guard let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? FeedCell else { return }
        cell.updateEngagement(state)
    }

    private func configureAuxiliaryViews() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.xl)
        }

        coldBanner.isHidden = true
        coldBanner.constrain(in: view) { parent in
            coldBanner.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
            coldBanner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
        }
    }

    // MARK: - Rendering

    private func render(_ state: FeedViewModel.RenderState) {
        refreshControl.endRefreshing()

        orderedIDs = state.items.map(\.id)
        modelsByID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, PostID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(orderedIDs)
        dataSource.apply(snapshot, animatingDifferences: false)

        switch state.phase {
        case .loading:
            statusLabel.isHidden = true
        case .content:
            statusLabel.isHidden = true
        case .empty:
            statusLabel.text = "Nothing here yet.\nFollow people to fill your timeline."
            statusLabel.isHidden = false
        case .failed(let message):
            statusLabel.text = message
            statusLabel.isHidden = false
        }

        coldBanner.isHidden = !state.isColdRefreshing
    }

    private func prefetchURLs(for indexPaths: [IndexPath]) -> [URL] {
        indexPaths.compactMap { orderedIDs.indices.contains($0.item) ? modelsByID[orderedIDs[$0.item]] : nil }
            .flatMap { [$0.avatarURL, $0.mediaURL] }
            .compactMap(\.self)
    }
}

// MARK: - Delegates

extension FeedViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard indexPath.item < orderedIDs.count, let model = modelsByID[orderedIDs[indexPath.item]] else {
            return CGSize(width: collectionView.bounds.width, height: 44)
        }
        return CGSize(width: collectionView.bounds.width, height: model.height)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        viewModel.willDisplayItem(at: indexPath.item)
    }
}

extension FeedViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let urls = prefetchURLs(for: indexPaths)
        let pipeline = imagePipeline
        Task { await pipeline.prefetch(urls) }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let urls = prefetchURLs(for: indexPaths)
        let pipeline = imagePipeline
        Task { await pipeline.cancelPrefetch(urls) }
    }
}

/// Small floating pill shown while the backend reports a cold (cache-warming) feed.
private final class ColdBannerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor

        let label = UILabel()
        label.text = "Catching up on your timeline…"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.constrain(in: self) { parent in
            label.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.md)
            label.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
            label.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xs + 2)
            label.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -(Spacing.xs + 2))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
