import DesignSystem
import MediaCore
import UIKit

/// The notifications list, as the shell's left drawer shows it: "New" (the six
/// most recent, then "Show more"), then "Earlier". Rows lie on the page with
/// no separators and no unread tint — see `NotificationSection` and
/// `NotificationCell` for why.
///
/// It does not know it lives in a drawer. The drawer container forwards real
/// appearance callbacks, and those are what drive the visit: `viewWillAppear`
/// refreshes, `viewDidAppear` marks the new rows seen, `viewDidDisappear` moves
/// them to "Earlier" (see `NotificationsViewModel`).
final class NotificationsViewController: UIViewController {
    private enum Item: Hashable {
        case row(String)
        case showMore(NotificationSection.Kind)
        /// Under the last row while there is another page (#608): a spinner,
        /// or "Try Again" after a failure.
        case pageFooter
    }

    /// How close to the end a row has to come into view to ask for the next
    /// page — early enough that it usually lands before the end does.
    static let nearEndRowCount = 5

    private let viewModel: NotificationsViewModel
    private let imagePipeline: ImagePipeline?

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let refreshControl = AppRefreshControl()
    /// Rows where the rows will be, until the first page lands (charter P8).
    private let skeleton = PersonListSkeletonView(avatarSize: NotificationCell.Metrics.avatarArea, showsTrailingBone: true)
    private let emptyState = EmptyStateView()

    private var dataSource: UICollectionViewDiffableDataSource<NotificationSection.Kind, Item>!
    private var sections: [NotificationSection] = []
    private var modelsByID: [String: NotificationDisplayModel] = [:]
    /// True between `viewDidAppear` and `viewWillDisappear` — the only time a
    /// change is worth animating.
    private var isOnScreen = false
    /// The section the list has scrolled into, named in the bar's leading
    /// slot — New, Yesterday, … — and a tap on it scrolls back to its title
    /// (#1573, the app's one contract).
    private lazy var sectionBinding: PinnedSectionBarBinding = {
        let binding = PinnedSectionBarBinding(viewController: self, placement: .leading, scope: "notifications")
        binding.onSelect = { [weak self] index in self?.scrollToSection(index) }
        return binding
    }()

    init(viewModel: NotificationsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Surface.page
        configureCollectionView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onPageFooterChange = { [weak self] _ in
            guard let self, !sections.isEmpty else { return }
            apply(sections)
        }
        render(.loading)
        viewModel.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.willReveal()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        viewModel.didReveal()
        #if DEBUG
        debugShowMoreIfRequested()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.didConceal()
        // The next visit starts at the top, where "New" is.
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false
        )
    }

    // MARK: - Setup

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            configuration.headerMode = .supplementary
            // The first title a small step under the large title; "Earlier"
            // the app's one section gap under the rows above it
            // (`Spacing.section` to its line, the bar's own air counted in).
            configuration.headerTopPadding = index == 0
                ? Spacing.sm
                : SectionTitleView.gapAbove(traits: environment.traitCollection)
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // A plain list pins its headers; these scroll with their rows.
            // "New" and "Earlier" are landmarks in one list, not sticky
            // chrome — and pinned on a clear background they would sit over
            // the rows passing under them.
            for header in section.boundarySupplementaryItems {
                header.pinToVisibleBounds = false
            }
            return section
        }
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        // THE ONE LIST THAT KEEPS UIKIT'S EDGE EFFECT under its bar (asked for,
        // 2026-09-28): rows scrolling up under "Notifications" soften into the
        // system's own top-edge blur. Every other list hides it — see
        // `prefersClearTopEdge` — so this is deliberately NOT called here, and
        // the style is stated rather than left `.automatic`, so a change of
        // UIKit default cannot silently turn it into the hard band.
        collectionView.topEdgeEffect.style = .soft
        collectionView.pin(to: view)
        // Named, not searched for: the effect is drawn where the navigation
        // bar's pocket meets the scroll view it TRACKS, and the skeleton and
        // the empty state are siblings of this list. Registering it also
        // keeps the large title collapsing with the rows inside the drawer's
        // custom container, whatever order the views end up in.
        setContentScrollView(collectionView, for: .top)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl

        let rowRegistration = UICollectionView.CellRegistration<NotificationCell, String> {
            [weak self] cell, _, id in
            guard let self, let model = modelsByID[id] else { return }
            cell.configure(with: model, imagePipeline: imagePipeline)
        }
        let showMoreRegistration = UICollectionView.CellRegistration<NotificationShowMoreCell, Int> {
            cell, _, hiddenCount in
            cell.configure(hiddenCount: hiddenCount)
        }
        let pageFooterRegistration = UICollectionView.CellRegistration<NotificationPageFooterCell, Bool> {
            cell, _, failed in
            cell.configure(failed: failed)
        }
        // The app's one section title (`SectionTitleView`): a heading, no
        // count, nothing to tap.
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionTitleSupplementaryView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self, sections.indices.contains(indexPath.section) else { return }
            header.configure(.init(title: sections[indexPath.section].title))
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            switch item {
            case .row(let id):
                return collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            case .showMore(let kind):
                let hidden = self?.sections.first { $0.kind == kind }?.hiddenCount ?? 0
                return collectionView.dequeueConfiguredReusableCell(using: showMoreRegistration, for: indexPath, item: hidden)
            case .pageFooter:
                let failed = self?.viewModel.pageFooter == .retry
                return collectionView.dequeueConfiguredReusableCell(using: pageFooterRegistration, for: indexPath, item: failed)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configureStatusViews() {
        skeleton.pin(to: view)
        skeleton.isHidden = true
        emptyState.pin(to: view)
        emptyState.isHidden = true
    }

    // MARK: - Render

    private func render(_ phase: NotificationsViewModel.Phase) {
        switch phase {
        case .loading:
            // A pull-to-refresh keeps its own indicator and its rows; only a
            // first load, with nothing to show, wears the skeleton.
            if !refreshControl.isRefreshing, sections.isEmpty {
                skeleton.showSkeleton()
                collectionView.isHidden = true
            }
            emptyState.isHidden = true
        case .content(let sections):
            refreshControl.endRefreshing()
            emptyState.isHidden = true
            collectionView.isHidden = false
            apply(sections)
            skeleton.fadeOutSkeleton()
        case .empty:
            refreshControl.endRefreshing()
            collectionView.isHidden = true
            skeleton.fadeOutSkeleton()
            emptyState.configure(
                symbolName: "bell",
                title: "No notifications yet",
                subtitle: "Likes, comments and mentions of your posts will show up here."
            )
            emptyState.isHidden = false
        case .failed(let message):
            refreshControl.endRefreshing()
            collectionView.isHidden = true
            skeleton.fadeOutSkeleton()
            emptyState.configure(
                symbolName: "wifi.exclamationmark",
                title: message,
                actionTitle: "Try Again"
            ) { [weak self] in
                self?.viewModel.refresh()
            }
            emptyState.isHidden = false
        }
    }

    private func apply(_ newSections: [NotificationSection]) {
        let previous = modelsByID
        sections = newSections
        modelsByID = Dictionary(
            newSections.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var snapshot = NSDiffableDataSourceSnapshot<NotificationSection.Kind, Item>()
        for section in newSections {
            snapshot.appendSections([section.kind])
            snapshot.appendItems(section.rows.map { .row($0.id) }, toSection: section.kind)
            if section.hiddenCount > 0 {
                snapshot.appendItems([.showMore(section.kind)], toSection: section.kind)
            }
        }
        // The page footer closes the LAST section, whichever it is.
        if viewModel.pageFooter != .none, let last = newSections.last {
            snapshot.appendItems([.pageFooter], toSection: last.kind)
        }
        // A row whose content changed under the same id (a new time, a fold
        // that added a sender) is re-drawn in place.
        let changed = modelsByID.compactMap { id, model -> Item? in
            guard let old = previous[id], old != model else { return nil }
            return .row(id)
        }
        snapshot.reconfigureItems(changed.filter { snapshot.indexOfItem($0) != nil })
        let showMores = newSections.map { Item.showMore($0.kind) }.filter { snapshot.indexOfItem($0) != nil }
        if !showMores.isEmpty { snapshot.reconfigureItems(showMores) }
        if snapshot.indexOfItem(.pageFooter) != nil {
            snapshot.reconfigureItems([.pageFooter])
        }
        dataSource.apply(snapshot, animatingDifferences: isOnScreen && !previous.isEmpty)
        updateSectionItem()
    }

    #if DEBUG
    /// `-notifications-show-more`: presses "Show more" a second after the list
    /// is first on screen, so the expansion can be filmed without a tap.
    private func debugShowMoreIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-notifications-show-more") else { return }
        QAWait.until("-notifications-show-more: a list with Show more", { [weak self] in
            guard let self else { return true }
            return sections.contains { $0.hiddenCount > 0 }
        }) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let kind = sections.first(where: { $0.hiddenCount > 0 })?.kind else { return }
                viewModel.showMore(in: kind)
            }
        }
    }
    #endif
}

