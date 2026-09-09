import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The results screen's Users tab: the people a search matched.
///
/// ⚠️ THE SAME ROW THE REST OF THE APP USES. `PersonListCell` is what the
/// Messages inbox, its global search, the compose picker and the profile's
/// relationship lists all draw a person with — it moved to `DesignSystem` at
/// the third caller for exactly this reason. A search result is not a special
/// kind of person, so it is not a special kind of row.
@MainActor
final class SearchPeoplePage: UIViewController {
    /// What the page has to say, which is a projection of the search's phase —
    /// the tab knows nothing about typeahead or history.
    enum State {
        case loading
        case results([SearchResultDisplayModel])
        case empty(query: String)
        case failed(message: String)
    }

    var onSelect: ((ProfileID) -> Void)?

    private let imagePipeline: ImagePipeline
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ProfileID>!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusView = EmptyStateView()

    private var modelsByID: [ProfileID: SearchResultDisplayModel] = [:]
    private var avatarTasks: [ProfileID: Task<Void, Never>] = [:]

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureStatusViews()
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let registration = UICollectionView.CellRegistration<PersonListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let model = self.modelsByID[id] else { return }
            cell.configure(with: PersonRowContent(
                displayName: model.displayName,
                handle: model.handle,
                monogram: model.monogram,
                context: model.context
            ))
            self.loadAvatar(model.avatarURL, into: cell, for: id)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, ProfileID>(
            collectionView: collectionView
        ) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    private func configureStatusViews() {
        for subview in [spinner, statusView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
        spinner.hidesWhenStopped = true
        statusView.isHidden = true
    }

    /// How many people are on screen. The only thing a test can honestly
    /// observe about this page without reaching into cells.
    var rowCountForTesting: Int { dataSource.snapshot().numberOfItems }

    func render(_ state: State) {
        switch state {
        case .loading:
            spinner.startAnimating()
            statusView.isHidden = true

        case .results(let models):
            spinner.stopAnimating()
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            var snapshot = NSDiffableDataSourceSnapshot<Int, ProfileID>()
            if !models.isEmpty {
                snapshot.appendSections([0])
                snapshot.appendItems(models.map(\.id), toSection: 0)
            }
            // ⚠️ Rows that CARRY OVER are reconfigured by hand. Diffable
            // compares identifiers, and a profile id is stable — so a row whose
            // avatar or follow state resolved after it first appeared has an
            // empty diff, and the picture would never be drawn.
            let carried = Set(dataSource.snapshot().itemIdentifiers)
            let surviving = snapshot.itemIdentifiers.filter(carried.contains)
            if !surviving.isEmpty { snapshot.reconfigureItems(surviving) }
            dataSource.apply(snapshot, animatingDifferences: true)
            // ⚠️ AN EMPTY LIST HERE IS THE FILTER'S DOING, not the query's —
            // `.empty` is the phase for a query that matched nothing. Saying
            // "try different words" would blame the search for a scope the
            // viewer set themselves.
            if models.isEmpty {
                statusView.configure(
                    symbolName: "line.3.horizontal.decrease",
                    title: "Nothing in this scope",
                    subtitle: "The search found people, but none of them are in the "
                        + "scope you picked. Widen it to see the rest."
                )
                statusView.isHidden = false
            } else {
                statusView.isHidden = true
            }

        case .empty(let query):
            spinner.stopAnimating()
            dataSource.apply(NSDiffableDataSourceSnapshot<Int, ProfileID>(), animatingDifferences: true)
            statusView.configure(
                symbolName: "magnifyingglass",
                title: "No results",
                subtitle: "Nothing matched “\(query)”. Try different words."
            )
            statusView.isHidden = false

        case .failed(let message):
            spinner.stopAnimating()
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: "Couldn't search", subtitle: message
            )
            statusView.isHidden = false
        }
    }

    /// ⚠️ KEYED BY PERSON, NOT BY CELL. A cell is reused; a task started for
    /// the row that was there before must not paint the row that is there now.
    private func loadAvatar(_ url: URL?, into cell: PersonListCell, for id: ProfileID) {
        guard let url else { return }
        avatarTasks[id]?.cancel()
        avatarTasks[id] = Task { [weak self, weak cell] in
            guard let image = try? await self?.imagePipeline.image(for: url) else { return }
            guard let cell, !Task.isCancelled else { return }
            cell.setAvatarImage(image)
        }
    }
}

extension SearchPeoplePage: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect?(id)
    }
}
