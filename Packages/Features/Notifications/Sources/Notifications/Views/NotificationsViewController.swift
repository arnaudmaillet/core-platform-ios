import DesignSystem
import UIKit

final class NotificationsViewController: UIViewController {
    private enum Section { case main }

    private let viewModel: NotificationsViewModel

    /// ⚠️ Built with its horizontal indicator off explicitly. The app-wide
    /// appearance default (`ScrollIndicatorStyle`) covers the vertical one and
    /// covers collection views entirely, but `UITableView` sets
    /// `showsHorizontalScrollIndicator` on itself at init, and an instance
    /// value outranks an appearance default.
    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.showsHorizontalScrollIndicator = false
        return table
    }()
    private let refreshControl = UIRefreshControl()
    /// Rows where the rows will be, until the first page lands (charter P8).
    private let skeleton = PersonListSkeletonView(avatarSize: 40, showsTrailingBone: true)
    private let statusLabel = UILabel()
    private lazy var markAllReadButton = UIBarButtonItem(
        title: "Mark all read",
        primaryAction: UIAction { [weak self] _ in self?.viewModel.markAllRead() }
    )

    private var dataSource: UITableViewDiffableDataSource<Section, String>!
    private var modelsByID: [String: NotificationDisplayModel] = [:]

    init(viewModel: NotificationsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Activity"
        view.backgroundColor = .systemBackground
        configureNavigationBar()
        configureTableView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onHasUnreadChange = { [weak self] hasUnread in self?.markAllReadButton.isEnabled = hasUnread }
        render(.loading)
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        markAllReadButton.isEnabled = false
        navigationItem.rightBarButtonItem = markAllReadButton
    }

    private func configureTableView() {
        tableView.register(NotificationCell.self, forCellReuseIdentifier: NotificationCell.reuseIdentifier)
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        tableView.prefersClearTopEdge()
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = UITableViewDiffableDataSource<Section, String>(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationCell.reuseIdentifier, for: indexPath
            ) as! NotificationCell
            if let model = self?.modelsByID[id] {
                cell.configure(with: model)
            }
            return cell
        }
    }

    private func configureStatusViews() {
        skeleton.pin(to: view)
        skeleton.isHidden = true

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

    private func render(_ phase: NotificationsViewModel.Phase) {
        switch phase {
        case .loading:
            // A pull-to-refresh keeps its own indicator and its rows; only a
            // first load, with nothing to show, wears the skeleton.
            if !refreshControl.isRefreshing {
                skeleton.isHidden = false
                skeleton.alpha = 1
                tableView.isHidden = true
            }
            statusLabel.isHidden = true
        case .content(let models):
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            tableView.isHidden = false
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            apply(models.map(\.id))
            dismissSkeleton()
        case .empty:
            refreshControl.endRefreshing()
            tableView.isHidden = true
            dismissSkeleton()
            showStatus("No activity yet.")
        case .failed(let message):
            refreshControl.endRefreshing()
            tableView.isHidden = true
            dismissSkeleton()
            showStatus(message)
        }
    }

    /// Bones out, rows in: a cross-fade, never a pop (charter P10).
    private func dismissSkeleton() {
        guard !skeleton.isHidden else { return }
        UIView.animate(withDuration: 0.25) {
            self.skeleton.alpha = 0
        } completion: { _ in
            self.skeleton.isHidden = true
        }
    }

    private func apply(_ ids: [String]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }
}

extension NotificationsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
    }
}
