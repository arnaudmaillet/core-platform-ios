import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// The For You tab root: curated content in the shared three-format grid, with
/// a discovery filter tray, and a tile tap opening the full-screen feed.
///
/// This is a **tab root**, which settles two things that would otherwise be
/// style choices. The filter tray is hosted in this screen's own view above the
/// bottom safe area — the navigation toolbar cannot be made to clear a tab bar
/// (measured three ways; see `InlineFilterTrayView`) — and the tab bar stays,
/// because it is how the viewer leaves.
final class ForYouViewController: UIViewController {
    private let viewModel: ForYouViewModel
    private let pager: ForYouPagerView
    private let makeSnapFeed: ([PostID]) -> UIViewController
    private let prewarm: ([PostID]) async -> Void

    /// The format tabs. Bare by design — `InlineFilterTrayView` supplies the
    /// one glass capsule each control gets outside a toolbar.
    private let formatRow = GlassSegmentRow(segments: [
        .title("Activity"), .title("Media"), .title("Short")
    ])

    /// The discovery axis's options, in menu order. One table so the menu, the
    /// bubble's glyph and any programmatic selection cannot disagree about
    /// what a source looks like.
    private struct SourceOption {
        let source: DiscoverySource
        let title: String
        let symbol: String
    }

    private static let sourceOptions: [SourceOption] = [
        SourceOption(source: .trending, title: "Trending", symbol: "flame"),
        SourceOption(source: .recent, title: "Recent", symbol: "clock"),
        SourceOption(source: .following, title: "Following", symbol: "person.2")
    ]

    /// The discovery axis: one drop-down whose native single-selection menu
    /// carries the options and whose bubble shows the active one's glyph.
    /// Lazy — the menu actions capture self.
    private lazy var sourceMenuButton = GlassMenuButton(
        // Closure form, not a bare `map(makeSourceAction)`: passing a
        // MainActor-isolated method as a function value strips its isolation
        // and Swift 6 rejects it.
        menu: UIMenu(options: .singleSelection, children: Self.sourceOptions.map { makeSourceAction($0) }),
        accessibilityLabel: "Discovery filter"
    )

    private lazy var trayView = InlineFilterTrayView(leading: formatRow, trailing: sourceMenuButton)

    /// Retains the navigation-controller delegate for the life of a flight —
    /// the stack holds its delegate weakly.
    private var activeTransition: ZoomTransitionController?

    /// How many posts a tile tap hands the feed, counting from the tapped one.
    ///
    /// `FixedPostsFeedProvider` hydrates its whole set in ONE concurrent
    /// fan-out, so an uncapped deep grid would fire hundreds of `GetPost`
    /// calls on a single tap. The consequence is stated rather than hidden:
    /// one feed session reaches at most this many posts, and paging on through
    /// the grid's own cursor is a follow-up.
    private static let seedWindow = 40

    init(
        viewModel: ForYouViewModel,
        imagePipeline: ImagePipeline,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController,
        prewarm: @escaping ([PostID]) async -> Void
    ) {
        self.viewModel = viewModel
        self.makeSnapFeed = makeSnapFeed
        self.prewarm = prewarm
        pager = ForYouPagerView(imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)
        // NOT hidesBottomBarWhenPushed: this is a tab root, and the bar is how
        // the viewer leaves it.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "For You"
        // The big left-aligned title, which is the convention for a root tab.
        //
        // `.inline` is genuinely the mode that produces it here, however
        // backwards that reads. This stack leaves `prefersLargeTitles` at its
        // default of false, and under iOS 26 that makes `.always` and `.never`
        // BOTH resolve to the small centred bar title, while `.inline` renders
        // the large one in the content area. All three were measured in-sim
        // before this line was settled; don't "fix" it to `.always` without
        // re-measuring. Verified not to leak into the pushed feed, whose bar
        // keeps just its back item and author pill.
        navigationItem.largeTitleDisplayMode = .inline

        pager.pin(to: view)
        // The tray floats over the pages, so they must be able to scroll their
        // last row clear of it.
        pager.trayClearance = InlineFilterTrayView.height + InlineFilterTrayView.spacingBelow * 2

        view.addSubview(trayView)
        NSLayoutConstraint.activate([
            trayView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            trayView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            trayView.heightAnchor.constraint(equalToConstant: InlineFilterTrayView.height),
            trayView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -InlineFilterTrayView.spacingBelow
            )
        ])

        formatRow.onSelect = { [weak self] index in
            guard let self else { return }
            let format = ForYouPagerView.pageOrder[index]
            viewModel.setFormat(format)
            pager.setActivePage(format, animated: true)
        }
        pager.onPageSettled = { [weak self] format in
            guard let self else { return }
            viewModel.setFormat(format)
            if let index = ForYouPagerView.pageOrder.firstIndex(of: format) {
                formatRow.select(index, notify: false)
            }
        }
        pager.onItemTapped = { [weak self] format, index in
            self?.openFeed(from: format, at: index)
        }
        pager.onNearEnd = { [weak self] in self?.viewModel.loadNextPageIfNeeded() }
        pager.onRefresh = { [weak self] in self?.viewModel.refresh() }

