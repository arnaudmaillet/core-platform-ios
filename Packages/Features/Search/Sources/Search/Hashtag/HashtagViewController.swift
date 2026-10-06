import CoreNavigation
import DesignSystem
import UIKit

/// One `#tag`'s posts (#524): Top, a gallery of its most liked posts with a
/// picture, and Recent, every post as cards, newest first.
///
///     navigation bar   [back]   #travel / 12 posts
///     bottom band      [Top | Recent]
///
/// The tag is the title and its count the subtitle — the bar's own two
/// lines, so the header is UIKit's and rides a push like any other.
///
/// The two pages and the band are the search results screen's, minus what a
/// tag has no use for (a query field, filters, people): the same opaque
/// `SearchPostSurface`s filled from Feed — so a tile opens the post the way
/// For You does — and the same `SelectorAccessory` at the foot, for the
/// reasons `SearchResultsViewController` documents (the strip in the band,
/// the strip winning the touch it is under, the stack's pans suspended while
/// it does).
@MainActor
final class HashtagViewController: UIViewController {
    private let viewModel: HashtagViewModel
    private let tabBar = PagedTabBar(titles: ["Top", "Recent"], style: .navigationTitle)
    private var pager: HorizontalPagerView!
    let topPage: any SearchPostSurface
    let recentPage: any SearchPostSurface
    private(set) var selectorAccessory: SelectorAccessory?
    private var hasLoaded = false

    init(viewModel: HashtagViewModel, postSurfaces: (any SearchPostSurfaceProviding)?) {
        self.viewModel = viewModel
        topPage = postSurfaces?.makePostSurface(style: .gallery)
            ?? SearchPendingSurfaceViewController(kind: .media)
        recentPage = postSurfaces?.makePostSurface(style: .cards)
            ?? SearchPendingSurfaceViewController(kind: .posts)
        super.init(nibName: nil, bundle: nil)
        // In the initialiser, as on the results screen: the navigation
        // controller reads it when the push BEGINS.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = viewModel.title
        navigationItem.largeTitleDisplayMode = .never
        configurePages()
        selectorAccessory = SelectorAccessory(strip: tabBar)
        selectorTouchProbe.attach(to: tabBar)
        viewModel.onChange = { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installBottomChromeWhenAppearing(
            handsOver: tabBarController?.bottomAccessory != nil
        ) { [weak self] in
            guard let self else { return }
            selectorAccessory?.install(into: tabBarController, alongside: transitionCoordinator)
        }
        guard !hasLoaded else { return }
        hasLoaded = true
        Task { [weak self] in await self?.viewModel.load() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        selectorAccessory?.install(into: tabBarController)
        updatePlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        selectorAccessory?.remove(from: tabBarController, alongside: transitionCoordinator)
        setPageScrollEnabled(true)
        topPage.setPlaybackActive(false)
        recentPage.setPlaybackActive(false)
    }

    // MARK: - Pages

    private func configurePages() {
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pager.setActivePage(tabBar.selectedIndex, animated: true)
        }, for: .valueChanged)
        for page in [topPage.viewController, recentPage.viewController] {
            addChild(page)
            page.didMove(toParent: self)
        }
        pager = HorizontalPagerView(
            pages: [topPage.viewController.view, recentPage.viewController.view],
            initialIndex: 0
        )
        pager.translatesAutoresizingMaskIntoConstraints = false
        pager.onActiveScrollViewChanged = { [weak self] scroller in
            self?.setContentScrollView(scroller, for: .bottom)
        }
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        tabBar.onScrub = { [weak self] progress in self?.pager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in self?.pager.settleAfterScrub(velocityInPages: velocity) }
        pager.onSettled = { [weak self] index in
            self?.tabBar.select(index)
            self?.updatePlayback()
        }
        view.addSubview(pager)
        // To the top of the VIEW, under the translucent bar, as on the results
        // screen: the pages' own insets keep their first row clear.
        NSLayoutConstraint.activate([
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func render() {
        navigationItem.subtitle = viewModel.countText
        topPage.show(viewModel.top)
        recentPage.show(viewModel.recent)
    }

    /// The page in front plays, and only while this screen is up.
    private func updatePlayback() {
        let active = isViewLoaded && view.window != nil
        topPage.setPlaybackActive(active && tabBar.selectedIndex == 0)
        recentPage.setPlaybackActive(active && tabBar.selectedIndex == 1)
    }

    // MARK: - The strip wins the touch it is under

    private lazy var selectorTouchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.setPageScrollEnabled(!isTouching)
    }

    private var isPageScrollEnabled = true
    private var suspendedPans: [(UIGestureRecognizer, Bool)] = []

    /// The pages' pans and the stack's back swipes stand down while a finger
    /// is on the selector — `SearchResultsViewController.setPageScrollEnabled`
    /// and `setPopGestureEnabled` say why it is the pans and not
    /// `isScrollEnabled`, and why every pan on the stack's view.
    private func setPageScrollEnabled(_ isEnabled: Bool) {
        guard isEnabled != isPageScrollEnabled else { return }
        isPageScrollEnabled = isEnabled
        func walk(_ view: UIView) {
            (view as? UIScrollView)?.panGestureRecognizer.isEnabled = isEnabled
            view.subviews.forEach(walk)
        }
        walk(pager)
        if isEnabled {
            for (recogniser, wasEnabled) in suspendedPans { recogniser.isEnabled = wasEnabled }
            suspendedPans = []
        } else if navigationController?.topViewController === self, suspendedPans.isEmpty,
                  let host = navigationController?.view {
            let pans = (host.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
            suspendedPans = pans.map { ($0, $0.isEnabled) }
            for recogniser in pans { recogniser.isEnabled = false }
        }
    }
}
