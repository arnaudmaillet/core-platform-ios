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
final class MessageRequestsViewController: UIViewController {
    /// ⚠️ THE RESTING OFFSET IS APPLIED WHEN THE CONTENT SIZE LANDS, NOT ON
    /// APPLY. The first apply returns before the rows exist in the table (the
    /// batch update is still in flight) and, for a page the pager has not
    /// shown yet, before the table has a height — an offset set then was
    /// clamped straight back to the top, and the list opened on its header
    /// after all; a layout pass of this controller's VIEW never came either,
    /// because rows landing inside the table lay out the table, not its
    /// host. `contentSize` is the one thing that changes when they land, so it
    /// is watched — for the life of the list, because the bottom padding that
    /// lets a short list rest past its header (`padToRestPastLeadingHeader`)
    /// has to follow every change of size — and the rest itself is asked for
    /// once, until it takes.
    private var contentObservation: NSKeyValueObservation?
    private var wantsRestPastHeader = false

    private func restPastLeadingHeaderWhenContentLands() {
        wantsRestPastHeader = true
        guard contentObservation == nil else { return }
        contentObservation = tableView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
            self?.settleLeadingHeader()
        }
    }

    /// The padding first, so the rest has somewhere to go.
    private func settleLeadingHeader() {
        guard tableView.bounds.height > 0,
              tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0
        else { return }
        tableView.padToRestPastLeadingHeader()
        guard wantsRestPastHeader else { return }
        let before = tableView.contentOffset.y
        tableView.restPastLeadingHeader()
        if tableView.contentOffset.y > before + 0.5 { wantsRestPastHeader = false }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The bounds are the other input to the padding — a page laid out
        // for the first time, a rotation.
        if contentObservation != nil { settleLeadingHeader() }
    }

    /// See `InboxSurface.pinnedSectionTitle`; kept current by
    /// `updatePinnedSection` on every scroll and every apply.
    private(set) var pinnedSectionTitle: String?
    private var pinnedSectionIndex: Int?
    var onPinnedSectionChange: ((String?) -> Void)?

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
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        tableView.prefersClearTopEdge()
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
            tableView.endRefreshingAtRest(refreshControl)
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
            // Read before the `defer`, which runs after the flag is flipped —
            // see `ConversationListViewController`.
            let isFirstRender = !hasRenderedContent
            defer {
                if isFirstRender { restPastLeadingHeaderWhenContentLands() }
                updatePinnedSection()
            }
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
        header?.setTitle(section.title, // ⚠️ TRUE for every section, not just the first. `leadsList: false` spends
            // the section gap under the pill, which put a band of space between a
            // header and its OWN first row from section two down. The separation
            // between sections is the footer's job — see `heightForFooterInSection`
            // — so the header has nothing left to pad.
            leadsList: true)
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

    /// ⚠️ A FOOTER, not a bigger header margin.
    ///
    /// The section gap used to sit above the next header, which put the break in
    /// the right place visually and the pill in the wrong one: a plain table PINS
    /// its headers, so that margin travelled with the pill and hung a stuck
    /// header lower than the first one's. Spending the space at the END of the
    /// previous section separates the two lists without moving anything that pins.
    func tableView(_ tableView: UITableView, heightForFooterInSection index: Int) -> CGFloat {
        index < tableView.numberOfSections - 1
            ? SectionHeaderPillButton.Metrics.sectionGap
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

    // MARK: - The pinned section, for the bar

    func scrollToPinnedSection() {
        guard let index = pinnedSectionIndex else { return }
        dataSource.scroll(tableView, toSectionAt: index)
    }

    /// The section stuck at the pin line, published only when it changes: a
    /// scroll fires this every frame, and the bar must not be rewritten on
    /// every one of them. The rule is each header's own
    /// (`SectionHeaderPillButton.pinnedSection`), asked once for the list.
    func updatePinnedSection() {
        let pinLine = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let tops = (0..<tableView.numberOfSections).map { tableView.rect(forSection: $0).minY }
        let index = SectionHeaderPillButton.pinnedSection(sectionTops: tops, pinLine: pinLine)
            .flatMap { dataSource.headedSection(at: $0) == nil ? nil : $0 }
        let title = index.flatMap { dataSource.headedSection(at: $0)?.title }
        pinnedSectionIndex = index
        guard title != pinnedSectionTitle else { return }
        pinnedSectionTitle = title
        onPinnedSectionChange?(title)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePinnedSection()
    }

    /// ⚠️ THE LIST RESTS WITH ITS FIRST ROW UNDER THE BAR, not with its first
    /// header — the bar names that section, so a large "New" under a bar
    /// already saying "New" was the same word twice and a band of it between
    /// the bar and the first row. The header is still there, ABOVE the
    /// resting position: pull the list down and it comes into view as the
    /// title over the first row while the bar's item fades out, and a release
    /// that does not refresh snaps past it again (`snapPastLeadingHeader`),
    /// the way a large title snaps shown or hidden. A refresh leaves it shown
    /// until the next scroll, which is what pulling was for.
    /// ⚠️ THE BOUNCE'S OWN TARGET, not a scroll issued beside it. A
    /// `setContentOffset(animated:)` at `didEndDragging` ran first and was
    /// then overrun by UIKit's bounce back to the top of the content, and the
    /// snap at `didEndDecelerating` made a third motion — filmed at 30fps as
    /// the header leaving, returning, and leaving again. Handing UIKit the
    /// resting offset as the deceleration's target makes its one bounce land
    /// there.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        if let target = tableView.restingOffsetIfAboveFirstRow(unlessRefreshing: refreshControl) {
            targetContentOffset.pointee.y = target
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // A release that will not decelerate has no bounce to land: snap.
        if !decelerate { tableView.snapPastLeadingHeader(unlessRefreshing: refreshControl) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A fling from deeper in the list that ran out inside the header band.
        tableView.snapPastLeadingHeader(unlessRefreshing: refreshControl)
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
        #if DEBUG
        runSectionTapDebugSequence()
        #endif
    }
}
