import CoreModels
import UIKit

final class ConversationListViewController: UIViewController {
    fileprivate enum Section { case main }

    private let viewModel: ConversationListViewModel

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let skeletonView = ConversationListSkeletonView()
    private let statusLabel = UILabel()

    private var dataSource: UITableViewDiffableDataSource<Section, ConversationID>!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    private var hasRenderedContent = false

    /// Builds the thread screen a context-menu long-press previews — injected
    /// by the feature builder so preview and push share one construction.
    var threadPreviewProvider: ((ConversationID) -> UIViewController)?

    /// Native system bar item (the bar supplies the glass bubble and
    /// safe-area placement); the action rides the same route seam as row
    /// selection, so the contact-selection flow lands resolver-side.
    private lazy var composeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.viewModel.didTapCompose() }
        )
        item.accessibilityLabel = "New Message"
        return item
    }()

    /// Batch delete for multi-selection mode; swapped in for compose while
    /// editing, enabled only with a non-empty selection.
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
        title = "Messages"
        view.backgroundColor = .systemBackground
        // The system's own edit toggle: it drives `setEditing(_:animated:)`
        // and swaps its Edit/Done title itself — no state to hand-manage.
        navigationItem.leftBarButtonItem = editButtonItem
        navigationItem.rightBarButtonItem = composeItem
        configureTableView()
        configureStatusViews()

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

        dataSource = EditableDataSource(tableView: tableView) {
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
    /// leading toggle becomes a native `Cancel` and the trailing compose item
    /// becomes batch `Delete`; UIKit animates the selection affordances and
    /// clears any selection when the mode ends, so exit needs no manual cleanup
    /// beyond restoring the bar.
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        batchDeleteItem.isEnabled = false
        navigationItem.leftBarButtonItem = editing ? cancelItem : editButtonItem
        navigationItem.rightBarButtonItem = editing ? batchDeleteItem : composeItem
    }

    private func deleteSelectedRows() {
        guard let selected = tableView.indexPathsForSelectedRows, !selected.isEmpty else { return }
        let ids = selected.compactMap { dataSource.itemIdentifier(for: $0) }
        viewModel.delete(Set(ids))
        batchDeleteItem.isEnabled = false
    }

    private func updateBatchDeleteState() {
        batchDeleteItem.isEnabled = !(tableView.indexPathsForSelectedRows ?? []).isEmpty
    }

    private func configureStatusViews() {
        skeletonView.isHidden = true
        skeletonView.constrain(in: view) { parent in
            skeletonView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            skeletonView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            skeletonView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            skeletonView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
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

    private func render(_ phase: ConversationListViewModel.Phase) {
        switch phase {
        case .loading:
            skeletonView.isHidden = false
            tableView.isHidden = true
            statusLabel.isHidden = true
        case .content(let models):
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
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
            statusLabel.text = "No conversations yet."
            statusLabel.isHidden = false
        case .failed(let message):
            refreshControl.endRefreshing()
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
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
            updateBatchDeleteState()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing { updateBatchDeleteState() }
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

    // MARK: - Swipe actions

    /// Leading: Pin/Unpin (Messages-style), full swipe commits it.
    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let isPinned = viewModel.isPinned(id)
        let pin = UIContextualAction(style: .normal, title: isPinned ? "Unpin" : "Pin") {
            [weak self] _, _, completion in
            self?.viewModel.togglePin(id)
            completion(true)
        }
        pin.image = UIImage(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemYellow
        return UISwipeActionsConfiguration(actions: [pin])
    }

    /// Trailing: Delete (destructive — the system's red, and the full-swipe
    /// default) then Mute.
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }

        let delete = UIContextualAction(style: .destructive, title: "Delete") {
            [weak self] _, _, completion in
            self?.viewModel.delete([id])
            completion(true)
        }
        delete.image = UIImage(systemName: "trash.fill")

        let isMuted = viewModel.isMuted(id)
        let mute = UIContextualAction(style: .normal, title: isMuted ? "Unmute" : "Mute") {
            [weak self] _, _, completion in
            self?.viewModel.toggleMute(id)
            completion(true)
        }
        mute.image = UIImage(systemName: isMuted ? "bell.fill" : "bell.slash.fill")
        mute.backgroundColor = .systemIndigo

        return UISwipeActionsConfiguration(actions: [delete, mute])
    }
}

/// Diffable data sources report rows as non-editable by default, which
/// disables both swipe actions and editing-mode selection — opt every row in.
private final class EditableDataSource: UITableViewDiffableDataSource<
    ConversationListViewController.Section, ConversationID
> {
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }
}