// MARK: - The section in the bar (#1573)

extension NotificationsViewController {
    /// The section titles' tops, in the list's content coordinates.
    ///
    /// ⚠️ Asked of the LAYOUT, and only for sections the list already has: the
    /// collection view's own lookup aborts for a section its data has not
    /// caught up with (an apply in flight, the first render before a layout).
    private var sectionTops: [CGFloat] {
        let known = collectionView.numberOfSections
        return sections.indices.map { index in
            guard index < known else { return .greatestFiniteMagnitude }
            return collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index)
            )?.frame.minY ?? .greatestFiniteMagnitude
        }
    }

    /// Tells the bar which section the list is in.
    func updateSectionItem() {
        let described = sections.map {
            PinnedSectionBarBinding.Section(id: $0.kind.rawValue, title: $0.title)
        }
        sectionBinding.update(sections: described, sectionTops: sectionTops, in: collectionView)
    }

    /// Puts section `index`'s title under the bar — what tapping its name
    /// means. Clamped: a list too short to scroll stays where it is.
    private func scrollToSection(_ index: Int) {
        guard sectionTops.indices.contains(index) else { return }
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let furthest = collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        let target = min(sectionTops[index] - inset.top, furthest)
        collectionView.setContentOffset(CGPoint(x: 0, y: max(-inset.top, target)), animated: true)
    }

    #if DEBUG
    /// The bar's section item while it is shown — what a test reads.
    var debugSectionItemTitle: String? { sectionBinding.item?.title }
    #endif
}

extension NotificationsViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSectionItem()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let id):
            viewModel.didSelect(id)
        case .showMore(let kind):
            viewModel.showMore(in: kind)
        case .pageFooter:
            viewModel.retryPage()
        case nil:
            break
        }
    }

    /// Paging (#608): one of the last rows, or the footer itself, coming into
    /// view asks for the next page. Deferred, so the page's snapshot is never
    /// applied from inside the display pass.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard viewModel.pageFooter == .loading, let item = dataSource.itemIdentifier(for: indexPath),
              dataSource.snapshot().itemIdentifiers.suffix(Self.nearEndRowCount).contains(item) else { return }
        DispatchQueue.main.async { [weak self] in self?.viewModel.loadNextPageIfNeeded() }
    }

    /// Only the "Try Again" footer answers a tap; the spinner is not a button.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .pageFooter || viewModel.pageFooter == .retry
    }
}
