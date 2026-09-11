import CoreStorage
import DesignSystem
import UIKit

/// The drafts the viewer kept, pushed inside the Text Post sheet from its
/// "Drafts" button. Tapping one opens it in the composer; swiping deletes it.
final class TextPostDraftsViewController: UIViewController {
    private let store: PostDraftStore
    /// The draft tapped — the composer opens it and brings itself back.
    var onSelect: ((PostDraft) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let emptyState = EmptyStateView()
    private let observers = NotificationObserverTokenBag()

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    init(store: PostDraftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "Drafts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureList()
        emptyState.configure(
            symbolName: "doc.text",
            title: "No drafts",
            subtitle: "Posts you save as drafts appear here."
        )
        emptyState.isUserInteractionEnabled = false
        emptyState.pin(to: view)
        observers.tokens = [
            NotificationCenter.default.addObserver(
                forName: PostDraftStore.didChangeNotification, object: store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload(animated: true) }
            },
        ]
        reload(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The composer's footer is the composer's.
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                self?.store.delete(id)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [delete])
        }
        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.pin(to: view)

        let store = store
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, id in
            guard let draft = store.draft(id) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = draft.text
            content.textProperties.numberOfLines = 3
            let saved = Date(timeIntervalSince1970: TimeInterval(draft.updatedAtMS) / 1000)
            content.secondaryText = "Saved " + Self.ageFormatter.localizedString(for: saved, relativeTo: Date())
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: id)
        }
    }

    private func reload(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(store.drafts.map(\.id))
        // A draft saved in place keeps its id and changes its text: without a
        // reconfigure its row would keep the old words.
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(store.drafts.map(\.id).filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: animated)
        emptyState.isHidden = !store.drafts.isEmpty
    }
}

extension TextPostDraftsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let draft = store.draft(id) else { return }
        onSelect?(draft)
    }
}
