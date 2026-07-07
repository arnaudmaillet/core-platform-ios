import CoreModels
import UIKit

final class SearchViewController: UIViewController {
    private enum Section { case main }

    private let viewModel: SearchViewModel

    private let searchController = UISearchController(searchResultsController: nil)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    private var dataSource: UITableViewDiffableDataSource<Section, ProfileSearchResult.ID>!
    private var modelsByID: [ProfileSearchResult.ID: SearchResultDisplayModel] = [:]

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        view.backgroundColor = .systemBackground
        configureSearchController()
        configureTableView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in
            self?.render(phase)
        }
        render(.idle)

        #if DEBUG
        // Dev convenience: `-search-query <text>` seeds the field on launch, so
        // the results path is testable without driving the keyboard.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-search-query"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let seeded = ProcessInfo.processInfo.arguments[index + 1]
            searchController.searchBar.text = seeded
            viewModel.queryChanged(seeded)
        }
        #endif
    }

    // MARK: - Setup

    private func configureSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search people"
        searchController.searchBar.autocapitalizationType = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func configureTableView() {
        tableView.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.pin(to: view)

        dataSource = UITableViewDiffableDataSource<Section, ProfileSearchResult.ID>(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SearchResultCell.reuseIdentifier, for: indexPath
            ) as! SearchResultCell
            if let model = self?.modelsByID[id] {
                cell.configure(with: model)
            }
            return cell
        }
    }

    private func configureStatusViews() {
        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: SearchViewModel.Phase) {
        switch phase {
        case .idle:
            spinner.stopAnimating()
            apply([])
            showStatus("Search for people by name or @handle.")

        case .loading:
            spinner.startAnimating()
            statusLabel.isHidden = true

        case .results(let models):
            spinner.stopAnimating()
            statusLabel.isHidden = true
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            apply(models.map(\.id))

        case .empty(let query):
            spinner.stopAnimating()
            apply([])
            showStatus("No people found for “\(query)”.")

        case .failed(let message):
            spinner.stopAnimating()
            apply([])
            showStatus(message)
        }
    }

    private func apply(_ ids: [ProfileSearchResult.ID]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ProfileSearchResult.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }
}

extension SearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.queryChanged(searchController.searchBar.text ?? "")
    }
}

extension SearchViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelectResult(id)
    }
}
