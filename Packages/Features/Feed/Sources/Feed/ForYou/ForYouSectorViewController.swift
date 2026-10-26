import CoreNavigation
import DesignSystem
import FeedInterface
import UIKit

/// A page of the For You sector (#1703): a whole screen that, while it is in
/// front, writes the SECTOR's navigation item instead of its own.
///
/// The navigation bar shows the stack's top controller's item — the sector's.
/// Each page keeps composing its bar exactly as it does alone (its leading
/// run, its trailing items, its appearance), through `navigationItem`; the
/// page in front answers that with the sector's item (`sectorNavigationItem`),
/// the one behind with its own (`ownNavigationItem`), and the sector copies
/// the state across at every change of page.
@MainActor
protocol ForYouSectorPage: UIViewController {
    /// The sector's item while this page is in front; nil behind.
    var sectorNavigationItem: UINavigationItem? { get set }
    /// The page's own item, whatever is in front.
    var ownNavigationItem: UINavigationItem { get }
    /// The sector's selector, worn just inboard of the bell.
    var sectorSelectorItem: UIBarButtonItem? { get set }
    /// The page came to the front (true) or went behind (false), after its
    /// appearance callbacks.
    func sectorPageDidChangeActivity(_ isActive: Bool)
    /// The sector's safe area, handed over (see the sector's note on Feed).
    func sectorSafeAreaDidChange(_ insets: UIEdgeInsets)
    /// Whether a horizontal drag starting now is the page's own — a drawer it
    /// holds open, which the swipe closes — rather than a change of page.
    func sectorPageOwnsHorizontalDrag(velocity: CGPoint) -> Bool
}

/// The For You tab (#1703, #1705, the owner 2026-10-24/25): two pages — Feed
/// (the discovery list: friends, following, the "For you" posts) and Shots
/// (the full-screen photos and short videos) — switched by the app's selector
/// (`PagedTabBar`) just right of the bell, or by a horizontal swipe. Opens on
/// Shots.
///
/// **One page in front.** Appearance callbacks are forwarded by hand to the
/// page in front only (`shouldAutomaticallyForwardAppearanceMethods`): the
/// page behind is disappeared — its playback parked, its chrome handed back —
/// though its view stays in the pager, and the new page appears at the settle.
///
/// **The page over half the screen is the page in front** (#1707, the owner):
/// mid-drag, as soon as it fills more than 50%, it wears the bar and appears
/// — Shots' media plays from there, not from the settle — and the other page
/// disappears; back under half, they swap back.
///
/// **The pager gives away what it cannot use** (`yieldsPastEnds`): on Shots,
/// the last page, a leftward drag belongs to its own swipe chain.
final class ForYouSectorViewController: UIViewController, HeaderAccessoryHosting, ForYouSectorPaging {
    static let feedIndex = 0
    static let shotsIndex = 1
    static let selectorItemID = "foryou.sector.selector"

    private let pages: [any ForYouSectorPage]
    /// The selector's words (#1705, the owner's pick): Feed, the discovery
    /// list; Shots, the full-screen photos and short videos.
    static let titles = ["Feed", "Shots"]
    private let selector = PagedTabBar(titles: ForYouSectorViewController.titles, style: .navigationTitle)
    private lazy var selectorItem = BarItems.container(id: Self.selectorItemID, view: selector)
    private var pager: HorizontalPagerView?
    /// The page in front — the one whose bar the sector wears.
    private(set) var activeIndex = ForYouSectorViewController.startIndex(
        arguments: ProcessInfo.processInfo.arguments
    )
    private var isVisible = false

    var isShowingShots: Bool { activeIndex == Self.shotsIndex }
    var onPageChange: (() -> Void)?

    /// Shots pauses behind the notifications drawer (#1703).
    func setSetAside(_ setAside: Bool) {
        (pages[Self.shotsIndex] as? SnapFeedViewController)?.setSetAside(setAside)
    }

    /// The page the sector opens on: Shots. DEBUG: Feed under the QA hooks
    /// that drive its list (`-foryou-*`, `-zoom-repeat*`, `-hero-audit`) —
    /// they were written for a tab that opened on it.
    static func startIndex(arguments: [String]) -> Int {
        #if DEBUG
        let drivesFeed = arguments.contains {
            $0.hasPrefix("-foryou-") || $0.hasPrefix("-zoom-repeat") || $0 == "-hero-audit"
        }
        if drivesFeed { return feedIndex }
        #endif
        return shotsIndex
    }

