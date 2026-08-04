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
    private let viewModel: MessageRequestsViewModel

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let skeletonView = ConversationListSkeletonView()
    private let statusView = InboxStatusView()

    private var dataSource: SectionedConversationDataSource!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    private var hasRenderedContent = false

    private(set) var chrome = InboxSurfaceChrome() {
        didSet { onChromeChange?(chrome) }
    }

    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    // MARK: - Chrome

    private func publishChrome() {
        chrome = InboxSurfaceChrome(badgeCount: viewModel.newCount)
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
        // Published from off screen too — a request landing while the viewer is
        // on another tab is exactly what the badge is for.
        viewModel.onNewCountChange = { [weak self] _ in self?.publishChrome() }
        publishChrome()
        render(.loading)
    }

    private func configureTableView() {
        tableView.register(MessageRequestCell.self, forCellReuseIdentifier: MessageRequestCell.reuseIdentifier)
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = SectionedConversationDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageRequestCell.reuseIdentifier, for: indexPath
            ) as! MessageRequestCell
            if let model = self?.modelsByID[id] { cell.configure(with: model) }
            // Decisions are captured per row: the diffable snapshot animates
            // the row out, so neither handler needs an index path.
            cell.onAccept = { [weak self] in self?.viewModel.accept(id) }
            cell.onDismiss = { [weak self] in self?.viewModel.decline(id) }
            return cell
        }
        dataSource.titles = [.new: "New Requests", .earlier: "Earlier"]
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
        case .content(let sections):
            refreshControl.endRefreshing()
            statusView.isHidden = true
            var snapshot = NSDiffableDataSourceSnapshot<InboxListSection, ConversationID>()
            if !sections.new.isEmpty {
                snapshot.appendSections([.new])
                snapshot.appendItems(sections.new.map(\.id), toSection: .new)
            }
            if !sections.earlier.isEmpty {
                snapshot.appendSections([.earlier])
                snapshot.appendItems(sections.earlier.map(\.id), toSection: .earlier)
            }
            modelsByID = Dictionary(uniqueKeysWithValues: sections.all.map { ($0.id, $0) })
            // Animate only while visible — an off-screen change would replay
            // its animation after the next transition.
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
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
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
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

    /// Leaving is what clears this tab's badge — see `didLeave`.
    func surfaceWillResignActive() {
        viewModel.didLeave()
    }
}
