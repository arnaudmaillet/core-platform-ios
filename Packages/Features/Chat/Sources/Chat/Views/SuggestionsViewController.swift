import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// The inbox's "Suggestions" surface: accounts worth following, each with an
/// inline follow and a dismiss.
///
/// Loads lazily — a viewer who never swipes this far never pays for the social
/// graph fan-out behind it.
final class SuggestionsViewController: UIViewController {
    fileprivate enum Section { case main }

    private let viewModel: SuggestionsViewModel
    private let imagePipeline: ImagePipeline?

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
    private let skeletonView = ConversationListSkeletonView()
    private let statusView = InboxStatusView()

    private var dataSource: UITableViewDiffableDataSource<Section, ProfileID>!
    private var modelsByID: [ProfileID: SuggestionDisplayModel] = [:]
    private var hasRenderedContent = false

    /// Suggestions contributes no bar items and never changes: every row
    /// carries its own Follow and dismiss, and there is no bulk operation over
    /// a list the viewer is meant to skim. The container's compose item shows
    /// through, so this is a constant and `onChromeChange` never fires.
    let chrome = InboxSurfaceChrome()
    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    init(viewModel: SuggestionsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
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
        render(.loading)
    }

    private func configureTableView() {
        tableView.register(SuggestionCell.self, forCellReuseIdentifier: SuggestionCell.reuseIdentifier)
        // No indicators on the inbox's pages either — the tabs sit above them
        // and each page keeps its own position, so a bar that flashes on every
        // switch reads as motion nobody asked for.
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.delegate = self
        // No hairlines, matching every other people list in the app: a 48pt
        // disc and two lines of type already make each row its own object.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = UITableViewDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SuggestionCell.reuseIdentifier, for: indexPath
            ) as! SuggestionCell
            if let model = self?.modelsByID[id] {
                cell.configure(with: model, imagePipeline: self?.imagePipeline)
            }
            cell.onToggleFollow = { [weak self] in self?.viewModel.toggleFollow(id) }
            cell.onDismiss = { [weak self] in self?.viewModel.dismiss(id) }
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

    private func render(_ phase: SuggestionsViewModel.Phase) {
        switch phase {
        case .loading:
            skeletonView.isHidden = false
            tableView.isHidden = true
            statusView.isHidden = true
        case .content(let models):
            refreshControl.endRefreshing()
            statusView.isHidden = true
            var snapshot = NSDiffableDataSourceSnapshot<Section, ProfileID>()
            snapshot.appendSections([.main])
            snapshot.appendItems(models.map(\.id), toSection: .main)
            // Follow state changes in place; only dismissals move rows, so the
            // follow flip reads as a button toggling rather than a reload.
            snapshot.reconfigureItems(models.filter { modelsByID[$0.id] != nil && modelsByID[$0.id] != $0 }.map(\.id))
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
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
                symbol: "person.2",
                title: "No suggestions right now",
                message: "Follow a few accounts and we'll find people you might know."
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

extension SuggestionsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
    }

    /// The long-press menu carries the action the row has no room for: this is
    /// the Messages tab, so starting a DM belongs here.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(
            identifier: id.rawValue as NSString,
            previewProvider: nil
        ) { [weak self] _ in
            guard let self else { return nil }
            let isFollowing = self.viewModel.isFollowing(id)
            let message = UIAction(title: "Message", image: UIImage(systemName: "bubble.left")) {
                [weak self] _ in self?.viewModel.message(id)
            }
            let follow = UIAction(
                title: isFollowing ? "Unfollow" : "Follow",
                image: UIImage(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
            ) { [weak self] _ in self?.viewModel.toggleFollow(id) }
            let hide = UIAction(
                title: "Not interested",
                image: UIImage(systemName: "hand.thumbsdown"),
                attributes: .destructive
            ) { [weak self] _ in self?.viewModel.dismiss(id) }
            return UIMenu(children: [message, follow, UIMenu(options: .displayInline, children: [hide])])
        }
    }
}

// MARK: - InboxSurface

extension SuggestionsViewController: InboxSurface {
    var category: MessagesCategory { .suggestions }

    func surfaceDidBecomeActive() {
        viewModel.loadIfNeeded()
    }
}
