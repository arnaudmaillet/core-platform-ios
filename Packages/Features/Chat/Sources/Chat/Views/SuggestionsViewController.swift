import DesignSystem
import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// The inbox's "Suggestions" surface: accounts worth following, each with an
/// inline follow and a dismiss.
///
/// Loads lazily — a viewer who never swipes this far never pays for the
/// suggestions behind it — and asks for the next page at its end.
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
    private let skeletonView = ConversationListSkeletonView()
    private let statusView = InboxStatusView()
    /// The inbox's paging spinner, under the last row while another page is
    /// there to load (#644, as #593).
    private let pagingFooter = PagingFooterView()

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
        // The row has already flipped back; the toast says why (#802).
        viewModel.onFollowFailure = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        render(viewModel.phase)
    }

    private func configureTableView() {
        tableView.register(SuggestionCell.self, forCellReuseIdentifier: SuggestionCell.reuseIdentifier)
        // No indicators on the inbox's pages either — the tabs sit above them
        // and each page keeps its own position, so a bar that flashes on every
        // switch reads as motion nobody asked for.
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        tableView.prefersClearTopEdge()
        tableView.delegate = self
        // No hairlines, matching every other people list in the app: a 48pt
        // disc and two lines of type already make each row its own object.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.pin(to: view)

        // ⚠️ NO REFRESH CONTROL. Pulling this list down opens search now —
        // see `InboxPullToSearch`. The pull was this page's ONLY refresh, so
        // `surfaceDidBecomeActive` refreshes it instead, every time the page
        // comes to the front.

        dataSource = UITableViewDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SuggestionCell.reuseIdentifier, for: indexPath
            ) as! SuggestionCell
            if let model = self?.modelsByID[id] {
                cell.configure(with: model, imagePipeline: self?.imagePipeline)
            }
            cell.onToggleFollow = { [weak self] in self?.viewModel.toggleFollow(id) }
            cell.onDismiss = { [weak self] in self?.dismiss(id) }
            return cell
        }
    }

    /// Hides a suggestion with Undo (#957). Nothing is sent either way — the
    /// dismissal is local (`SuggestionsViewModel.dismiss`) — so the commit is
    /// empty and Undo just shows the row again.
    private func dismiss(_ id: ProfileID) {
        viewModel.dismiss(id)
        Feedback.undoable(
            "Hidden from suggestions", symbol: "hand.thumbsdown", from: self,
            commit: {},
            undo: { [weak self] in self?.viewModel.undoDismiss(id) }
        )
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
            // The list moved under the spinner (or the ask failed): it waits
            // for the end to come back in reach before it turns again.
            updatePagingFooter()
            revealContent()
            if viewModel.canPageOnItsOwn { askIfTheEndIsInView() }
        case .empty:
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusView.configure(
                symbol: "person.2",
                title: "No suggestions right now",
                message: "Follow a few accounts and we'll find people you might know."
            )
            statusView.isHidden = false
        case .failed(let message):
            skeletonView.isHidden = true
            tableView.isHidden = true
            statusView.configure(
                symbol: "exclamationmark.triangle", title: "Something went wrong", message: message,
                actionTitle: "Try Again", action: { [weak self] in self?.viewModel.refresh() }
            )
            statusView.isHidden = false
        }
    }

    /// ⚠️ **ROWS ALREADY ON SCREEN NEVER ASK AGAIN.** `willDisplay` fires
    /// once per row coming into view, so a list whose every row fits — after
    /// a walk of empty pages, or a failed ask — would sit under its footer
    /// for good. Asked after each render (when the list may page on its own)
    /// and when the viewer's scroll comes to rest.
    private func askIfTheEndIsInView() {
        guard viewModel.hasMore else { return }
        tableView.layoutIfNeeded()
        let nearEnd = Set(dataSource.snapshot().itemIdentifiers.suffix(InboxPaging.nearEndRowCount))
        let shown = (tableView.indexPathsForVisibleRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        guard shown.contains(where: nearEnd.contains) else { return }
        pagingFooter.setSpinning(true)
        viewModel.loadMore()
    }

    /// The spinner hangs under the last row only while there is more to load.
    private func updatePagingFooter() {
        pagingFooter.setSpinning(false)
        let footer: UIView? = viewModel.hasMore ? pagingFooter : nil
        if tableView.tableFooterView !== footer { tableView.tableFooterView = footer }
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
    /// ⚠️ A FOOTER, not a bigger header margin.
    ///
    /// The section gap used to sit above the next header, which put the break in
    /// the right place visually and the pill in the wrong one: a plain table PINS
    /// its headers, so that margin travelled with the pill and hung a stuck
    /// header lower than the first one's. Spending the space at the END of the
    /// previous section separates the two lists without moving anything that pins.
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

    /// A row near the end asks for the next page (#644), early enough that
    /// it usually lands before the end does.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard viewModel.hasMore, let id = dataSource.itemIdentifier(for: indexPath),
              dataSource.snapshot().itemIdentifiers.suffix(InboxPaging.nearEndRowCount).contains(id)
        else { return }
        pagingFooter.setSpinning(true)
        viewModel.loadMore()
    }

    /// The viewer's own approach to the end: asks even after a failed ask.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        askIfTheEndIsInView()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { askIfTheEndIsInView() }
    }

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
            let isRequested = self.viewModel.isRequested(id)
            let message = UIAction(title: "Message", image: UIImage(systemName: "bubble.left")) {
                [weak self] _ in self?.viewModel.message(id)
            }
            let follow = UIAction(
                title: isRequested ? "Withdraw Request" : isFollowing ? "Unfollow" : "Follow",
                image: UIImage(systemName: isRequested || isFollowing ? "person.badge.minus" : "person.badge.plus")
            ) { [weak self] _ in self?.viewModel.toggleFollow(id) }
            let hide = UIAction(
                title: "Not interested",
                image: UIImage(systemName: "hand.thumbsdown"),
                attributes: .destructive
            ) { [weak self] _ in self?.dismiss(id) }
            return UIMenu(children: [message, follow, UIMenu(options: .displayInline, children: [hide])])
        }
    }
}

// MARK: - InboxSurface

extension SuggestionsViewController: InboxSurface {
    var listScrollView: UIScrollView? { tableView }

    var category: MessagesCategory { .suggestions }

    /// Loads on first arrival, and refreshes on every one after it.
    ///
    /// ⚠️ It used to load ONCE and leave the rest to pull-to-refresh, which
    /// was the only way this page ever re-read its suggestions. The pull opens
    /// search now, so the refresh moved here: coming back to the page is the
    /// moment someone would have pulled. `refresh()` no-ops while a load is in
    /// flight, so the first arrival's load is not doubled.
    func surfaceDidBecomeActive() {
        viewModel.loadIfNeeded()
        viewModel.refresh()
    }
}
