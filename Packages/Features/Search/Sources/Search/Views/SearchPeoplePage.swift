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
    /// One of the last rows came into view: the cue to fetch the next page of
    /// people, which arrives as a longer `.results` (#612).
    var onNearEnd: (() -> Void)?
    /// The failed state's Try Again (#798).
    var onRetry: (() -> Void)?
    /// How close to the end a row has to come into view to ask for more —
    /// early enough that the page usually lands before the end does.
    static let nearEndRowCount = 5
    /// A next page is on its way: the list ends on a spinner.
    private var isPaging = false

    private let imagePipeline: ImagePipeline
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ProfileID>!
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// The first query's wait, before there is a list to re-query over
    /// (charter P8): rows where the rows will be. A LATER query keeps its
    /// results on screen and the small spinner over them.
    private let skeleton = PersonListSkeletonView()
    private let statusView = EmptyStateView()

    private var modelsByID: [ProfileID: SearchResultDisplayModel] = [:]
    private let avatarLoads = RowAvatarLoads()

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
        // A provider rather than one fixed list: the footer (the paging
        // spinner, #612) exists only while a page is on its way, and a
        // footer that stayed would leave a blank band under the last row.
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.footerMode = self?.isPaging == true ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.keyboardDismissMode = .onDrag
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
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
            self.loadAvatar(model.avatarURL, into: cell)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, ProfileID>(
            collectionView: collectionView
        ) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        let footer = UICollectionView.SupplementaryRegistration<SearchPagingFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { _, _, _ in }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// The footer spinner, while a next page is fetched (#612).
    func setPaging(_ paging: Bool) {
        guard paging != isPaging else { return }
        isPaging = paging
        guard isViewLoaded else { return }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    /// Whether the list currently ends on the paging spinner.
    var isPagingForTesting: Bool { isPaging }

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
        skeleton.pin(to: view)
        skeleton.isHidden = true
    }

    private func showSkeleton(_ shown: Bool) {
        if shown {
            skeleton.showSkeleton()
        } else {
            skeleton.fadeOutSkeleton()
        }
    }

    /// How many people are on screen. The only thing a test can honestly
    /// observe about this page without reaching into cells.
    var rowCountForTesting: Int { dataSource.snapshot().numberOfItems }

    /// The handles this page is showing, in the order it is showing them.
    ///
    /// ⚠️ THIS IS WHERE A REFINED QUERY IS VISIBLE NOW. The results header used
    /// to carry the words in a field and a test could read its text; the header
    /// is a magnifier glyph, so what the page RENDERED is the only place the
    /// screen still shows which query it answered.
    var displayedHandlesForTesting: [String] {
        dataSource.snapshot().itemIdentifiers.compactMap { modelsByID[$0]?.handle }
    }

    #if DEBUG
    /// `-search-tap-user <index>` selects a row the way a finger would — the
    /// simulator injects no touches, and the only way to see what a tap does
    /// is to take the same path a tap takes.
    private var didTapForQA = false

    private func tapRowForQAIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-search-tap-user"),
              position + 1 < arguments.count,
              let row = Int(arguments[position + 1]),
              !didTapForQA
        else { return }
        didTapForQA = true
        // Marked done on the FIRST results, so the 2s beat still starts there —
        // but the tap now waits for the row it names. Those first results can
        // be a partial answer (fewer rows than the index), and the old
        // `guard … else { return }` then dropped the tap without a word and no
        // later render could retry it, since the flag was already set.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            QAWait.until("search-tap-user \(row)", { [weak self] in
                (self?.dataSource.snapshot().numberOfItems ?? 0) > row
            }) { [weak self] in
                guard let self else { return }
                self.collectionView(self.collectionView, didSelectItemAt: IndexPath(item: row, section: 0))
            }
        }
    }
    #endif

    func render(_ state: State) {
        switch state {
        case .loading:
            if dataSource.snapshot().numberOfItems == 0 {
                showSkeleton(true)
            } else {
                spinner.startAnimating()
            }
            statusView.isHidden = true

        case .results(let models):
            spinner.stopAnimating()
            showSkeleton(false)
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
            #if DEBUG
            tapRowForQAIfRequested()
            #endif
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
            showSkeleton(false)
            dataSource.apply(NSDiffableDataSourceSnapshot<Int, ProfileID>(), animatingDifferences: true)
            statusView.configure(
                symbolName: "magnifyingglass",
                title: "No results",
                subtitle: "Nothing matched “\(query)”. Try different words."
            )
            statusView.isHidden = false

        case .failed(let message):
            spinner.stopAnimating()
            showSkeleton(false)
            // ⚠️ The rows of the PREVIOUS answer go, as they do for `.empty`
            // (#798): left under the failure, they read as this query's
            // results, with a message over them saying there are none.
            dataSource.apply(NSDiffableDataSourceSnapshot<Int, ProfileID>(), animatingDifferences: true)
            statusView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't search",
                subtitle: message,
                actionTitle: "Try Again",
                actionHandler: { [weak self] in self?.onRetry?() }
            )
            statusView.isHidden = false
        }
    }

    /// ⚠️ KEYED BY CELL, NOT BY PERSON (#780). A cell is reused; a task
    /// started for the row that was there before must not paint the row that
    /// is there now. Keyed by person, nothing cancelled A's load when its cell
    /// was configured for B, and A's face landed on B's row after a fast
    /// scroll. See `RowAvatarLoads`.
    private func loadAvatar(_ url: URL?, into cell: PersonListCell) {
        avatarLoads.load(url, using: imagePipeline, for: cell) { [weak cell] image in
            cell?.setAvatarImage(image)
        }
    }
}

extension SearchPeoplePage: UICollectionViewDelegate {
    /// Paging (#612): one of the last rows coming into view asks for more.
    /// The view model ignores the ask when there is no next page, or one is
    /// already on its way.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              dataSource.snapshot().itemIdentifiers.suffix(Self.nearEndRowCount).contains(id) else { return }
        // Deferred: the next page's snapshot must not be applied from inside
        // this display pass.
        DispatchQueue.main.async { [weak self] in self?.onNearEnd?() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect?(id)
    }
}

/// The Users tab's footer while a next page is on its way: a spinner where
/// the next rows will be (#612).
final class SearchPagingFooterView: UICollectionReusableView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .tertiaryLabel
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        let height = heightAnchor.constraint(equalToConstant: 56)
        height.priority = .required - 1
        NSLayoutConstraint.activate([
            height,
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Loading more people"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.startAnimating()
    }
}
