import CoreNavigation
import DesignSystem
import MediaCore
import UIKit

/// The lists behind a hero header's counters (#2237), pushed by a tap on a
/// counter and opened on its tab: one paged list per tab, a swipeable pager
/// between them, the tabs' strip in the toolbar at the foot of the screen —
/// the shape of a profile's Followers / Following / Friends
/// (`ProfileRelationshipsViewController`), whose rules it keeps:
///
/// - **the strip in the toolbar**, never the title slot: a pushed screen's
///   leading group already holds the back button, and a toolbar has no item
///   groups to collapse into a "•••";
/// - **lazy pages**: a list is made when the pager is about to show it, and
///   reads its first page then — never every tab's audience on the push;
/// - **the pager waits for the back swipe** (#1300): the full-surface swipe
///   pops from the first tab only, pages back from the others.
///
/// What a tab holds and what a row does are the source's
/// (`PersonListsSource`); the screen draws.
public final class PersonListsViewController: UIViewController {
    /// The strip. Internal so tests read what it says.
    let tabBar: PagedTabBar
    let pager: HorizontalPagerView
    private var pages: [PersonListPageViewController]
    private(set) var tabs: [PersonListTab]
    /// Held for the screen's life: the lists' feeds hold it weakly.
    private let source: any PersonListsSource

