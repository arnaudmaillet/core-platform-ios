import DesignSystem
import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// The inbox's "All" surface: every active direct message, with unread ones
/// marked in place — bold row, a count on the row, and a count on the tab
/// itself.
///
/// ONE LIST (#2292, the owner 2026-11-11): no New / Recent sections, sorted
/// by the last activity with the pinned rows first. A row new since the
/// visit wears its count in the primary, every other unread row in grey
/// (`ConversationDisplayModel.unreadInk`).
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
    /// The inbox's rows before the first page (#1769): DesignSystem's person
    /// rows with a preview line and the time at the trailing edge.
    private let skeletonView = PersonListSkeletonView(trailing: .timeBone, lines: .preview, header: .largeTitle)
    private let statusView = InboxStatusView()
    /// Which of the skeleton, the table and the status shows, on the kit's
    /// timing (#1768): no skeleton for an inbox that answers at once, held
    /// its minimum once up, and "taking longer" with a retry after 10 s.
    /// Injectable so a test steps the timing.
    var skeletonClock: LoadingClock = .system
    private lazy var loading: ScreenLoadingHost = {
        let host = ScreenLoadingHost(
            container: view, skeleton: skeletonView, content: tableView, status: statusView, clock: skeletonClock
        )
        host.onTakingLonger = { [weak self] in
            guard let self else { return }
            statusView.configure(
                symbol: TakingLongerCopy.symbol, title: TakingLongerCopy.title,
                message: "Your conversations are still on their way.",
                actionTitle: TakingLongerCopy.action, action: { [weak self] in self?.retryLoad() }
            )
            loading.showStatus()
        }
        return host
    }()
    /// Under the last row while another page is there to load (#593).
    private let pagingFooter = PagingFooterView()

    private var adapter: ConversationListTableAdapter!
    private var modelsByID: [ConversationID: ConversationDisplayModel] = [:]
    private var hasRenderedContent = false

    /// Builds the thread screen a context-menu long-press previews — injected
    /// by the feature builder so preview and push share one construction.
    var threadPreviewProvider: ((ConversationID) -> UIViewController)?
    /// A channel's info screen, pushed (#2230): where the owner who asked
    /// to leave hands the channel over first. Nil: the owner is told only.
    var onOpenChannelInfo: ((_ presenter: UIViewController, _ id: ConversationID) -> Void)?

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

    /// `imagePipeline` and `avatars` are optional: the list is complete
    /// without them (see `ConversationCell.configure`), and mock builds that
    /// wire neither still render initials.
    private let imagePipeline: ImagePipeline?
    private let avatars: (any PeerAvatarProviding)?
    /// The peers' relations, for the faces' mark and its "+" (#2049). Nil:
    /// no mark.
    private let relations: InboxRelations?

    init(
        viewModel: ConversationListViewModel,
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
        // The chrome is the container's, and the container reads it before
        // this view exists: the inbox no longer loads every surface's view up
        // front (charter P3), so the badge is published from here, off the
        // view model alone.
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
        configureTableView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        // A relation that changed: the faces on screen take it, animated.
        relations?.observe(by: self) { [weak self] peers in self?.applyRelations(of: peers) }
        // Pull to refresh, with the app's loader (#1901, the owner 2026-10-30):
        // the pull came back when search moved into the stacked field.
        refreshControl.onRefresh = { [weak self] in self?.pullToRefresh() }
        tableView.refreshControl = refreshControl
        viewModel.onHasMoreChange = { [weak self] _ in self?.updatePagingFooter() }
        // A row's mute, once the server has answered (#803).
        viewModel.onMuteAnswered = { [weak self] message, muting, confirmed in
            guard let self else { return }
            if confirmed {
                Feedback.success(message, symbol: muting ? "bell.slash.fill" : "bell.fill", from: self)
            } else {
                Feedback.failure(message, from: self)
            }
        }
        // A group invitation's answer the server refused (#2214).
        viewModel.onInvitationRefused = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        // A channel's Leave the server refused (#2230): the row is back.
        viewModel.onLeaveRefused = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        viewModel.onMuteUndoable = { [weak self] message, undo in
            guard let self else { return }
            Feedback.undoable(message, symbol: "bell.slash.fill", from: self, commit: {}, undo: undo)
        }
        updatePagingFooter()
        // The view model may have moved past `.loading` before this view was
        // asked for (the catalog replays its snapshot at subscription), so the
        // first render is whatever it holds now, not a fresh skeleton.
        render(viewModel.phase)

        #if DEBUG
        // `-chat-pin-demo` pins the last VISIBLE row ~2s in and shows the tint
        // plus the reorder-to-top.
        //
        // ⚠️ Visible, not `itemIdentifiers.last` — which is usually off-screen,
        // where there is no cell to paint and the whole point of the fix
        // (front-running the data source on the live cell) goes unexercised.
        // Watch it with Slow Animations on: the band must be there on frame 0
        // of the slide, not when it lands.
        //
        // ⚠️ The 2 s is the beat that shows the list before the pin, not a
        // promise that the rows are there: on a slow load there was no visible
        // row yet, the guard returned, and the demo did nothing without a
        // word. It now waits for a visible row on a list in a window (the
        // table is only shown once the skeleton gives way to content), and
        // prints GAVE UP if one never comes.
        if ProcessInfo.processInfo.arguments.contains("-chat-pin-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                QAWait.until("-chat-pin-demo: a visible row", { [weak self] in
                    guard let self else { return true }
                    return view.window != nil && !tableView.isHidden
                        && tableView.indexPathsForVisibleRows?.last
                            .flatMap { self.adapter.itemIdentifier(for: $0) } != nil
                }) { [weak self] in
                    guard let self,
                          let indexPath = self.tableView.indexPathsForVisibleRows?.last,
                          let id = self.adapter.itemIdentifier(for: indexPath)
                    else { return }
                    self.pin(id)
                }
            }
        }
        // `-chat-preview-demo` presents the context-menu preview construction
        // (`.preview` mode) as a sheet ~2s in, which isolates the preview
        // screen itself — the stripped compose bar and the live transcript.
        //
        // ⚠️ It is NOT needed to reach the menu: a long-press CAN be injected,
        // via a held CGEvent drag (mouse down, jitter for ~1.4s, up). The
        // comment here used to say otherwise. Both halves were verified that
        // way on the Requests tab, which wears the same seam.
        if ProcessInfo.processInfo.arguments.contains("-chat-preview-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let id = self.adapter.allIdentifiers.first,
                      let make = self.threadPreviewProvider else { return }
                self.present(make(id), animated: true)
            }
        }
        #endif
    }

    /// Toggles the pin, painting the row's band before the move begins.
    ///
    /// The paint is a plain, unanimated property set on the live cell; the
    /// movement belongs entirely to `performBatchUpdates` in
    /// `ConversationListTableAdapter`. Nothing is flushed and nothing is
    /// deferred.
    ///
    /// ⚠️ **Both of those were here and both were wrong.** A
    /// `CATransaction.flush()` committed a frame in the middle of the update
    /// UIKit was assembling, and a `DispatchQueue.main.async` hop split the
    /// state change away from it — between them the moving cell was dropped
    /// for the length of the animation, which is the blank hole the row left
    /// behind. They were compensating for a diffable data source that faded
    /// rather than moved; with a real `moveRow` there is nothing to
    /// compensate for.
    ///
    /// Unpinning is the same call with the flag inverted.
    private func pin(_ id: ConversationID) {
        let willPin = !viewModel.isPinned(id)
        if let indexPath = adapter.indexPath(for: id),
           let cell = tableView.cellForRow(at: indexPath) as? ConversationCell {
            cell.setPinnedStyle(willPin, animated: false)
        }
        viewModel.togglePin(id)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.viewWillAppear()
        // Back from a thread or a profile: a follow made there shows.
        if hasRenderedContent { resolveRelations(refresh: true) }
    }

    // MARK: - The relation mark (#2049)

    /// The peers to ask about: the rows on screen and the next page's —
    /// as many again below the last one shown. Before the first layout, the
    /// first two screens' worth.
    private func peersToResolve() -> [ProfileID] {
        let ids = adapter.allIdentifiers
        let visible = (tableView.indexPathsForVisibleRows ?? []).compactMap { adapter.itemIdentifier(for: $0) }
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
        for case let cell as ConversationCell in tableView.visibleCells {
            guard let peer = cell.peerID, peers?.contains(peer) ?? true else { continue }
            cell.setRelationMark(relations.mark(for: peer), animated: true)
        }
    }

    /// The "+" on `model`'s face.
    private func followHandler(for model: ConversationDisplayModel) -> (() -> Void)? {
        guard let relations, relations.isEnabled, let peer = model.peerID else { return nil }
        return { [weak self, weak relations] in
            guard let self else { return }
            relations?.follow(peer, handle: model.peerHandle, name: model.title, from: self)
        }
    }

    private func configure(_ cell: ConversationCell, with model: ConversationDisplayModel) {
        relations?.saw(model)
        cell.configure(
            with: model, imagePipeline: imagePipeline, avatars: avatars,
            mark: relations?.mark(for: model.peerID) ?? .none, onFollow: followHandler(for: model)
        )
    }

    private func configureTableView() {
        tableView.register(ConversationCell.self, forCellReuseIdentifier: ConversationCell.reuseIdentifier)
        // A group invitation (#2214) is a request's row: the same Accept and ✕.
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
        // One list with no header (#2292). A plain table still reserves ~22pt
        // of padding above a section's header, which would be a band of
        // nothing between the tab capsule and the first row.
        tableView.sectionHeaderTopPadding = 0
        // No hairlines, matching every other people list in the app: a 48pt
        // disc and two lines of type already make each row its own object.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.pin(to: view)

        adapter = ConversationListTableAdapter(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            if let self, let model = self.modelsByID[id], model.invitation != nil {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: MessageRequestCell.reuseIdentifier, for: indexPath
                ) as! MessageRequestCell
                self.configureInvitation(cell, with: model)
                return cell
            }
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ConversationCell.reuseIdentifier, for: indexPath
            ) as! ConversationCell
            if let self, let model = self.modelsByID[id] {
                self.configure(cell, with: model)
            }
            return cell
        }
    }

    /// A group's invitation (#2214): its Accept and ✕ answer it.
    private func configureInvitation(_ cell: MessageRequestCell, with model: ConversationDisplayModel) {
        cell.configure(with: model, imagePipeline: imagePipeline, avatars: avatars)
        let id = model.id
        cell.onAccept = { [weak self] in self?.viewModel.answerInvitation(id, accept: true) }
        cell.onDismiss = { [weak self] in self?.viewModel.answerInvitation(id, accept: false) }
    }

    /// Re-renders rows whose content changed but whose position did not,
    /// straight onto the live cells.
    ///
    /// A row that changed KIND — an invitation accepted (#2214) — is skipped:
    /// its cell is of the other type, and it is reloaded once the
    /// arrangement is applied (`reloadRowsOfChangedKind`).
    private func reconfigureVisible(_ ids: [ConversationID]) {
        for id in ids {
            guard let indexPath = adapter.indexPath(for: id), let model = modelsByID[id] else { continue }
            switch tableView.cellForRow(at: indexPath) {
            case let cell as ConversationCell where model.invitation == nil:
                configure(cell, with: model)
            case let cell as MessageRequestCell where model.invitation != nil:
                configureInvitation(cell, with: model)
            default:
                continue
            }
        }
    }

    /// The rows on screen whose cell is of the wrong kind for their model —
    /// an invitation accepted becomes a group's row (#2214) — reloaded in
    /// their new places.
    private func reloadRowsOfChangedKind(_ ids: [ConversationID]) {
        let paths = ids.compactMap { id -> IndexPath? in
            guard let indexPath = adapter.indexPath(for: id), let model = modelsByID[id],
                  let cell = tableView.cellForRow(at: indexPath) else { return nil }
            let isInvitationCell = cell is MessageRequestCell
            return isInvitationCell == (model.invitation != nil) ? nil : indexPath
        }
        guard !paths.isEmpty else { return }
        tableView.reloadRows(at: paths, with: .fade)
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
        if case .loading = phase {} else { refreshControl.endRefreshing() }
        switch phase {
        case .loading:
            loading.load()
        case .content(let models):
            // Rows whose content changed without moving. Applied straight to
            // the visible cells below — there is no snapshot to reconcile, so
            // this cannot collide with the move animation the way a diffable
            // `reconfigureItems` did. See `InboxRowDiff`, and
            // `ConversationListTableAdapter` for why this list is hand-driven.
            //
            // The row `pin(_:)` just painted is excluded: its cell is already
            // correct, and re-configuring it mid-move would fight the paint.
            let changed = InboxRowDiff.changedRows(in: models, against: modelsByID)
            // BEFORE the apply: `cellForRowAt` reads this.
            modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            // Animate only while visible. A change that arrives while a thread
            // is pushed over the inbox — reading one, say — would otherwise
            // play its row animation on the way back, turning a settled screen
            // into a moving one right after the pop.
            // ⚠️ **BEFORE the move, at the rows' OLD positions.** `moveRow`
            // reuses a cell as-is — it never re-asks for one — so a row that
            // travels wearing stale content keeps it for the whole flight and
            // only corrects when something re-configures it afterwards. That
            // is the pinned row arriving grey a beat late.
            //
            // Reconfiguring here, while the old index paths are still the live
            // ones, means the cell already looks right when the batch picks it
            // up and the band travels with it.
            reconfigureVisible(changed)
            adapter.apply(models, animated: hasRenderedContent && view.window != nil)
            reloadRowsOfChangedKind(changed)
            hasRenderedContent = true
            // The list moved under the spinner: it waits for the end to
            // come back in reach before it turns again.
            pagingFooter.setSpinning(false)
            revealContent()
            // The rows draw now; their marks arrive as the relations land.
            // Next turn, once the table has laid the rows out.
            DispatchQueue.main.async { [weak self] in self?.resolveRelations() }
        case .empty:
            statusView.configure(
                symbol: "bubble.left.and.bubble.right",
                title: "No conversations yet",
                message: "Start one from someone's profile, or from search."
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

    /// Swaps the skeleton for the populated table. The rows are applied
    /// before this runs, so the host's dissolve is hydration in place.
    private func revealContent() {
        loading.showContent()
    }

    /// Try Again: the wait starts over under the skeleton's timing.
    private func retryLoad() {
        loading.load()
        viewModel.retry()
    }

    /// The spinner hangs under the last row only while there is more to load.
    private func updatePagingFooter() {
        pagingFooter.setSpinning(false)
        tableView.tableFooterView = viewModel.hasMore ? pagingFooter : nil
    }
}

extension ConversationListViewController: UITableViewDelegate {
    /// Paging: one of the last rows coming on screen asks for the next page
    /// (#593), early enough that it usually lands before the end does.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        resolveRelations()
        guard viewModel.hasMore, let id = adapter.itemIdentifier(for: indexPath),
              adapter.allIdentifiers.suffix(InboxPaging.nearEndRowCount).contains(id) else { return }
        pagingFooter.setSpinning(true)
        viewModel.loadMore()
    }

    // MARK: - No section header (#2292)

    /// None: one list, no title. ⚠️ A plain table gives a section a default
    /// header height even when its header view is nil, which would leave a
    /// blank band above the first row.
    func tableView(_ tableView: UITableView, heightForHeaderInSection index: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection index: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = adapter.itemIdentifier(for: indexPath) else { return }
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
        guard let id = adapter.itemIdentifier(for: indexPath) else { return nil }
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
        ) { [weak self] _ in self?.pin(id) }
        let mute = UIAction(
            title: isMuted ? "Unmute" : "Mute",
            image: UIImage(systemName: isMuted ? "bell" : "bell.slash")
        ) { [weak self] _ in self?.viewModel.toggleMute(id) }
        let delete: UIAction
        if let model = modelsByID[id], model.isChannel {
            // A channel's Delete is Leave (#2230): deleting the row of a
            // channel the viewer still follows would only hide it until the
            // next launch, its posts still arriving. Said, and confirmed.
            delete = UIAction(
                title: "Leave Channel",
                image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmLeave(model) }
        } else {
            delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.viewModel.delete([id]) }
        }
        // Destructive action in its own inline section, per system menus.
        return UIMenu(children: [pin, mute, UIMenu(options: .displayInline, children: [delete])])
    }

    /// A channel's Leave, from its row (#2230): confirmed in words that say
    /// so — the info screen's (#2215). The owner can't leave yet (chat.v1
    /// refuses it): they are told why and offered the info screen, where
    /// they hand the channel to an admin.
    private func confirmLeave(_ model: ConversationDisplayModel) {
        let alert: UIAlertController
        if model.ownsChannel {
            alert = UIAlertController(
                title: "Make someone else the owner",
                message: ChannelCopy.leaveBlockedReason(for: .owner), preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let onOpenChannelInfo {
                alert.addAction(UIAlertAction(title: ChannelCopy.openInfoTitle, style: .default) { [weak self] _ in
                    guard let self else { return }
                    onOpenChannelInfo(self, model.id)
                })
            }
        } else {
            alert = UIAlertController(
                title: ChannelCopy.leaveTitle(model.title), message: ChannelCopy.leaveMessage, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
                self?.viewModel.leaveChannel(model.id)
            })
        }
        present(alert, animated: true)
    }
}

// MARK: - InboxSurface

extension ConversationListViewController: InboxSurface {
    var listScrollView: UIScrollView? { tableView }

    // No `pinnedSection`: one list, no section to name in the bar (#2292).

    var category: MessagesCategory { .all }

    /// Paging back here re-checks for new messages. `refresh()` no-ops while a
    /// load is already in flight, so this is free on the appear path.
    func surfaceDidBecomeActive() {
        viewModel.refresh()
    }
}

#if DEBUG
extension ConversationListViewController {
    /// The list's table (#2292: one section, no header). Tests.
    var debugTableView: UITableView { tableView }

    /// The rows on show, in order. Tests.
    var debugRowIDs: [ConversationID] { adapter.allIdentifiers }
}
#endif