        viewModel.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            pager.render(snapshot)
            prewarmVisible()
        }
        viewModel.onLoadSettled = { [weak self] in self?.pager.endRefreshing() }

        // Land on the stored format before first layout, so the screen OPENS
        // there with no visible jump.
        let format = viewModel.format
        if let index = ForYouPagerView.pageOrder.firstIndex(of: format) {
            formatRow.select(index, notify: false)
        }
        pager.setActivePage(format, animated: false)

        viewModel.viewDidLoad()

        #if DEBUG
        installDebugHooks()
        #endif
    }

    private func makeSourceAction(_ option: SourceOption) -> UIAction {
        UIAction(
            title: option.title,
            image: UIImage(systemName: option.symbol),
            state: option.source == viewModel.source ? .on : .off
        ) { [weak self] _ in
            self?.applySource(option.source)
        }
    }

    /// Adopts a source everywhere it shows. The icon-only bubble carries no
    /// system mirroring, so the glyph and the VoiceOver value are set by hand —
    /// and they are set HERE rather than in the menu action so that every path
    /// that changes the source (including the debug hook) moves the bubble too.
    /// A menu tap additionally moves its own checkmark, which `.singleSelection`
    /// owns; a programmatic change cannot, so the checkmark can lag until the
    /// menu is next rebuilt. That is a debug-only discrepancy — the bubble,
    /// which is what's on screen, is always right.
    private func applySource(_ source: DiscoverySource) {
        guard let option = Self.sourceOptions.first(where: { $0.source == source }) else { return }
        viewModel.setSource(source)
        sourceMenuButton.button.configuration?.image = UIImage(systemName: option.symbol)
        sourceMenuButton.button.accessibilityValue = option.title
    }

    /// Opens the full-screen feed on the tapped post, with the hero zoom.
    ///
    /// The feed is seeded from the page's own ordered ids as a SUFFIX starting
    /// at the tap, so swiping down in the feed continues through the grid in
    /// the order the viewer was reading it. This is the Maps pin path's
    /// mechanism end to end — `makeSnapFeedViewController(postIDs:)` over
    /// `FixedPostsFeedProvider`, pushed under a `ZoomTransitionController` —
    /// with a tile as the source instead of a pin.
    private func openFeed(from format: GalleryFilter.Format, at index: Int) {
        // One flight at a time: a second tap while a card is in the air would
        // stage a transition over a live one. Same guard as the map's.
        guard activeTransition == nil else { return }
        let posts = pager.posts(for: format)
        guard posts.indices.contains(index), let navigationController else { return }
        let tapped = posts[index]
        let ids = posts[index...].prefix(Self.seedWindow).map(\.id)
        let feed = makeSnapFeed(Array(ids))

        // The feed owns the whole screen: hide the bar with the push. Managed
        // by hand rather than via `hidesBottomBarWhenPushed`, because that
        // flag's choreography doesn't scrub with a custom interactive pop —
        // the bar snaps in at pop-begin and flashes over the feed when a grab
        // cancels (measured on both the pin and timeline paths).
        tabBarController?.setTabBarHidden(true, animated: true)

        guard let page = pager.page(for: format),
              let destination = feed as? any ZoomTransitionDestination,
              page.hero(for: tapped.id, in: view) != nil
        else {
            // No hero available — a text-only row has no media to fly, and a
            // destination without the seam can't be flown to. A plain push is
            // the honest fallback; it is still the same feed.
            navigationController.pushViewController(feed, animated: true)
            return
        }

        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tapped.id,
            // Injected rather than imported: the source stays a grid concept
            // and never learns what a feed is.
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID }
        )
        let transition = ZoomTransitionController(source: source, destination: destination)
        activeTransition = transition
        // The bar's alpha is driven 1:1 by the grab (and by the flight's spring
        // on a tap-back), so it is revealed by the hand instead of appearing
        // after the card has already landed.
        transition.returningSourceChrome = tabBarController?.tabBar
        transition.onSourceReturned = { [weak self] in
            // Completed pop only — a cancelled grab reports through
            // `onDismissalCancelled`, so the transition (and future grabs)
            // survives it by construction.
            self?.navigationController?.delegate = nil
            self?.activeTransition = nil
            // Idempotent close-out: the state and the alpha are already correct
            // by now, this just guarantees it if a leg was skipped.
            self?.showTabBar(alpha: 1)
        }
        transition.onDismissalCancelled = { [weak self] in
            // The feed is staying up, so put the bar back down — it is behind
            // the restored page by now, so nothing renders the change.
            self?.tabBarController?.setTabBarHidden(true, animated: false)
            self?.tabBarController?.tabBar.alpha = 1
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        transition.attachInteractiveDismissal(to: feed.view) { [weak self] in
            // Restore the bar's hidden STATE here, at grab-begin — before the
            // pop and therefore before any transition is in flight.
            //
            // Both halves of that matter. Doing it inside the transition
            // permanently breaks the bar's rendering: the frame returns and
            // `isTabBarHidden` reads false, but the buttons never paint, leaving
            // a row of empty glass capsules (measured; the map's grab, which
            // restores outside the transition, paints correctly). And doing it
            // BEFORE the pop is what settles the grid's layout — its cells live
            // inside the bar's safe area — so every landing rect the flight
            // reads is already the rect the tile will still occupy.
            //
            // It goes back at alpha 0 so the drag can fade it in; the bar is a
            // sibling of the navigation controller's view and renders above the
            // transition's dim, which is why the dim cannot veil it for us.
            self?.showTabBar(alpha: 0)
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController.delegate = transition
        navigationController.pushViewController(feed, animated: true)

        #if DEBUG
        // `-foryou-demo-grab`: once the feed has landed, drive the grab twice —
        // below the completion threshold (springs back to full screen) and past
        // it (flies home to the tile). The sim injects no pans, so this is the
        // only way to exercise the release contract here.
        if ProcessInfo.processInfo.arguments.contains("-foryou-demo-grab") {
            transition.onDestinationShown = { [weak transition] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    transition?.debugScriptedGrab()
                }
            }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from the feed: this screen owns the bottom again.
        guard navigationController?.topViewController === self else { return }
        guard activeTransition != nil else {
            // No hero in play: the plain-push fallback for a text-only row, and
            // a tab switch back. Nothing is animating the bar, so show it
            // outright.
            tabBarController?.setTabBarHidden(false, animated: animated)
            tabBarController?.tabBar.alpha = 1
            return
        }
        // A hero return: put the bar back INVISIBLE so the flight has something
        // to fade in, and so the grid's inset freeze captures the resting
        // layout (see `showTabBar`).
        //
        // This is the only chance the *back-button* pop gets — there is no
        // grab-begin on that path, and leaving the state to the transition's
        // completion is exactly what made the bar snap in after the card had
        // already landed. On an interactive grab the state was restored at
        // grab-begin, before this ran, so this is a no-op there. Either way the
        // opacity is the flight's to drive, never this method's.
        showTabBar(alpha: 0)
    }

    /// Puts the tab bar back, at a given opacity, and settles the layout it
    /// changes.
    ///
    /// The alpha is separate from the hidden state on purpose: the STATE is what
    /// the grid's safe area (and therefore every tile's frame) depends on, so it
    /// has to be final before a flight measures anything, while the OPACITY is
    /// what the viewer reads and belongs on the gesture's clock. Splitting them
    /// is what lets the bar be geometrically present and visually absent for the
    /// length of a drag.
    private func showTabBar(alpha: CGFloat) {
        guard let tabBarController else { return }
        tabBarController.tabBar.alpha = alpha
        guard tabBarController.isTabBarHidden else { return }
        tabBarController.setTabBarHidden(false, animated: false)
        // Force the layout the change implies now, so nothing downstream reads
        // a stale cell rect.
        tabBarController.view.layoutIfNeeded()
        view.layoutIfNeeded()
    }

    /// Warms the top of the corpus into the feed's post cache so a tile tap
    /// opens from memory instead of the network — the same trick Maps uses on
    /// viewport settle.
    private func prewarmVisible() {
        let ids = viewModel.posts(for: viewModel.format).prefix(12).map(\.id)
        guard !ids.isEmpty else { return }
        Task { [prewarm] in await prewarm(Array(ids)) }
    }

    #if DEBUG
    /// `-foryou-open <index>` taps a tile once content has landed (the sim
    /// injects no taps), and `-foryou-source <trending|recent|following>`
    /// drives the drop-down — a `UIMenu` needs a real tap to open.
    private func installDebugHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-foryou-source"), position + 1 < arguments.count {
            let source: DiscoverySource? = switch arguments[position + 1] {
            case "trending": .trending
            case "recent": .recent
            case "following": .following
            default: nil
            }
            if let source {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.applySource(source)
                }
            }
        }
        guard let position = arguments.firstIndex(of: "-foryou-open"), position + 1 < arguments.count,
              let index = Int(arguments[position + 1])
        else { return }
        // Polls rather than firing on a fixed delay: the tap needs landed
        // content, and a fixed delay silently no-ops under `-mock-latency`.
        //
        // It waits for the tile's COVER, not just the model. A person taps a
        // tile they can see, and the hero card is built from the pixels that
        // tile is rendering — firing the instant the model lands flies a blank
        // card and misreports the transition as broken. (It is not: an
        // unloaded tile and its card are both the same empty placeholder. But
        // the capture is worthless.) Text-only rows never get a cover, so the
        // attempt budget is the backstop that still lets them through.
        var attempts = 0
        func attempt() {
            attempts += 1
            let format = viewModel.format
            let posts = pager.posts(for: format)
            guard posts.indices.contains(index) else {
                if attempts < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt) }
                return
            }
            let ready = pager.page(for: format)?.heroAppearance(for: posts[index].id)?.cover != nil
            guard ready || attempts >= 60 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                return
            }
            openFeed(from: format, at: index)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt)
    }
    #endif
}