    init(feed: any ForYouSectorPage, shots: any ForYouSectorPage) {
        pages = [feed, shots]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        selector.hosting = .platter
        for page in pages {
            addChild(page)
            page.sectorSelectorItem = selectorItem
        }
        let pager = HorizontalPagerView(pages: pages.map(\.view), initialIndex: activeIndex)
        pager.yieldsPastEnds = true
        // The notifications drawer is "page −1": pulled past Feed with the
        // pages' own gesture, from the very edge (a root has no back swipe) (#1739).
        pager.leadingPullTarget = DrawerPull.shared
        pager.reservesLeadingEdge = false
        pager.yieldsDrag = { [weak self] velocity in
            guard let self else { return false }
            return self.pages[self.activeIndex].sectorPageOwnsHorizontalDrag(velocity: velocity)
        }
        pager.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pager)
        NSLayoutConstraint.activate([
            // Under the bars, like every paged header in the app: the pages
            // inset themselves through the safe area.
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for page in pages { page.didMove(toParent: self) }
        self.pager = pager

        selector.select(activeIndex)
        // The selector follows the swipe; the pages follow the selector.
        pager.onProgress = { [weak self] progress in
            self?.selector.setProgress(progress)
            self?.applyOccupancy(shotsShare: progress)
        }
        pager.onSettled = { [weak self] index in self?.settle(on: index) }
        selector.onScrub = { [weak self] progress in self?.pager?.scrub(to: progress) }
        selector.onScrubEnd = { [weak self] velocity in self?.pager?.settleAfterScrub(velocityInPages: velocity) }
        selector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pager?.setActivePage(self.selector.selectedIndex, animated: self.selector.animatesPageChanges)
        }, for: .valueChanged)

        // The page in front wears the sector's item from the start.
        let front = pages[activeIndex]
        Self.copy(front.ownNavigationItem, to: navigationItem)
        front.sectorNavigationItem = navigationItem
    }

    /// ⚠️ FEED GETS NO SAFE AREA FROM UIKIT IN HERE (measured, #1703): its
    /// root view read 0 at the top while the pager it sits in, and Shots
    /// beside it, read the bars' 116 — on screen or off, first page or not,
    /// even with `additionalSafeAreaInsets` set on it. Its list started under
    /// the bars and stayed there. So every page is HANDED the sector's insets
    /// (`sectorSafeAreaDidChange`), and Feed lays its list out from them.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        handOverSafeArea()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        handOverSafeArea()
    }

    private func handOverSafeArea() {
        let insets = view.safeAreaInsets
        for page in pages where page.isViewLoaded { page.sectorSafeAreaDidChange(insets) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        pages[activeIndex].beginAppearanceTransition(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pages[activeIndex].endAppearanceTransition()
        #if DEBUG
        // QA (#1707): `-sector-scrub <Shots' share>` holds the pager mid-drag,
        // to film the swap at half.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-sector-scrub"), flag + 1 < arguments.count,
           let share = Double(arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pager?.scrub(to: share) }
        }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        pages[activeIndex].beginAppearanceTransition(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pages[activeIndex].endAppearanceTransition()
    }

    // MARK: - Paging

    /// Whether a swipe may change page — off while Shots' comments are open
    /// (their stream and composer own the screen).
    func setPagingEnabled(_ enabled: Bool) {
        pager?.isPagingEnabled = enabled
    }

    /// Brings `index` to the front, as a tap on its segment would.
    func showPage(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        pager?.setActivePage(index, animated: animated)
        if !animated { settle(on: index) }
    }

    /// The pager's position as Shots' share of the screen (Feed's the rest):
    /// the page over half is brought to the front.
    private func applyOccupancy(shotsShare: CGFloat) {
        let shots = min(max(shotsShare, 0), 1)
        if shots > 0.5 { bringToFront(Self.shotsIndex) } else if shots < 0.5 { bringToFront(Self.feedIndex) }
    }

    private func settle(on index: Int) {
        selector.select(index)
        bringToFront(index)
    }

    /// Makes `index` the page in front: its bar on the sector's item, its
    /// appearance — the other page's taken back.
    private func bringToFront(_ index: Int) {
        guard index != activeIndex, pages.indices.contains(index) else { return }
        let outgoing = pages[activeIndex]
        let incoming = pages[index]
        // The bar's state goes home with the page leaving, and the arriving
        // page's comes out.
        Self.copy(navigationItem, to: outgoing.ownNavigationItem)
        outgoing.sectorNavigationItem = nil
        Self.copy(incoming.ownNavigationItem, to: navigationItem)
        incoming.sectorNavigationItem = navigationItem
        activeIndex = index
        if isVisible {
            outgoing.beginAppearanceTransition(false, animated: true)
            outgoing.endAppearanceTransition()
            incoming.beginAppearanceTransition(true, animated: true)
            incoming.endAppearanceTransition()
        }
        outgoing.sectorPageDidChangeActivity(false)
        incoming.sectorPageDidChangeActivity(true)
        onPageChange?()
    }

    /// Drives the pager as a drag at `shotsShare` would — for tests.
    func debugApplyOccupancy(shotsShare: CGFloat) { applyOccupancy(shotsShare: shotsShare) }

    /// Everything a page composes in its bar.
    static func copy(_ source: UINavigationItem, to target: UINavigationItem) {
        target.title = source.title
        target.titleView = source.titleView
        target.leftBarButtonItems = source.leftBarButtonItems
        target.rightBarButtonItems = source.rightBarButtonItems
        target.standardAppearance = source.standardAppearance
        target.scrollEdgeAppearance = source.scrollEdgeAppearance
        target.compactAppearance = source.compactAppearance
        target.compactScrollEdgeAppearance = source.compactScrollEdgeAppearance
    }

    // MARK: - HeaderAccessoryHosting

    /// The shell's bell leads both pages' bars.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        for case let page as any HeaderAccessoryHosting in pages {
            page.setLeadingAccessoryItem(item)
        }
    }

    /// The shell's points badge: Feed's (Shots wears its own).
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        (pages[Self.feedIndex] as? any HeaderAccessoryHosting)?.setTrailingAccessoryItem(item)
    }
}

