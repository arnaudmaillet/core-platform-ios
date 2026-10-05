import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// Settings → Your Activity → Recently Deleted (#408, backend #663): the
/// active profile's deleted posts, newest first, each restorable for 30 days
/// after it was deleted. Restore from a tap (with confirmation) or a swipe.
final class RecentlyDeletedViewController: UIViewController {
    private enum Item: Hashable {
        case post(PostID)
        case loading
        case failed
        case empty
    }

    private let viewModel: RecentlyDeletedViewModel
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(viewModel: RecentlyDeletedViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = "Recently Deleted"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let footer = "Deleted posts stay here for 30 days, and only you can see them. After that, they can't be restored."

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let deleted = deletedPost(at: indexPath) else { return nil }
            let action = UIContextualAction(style: .normal, title: "Restore") { [weak self] _, _, done in
                self?.restore(deleted)
                done(true)
            }
            action.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [action])
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await viewModel.load() }
    }

    private func deletedPost(at indexPath: IndexPath) -> DeletedPost? {
        guard case .post(let id) = dataSource.itemIdentifier(for: indexPath),
              case .loaded(let posts) = viewModel.phase else { return nil }
        return posts.first { $0.post.id == id }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, indexPath, item in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            switch item {
            case .post:
                guard let deleted = deletedPost(at: indexPath) else { return }
                content.text = RecentlyDeletedViewModel.title(of: deleted)
                content.textProperties.numberOfLines = 2
                content.secondaryText = RecentlyDeletedViewModel.remaining(deleted)
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: deleted.post.kind == .text ? "text.alignleft" : "photo")
                content.imageProperties.tintColor = .secondaryLabel
                content.imageProperties.maximumSize = CGSize(width: 48, height: 48)
                content.imageProperties.reservedLayoutSize = CGSize(width: 48, height: 48)
                content.imageProperties.cornerRadius = 8
                if let url = deleted.post.thumbnailURL, let pipeline = imagePipeline {
                    Task { [weak cell] in
                        guard let image = try? await pipeline.image(for: url),
                              var current = cell?.contentConfiguration as? UIListContentConfiguration else { return }
                        current.image = image
                        cell?.contentConfiguration = current
                    }
                }
            case .loading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                content.text = "Couldn't load deleted posts. Tap to try again."
                content.textProperties.color = .secondaryLabel
            case .empty:
                content = .cell()
                content.text = "No recently deleted posts."
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = Self.footer
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch viewModel.phase {
        case .loading: snapshot.appendItems([.loading])
        case .failed: snapshot.appendItems([.failed])
        case .loaded(let posts) where posts.isEmpty: snapshot.appendItems([.empty])
        case .loaded(let posts): snapshot.appendItems(posts.map { .post($0.post.id) })
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func confirmRestore(_ deleted: DeletedPost, from indexPath: IndexPath) {
        let sheet = UIAlertController(
            title: "Restore this post?",
            message: "It goes back on your profile where it was.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            self?.restore(deleted)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func restore(_ deleted: DeletedPost) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.restore(deleted)
                ToastView.present("Post restored", symbol: "arrow.uturn.backward", in: view)
            } catch {
                let message = (error as? PostRestoreError) == .tooLate
                    ? "This post was deleted more than 30 days ago and can't be restored."
                    : "Couldn't restore this post. Try again."
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension RecentlyDeletedViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .post, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .post: if let deleted = deletedPost(at: indexPath) { confirmRestore(deleted, from: indexPath) }
        case .failed: Task { await viewModel.load() }
        default: break
        }
    }
}
