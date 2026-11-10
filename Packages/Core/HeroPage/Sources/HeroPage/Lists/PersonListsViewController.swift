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

extension PersonListsViewController {
    /// The source, for the pages.
    var sourceForPages: (any PersonListsSource)? { source }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
