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
/// **The page leaving blurs by how little of the screen it fills** (#1707,
/// the owner): 100% at 0%, nothing from 50% on (`blurAmount`), so the change
/// of page cross-fades. Only the page the drag LEFT — the settled one — blurs;
/// the page arriving stays sharp.
/// The blur exists only mid-drag: at rest neither page wears one
/// (`PageBlur.clear`), so nothing is left on the paused animator that drives
/// it when the tab's view leaves the window.
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
    /// Each page's occupancy blur, in page order.
    private var blurs: [PageBlur] = []
    /// The page the sector last settled on — the one a drag leaves, and the
    /// only one that blurs (#1707).
    private var settledIndex = ForYouSectorViewController.startIndex(arguments: ProcessInfo.processInfo.arguments)
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
        // Each page in a host that lays its blur over it (#1707).
        let hosts = pages.enumerated().map { index, page in
            let blur = PageBlur(style: index == Self.shotsIndex ? .dark : .regular)
            blurs.append(blur)
            return Self.host(page.view, under: blur.view)
        }
        let pager = HorizontalPagerView(pages: hosts, initialIndex: activeIndex)
        pager.yieldsPastEnds = true
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
            self.pager?.setActivePage(self.selector.selectedIndex, animated: true)
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
        // to film the occupancy blur and the swap at half.
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

    /// The pager's position as each page's share of the screen (`shotsShare`
    /// = Shots', Feed's the rest): the page over half is brought to the front,
    /// and each blurs by its share.
    private func applyOccupancy(shotsShare: CGFloat) {
        let shots = min(max(shotsShare, 0), 1)
        if shots > 0.5 { bringToFront(Self.shotsIndex) } else if shots < 0.5 { bringToFront(Self.feedIndex) }
        // At rest, nothing: a page fully off screen is not seen, and a paused
        // animator left over it would outlive the window.
        guard abs(shots - shots.rounded()) > 0.001 else { return blurs.forEach { $0.clear() } }
        // Only the page leaving: the one the drag started from.
        let shares = [1 - shots, shots]
        for (index, blur) in blurs.enumerated() {
            if index == settledIndex {
                blur.setAmount(Self.blurAmount(occupancy: shares[index]))
            } else {
                blur.clear()
            }
        }
    }

    /// How blurred a page filling `occupancy` of the screen is (#1707):
    /// fully at 0, not at all from half the screen on, linear between.
    static func blurAmount(occupancy: CGFloat) -> CGFloat {
        min(1, max(0, 1 - occupancy / 0.5))
    }

    private func settle(on index: Int) {
        selector.select(index)
        bringToFront(index)
        settledIndex = index
        blurs.forEach { $0.clear() }
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

    /// `page` filling a plain host, `blur` laid over it — touches pass
    /// through the blur.
    private static func host(_ page: UIView, under blur: UIView) -> UIView {
        let host = UIView()
        page.translatesAutoresizingMaskIntoConstraints = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        host.addSubview(page)
        host.addSubview(blur)
        NSLayoutConstraint.activate([page, blur].flatMap { view in [
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ] })
        return host
    }

    /// Each page's blur amount now (0 = none) — for tests.
    var debugBlurAmounts: [CGFloat] { blurs.map(\.amount) }

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

/// A page's occupancy blur (#1707): a blur effect whose strength is the
/// fraction of a paused animator taking it from none to full — the one way
/// UIKit animates a blur's radius. Only ever live mid-drag (`clear` at rest).
@MainActor
private final class PageBlur {
    let view = UIVisualEffectView(effect: nil)
    private let style: UIBlurEffect.Style
    private var animator: UIViewPropertyAnimator?
    private(set) var amount: CGFloat = 0

    init(style: UIBlurEffect.Style) {
        self.style = style
    }

    func setAmount(_ value: CGFloat) {
        guard value > 0 else { return clear() }
        if animator == nil {
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [view, style] in
                view.effect = UIBlurEffect(style: style)
            }
            animator.pausesOnCompletion = true
            self.animator = animator
        }
        amount = min(1, value)
        animator?.fractionComplete = amount
    }

    /// No blur, and no animator left running.
    func clear() {
        amount = 0
        guard let animator else { return }
        animator.stopAnimation(true)
        self.animator = nil
        view.effect = nil
    }
}
