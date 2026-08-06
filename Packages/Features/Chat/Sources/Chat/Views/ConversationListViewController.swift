import CoreModels
import CoreNavigation
import UIKit

/// The inbox's "All" surface: every active direct message, with unread ones
/// marked in place — bold row, tinted dot, and a count on the tab itself.
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
    private let viewModel: ConversationListViewModel

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

    private var dataSource: SectionedConversationDataSource!
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

    /// Recomputes what the container should show for this surface: the count
    /// on its tab.
    private func publishChrome() {
        chrome = InboxSurfaceChrome(badgeCount: viewModel.newCount)
    }

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
        viewModel.onNewCountChange = { [weak self] _ in self?.publishChrome() }
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
        // No indicators on the inbox's pages either — the tabs sit above them
        // and each page keeps its own position, so a bar that flashes on every
        // switch reads as motion nobody asked for.
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.delegate = self
        tableView.register(
            InboxSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: InboxSectionHeaderView.reuseIdentifier
        )
        tableView.estimatedSectionHeaderHeight = 44
        // A plain table reserves ~22pt above every section header by default,
        // which under a floating pill is a band of nothing between the tab
        // capsule and the first row. The pill carries its own breathing room
        // (`SectionHeaderPillButton.Metrics.float`), so this is padding on top
        // of padding.
        tableView.sectionHeaderTopPadding = 0
        // No hairlines, matching every other people list in the app: a 48pt
        // disc and two lines of type already make each row its own object.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = SectionedConversationDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ConversationCell.reuseIdentifier, for: indexPath
            ) as! ConversationCell
            if let model = self?.modelsByID[id] { cell.configure(with: model) }
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

    private func render(_ phase: ConversationListViewModel.Phase) {
        switch phase {
        case .loading:
            skeletonView.isHidden = false
            tableView.isHidden = true
            statusView.isHidden = true
        case .content(let sections):
            refreshControl.endRefreshing()
            statusView.isHidden = true
            let models = sections.all
            var snapshot = NSDiffableDataSourceSnapshot<InboxListSection, ConversationID>()
            // Empty sections are never appended, so a list with no arrivals is
            // one plain list rather than a header over nothing.
            if !sections.new.isEmpty {
                snapshot.appendSections([.new])
                snapshot.appendItems(sections.new.map(\.id), toSection: .new)
            }
            if !sections.earlier.isEmpty {
                snapshot.appendSections([.earlier])
                snapshot.appendItems(sections.earlier.map(\.id), toSection: .earlier)
            }
            // Same-identity rows whose content changed (pin/mute flags, a read
            // that cleared the bold preview) re-render in place; identity
            // moves/removals animate, so swipe outcomes read as system row
            // animations, not reloads. See `InboxRowDiff`.
            snapshot.reconfigureItems(InboxRowDiff.changedRows(in: models, against: modelsByID))
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            // Animate only while visible. A change that arrives while a thread
            // is pushed over the inbox — reading one, say — would otherwise
            // play its row animation on the way back, turning a settled screen
            // into a moving one right after the pop.
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
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
    #if DEBUG
    /// `-inbox-tap-section new|recent` fires a header pill's own action ~2s in.
    ///
    /// A tap cannot be injected in the simulator, and driving one through
    /// CGEvent needs the Simulator window's geometry — which changes the moment
    /// the window is resized or reopened, and a mis-mapped tap looks exactly
    /// like a header that does not respond. This calls what the pill calls.
    private func runSectionTapDebugSequence() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-inbox-tap-section"),
              let name = arguments.dropFirst(index + 1).first
        else { return }
        let section: InboxListSection = name == "new" ? .new : .earlier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let target = dataSource.index(of: section) else { return }
            dataSource.scroll(tableView, toSectionAt: target)
        }
    }
    #endif
}

extension ConversationListViewController: UITableViewDelegate {
    // MARK: - Section headers

    /// The glass pill, and the tap that scrolls to the section it names.
    func tableView(_ tableView: UITableView, viewForHeaderInSection index: Int) -> UIView? {
        guard let section = dataSource.headedSection(at: index) else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: InboxSectionHeaderView.reuseIdentifier
        ) as? InboxSectionHeaderView
        header?.setTitle(section.title, leadsList: index == 0)
        // The section's own first row, so tapping "Recent" puts Recent under
        // the header rather than wherever the list happened to be.
        header?.onTap = { [weak self] in
            guard let self else { return }
            dataSource.scroll(tableView, toSectionAt: index)
        }
        return header
    }

    /// Zero for an unheaded list — a table gives an unclaimed plain-style
    /// section a default height even when its header view is nil, which would
    /// leave a blank band above a list that has no header at all.
    func tableView(_ tableView: UITableView, heightForHeaderInSection index: Int) -> CGFloat {
        dataSource.headedSection(at: index) == nil ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.didSelect(id)
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
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
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
        #if DEBUG
        runSectionTapDebugSequence()
        #endif
    }
}
