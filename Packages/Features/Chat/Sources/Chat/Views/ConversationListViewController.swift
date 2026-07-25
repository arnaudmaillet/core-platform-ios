import CoreModels
import CoreNavigation
import UIKit

/// The inbox's "All" surface: active direct-message conversations.
///
/// It is a paged child of `MessagesInboxViewController`, which owns the only
/// navigation bar on screen — so the Edit/Cancel/Delete items are *published*
/// as `InboxSurfaceChrome` rather than written onto a `navigationItem` this
/// screen doesn't display.
///
/// Row management (pin, mute, delete) is reached through the long-press
/// context menu and multi-selection editing. There are deliberately no swipe
/// actions: the horizontal axis belongs to paging between inbox categories,
/// and a row that also claims it would make every page swipe a coin flip.
final class ConversationListViewController: UIViewController {
    fileprivate enum Section { case main }

    private let viewModel: ConversationListViewModel

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let skeletonView = ConversationListSkeletonView()
    private let statusView = InboxStatusView()

    private var dataSource: UITableViewDiffableDataSource<Section, ConversationID>!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    private var hasRenderedContent = false

    /// Builds the thread screen a context-menu long-press previews — injected
    /// by the feature builder so preview and push share one construction.
    var threadPreviewProvider: ((ConversationID) -> UIViewController)?

    // MARK: - InboxSurface chrome

    private(set) var chrome = InboxSurfaceChrome() {
        didSet { onChromeChange?(chrome) }
    }

    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    /// Recomputes what the container should show for this surface. Editing
    /// swaps in Cancel plus this tab's batch actions and freezes paging;
    /// otherwise the trailing slot stays empty so the inbox's own compose item
    /// shows through.
    private func publishChrome() {
        updateBatchItemState()
        chrome = InboxSurfaceChrome(
            leadingBarItem: isEditing ? cancelItem : editButtonItem,
            trailingBarItems: isEditing ? [batchDeleteItem, batchPinItem] : [],
            badgeCount: 0,
            locksPaging: isEditing
        )
    }