    /// - Parameters:
    ///   - title: the bar's title — the group's or the channel's name.
    ///   - tabs: in the strip's order.
    ///   - initialTab: the counter's tab; the first when unknown.
    public init(
        title: String, tabs: [PersonListTab], initialTab: String, source: any PersonListsSource,
        imagePipeline: ImagePipeline?
    ) {
        precondition(!tabs.isEmpty, "a list screen holds at least one tab")
        self.tabs = tabs
        self.source = source
        tabBar = PagedTabBar(titles: tabs.map(\.title), style: .navigationTitle)
        let made = tabs.map { tab in
            PersonListPageViewController(tab: tab, feed: PersonListFeed(tab: tab.id, source: source), imagePipeline: imagePipeline)
        }
        pages = made
        let start = tabs.firstIndex { $0.id == initialTab } ?? 0
        // ⚠️ LAZY: a page's view — and its first read — when the pager is
        // about to show it, as the profile's lists (charter P3).
        pager = HorizontalPagerView(
            lazyPages: made.map { page in { page.view } }, initialIndex: start, prefersClearTopEdge: false
        )
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = title
        hidesBottomBarWhenPushed = true
        for page in made { page.host = self }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        for page in pages {
            addChild(page)
            page.didMove(toParent: self)
        }
        pager.pin(to: view)
        // The titled header's soft blur, on the pager: the lists are nested
        // in its scroll view and UIKit draws no edge for them (#1591).
        pager.pagingScrollView.applyTopEdge(for: .titled)
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pager.setActivePage(tabBar.selectedIndex, animated: tabBar.animatesPageChanges)
        }, for: .valueChanged)
        tabBar.onScrub = { [weak self] progress in self?.pager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in self?.pager.settleAfterScrub(velocityInPages: velocity) }
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onSettled = { [weak self] index in self?.pages[safe: index]?.feed.start() }
        tabBar.select(pager.activeIndex)
        configureToolbar()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // One tab is no strip: the toolbar stays down.
        navigationController?.setToolbarHidden(tabs.count < 2, animated: animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        subordinatePagerToBackSwipes()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setStackGesturesEnabled(true)
        guard isMovingFromParent else { return }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    // MARK: - For the source

    /// Reads `tabIDs` again from their first page — after a write that
    /// changed them (a role, a removal, an answered request). Nil: every tab.
    public func reload(_ tabIDs: Set<String>? = nil) {
        for page in pages where tabIDs?.contains(page.listTab.id) ?? true {
            page.feed.reload()
        }
    }

    /// New words for the tabs (their counts), in the same order.
    public func setTabs(_ next: [PersonListTab]) {
        guard next.map(\.id) == tabs.map(\.id) else { return }
        tabs = next
        tabBar.setTitles(next.map(\.title))
        for (page, tab) in zip(pages, next) { page.listTab = tab }
    }

    /// The tab on screen.
    public var activeTab: String { tabs[safe: pager.activeIndex]?.id ?? tabs[0].id }

    // MARK: - The strip

    /// ⚠️ THE TOOLBAR IS WHAT OWNS THE BOTTOM: pushed with
    /// `hidesBottomBarWhenPushed`, there is no tab bar to hang an accessory
    /// over. The strip leads it, in the bar's own platter (no bubble in a
    /// bubble), as on the profile's lists.
    private func configureToolbar() {
        guard tabs.count > 1 else { return }
        selectorTouchProbe.attach(to: tabBar)
        tabBar.hosting = .platter
        toolbarItems = [BarItems.container(id: "person-lists.tabs", view: tabBar), .flexibleSpace()]
    }

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`.
    private lazy var selectorTouchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.setStackGesturesEnabled(!isTouching)
    }

    /// Every pan on the stack's container, suspended for the length of a
    /// touch on the strip and restored to what it was — the stack has two
    /// back-swipe recognisers and vends one.
    private func setStackGesturesEnabled(_ isEnabled: Bool) {
        if isEnabled {
            for (recogniser, wasEnabled) in suspendedPans { recogniser.isEnabled = wasEnabled }
            suspendedPans = []
            return
        }
        guard navigationController?.topViewController === self, suspendedPans.isEmpty,
              let host = navigationController?.view else { return }
        let pans = (host.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
        suspendedPans = pans.map { ($0, $0.isEnabled) }
        for recogniser in pans { recogniser.isEnabled = false }
    }

    private var suspendedPans: [(UIGestureRecognizer, Bool)] = []
    private var didSubordinatePagerToPop = false

    /// ⚠️ THE PAGER WAITS FOR THE BACK SWIPE (#1300): the full-surface one
    /// declines past the first tab (`allowsContentPop`), and the pager pages.
    private func subordinatePagerToBackSwipes() {
        guard !didSubordinatePagerToPop, let navigationController else { return }
        didSubordinatePagerToPop = true
        if let pop = navigationController.interactivePopGestureRecognizer {
            pager.horizontalPan.require(toFail: pop)
        }
        if let content = navigationController.interactiveContentPopGestureRecognizer {
            pager.horizontalPan.require(toFail: content)
        }
    }

    #if DEBUG
    /// The strip's tabs, in order. Tests.
    public var debugTabIDs: [String] { tabs.map(\.id) }
    /// Tab `id`'s list. Tests.
    public func debugFeed(_ id: String) -> PersonListFeed? { pages.first { $0.listTab.id == id }?.feed }
    /// What tab `id` says while empty, once loaded. Tests.
    public func debugEmptyTitle(_ id: String) -> String? { pages.first { $0.listTab.id == id }?.listTab.empty.title }
    #endif
}

// MARK: - The native back swipe (#1300)

extension PersonListsViewController: ContentPopGating {
    public func allowsContentPop(beginningAt point: CGPoint, in view: UIView) -> Bool {
        guard let navigationController else { return false }
        return PagedScreenDismissalPolicy.allowsFullWidthDismissal(
            activeIndex: pager.activeIndex, isPushed: navigationController.viewControllers.first !== self
        )
    }
}

// MARK: - How it is left (#1144)

extension PersonListsViewController: StackScreen {
    public var leaving: ScreenLeaving { .nativeBack }
}

/// One tab's list, a page of the pager. Each tab its own controller, as the
/// profile's lists: during a swipe two are on screen, each with its own
/// rows, its own empty state and its own scroll.
final class PersonListPageViewController: UIViewController {
    private enum Section: Hashable { case lead, people, skeleton, paging }
    private enum Item: Hashable {
        case lead
        case person(String)
        case placeholder(Int)
        case paging
    }

    var listTab: PersonListTab {
        didSet {
            guard listTab != oldValue, isViewLoaded else { return }
            render(feed.phase)
            setNeedsUpdateContentUnavailableConfiguration()
        }
    }
    let feed: PersonListFeed
    weak var host: PersonListsViewController?
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let refreshControl = AppRefreshControl()
    private var rowsByID: [String: PersonListRow] = [:]

    init(tab: PersonListTab, feed: PersonListFeed, imagePipeline: ImagePipeline?) {
        self.listTab = tab
        self.feed = feed
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureList()
        feed.onChange = { [weak self] phase in
            self?.render(phase)
            self?.setNeedsUpdateContentUnavailableConfiguration()
        }
        render(feed.phase)
        // Made when the pager is about to show it: its first page now.
        feed.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The skeleton runs to the foot, and how many rows that takes is
        // only known once laid out.
        if case .loading = feed.phase { render(.loading) }
    }

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.alwaysBounceHorizontal = false
        // Clear: the pager carries the blur (see the screen's `viewDidLoad`).
        collectionView.prefersClearTopEdge()
        collectionView.pin(to: view)
        refreshControl.addAction(UIAction { [weak self] _ in self?.feed.reload() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl

        let lead = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let action = self?.listTab.leadingAction else { return }
            var content = cell.defaultContentConfiguration()
            content.text = action.title
            content.image = UIImage(systemName: action.symbol)
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
        }
        let person = UICollectionView.CellRegistration<PersonListCell, String> { [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            configure(cell, with: row)
        }
        let skeleton = UICollectionView.CellRegistration<PersonSkeletonCell, Int> { cell, _, index in
            cell.configure(at: index)
            // Laid out before any animation sees it (#717).
            UIView.performWithoutAnimation { cell.layoutIfNeeded() }
        }
        let paging = UICollectionView.CellRegistration<PagingFooterCell, Int> { cell, _, _ in
            cell.footer.loadingAccessibilityLabel = "Loading more people"
            cell.configure(.loading)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, item in
            switch item {
            case .lead: collectionView.dequeueConfiguredReusableCell(using: lead, for: path, item: item)
            case .person(let id): collectionView.dequeueConfiguredReusableCell(using: person, for: path, item: id)
            case .placeholder(let index): collectionView.dequeueConfiguredReusableCell(using: skeleton, for: path, item: index)
            case .paging: collectionView.dequeueConfiguredReusableCell(using: paging, for: path, item: 0)
            }
        }
    }

    private func configure(_ cell: PersonListCell, with row: PersonListRow) {
        cell.configure(with: PersonRowContent(displayName: row.name, handle: row.detail, monogram: row.monogram))
        cell.avatar.setPicture(row.avatarURL, pipeline: imagePipeline)
        if row.answersRequest {
            // A request's two answers, as the Requests screen draws them
            // (#2231): Approve tinted, Decline a glyph.
            let approve = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Approve"))
            approve.accessibilityLabel = "Approve \(row.name)"
            let decline = AppIconButton(style: .glyph, content: .symbol("xmark"))
            decline.inkColor = .secondaryLabel
            decline.accessibilityLabel = "Decline \(row.name)"
            approve.addAction(UIAction { [weak self] _ in self?.answer(row, approve: true) }, for: .primaryActionTriggered)
            decline.addAction(UIAction { [weak self] _ in self?.answer(row, approve: false) }, for: .primaryActionTriggered)
            cell.accessories = [
                .customView(configuration: .init(customView: approve, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
                .customView(configuration: .init(customView: decline, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
            ]
            return
        }
        guard !row.actions.isEmpty else { return }
        let more = AppIconButton(style: .glyph, content: .symbol("ellipsis"))
        more.inkColor = .secondaryLabel
        more.accessibilityLabel = "Manage \(row.name)"
        more.addAction(UIAction { [weak self, weak more] _ in self?.presentMenu(for: row, from: more) }, for: .primaryActionTriggered)
        cell.accessories.append(.customView(configuration: .init(
            customView: more, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual
        )))
    }

    // MARK: - Render

    private func render(_ phase: PersonListFeed.Phase) {
        guard isViewLoaded else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if listTab.leadingAction != nil {
            snapshot.appendSections([.lead])
            snapshot.appendItems([.lead], toSection: .lead)
        }
        var rows: [PersonListRow] = []
        switch phase {
        case .loading:
            let count = PersonSkeletonCell.rowsToFill(max(view.bounds.height, 1))
            snapshot.appendSections([.skeleton])
            snapshot.appendItems((0..<max(1, count)).map(Item.placeholder), toSection: .skeleton)
        case .content(let shown, let isLoadingMore):
            rows = shown
            snapshot.appendSections([.people])
            snapshot.appendItems(shown.map { .person($0.id) }, toSection: .people)
            if isLoadingMore {
                snapshot.appendSections([.paging])
                snapshot.appendItems([.paging], toSection: .paging)
            }
        case .empty, .failed:
            break
        }
        if case .loading = phase {} else { refreshControl.endRefreshing() }
        let before = rowsByID
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = rows.filter { before[$0.id] != nil && before[$0.id] != $0 }.map { Item.person($0.id) }
        snapshot.reconfigureItems(changed)
        if listTab.leadingAction != nil { snapshot.reconfigureItems([.lead]) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Never a header over nothing: an empty tab says so, a failed one
    /// offers Try Again — the platform's own block, as on the profile.
    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch feed.phase {
        case .empty:
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: listTab.empty.symbol)
            empty.text = listTab.empty.title
            empty.secondaryText = listTab.empty.message
            contentUnavailableConfiguration = empty
        case .failed(let message):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = "Couldn't Load"
            failed.secondaryText = message
            var button = UIButton.Configuration.borderless()
            button.title = "Try Again"
            failed.button = button
            failed.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.feed.reload() }
            contentUnavailableConfiguration = failed
        case .loading, .content:
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: - Actions

    private func presentMenu(for row: PersonListRow, from anchor: UIView?) {
        let sheet = UIAlertController(title: row.name, message: nil, preferredStyle: .actionSheet)
        for action in row.actions {
            sheet.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) {
                [weak self] _ in self?.perform(action, on: row)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = anchor ?? view
        present(sheet, animated: true)
    }

    private func perform(_ action: PersonListRowAction, on row: PersonListRow) {
        guard let host else { return }
        host.sourceForPages?.perform(action, on: row, in: listTab.id, from: host)
    }

    private func answer(_ row: PersonListRow, approve: Bool) {
        guard let host else { return }
        host.sourceForPages?.answer(row, approve: approve, in: listTab.id, from: host)
    }
}

extension PersonListPageViewController: UICollectionViewDelegate {
    /// The next page as the end comes into view, three rows ahead; asked a
    /// runloop turn later, never inside `willDisplay`'s layout.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .person = dataSource.itemIdentifier(for: indexPath) else { return }
        let count = collectionView.numberOfItems(inSection: indexPath.section)
        guard indexPath.item >= count - 3 else { return }
        DispatchQueue.main.async { [weak self] in self?.feed.loadMoreIfNeeded() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .lead: true
        case .person(let id): rowsByID[id]?.opens == true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let host, let source = host.sourceForPages else { return }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .lead:
            source.performLeadingAction(in: listTab.id, from: host)
        case .person(let id):
            guard let row = rowsByID[id], row.opens else { return }
            source.open(row, in: listTab.id, from: host)
        default:
            break
        }
    }

    /// A row's "⋯" on a long press too.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, case .person(let id) = dataSource.itemIdentifier(for: path),
              let row = rowsByID[id], !row.actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: row.actions.map { action in
                UIAction(title: action.title, attributes: action.isDestructive ? .destructive : []) { _ in
                    self?.perform(action, on: row)
                }
            })
        })
    }
}

extension PersonListsViewController {
    /// The source, for the pages.
    fileprivate var sourceForPages: (any PersonListsSource)? { source }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
