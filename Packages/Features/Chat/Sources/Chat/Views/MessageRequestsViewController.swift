import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// The inbox's "Requests" surface: conversations from accounts the viewer
/// doesn't follow, each with its accept/decline decision on the row.
///
/// It renders from the same `InboxCatalog` as the conversation list, so a
/// decision here lands in All without a refetch, and the header's badge is
/// driven by the same projection that fills this table.
final class MessageRequestsViewController: UIViewController {
    private let viewModel: MessageRequestsViewModel

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

    private(set) var chrome = InboxSurfaceChrome() {
        didSet { onChromeChange?(chrome) }
    }

    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    // MARK: - Chrome

    private func publishChrome() {
        chrome = InboxSurfaceChrome(badgeCount: viewModel.newCount)
    }

    /// Builds the thread screen shown in a long-press preview. Supplied by the
    /// composition root, exactly as the All tab's is — the peek is the real
    /// screen in `.preview` mode, not a facsimile.
    var threadPreviewProvider: ((ConversationID) -> UIViewController)?
    private let imagePipeline: ImagePipeline?
    private let avatars: (any PeerAvatarProviding)?

    init(
        viewModel: MessageRequestsViewModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.avatars = avatars
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
        tableView.estimatedRowHeight = 84
        tableView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        dataSource = SectionedConversationDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageRequestCell.reuseIdentifier, for: indexPath
            ) as! MessageRequestCell
            if let self, let model = self.modelsByID[id] {
                cell.configure(with: model, imagePipeline: self.imagePipeline, avatars: self.avatars)
            }
            // Decisions are captured per row: the diffable snapshot animates
            // the row out, so neither handler needs an index path.
            cell.onAccept = { [weak self] in self?.viewModel.accept(id) }
            cell.onDismiss = { [weak self] in self?.viewModel.decline(id) }
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
            // Same-identity rows whose content changed re-render in place —
            // reading a request clears its bold preview and its count without
            // moving it. See `InboxRowDiff`.
            let models = sections.all
            snapshot.reconfigureItems(InboxRowDiff.changedRows(in: models, against: modelsByID))
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

extension MessageRequestsViewController: UITableViewDelegate {
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

    /// The same seam the All tab uses: long-press lifts the row and previews
    /// the actual thread screen through `threadPreviewProvider`.
    ///
    /// ⚠️ The MENU differs, and has to. A request is not yet a conversation —
    /// it cannot be pinned or muted, and the view model exposes no such calls.
    /// What a request offers is the decision it is waiting on, which is also
    /// what its row's two buttons offer.
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

    /// Tapping the lifted preview commits to the real thing, through the same
    /// route seam as a row tap.
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
        let accept = UIAction(
            title: "Accept",
            image: UIImage(systemName: "checkmark")
        ) { [weak self] _ in self?.viewModel.accept(id) }
        let decline = UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.viewModel.decline(id) }
        return UIMenu(children: [accept, decline])
    }
}

// MARK: - InboxSurface

extension MessageRequestsViewController: InboxSurface {
    var listScrollView: UIScrollView { tableView }

    var category: MessagesCategory { .requests }

    /// The catalog is already loaded by the time this surface is reachable
    /// (the conversation list loads it on appear), so becoming active only
    /// asks for a refresh — which no-ops while one is in flight.
    func surfaceDidBecomeActive() {
        viewModel.refresh()
        #if DEBUG
        runSectionTapDebugSequence()
        #endif
    }
}