    /// Batch pin toggle. Its title follows the selection: an all-pinned
    /// selection offers "Unpin", anything else "Pin" — so the button always
    /// names what it is about to do rather than what the rows currently are.
    private lazy var batchPinItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Pin",
            primaryAction: UIAction { [weak self] _ in self?.togglePinOnSelectedRows() }
        )
        item.isEnabled = false
        return item
    }()

    /// Batch delete for multi-selection mode, enabled only with a non-empty
    /// selection.
    private lazy var batchDeleteItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Delete",
            primaryAction: UIAction { [weak self] _ in self?.deleteSelectedRows() }
        )
        item.tintColor = .systemRed
        item.isEnabled = false
        return item
    }()

    /// Native "Cancel" shown in place of the Edit/Done toggle while editing;
    /// leaves multi-selection (deletes already commit immediately via the
    /// trailing Delete item, so there's nothing to discard).
    private lazy var cancelItem = UIBarButtonItem(
        title: "Cancel",
        primaryAction: UIAction { [weak self] _ in self?.setEditing(false, animated: true) }
    )

    init(viewModel: ConversationListViewModel) {
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
        publishChrome()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        render(.loading)

        #if DEBUG
        // `-chat-pin-demo` pins the LAST row ~2s in — swipes can't be
        // injected in-sim; shows the pinned tint and the reorder-to-top.
        if ProcessInfo.processInfo.arguments.contains("-chat-pin-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let id = self.dataSource.snapshot().itemIdentifiers.last else { return }
                self.viewModel.togglePin(id)
            }
        }
        // `-chat-preview-demo` presents the context-menu preview
        // construction (`.preview` mode) as a sheet ~2s in — long-presses
        // can't be injected in-sim; verifies the stripped compose bar and
        // the live transcript.
        if ProcessInfo.processInfo.arguments.contains("-chat-preview-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let id = self.dataSource.snapshot().itemIdentifiers.first,
                      let make = self.threadPreviewProvider else { return }
                self.present(make(id), animated: true)
            }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.viewWillAppear()
    }

    private func configureTableView() {
        tableView.register(ConversationCell.self, forCellReuseIdentifier: ConversationCell.reuseIdentifier)
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        // Native multi-selection: editing mode shows the system's circled
        // checkmarks, animated in by `setEditing` — no custom selection UI.
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = EditableDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ConversationCell.reuseIdentifier, for: indexPath
            ) as! ConversationCell
            if let model = self?.modelsByID[id] { cell.configure(with: model) }
            return cell
        }
    }

    // MARK: - Editing (multi-selection)

    /// `editButtonItem` (and the `Cancel` item) funnel here. While editing, the
    /// leading toggle becomes a native `Cancel` and the trailing slot becomes
    /// this tab's batch actions; UIKit animates the selection affordances and
    /// clears any selection when the mode ends, so exit needs no manual
    /// cleanup beyond republishing the chrome.
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        publishChrome()
    }

    private var selectedIDs: [ConversationID] {
        (tableView.indexPathsForSelectedRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
    }

    private func deleteSelectedRows() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        viewModel.delete(Set(ids))
        setEditing(false, animated: true)
    }

    /// Pins the selection, or unpins it when every selected row is already
    /// pinned — the same rule the button's title states.
    private func togglePinOnSelectedRows() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let shouldUnpin = ids.allSatisfy { viewModel.isPinned($0) }
        for id in ids where viewModel.isPinned(id) == shouldUnpin {
            viewModel.togglePin(id)
        }
        setEditing(false, animated: true)
    }

    /// Batch actions are meaningless without a selection, and the pin item
    /// has to re-title itself as the selection changes.
    private func updateBatchItemState() {
        let ids = selectedIDs
        batchDeleteItem.isEnabled = !ids.isEmpty
        batchPinItem.isEnabled = !ids.isEmpty
        batchPinItem.title = !ids.isEmpty && ids.allSatisfy { viewModel.isPinned($0) } ? "Unpin" : "Pin"
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

    private func render(_ phase: ConversationListViewModel.Phase) {
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
            // Same-identity rows whose content changed (pin/mute flags)
            // re-render in place; identity moves/removals animate, so swipe
            // outcomes read as system row animations, not reloads.
            snapshot.reconfigureItems(models.filter { modelsByID[$0.id] != nil && modelsByID[$0.id] != $0 }.map(\.id))
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent)
            hasRenderedContent = true
            revealContent()
        case .empty:
            refreshControl.endRefreshing()
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusView.configure(
                symbol: "bubble.left.and.bubble.right",
                title: "No conversations yet",
                message: "Start one from someone's profile, or tap the compose button."
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

    /// Swaps the skeleton for the populated table. The rows are applied
    /// before this runs, so the cross-dissolve is hydration in place; the
    /// dissolve only fires when actually leaving the skeleton on screen.
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

extension ConversationListViewController: UITableViewDelegate {
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

    // MARK: - Context menu (haptic long-press)

    /// The table's native `UIContextMenuInteraction` seam: long-press lifts
    /// the row, previews the actual thread screen, and lists the same
    /// management actions the swipes expose.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let makePreview = threadPreviewProvider
        return UIContextMenuConfiguration(
            identifier: id.rawValue as NSString,
            previewProvider: makePreview.map { make in { make(id) } },
            actionProvider: { [weak self] _ in self?.contextMenu(for: id) }
        )
    }

    /// Tapping the lifted preview commits to the real thing — through the
    /// same route seam as a row tap, once the dismissal animation completes.
    func tableView(
        _ tableView: UITableView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let raw = configuration.identifier as? String else { return }
        animator.addCompletion { [weak self] in
            self?.viewModel.didSelect(ConversationID(raw))
        }
    }

    private func contextMenu(for id: ConversationID) -> UIMenu {
        let isPinned = viewModel.isPinned(id)
        let isMuted = viewModel.isMuted(id)
        let pin = UIAction(
            title: isPinned ? "Unpin" : "Pin",
            image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
        ) { [weak self] _ in self?.viewModel.togglePin(id) }
        let mute = UIAction(
            title: isMuted ? "Unmute" : "Mute",
            image: UIImage(systemName: isMuted ? "bell" : "bell.slash")
        ) { [weak self] _ in self?.viewModel.toggleMute(id) }
        let delete = UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.viewModel.delete([id]) }
        // Destructive action in its own inline section, per system menus.
        return UIMenu(children: [pin, mute, UIMenu(options: .displayInline, children: [delete])])
    }
}

// MARK: - InboxSurface

extension ConversationListViewController: InboxSurface {
    var category: MessagesCategory { .all }

    /// Paging back here re-checks for new messages. `refresh()` no-ops while a
    /// load is already in flight, so this is free on the appear path.
    func surfaceDidBecomeActive() {
        viewModel.refresh()
    }
}
