import DesignSystem
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
///
/// Pushed on its own over the HIDDEN REQUESTS folder, it is also the **Hidden
/// requests** list (#552) that the Requests list's last row opens.
///
/// With channels (#2230), the list leads with the channels' **join
/// requests**: one row per channel the viewer runs with requests waiting,
/// which opens that channel's requests list. They wear NO HEADER (#2328, the
/// owner 2026-11-11): the row names itself ("Studio drops · 3 requests"), as
/// the Hidden requests row at the other end does, and the Accept and ×
/// buttons tell the conversation requests between them apart. A gap under
/// the last channel row is all that separates the two kinds.
///
/// The conversation requests are ONE LIST with no header (#2292, the owner
/// 2026-11-11): the New / Recent split went. An unviewed request keeps its
/// full-weight preview; "Hidden requests" stays the last row.
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
    /// The row's own shape (#1774): a request row, with its buttons — not a
    /// conversation row's preview and time.
    private let skeletonView = PersonListSkeletonView(trailing: .acceptAndDismiss)
    private let statusView = InboxStatusView()
    /// Which of the skeleton, the table and the status shows, on the kit's
    /// timing (#1770, `ScreenLoadingHost`): no skeleton for a list that
    /// answers at once, held its minimum once up, and "taking longer" with a
    /// retry after 10 s.
    private lazy var loading: ScreenLoadingHost = {
        let host = ScreenLoadingHost(container: view, skeleton: skeletonView, content: tableView, status: statusView)
        host.onTakingLonger = { [weak self] in
            guard let self else { return }
            statusView.configure(
                symbol: TakingLongerCopy.symbol, title: TakingLongerCopy.title,
                message: "Your requests are still on their way.",
                actionTitle: TakingLongerCopy.action, action: { [weak self] in self?.retryLoad() }
            )
            loading.showStatus()
        }
        return host
    }()
    /// Under the last row while another page is there to load (#593).
    private let pagingFooter = PagingFooterView()
    /// Under the last row once every page has loaded and the hidden folder
    /// holds requests (#552).
    private let hiddenRequestsRow = HiddenRequestsRowView()

    private var dataSource: SectionedConversationDataSource!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    /// The Join requests rows on show (#2230), by channel: a channel's id is
    /// never a request's, so the two kinds of row share the data source.
    private var joinRequestsByID: [ConversationID: ChannelJoinRequestsDigest.Entry] = [:]
    /// A Join requests row was picked (#2230): the host pushes that
    /// channel's requests list.
    var onOpenJoinRequests: ((_ presenter: UIViewController, _ channel: RunChannel) -> Void)?

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
    /// Builds the Hidden requests list the last row pushes (#552). Supplied
    /// by the composition root, which owns the shared catalog.
    var hiddenRequestsProvider: (() -> UIViewController)?
    private let imagePipeline: ImagePipeline?
    private let avatars: (any PeerAvatarProviding)?
    /// The peers' relations, for the faces' mark and its "+" (#2088), as the
    /// All list's (#2049). Nil: no mark.
    private let relations: InboxRelations?

    init(
        viewModel: MessageRequestsViewModel,
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil,
        relations: InboxRelations? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        // The faces the rows read are kept for the thread they open (#2049).
        self.avatars = relations?.recording(avatars) ?? avatars
        self.relations = relations
        super.init(nibName: nil, bundle: nil)
        // Published from the init, off the view model, and from off screen
        // too — a request landing while the viewer is on another tab is
        // exactly what the badge is for, and the inbox reads a surface's
        // chrome before its view exists (charter P3).
        viewModel.onNewCountChange = { [weak self] _ in self?.publishChrome() }
        publishChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private let refreshControl = AppRefreshControl()

    /// A pull: the page reloads, and the loader ends with the answer
    /// (`render`) once it has turned its minimum (`AppRefreshControl`). A
    /// reload that changes nothing may publish nothing, so it also ends on
    /// its own after a beat.
    private func pullToRefresh() {
        viewModel.refresh()
        resolveRelations(refresh: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshControl.endRefreshing()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if viewModel.folder == .hiddenRequests {
            title = "Hidden requests"
            navigationItem.largeTitleDisplayMode = .never
        }
        configureTableView()
        configureStatusViews()
        hiddenRequestsRow.addTarget(self, action: #selector(openHiddenRequests), for: .touchUpInside)

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        // A relation that changed: the faces on screen take it, animated.
        relations?.observe(by: self) { [weak self] peers in self?.applyRelations(of: peers) }
        // Pull to refresh, with the app's loader (#1901, the owner 2026-10-30):
        // the pull came back when search moved into the stacked field.
        refreshControl.onRefresh = { [weak self] in self?.pullToRefresh() }
        tableView.refreshControl = refreshControl
        viewModel.onHasMoreChange = { [weak self] _ in self?.updatePagingFooter() }
        viewModel.onShowsHiddenRequestsRowChange = { [weak self] _ in self?.updatePagingFooter() }
        updatePagingFooter()
        // Whatever the view model holds now — the catalog may have answered
        // before this view was asked for.
        render(viewModel.phase)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from a thread or a profile: a follow made there shows.
        if hasRenderedContent { resolveRelations(refresh: true) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The hidden folder is sorted with the viewer's CURRENT filter when it
        // is read (#552): opening the list reads it again, so hidden words
        // edited since the inbox loaded are reflected. The Requests page asks
        // the same through `surfaceDidBecomeActive`.
        if viewModel.folder == .hiddenRequests { viewModel.refresh() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHiddenRequestsRow()
    }

    /// A table footer keeps the frame it is given: the row is measured at the
    /// table's width, and handed back whenever its height changes (a text
    /// size change, the first layout).
    private func sizeHiddenRequestsRow() {
        guard tableView.tableFooterView === hiddenRequestsRow, tableView.bounds.width > 0 else { return }
        let height = hiddenRequestsRow.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height.rounded(.up)
        guard hiddenRequestsRow.frame.height != height || hiddenRequestsRow.frame.width != tableView.bounds.width else { return }
        hiddenRequestsRow.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
        tableView.tableFooterView = hiddenRequestsRow
    }

    @objc private func openHiddenRequests() {
        guard let hidden = hiddenRequestsProvider?() else { return }
        navigationController?.pushViewController(hidden, animated: true)
    }

    private func configureTableView() {
        tableView.register(MessageRequestCell.self, forCellReuseIdentifier: MessageRequestCell.reuseIdentifier)
        tableView.register(JoinRequestsCell.self, forCellReuseIdentifier: JoinRequestsCell.reuseIdentifier)
        // No indicators on the inbox's pages either — the tabs sit above them
        // and each page keeps its own position, so a bar that flashes on every
        // switch reads as motion nobody asked for.
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        // A titled header: the soft blur covers the bar (#1591) — see
        // `applyTopEdge(for:)`.
        tableView.applyTopEdge(for: .titled)
        tableView.delegate = self
        // No section header (#2328): a plain table reserves ~22pt above every
        // section's header by default, a band of nothing between the tab
        // capsule and the first row.
        tableView.sectionHeaderTopPadding = 0
        // No hairlines, matching every other people list in the app: a 48pt
        // disc and two lines of type already make each row its own object.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.pin(to: view)

        dataSource = SectionedConversationDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            // A channel with join requests waiting (#2230).
            if let entry = self?.joinRequestsByID[id] {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: JoinRequestsCell.reuseIdentifier, for: indexPath
                ) as! JoinRequestsCell
                cell.configure(with: entry)
                return cell
            }
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageRequestCell.reuseIdentifier, for: indexPath
            ) as! MessageRequestCell
            if let self, let model = self.modelsByID[id] {
                self.relations?.saw(model)
                cell.configure(
                    with: model, imagePipeline: self.imagePipeline, avatars: self.avatars,
                    mark: self.relations?.mark(for: model.peerID) ?? .none, onFollow: self.followHandler(for: model)
                )
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
        if case .loading = phase {} else { refreshControl.endRefreshing() }
        switch phase {
        case .loading:
            loading.load()
        case .content(let models):
            var snapshot = NSDiffableDataSourceSnapshot<InboxListSection, ConversationID>()
            // The channels' join requests first (#2230): what waits on the
            // viewer as the channel's owner or admin. No header (#2328).
            let joinRequests = viewModel.joinRequests
            let previousJoinRequests = joinRequestsByID
            joinRequestsByID = Dictionary(joinRequests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if !joinRequests.isEmpty {
                snapshot.appendSections([.joinRequests])
                snapshot.appendItems(joinRequests.map(\.id), toSection: .joinRequests)
            }
            // Then the requests: one list, in recency order, unheaded
            // (#2292).
            if !models.isEmpty {
                snapshot.appendSections([.conversations])
                snapshot.appendItems(models.map(\.id), toSection: .conversations)
            }
            // Same-identity rows whose content changed re-render in place —
            // reading a request clears its bold preview without moving it.
            // See `InboxRowDiff`.
            snapshot.reconfigureItems(InboxRowDiff.changedRows(in: models, against: modelsByID))
            // A channel's count that changed redraws its row in place.
            let recounted = joinRequests.filter { previousJoinRequests[$0.id] != nil && previousJoinRequests[$0.id] != $0 }
            snapshot.reconfigureItems(recounted.map(\.id))
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            // Animate only while visible — an off-screen change would replay
            // its animation after the next transition.
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
            hasRenderedContent = true
            // The list moved under the spinner: it waits for the end to
            // come back in reach before it turns again.
            pagingFooter.setSpinning(false)
            revealContent()
            // The rows draw now; their marks arrive as the relations land.
            // Next turn, once the table has laid the rows out.
            DispatchQueue.main.async { [weak self] in self?.resolveRelations() }
        case .empty where viewModel.folder == .hiddenRequests:
            statusView.configure(
                symbol: "eye.slash",
                title: "No hidden requests",
                message: "Requests that match your hidden words will wait here."
            )
            loading.showStatus()
        case .empty:
            statusView.configure(
                symbol: "tray",
                title: "No requests",
                message: "Messages from people you don't follow will wait here."
            )
            loading.showStatus()
        case .failed(let message):
            statusView.configure(
                symbol: "exclamationmark.triangle", title: "Something went wrong", message: message,
                actionTitle: "Try Again", action: { [weak self] in self?.retryLoad() }
            )
            loading.showStatus()
        }
    }

    /// Swaps the skeleton for the populated table — hydration in place, and
    /// only when the skeleton is actually on screen.
    private func revealContent() {
        loading.showContent()
    }

    /// Try Again: the wait starts over under the skeleton's timing.
    private func retryLoad() {
        loading.load()
        viewModel.retry()
    }
    // MARK: - The relation mark (#2088, as the All list's #2049)

    /// The peers to ask about: the rows on screen and as many again below
    /// the last one shown. Before the first layout, the first two screens'
    /// worth.
    private func peersToResolve() -> [ProfileID] {
        let ids = dataSource.snapshot().itemIdentifiers
        let visible = (tableView.indexPathsForVisibleRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        let range: Range<Int>
        if let first = visible.first.flatMap({ ids.firstIndex(of: $0) }),
           let last = visible.last.flatMap({ ids.firstIndex(of: $0) }) {
            range = first..<min(ids.count, last + 1 + visible.count)
        } else {
            range = 0..<min(ids.count, InboxPaging.relationLookahead)
        }
        return ids[range].compactMap { modelsByID[$0]?.peerID }
    }

    private func resolveRelations(refresh: Bool = false) {
        guard let relations, relations.isEnabled else { return }
        relations.resolve(peersToResolve(), refresh: refresh)
    }

    /// The faces on screen whose peer's relation changed.
    /// `peers` nil: every row (a viewer change).
    private func applyRelations(of peers: Set<ProfileID>?) {
        guard let relations else { return }
        for case let cell as MessageRequestCell in tableView.visibleCells {
            guard let peer = cell.peerID, peers?.contains(peer) ?? true else { continue }
            cell.setRelationMark(relations.mark(for: peer), animated: true)
        }
    }

    /// The "+" on `model`'s face: the inbox's follow (member gate,
    /// optimistic flip, haptic, a failure put back and announced). It never
    /// accepts the request: the row stays a request until Accept.
    private func followHandler(for model: ConversationDisplayModel) -> (() -> Void)? {
        guard let relations, relations.isEnabled, let peer = model.peerID else { return nil }
        return { [weak self, weak relations] in
            guard let self else { return }
            relations?.follow(peer, handle: model.peerHandle, name: model.title, from: self)
        }
    }

    /// The spinner hangs under the last row while there is more to load;
    /// once there isn't, the Hidden requests row closes the list (#552) —
    /// at the very end, never between two pages.
    private func updatePagingFooter() {
        pagingFooter.setSpinning(false)
        if viewModel.hasMore {
            tableView.tableFooterView = pagingFooter
        } else if viewModel.showsHiddenRequestsRow {
            tableView.tableFooterView = hiddenRequestsRow
            sizeHiddenRequestsRow()
        } else {
            tableView.tableFooterView = nil
        }
    }
}

extension MessageRequestsViewController: UITableViewDelegate {
    /// Paging: one of the last rows coming on screen asks for the next page
    /// (#593), early enough that it usually lands before the end does.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        resolveRelations()
        guard viewModel.hasMore, let id = dataSource.itemIdentifier(for: indexPath),
              dataSource.snapshot().itemIdentifiers.suffix(InboxPaging.nearEndRowCount).contains(id) else { return }
        pagingFooter.setSpinning(true)
        viewModel.loadMore()
    }

    // MARK: - No section header (#2292, #2328)

    /// None, on either section: the conversation requests are one list with
    /// no title (#2292), and the join requests above them name themselves
    /// on their rows (#2328). ⚠️ A plain table gives a section a default
    /// header height even when its header view is nil, which would leave a
    /// blank band above the first row.
    func tableView(_ tableView: UITableView, heightForHeaderInSection index: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    /// ⚠️ A FOOTER: the gap under the last channel row, before the first
    /// conversation request — what separates the two kinds of request now
    /// that no header does (#2328). It was spent at the end of the previous
    /// section rather than above the next header so nothing pinned moved;
    /// with no header left, the footer stays the one place it lives.
    func tableView(_ tableView: UITableView, heightForFooterInSection index: Int) -> CGFloat {
        index < tableView.numberOfSections - 1
            ? SectionHeaderPillButton.sectionGap(traits: tableView.traitCollection)
            : .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection index: Int) -> UIView? {
        let spacer = UIView()
        spacer.backgroundColor = .clear
        return spacer
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if let entry = joinRequestsByID[id] {
            onOpenJoinRequests?(self, entry.channel)
            return
        }
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
        // A Join requests row is no conversation: nothing to peek (#2230).
        guard let id = dataSource.itemIdentifier(for: indexPath), joinRequestsByID[id] == nil else { return nil }
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
    var listScrollView: UIScrollView? { tableView }

    // No `pinnedSection`: no section is headed, so none is named in the bar
    // (#2328).

    var category: MessagesCategory { .requests }

    /// The catalog is already loaded by the time this surface is reachable
    /// (the conversation list loads it on appear), so becoming active only
    /// asks for a refresh — which no-ops while one is in flight.
    func surfaceDidBecomeActive() {
        viewModel.refresh()
    }
}

// MARK: - How it is left (#1144)

extension MessageRequestsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

#if DEBUG
extension MessageRequestsViewController {
    /// The sections on show, in order (#2292). Tests.
    var debugSections: [InboxListSection] { dataSource.snapshot().sectionIdentifiers }

    /// The sections that wear a header, as the table lays them out: a
    /// header view, or a header height of a point or more. None since
    /// #2328. Tests.
    var debugHeadedSections: [InboxListSection] {
        let sections = dataSource.snapshot().sectionIdentifiers
        return sections.indices.compactMap { index in
            let height = tableView.delegate?.tableView?(tableView, heightForHeaderInSection: index) ?? 0
            let view = tableView.delegate?.tableView?(tableView, viewForHeaderInSection: index)
            return height >= 1 || view != nil || tableView.headerView(forSection: index) != nil
                ? sections[index] : nil
        }
    }

    /// The gap under section `index`: its footer's height. Tests.
    func debugGap(underSectionAt index: Int) -> CGFloat {
        tableView.delegate?.tableView?(tableView, heightForFooterInSection: index) ?? 0
    }

    /// The list's table. Tests.
    var debugTableView: UITableView { tableView }

    /// The rows of `section`, in order; empty when it is not on show. Tests.
    func debugRowIDs(in section: InboxListSection) -> [ConversationID] {
        let current = dataSource.snapshot()
        guard current.sectionIdentifiers.contains(section) else { return [] }
        return current.itemIdentifiers(inSection: section)
    }

    /// Whether the list ends on the Hidden requests row (#552). Tests.
    var debugEndsOnHiddenRequestsRow: Bool { tableView.tableFooterView === hiddenRequestsRow }
}
#endif
