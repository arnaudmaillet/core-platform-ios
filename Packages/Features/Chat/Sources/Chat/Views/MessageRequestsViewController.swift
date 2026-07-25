import CoreModels
import CoreNavigation
import UIKit

/// The inbox's "Requests" surface: conversations from accounts the viewer
/// doesn't follow, each with its accept/decline decision on the row.
///
/// It renders from the same `InboxCatalog` as the conversation list, so a
/// decision here lands in All without a refetch, and the header's badge is
/// driven by the same projection that fills this table.
final class MessageRequestsViewController: UIViewController {
    fileprivate enum Section { case main }

    private let viewModel: MessageRequestsViewModel

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let skeletonView = ConversationListSkeletonView()
    private let statusView = InboxStatusView()

    private var dataSource: UITableViewDiffableDataSource<Section, ConversationID>!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    private var hasRenderedContent = false

    private(set) var chrome = InboxSurfaceChrome() {
        didSet { onChromeChange?(chrome) }
    }

    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    // MARK: - Batch actions

    /// Accept/Refuse in bulk — the same two decisions the rows carry, applied
    /// to a selection. Enabled only with one.
    private lazy var batchAcceptItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Accept",
            primaryAction: UIAction { [weak self] _ in self?.applyToSelection { $0.accept($1) } }
        )
        item.isEnabled = false
        return item
    }()

    private lazy var batchRefuseItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Refuse",
            primaryAction: UIAction { [weak self] _ in self?.applyToSelection { $0.decline($1) } }
        )
        item.tintColor = .systemRed
        item.isEnabled = false
        return item
    }()

    private lazy var cancelItem = UIBarButtonItem(
        title: "Cancel",
        primaryAction: UIAction { [weak self] _ in self?.setEditing(false, animated: true) }
    )

    private func publishChrome() {
        let hasSelection = !selectedIDs.isEmpty
        batchAcceptItem.isEnabled = hasSelection
        batchRefuseItem.isEnabled = hasSelection
        chrome = InboxSurfaceChrome(
            leadingBarItem: isEditing ? cancelItem : editButtonItem,
            trailingBarItems: isEditing ? [batchRefuseItem, batchAcceptItem] : [],
            badgeCount: viewModel.count,
            locksPaging: isEditing
        )
    }

    private var selectedIDs: [ConversationID] {
        (tableView.indexPathsForSelectedRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
    }

    private func applyToSelection(_ decide: (MessageRequestsViewModel, ConversationID) -> Void) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        for id in ids { decide(viewModel, id) }
        setEditing(false, animated: true)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        publishChrome()
    }

    init(viewModel: MessageRequestsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureTableView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        // The badge rides the same chrome the bar items do, so a count landing
        // while this surface is off screen can't drop its Edit item.
        viewModel.onCountChange = { [weak self] _ in self?.publishChrome() }
        publishChrome()
        render(.loading)
    }

    private func configureTableView() {
        tableView.register(MessageRequestCell.self, forCellReuseIdentifier: MessageRequestCell.reuseIdentifier)
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = EditableDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageRequestCell.reuseIdentifier, for: indexPath
            ) as! MessageRequestCell
            if let model = self?.modelsByID[id] { cell.configure(with: model) }
            // Decisions are captured per row: the diffable snapshot animates
            // the row out, so neither handler needs an index path.
            cell.onAccept = { [weak self] in self?.viewModel.accept(id) }
            cell.onDecline = { [weak self] in self?.viewModel.decline(id) }
            return cell
        }
    }

    private func configureStatusViews() {
        skeletonView.isHidden = true
        skeletonView.constrain(in: view) { parent in
            skeletonView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            skeletonView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            skeletonView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            skeletonView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        statusView.isHidden = true
        statusView.pin(to: view, relativeTo: .safeArea)
    }

    private func render(_ phase: MessageRequestsViewModel.Phase) {
        switch phase {
        case .loading:
            skeletonView.isHidden = false
            tableView.isHidden = true
            statusView.isHidden = true
        case .content(let models):
            refreshControl.endRefreshing()
            statusView.isHidden = true
            var snapshot = NSDiffableDataSourceSnapshot<Section, ConversationID>()
            snapshot.appendSections([.main])
            snapshot.appendItems(models.map(\.id), toSection: .main)
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent)
            hasRenderedContent = true
            revealContent()
        case .empty:
            refreshControl.endRefreshing()
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusView.configure(
                symbol: "tray",
                title: "No requests",
                message: "Messages from people you don't follow will wait here."
            )
            statusView.isHidden = false
        case .failed(let message):
            refreshControl.endRefreshing()
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusView.configure(symbol: "exclamationmark.triangle", title: "Something went wrong", message: message)
            statusView.isHidden = false
        }
    }

    /// Swaps the skeleton for the populated table — hydration in place, and
    /// only when the skeleton is actually on screen.
    private func revealContent() {
        guard !skeletonView.isHidden, view.window != nil else {
            skeletonView.isHidden = true
            tableView.isHidden = false
            return
        }
        UIView.transition(
            with: view, duration: 0.35, options: [.transitionCrossDissolve, .curveEaseInOut]
        ) {
            self.skeletonView.isHidden = true
            self.tableView.isHidden = false
        }
    }
}

extension MessageRequestsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // In multi-selection mode a tap is a selection, not navigation.
        if tableView.isEditing {
            publishChrome()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing { publishChrome() }
    }
}

// MARK: - InboxSurface

extension MessageRequestsViewController: InboxSurface {
    var category: MessagesCategory { .requests }

    /// The catalog is already loaded by the time this surface is reachable
    /// (the conversation list loads it on appear), so becoming active only
    /// asks for a refresh — which no-ops while one is in flight.
    func surfaceDidBecomeActive() {
        viewModel.refresh()
    }
}
