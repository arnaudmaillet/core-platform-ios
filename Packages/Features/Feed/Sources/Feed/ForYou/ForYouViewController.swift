import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The For You tab root: two paged surfaces — **Discover** (the media grid) and
/// **Following** — under a tab capsule that lives IN the navigation bar, with a
/// tile tap opening the full-screen feed.
///
/// **The capsule is the title.** It is `navigationItem.titleView`, not a strip
/// beneath the bar, so this screen reserves no safe area of its own and the grid
/// starts directly under the navigation bar — one row of chrome, not two.
/// `MessagesInboxViewController` wears the same `PagedTabBar` the same way, and
/// everything else — fractional progress driving the lens, the capsule
/// scrubbing the pager, badges — is shared. The one thing it does that this
/// screen does not is stack a search field beneath the title row.
///
/// **The bar items are one action and one state.** Leading is `+`, which opens
/// the composer through `AppRoute.upload`. Trailing is the `ContentContext`
/// lens, whose glyph IS the current context — it does not offer an action, it
/// reports what the surface is currently showing, and tapping it opens the menu
/// to change that.
///
/// ⚠️ **`DiscoverySource` (Trending / Recent) has no UI entry point any more.**
/// It used to be the leading item; `+` took that slot. The ordering still
/// applies — everything is served under `.trending` — but nothing on screen can
/// change it. Either fold it into the context menu as a second section or
/// retire it; leaving it reachable only from a debug argument is not a
/// resting state.
///
/// This is a **tab root**, so the tab bar stays — it is how the viewer leaves.
final class ForYouViewController: UIViewController {
    private let viewModel: ForYouViewModel
    private let pager: ForYouPagerView
    private let makeSnapFeed: ([PostID]) -> UIViewController
    private let prewarm: ([PostID]) async -> Void
    /// How this screen leaves itself. Weak, and held by the composition root —
    /// the screen never builds a destination, it names one.
    private weak var router: (any Router)?

    /// The tab titles, in `ForYouPagerView.pageOrder` order: Discover (the
    /// media grid) then Following (the unfiltered page).
    ///
    /// They deliberately do not echo `GalleryFilter.Format`'s case names. The
    /// enum names the content SHAPE, these name the product idea; the audit
    /// reads this array rather than a second copy of the strings.
    private static let tabTitles = ["Discover", "Following"]

    /// The tab capsule. Shared with the Messages inbox — see `PagedTabBar` for
    /// why the lens is a tint rather than a second material.
    private let tabBar = PagedTabBar(titles: tabTitles, style: .navigationTitle)

    /// Compose. The leading item is an ACTION, so it is a plain glyph with a
    /// target — no menu, no state.
    private lazy var composeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openComposer() }
        )
        item.accessibilityLabel = "New Post"
        return item
    }()

    /// Reports how the app's own tab item should read — see
    /// `ForYouTabPresentation`.
    var onTabPresentationChange: ((ForYouTabPresentation) -> Void)?

    /// Every lens's count, as of the last publish. Read by the context menu
    /// when it opens and by the tab item when either half changes; held here
    /// rather than asked for because a menu opening is not a moment to run a
    /// derivation over the corpus.
    private var contextCounts: [ContentContext: Int] = [:]

    /// The content context: the trailing item, whose menu carries the lenses
    /// and whose GLYPH is the active one.
    ///
    /// The glyph doing that job is what lets the menu stay plain — see
    /// `makeContextMenu` for why there is no checkmark in it.
    private lazy var contextItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: viewModel.context.symbol))
        item.accessibilityLabel = "Content context"
        item.accessibilityValue = viewModel.context.title
        return item
    }()

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

    /// The dismissal's live surface, hosted in the tab bar controller's view
    /// for the length of the return flight.
    ///
    /// Above the navigation controller on purpose: a nav controller removes
    /// non-top views from the window, so a surface hosted in THIS controller's
    /// view would leave the render tree mid-flight and its layer would
    /// re-acquire on the way back. One level up, it never leaves — the spike
    /// measured zero `readyForDisplay` drops across a full push and pop.
    private weak var dismissHostedSurface: UIView?

    /// Installs `view` in the host at `rect`, converted from the transition
    /// container's space. Returns false when there is no host to put it in.
    private func hoistForDismissal(_ view: UIView, at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) -> Bool {
        guard let host = tabBarController?.view else { return false }
        // Into the CLIP straight away, sized to the whole host for the flight.
        // The clip later shrinks to the grid's rect, but the surface itself is
        // added exactly once — a second move at landing was costing the very
        // readiness drop this exists to remove.
        let clip = hostClip ?? {
            let created = UIView()
            created.clipsToBounds = true
            created.isUserInteractionEnabled = false
            host.addSubview(created)
            hostClip = created
            return created
        }()
        // The CLIP is the flying window — it takes the card's role once the
        // surface is hoisted: it holds the rect, the rounding and the crop.
        // Starts at the PAGE's radius so the spring interpolates down to the
        // tile's rather than jumping there at the end.
        clip.frame = space.convert(rect, to: host)
        clip.layer.cornerCurve = .continuous
        clip.layer.cornerRadius = cornerRadius

        view.removeFromSuperview()
        view.autoresizingMask = []
        // The surface's BOUNDS are deliberately left exactly as
        // `prepareZoomLiveMediaForFlight` set them — the media's native aspect,
        // sized to cover the page — and are never animated. A video layer whose
        // bounds animate does not re-render to track them; its video rect
        // snaps. Driving this by `frame` (which animates bounds) is what made
        // the media stop covering the card mid-dismissal.
        //
        // Coverage is a uniform scale about the centre instead, which is
        // exactly how the card poses it while the surface is still inside the
        // card. The clip's animating bounds are the only crop in the flight.
        view.layer.cornerRadius = 0
        view.clipsToBounds = false
        // TRANSPARENT, not the black floor `updatePosterVisibility` gave it at
        // prime time. This surface appears ABOVE the feed, full-page, in the
        // very first staging commit — and its background composites WITH that
        // commit while its video content rides the sample-buffer path outside
        // it. On a busy device the content can miss the first pass, and an
        // opaque floor turns that pass into a full-screen black plate over a
        // live page: the 1-frame blink at tap-back frame 0, invisible to the
        // red-floor diagnostic because this black belongs to the SURFACE, not
        // the card. Clear, the same pass shows the feed through — pixel
        // continuity — and the floor is not missed: `poseHostedSurface` keeps
        // the surface covering its clip through the whole flight, so there is
        // never a gap for a floor to fill.
        view.backgroundColor = .clear
        // Exactly one surface in the clip, always. `syncHostedSurface` glues
        // `subviews.first` to the tile, so a leftover from an earlier flight
        // would both draw over the grid and be the one that gets glued — the
        // real surface then tracking nothing. The coordinator releases a
        // superseded surface on the way in; this is the parenting half of the
        // same invariant, and it is cheap enough to assert unconditionally.
        for stale in clip.subviews where stale !== view {
            stale.removeFromSuperview()
        }
        clip.addSubview(view)
        dismissHostedSurface = view
        // Poses window AND covering scale together — synchronously here (the
        // takeoff state), and again inside the flight's spring block via
        // `zoomPoseHoistedMedia`, so both ride ONE animation on the render
        // server. This replaces a per-display-tick scale driver, whose clock
        // was the MAIN THREAD while the window animated server-side: every
        // missed tick froze the video's scale under a still-gliding window
        // and then snapped it frames' worth to catch up — the aspect-fill
        // stepping seen on device, intermittent because it needed a stall.
        poseHostedSurface(at: rect, in: space, cornerRadius: cornerRadius)
        #if DEBUG
        armFlightProbe()
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            let ready = (view as? VideoRenderView)?.isReadyForDisplay ?? false
            print(String(format: "[zoom-live] %.3f dismiss HOISTED ready=%@",
                         CACurrentMediaTime(), ready ? "true" : "false"))
        }
        #endif
        return true
    }

    /// Poses the hosted surface: the window (frame + radius) AND the video's
    /// covering scale, as one pose. Called synchronously at the hoist and
    /// inside the flight's spring block, so everything interpolates on the
    /// same animation.
    ///
    /// Animating the scale between the two endpoint covers is SAFE, and the
    /// reason is worth keeping: the scale the window needs at progress p is
    /// `max(w(p)/W, h(p)/H)` with w and h affine in p — a max of affine
    /// functions, which is CONVEX. The animated scale is the chord between
    /// that function's own endpoint values, and a chord never dips below a
    /// convex curve on its interval: mid-flight the video is always exactly
    /// covered or slightly over-covered (a marginally tighter crop, cropped
    /// away by the clip — invisible). The one place the chord CAN dip under
    /// is the spring's overshoot, which extrapolates past the interval —
    /// ~1.1% of progress at damping 0.82, a ≲3% cover deficit for a frame or
    /// two at the settle, against the card's own furniture. Accepted: the
    /// alternative was a per-display-tick driver on the main thread's clock,
    /// whose missed ticks froze and snapped the scale in visible steps.
    private func poseHostedSurface(at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) {
        guard let clip = hostClip, let host = tabBarController?.view else { return }
        clip.frame = space.convert(rect, to: host)
        clip.layer.cornerRadius = cornerRadius
        guard let view = dismissHostedSurface else { return }
        let size = clip.bounds.size
        let media = view.bounds.size
        guard media.width > 0, media.height > 0, size.width > 0, size.height > 0 else { return }
        let scale = ZoomTransitionGeometry.mediaFillScale(covering: size, surface: media)
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
        view.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    #if DEBUG
    // Samples what the hosted surface's LAYER is actually doing across a
    // dismissal, under `-zoom-probe`.
    //
    // The load-bearing field is `cover`: the drawn media's size over the window
    // it must cover, on both axes. Aspect fill holds iff both are >= 1. That is
    // not answerable from a still frame, and it is how the overshoot's uncovered
    // edges were found — the window deliberately outlasts the spring's rebond,
    // because an earlier version of this probe stopped at 0.9s and reported a
    // clean flight while the artifact happened at 1.2s.
    private var flightProbe: CADisplayLink?
    private var flightProbeStart: CFTimeInterval = 0

    private func armFlightProbe() {
        guard ProcessInfo.processInfo.arguments.contains("-zoom-probe") else { return }
        flightProbe?.invalidate()
        flightProbeStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(sampleFlightProbe))
        link.add(to: .main, forMode: .common)
        flightProbe = link
    }

    @objc private func sampleFlightProbe() {
        let t = CACurrentMediaTime() - flightProbeStart
        guard let view = dismissHostedSurface, let clip = hostClip, t < 3.0 else {
            flightProbe?.invalidate(); flightProbe = nil; return
        }
        let vp = view.layer.presentation()
        let cp = clip.layer.presentation()
        let bounds = vp?.bounds ?? view.layer.bounds
        let scale = vp?.affineTransform().a ?? view.transform.a
        let win = (cp?.bounds ?? clip.layer.bounds).size
        let coverX = win.width > 0 ? bounds.width * scale / win.width : 0
        let coverY = win.height > 0 ? bounds.height * scale / win.height : 0
        let opacity = vp?.opacity ?? view.layer.opacity
        print(String(format: "[probe] %.3f cover=%.3f/%.3f%@ op=%.2f%@ scale=%.3f b=%@ | clip f=%@ r=%.1f | surfkeys=%@",
                     t, coverX, coverY,
                     (coverX < 0.999 || coverY < 0.999) ? " UNCOVERED" : "",
                     opacity,
                     opacity < 0.99 ? " DIM" : "",
                     scale,
                     NSCoderRect(bounds),
                     NSCoderRect(cp?.frame ?? clip.layer.frame),
                     cp?.cornerRadius ?? clip.layer.cornerRadius,
                     (view.layer.animationKeys() ?? []).joined(separator: ",")))
    }

    private func NSCoderRect(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
    #endif

    /// Un-hoists the surface for a REVERSED dismissal and hands it back.
    ///
    /// The mirror of `hoistForDismissal`. A flight the viewer cancels leaves
    /// the feed on screen, so the surface must stop being hosted at the grid
    /// cell's rect — where it would otherwise keep drawing over the feed that
    /// came back, one level above the navigation controller and immune to
    /// anything the feed does.
    private func releaseHoistedForCancel() -> UIView? {
        guard let view = dismissHostedSurface else { return nil }
        dismissHostedSurface = nil
        view.transform = .identity
        view.removeFromSuperview()
        hostClip?.removeFromSuperview()
        hostClip = nil
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] dismiss REVERSED, hoisted surface released")
        }
        #endif
        return view
    }

    /// The post whose video renders from the host rather than from its cell.
    private var hostedPostID: PostID?
    private var hostedFormat: GalleryFilter.Format?
    /// Clips a hosted surface to the grid, so a tile scrolling under the bars
    /// cannot draw over them.
    private weak var hostClip: UIView?

    /// Lands the hosted surface WITHOUT moving it into the cell.
    ///
    /// The point of the permanent hoist: `addSubview` / `removeFromSuperview`
    /// are never called on the active player layer again, so the ~65ms
    /// readiness drop the landing card was covering does not happen at all. The
    /// tile publishes its rect instead of owning the view.
    private func landHostedSurface(for postID: PostID, format: GalleryFilter.Format) {
        guard let view = dismissHostedSurface as? VideoRenderView,
              let page = pager.page(for: format), let host = tabBarController?.view
        else { return }
        dismissHostedSurface = nil

        guard let clip = hostClip else { return }
        guard page.adoptHostedPlayback(view, for: postID) else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] land REFUSED by adoptHostedPlayback post=\(postID)")
            }
            #endif
            // Nothing landed, so nothing may survive: the surface used to be
            // unparented but left attached to its renderer, and the empty clip
            // stayed in the tab bar controller's view for the life of the tab
            // — one stranded pair per refused landing. Same teardown as
            // `releaseHoistedForCancel`, minus the hand-back (there is no
            // feed left to reclaim it).
            view.detachForReplacement()
            view.removeFromSuperview()
            clip.removeFromSuperview()
            hostClip = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.transform = .identity
        clip.layer.cornerRadius = 0
        clip.frame = page.gridRect(in: host)
        view.layer.cornerRadius = PostGridFlightCard.tileCornerRadius
        view.clipsToBounds = true
        CATransaction.commit()
        hostedPostID = postID
        hostedFormat = format
        page.onGeometryChanged = { [weak self] in self?.syncHostedSurface() }
        page.setHostedSurfaceReleasedHandler { [weak self] released in
            guard self?.hostedPostID == released else { return }
            self?.hostedPostID = nil
            self?.hostClip?.removeFromSuperview()
        }
        syncHostedSurface()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f dismiss LANDED HOSTED ready=%@",
                         CACurrentMediaTime(), view.isReadyForDisplay ? "true" : "false"))
        }
        #endif
    }

    /// Glues the hosted surface to its tile. Runs on every scroll frame.
    private func syncHostedSurface() {
        guard let postID = hostedPostID, let format = hostedFormat,
              let page = pager.page(for: format), let clip = hostClip,
              let host = tabBarController?.view
        else { return }
        clip.frame = page.gridRect(in: host)
        guard let rect = page.tileRect(for: postID, in: clip) else { return }
        // Implicit animation off: this tracks a scroll, and any easing reads as
        // the video lagging behind its own brick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.subviews.first?.frame = rect
        CATransaction.commit()
    }


    init(
        viewModel: ForYouViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController? = nil,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController,
        prewarm: @escaping ([PostID]) async -> Void,
        router: (any Router)? = nil
    ) {
        self.viewModel = viewModel
        self.makeSnapFeed = makeSnapFeed
        self.prewarm = prewarm
        self.router = router
        pager = ForYouPagerView(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        super.init(nibName: nil, bundle: nil)
        // NOT hidesBottomBarWhenPushed: this is a tab root, and the bar is how
        // the viewer leaves it.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // No title. The large left-aligned title was the convention for a root
        // tab here, and removing it also removes the large-title content-area
        // layout from the transition's path — which is the second reason for
        // this change, see below.
        // No title, because the tabs ARE the title: the capsule occupies the
        // slot a title string would have. Removing the large title also keeps
        // the large-title content-area layout out of the hero flight's path,
        // which is the second reason for it — see below.
        navigationItem.title = nil
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = tabBar
        // Native bar items on both sides. They lay out in the bar itself, which
        // is also what bounds the title slot the capsule now sits in — UIKit
        // gives the slot what is left between them, so neither can be covered.
        navigationItem.leftBarButtonItem = composeItem
        navigationItem.rightBarButtonItem = contextItem
        contextItem.menu = makeContextMenu()

        pager.pin(to: view)

        // NO `additionalSafeAreaInsets.top`, and no constraints for the bar:
        // the capsule is inside the navigation bar, so the navigation bar's own
        // height already accounts for it and the grid starts directly beneath
        // it. `MessagesInboxViewController` does the same.

        // Wired like any system control: the bar carries the chosen segment as
        // its value and announces it, rather than handing back a closure.
        tabBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                // ONE animation drives both. The pager scrolls to the target and
                // reports fractional progress every frame; the lens interpolates
                // off that, so page and lens cannot disagree and there is
                // nothing to keep in sync. The bar runs no animation of its own.
                let format = ForYouPagerView.pageOrder[tabBar.selectedIndex]
                viewModel.setFormat(format)
                pager.setActivePage(format, animated: true)
            },
            for: .valueChanged
        )
        // Dragging the capsule IS dragging the pages: the bar reports a
        // fractional page position and the pager is scrubbed to it, so the same
        // `onProgress` loop that answers a content swipe answers this too.
        tabBar.onScrub = { [weak self] progress in self?.pager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in
            self?.pager.settleAfterScrub(velocityInPages: velocity)
        }
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onPageSettled = { [weak self] format in
            self?.viewModel.setFormat(format)
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
        viewModel.onPagingChange = { [weak self] paging in self?.pager.setPaging(paging) }
        viewModel.onUnreadChange = { [weak self] counts in self?.applyBadges(counts) }
        viewModel.onContextCountsChange = { [weak self] counts in
            guard let self else { return }
            contextCounts = counts
            // The menu reads `contextCounts` when it opens, so it needs no
            // telling — but the tab item is a fact about the app's chrome and
            // has to be pushed.
            publishTabPresentation()
        }
        // The badged tab's rows split on this number. Only that page has
        // sections; Discover is a ranked mosaic with no "since" to divide on.
        viewModel.onNewCountChange = { [weak self] count in
            self?.pager.setNewCount(count, for: ForYouViewModel.badgedTab)
        }

        // Land on the stored format before first layout, so the screen OPENS
        // there with no visible jump.
        pager.setActivePage(viewModel.format, animated: false)

        viewModel.viewDidLoad()

        #if DEBUG
        installDebugHooks()
        debugTraceChrome()
        #endif
    }

    /// How For You presents an unread count: as a NUMBER.
    ///
    /// ⚠️ This was a dot, on the argument that "Following ③" invites arithmetic
    /// the viewer cannot act on — three posts are not three things to open, and
    /// the useful signal is only that the page has moved on. That argument held
    /// while the count answered one question. It no longer does: the count is
    /// now the size of the "New" section the viewer is about to scroll through
    /// AND the number beside each mode in the context menu, so the badge is the
    /// short form of something they can see spelled out in two other places. A
    /// dot over a section holding four posts is the screen disagreeing with
    /// itself.
    ///
    /// Zero renders nothing — `.count` already says so — so the presence signal
    /// the dot carried is not lost, it just arrived with a size attached.
    ///
    /// Pure and internal so a test can pin the rule rather than a screenshot.
    static func badgeStyle(forUnread count: Int) -> PagedTabBar.BadgeStyle {
        .count(count)
    }

    /// Pushes the counts onto the capsule, in pager order.
    ///
    /// ⚠️ A badge changes the capsule's WIDTH, and a navigation bar caches the
    /// size of its title view: `invalidateIntrinsicContentSize` alone is not
    /// enough, and the frame and the content drift apart the moment a count
    /// appears or clears. Measured symptom, with the strip measuring zero
    /// overflow at rest: scrubbing to Short cleared its badge, the bar resized
    /// the slot to the new narrower intrinsic width, the row inside kept the
    /// old one — and the leading title rendered as "tivity".
    ///
    /// Re-stating the size and forcing the bar to lay out is what makes the two
    /// agree. This has no equivalent in the floating arrangement, where the
    /// bar's width is the screen's and nothing has to be told about it.
    private func applyBadges(_ counts: [GalleryFilter.Format: Int]) {
        for (index, format) in ForYouPagerView.pageOrder.enumerated() {
            tabBar.setBadge(Self.badgeStyle(forUnread: counts[format] ?? 0), at: index)
        }
        tabBar.sizeToFit()
        navigationController?.navigationBar.setNeedsLayout()
        navigationController?.navigationBar.layoutIfNeeded()
    }

    /// Opens the post composer.
    ///
    /// Through the ROUTE, not by building the composer here: `AppRoute.upload`
    /// already presents it, and it is presented from several places. A screen
    /// that constructed its own would be a second answer to "what is the
    /// composer" the day one of them changes.
    private func openComposer() {
        router?.route(to: .upload)
    }

    /// The context menu: plain actions, **no `.singleSelection` and no
    /// checkmark**.
    ///
    /// The selection is already on screen — the bar item's glyph IS the active
    /// context, which is the whole reason it is a state item rather than an
    /// action. A tick beside the matching row says the same thing a second
    /// time, in a place you have to open a menu to read.
    ///
    /// Attached ONCE, and its contents are built fresh every time it opens.
    ///
    /// The rows now carry counts, which are live state — the thing this menu
    /// deliberately had none of. Rather than re-assigning `contextItem.menu` on
    /// every publish (a write per page load, to a menu nobody has open), the
    /// children come from a `UIDeferredMenuElement.uncached`: UIKit asks for
    /// them at the moment of presentation, so they are current by construction
    /// and there is nothing to keep in step. `.uncached` specifically —
    /// `.init(_:)` caches the first build, which is exactly the stale menu this
    /// avoids.
    func makeContextMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.makeContextActions() ?? [])
            }
        ])
    }

    /// The rows the menu shows, built fresh on every presentation.
    ///
    /// Separate from `makeContextMenu` because a `UIDeferredMenuElement`'s
    /// provider cannot be invoked from outside UIKit — so a test asserting what
    /// the menu offers would have nothing to read but the deferred element
    /// itself. This is the seam those tests use.
    func makeContextActions() -> [UIAction] {
        // Closure form, not a bare `map(makeContextAction)`: passing a
        // MainActor-isolated method as a function value strips its isolation
        // and Swift 6 rejects it.
        ContentContext.allCases.map { makeContextAction($0) }
    }

    /// One row: the mode, its glyph, and how much is waiting under it.
    ///
    /// The count is in the TITLE rather than a subtitle because the menu is a
    /// list of choices and the number is part of what makes one of them worth
    /// choosing — a subtitle would put it on a second line and half the width.
    /// Zero is shown too, not hidden: the menu's job here is to let someone
    /// compare five modes at a glance, and a row with nothing beside it would
    /// be ambiguous between "nothing new" and "not counted".
    private func makeContextAction(_ context: ContentContext) -> UIAction {
        UIAction(
            title: "\(context.title) (\(contextCounts[context] ?? 0))",
            image: UIImage(systemName: context.symbol)
        ) { [weak self] _ in
            self?.applyContext(context)
        }
    }

    /// Adopts a context everywhere it shows: the glyph, the VoiceOver value,
    /// and the corpus both tabs are reading.
    ///
    /// Set HERE rather than in the menu action so that every path that changes
    /// the context — a menu tap, a debug hook, a restore — moves all of them
    /// together.
    private func applyContext(_ context: ContentContext) {
        viewModel.setContext(context)
        contextItem.image = UIImage(systemName: context.symbol)
        contextItem.accessibilityValue = context.title
        publishTabPresentation()
    }

    /// Tells the shell how its own bar item should read.
    ///
    /// Sent from here rather than from the view model because it is a
    /// PRESENTATION fact — a title, a glyph, a badge — and the view model
    /// deals in contexts and counts. It also means the two callers that can
    /// change it (a lens tap, a fresh set of counts) go through one place, so
    /// the item can never carry one mode's name and another's number.
    private func publishTabPresentation() {
        let context = viewModel.context
        onTabPresentationChange?(
            ForYouTabPresentation(
                title: context.title,
                symbol: context.symbol,
                badgeCount: contextCounts[context] ?? 0
            )
        )
    }

    /// Opens the full-screen feed on the tapped post, with the hero zoom.
    ///
    /// The feed is seeded from the page's own ordered ids as a SUFFIX starting
    /// at the tap, so swiping down in the feed continues through the grid in
    /// the order the viewer was reading it. This is the Maps pin path's
    /// mechanism end to end — `makeSnapFeedViewController(postIDs:)` over
    /// `FixedPostsFeedProvider`, pushed under a `ZoomTransitionController` —
    /// with a tile as the source instead of a pin.
    /// A partial display model from the projection this grid already holds.
    ///
    /// Lives here, not on `FeedItemDisplayModel`, so the shared display model
    /// stays free of `PostGrid` — the grid is one opener among several, and the
    /// feed is also reached from Maps and from a route.
    ///
    /// Complete now that the projection carries author identity — the page
    /// opens with its capsule populated rather than filling in ~0.69s later.
    ///
    /// `metaText` is rebuilt here in the feed's own "@handle · age" form using
    /// the same `PostMetadata.compactAge` the grid's cells use, so the seeded
    /// string matches the one the real entry will carry and nothing re-renders
    /// differently when it lands.
    private static func seedModel(from post: GalleryPost) -> FeedItemDisplayModel {
        let handle = post.authorHandle.map { "@\($0)" } ?? ""
        let age = PostMetadata.compactAge(ofMillis: post.publishedAtMS)
        return FeedItemDisplayModel(
            id: post.id,
            authorID: post.authorID ?? ProfileID(""),
            authorName: post.authorName ?? "",
            metaText: handle.isEmpty ? age : "\(handle) · \(age)",
            avatarURL: post.authorAvatarURL,
            caption: post.caption.isEmpty ? nil : post.caption,
            mediaURL: post.videoURL ?? post.thumbnailURL,
            mediaKind: post.kind == .video ? .video : .image,
            thumbnailURL: post.thumbnailURL,
            audioText: post.kind == .video && !handle.isEmpty
                ? "Original audio · \(handle)" : nil,
            likeCount: post.reactionCount ?? 0,
            timestampText: age
        )
    }

    private func openFeed(from format: GalleryFilter.Format, at index: Int) {
        // One flight at a time: a second tap while a card is in the air would
        // stage a transition over a live one. Same guard as the map's.
        guard activeTransition == nil else { return }
        let posts = pager.posts(for: format)
        guard posts.indices.contains(index), let navigationController else { return }
        let tapped = posts[index]
        let ids = posts[index...].prefix(Self.seedWindow).map(\.id)

        // Open the handoff scope. Everything else stops — the grid is about to
        // be covered and its slots are what the feed needs — and the tapped
        // post becomes invisible to reconcile, so nothing can restart or stop
        // it while its player is in flight.
        pager.beginPlaybackHandoff(of: tapped.id)
        let feed = makeSnapFeed(Array(ids))
        // Hand the feed the projection this grid already holds, so its first
        // page configures at push time rather than when its own fetch returns.
        // Measured at ~0.69s of empty destination without it.
        if let seedable = feed as? SnapFeedViewController {
            seedable.seedProjection(posts[index...].prefix(Self.seedWindow).map(Self.seedModel))
        }

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
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID },
            // The gallery recedes; the tray and the title stay grounded.
            depthView: pager,
            // NOT hoisted — the two dismissals share one surface flow.
            //
            // Hoisting lifted the live layer out of the card and into a host
            // above the navigation controller for the return, and only the
            // tap-back path ever did it: the grab keeps the surface inside the
            // card the whole way. That asymmetry is where tap-back's two
            // defects lived. The hoisted landing has a refusal branch — if
            // `adoptHostedPlayback` cannot match the surface to a realized
            // tile it calls `detachForReplacement()` and drops the view — and a
            // torn-down surface means the tile starts a FRESH player, which is
            // the video restarting from zero mid-return. Nothing on the grab
            // path can do that, which is why only tap-back showed it.
            //
            // The readiness drop the hoist was introduced to remove is already
            // gone by other means: `adoptAttachedSurface` gives the landing tile
            // its OWN surface primed with the current frame, so the player layer
            // is never re-parented either way. Both paths now land through
            // `zoomAdoptLiveMediaView` and hold on the same
            // `zoomLandingMediaIsReady` gate.
            hoistLive: nil,
            poseHoisted: nil,
            releaseHoisted: nil,
            donateLive: { [weak self, weak page] in
                // Under `-avsbdl-render` the card joins the tile's playback as
                // an extra surface instead of taking it over. The tile keeps
                // rendering behind the card, so there is no park, no transfer,
                // and nothing to hand back if the flight is abandoned.
                let attached = VideoRenderFlags.usesSampleBufferLayer
                let surface = attached
                    ? page?.liveFlightSurface(for: tapped.id)
                    : page?.donateLivePlayback(of: tapped.id)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print(String(format: "[zoom-live] %.3f source %@ -> %@",
                                 CACurrentMediaTime(),
                                 attached ? "attach surface" : "donate+park",
                                 surface != nil ? "true" : "false"))
                }
                #endif
                return surface
            }
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
            self?.restoreChromeAfterTransition()
            // Close the handoff scope. This is the single act that restores the
            // grid: it clears the flight's state and reconciles once, so every
            // qualifying visible tile gets a slot again rather than whatever
            // subset survived the transition.
            // Land the hosted surface on the tile FIRST, then close the scope:
            // the tile must own a rendering surface before the reconcile that
            // restores every other slot runs.
            if let landed = (feed as? SnapFeedViewController)?.activePostID {
                self?.landHostedSurface(for: landed, format: format)
            }
            self?.pager.endPlaybackHandoff()
            #if DEBUG
            self?.debugAuditTabBar("returned")
            self?.debugAdvanceGrabCycleIfNeeded()
            #endif
        }
        transition.onDismissalCancelled = { [weak self] in
            // The feed is staying up, so put the bar back down — it is behind
            // the restored page by now, so nothing renders the change.
            self?.tabBarController?.setTabBarHidden(true, animated: false)
            self?.tabBarController?.tabBar.alpha = 1
            self?.restoreChromeAfterTransition()
            #if DEBUG
            self?.debugAuditTabBar("cancelled")
            #endif
        }
        transition.onPresentationCancelled = { [weak self] in
            // The PUSH was reversed mid-air: the feed never showed, `didShow`
            // reports nothing, and the grid is the screen again. The same
            // idempotent close-out as `onSourceReturned`, minus the landing —
            // a present hoists nothing, so there is nothing to land. Without
            // this, the retained transition made every future tile tap a
            // silent no-op and the handoff scope kept the grid's players down.
            self?.navigationController?.delegate = nil
            self?.activeTransition = nil
            self?.showTabBar(alpha: 1)
            self?.restoreChromeAfterTransition()
            self?.pager.endPlaybackHandoff()
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
        // `-foryou-demo-tapback`: pop programmatically instead of grabbing.
        //
        // The two dismissals are SEPARATE implementations —
        // `ZoomDismissInteractionController` for the grab,
        // `ZoomAnimator.dismiss` for the back button — and the harness could
        // only ever drive the first. Every dismiss measurement taken here was
        // therefore of the grab, and said nothing about the button, which is
        // exactly where a defect survived being "verified".
        if ProcessInfo.processInfo.arguments.contains("-foryou-demo-tapback") {
            transition.onDestinationShown = { [weak navigationController] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    navigationController?.popViewController(animated: true)
                }
            }
        }
        #endif
    }

    /// Rebuilds the capsule's appearance after any transition ends.
    ///
    /// Called on a completed hero return, a cancelled grab, and every appearance
    /// — all three, because the failure it repairs has been seen after an
    /// interactive dismissal and a cancelled grab reaches none of the completion
    /// callbacks. It is idempotent and costs a layout pass, so running it when
    /// nothing was wrong is not worth guarding against.
    private func restoreChromeAfterTransition() {
        tabBar.restoreAfterTransition()
    }

    /// Points the pager at the view model's format, without echoing the change
    /// back out as a user selection. The capsule follows through the pager's
    /// own progress, so it is never written directly.
    private func syncFormatSelection() {
        pager.setActivePage(viewModel.format, animated: false)
    }

    /// Reconciles autoplay once the grid has actually laid out.
    ///
    /// `viewWillAppear` is too early on its own: no cell is realized yet, so
    /// the reconcile there finds no candidates. And when content lands BEFORE
    /// the screen appears — which is the normal case against the mock backend,
    /// and against a warm cache on device — the post-reload reconcile runs
    /// while the surface is still inactive and also does nothing. Between them
    /// the grid could sit fully laid out, visible, and silent, with no further
    /// event to retrigger it until the viewer happened to scroll.
    ///
    /// Caught only because a loaded machine reversed the ordering and hid it;
    /// on an idle one the grid never started. `viewDidAppear` is the first
    /// moment both facts are true — surface active, cells realized — so the
    /// reconcile here is the one that cannot be raced.
    #if DEBUG
    /// `-foryou-tab-away <seconds>`: switch to another tab after a delay.
    ///
    /// Exists because the leak it checks for is invisible from this screen —
    /// the hosted surface lives in the tab bar controller's view, so the way
    /// to see it is to leave the tab and look at what is still drawing.
    private var hasScheduledTabAway = false

    private func scheduleTabAwayIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !hasScheduledTabAway,
              let position = arguments.firstIndex(of: "-foryou-tab-away"),
              position + 1 < arguments.count,
              let delay = Double(arguments[position + 1])
        else { return }
        hasScheduledTabAway = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let tabs = self?.tabBarController else { return }
            print("[zoom-live] TAB AWAY -> index 2")
            tabs.selectedIndex = 2
        }
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pager.setAutoplayActive(true)
        #if DEBUG
        scheduleTabAwayIfNeeded()
        #endif
    }

    /// Suspends the grid's media when the TAB moves away.
    ///
    /// A push disappears this screen too, and there the flight owns playback —
    /// stopping it is precisely the restart the whole handoff exists to
    /// prevent. The stack's top separates the two: on a push it is already the
    /// pushed screen, on a tab switch it is still this one.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard navigationController?.topViewController === self else { return }
        // The hosted surface lives in the TAB BAR CONTROLLER's view, one level
        // above the navigation controller — deliberately, so a push cannot
        // unmount it mid-flight. The consequence is that nothing about leaving
        // this tab removes it either: it kept drawing, and playing, at the grid
        // cell's rect over whichever tab the viewer switched to.
        //
        // Hidden first and synchronously, so it cannot compose over the
        // incoming tab even for one frame; `setAutoplayActive(false)` then
        // stops every playing tile, and `stop` is the path that actually
        // releases a hosted surface and tears its clip down.
        hostClip?.isHidden = true
        pager.setAutoplayActive(false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The segment row and the view model hold two copies of one fact — which
        // format is active — and the row's copy is the one nothing persists. Two
        // paths write it (a tap, and a settled pager swipe reported through
        // `onPageSettled`), so a callback lost across a transition would leave the
        // row highlighting a segment the pager is not on. Re-asserting from the
        // view model on every appearance makes the model the single authority and
        // costs nothing when they already agree.
        syncFormatSelection()
        restoreChromeAfterTransition()
        // The grid owns the screen again, so its bricks may play again. Runs
        // before the topViewController guard below: a tab switch back lands
        // here too, and autoplay should resume on either path.
        //
        // No handoff open (a plain push, or an ordinary tab switch): sweep any
        // stranded park. A live transition owns its own scope and closes it in
        // `onSourceReturned`.
        if activeTransition == nil { pager.discardPlaybackHandoff() }
        // Paired with the hide in `viewWillDisappear`. Usually moot — the stop
        // there tears the clip down outright — but a clip that outlived it must
        // not come back invisible.
        hostClip?.isHidden = false
        pager.setAutoplayActive(true)
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
    /// Remaining automatic open→grab→return cycles for `-foryou-grab-cycles`.
    private static var remainingGrabCycles = 0

    /// `-foryou-audit-tabs`: reports any part of the tab capsule that is not
    /// drawable or not reachable by a tap, at the end of every dismissal.
    ///
    /// "Did the transition leak a hidden state into the chrome?" is answerable
    /// exactly, so it is answered exactly instead of by squinting at a
    /// screenshot. Pair with `-foryou-grab-cycles` — a leak that survives one
    /// return is one anybody would catch, so the interesting ones need several
    /// round trips.
    ///
    /// ⚠️ **Neither `alpha` nor `isHidden` is an offence on its own here**,
    /// unlike in the filter tray this replaced — auditing either reports a
    /// perfectly clean bar as broken on every call. Selection is a crossfade
    /// between a regular and a semibold label per segment, so at rest three of
    /// the six titles are legitimately at alpha 0; and a segment with no count
    /// hides its badge, whose label then measures zero. The audit is therefore
    /// scoped to the thing that must never be missing — the TITLES — plus
    /// clipping and reachability, which is where the real failure lives.
    func debugAuditTabBar(_ label: String) {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-audit-tabs") else { return }
        let titles = Self.tabTitles
        func carriesTitle(_ v: UIView) -> Bool {
            if let label = v as? UILabel, titles.contains(label.text ?? "") { return true }
            return v.subviews.contains(where: carriesTitle)
        }
        var offenders: [String] = []
        func walk(_ view: UIView, _ path: String) {
            let name = "\(path)/\(type(of: view))"
            if view.isHidden {
                // Stop here. A hidden badge is a tab with nothing to report;
                // only a hidden TITLE means the bar came back broken.
                if carriesTitle(view) { offenders.append("\(name) isHidden") }
                return
            }
            if view.frame.width == 0 || view.frame.height == 0 {
                offenders.append("\(name) zero-frame")
            }
            view.subviews.forEach { walk($0, name) }
        }
        walk(tabBar, "tabs")
        // Every TITLE the bar is drawing, with its width. A title that has gone
        // missing or collapsed to zero width is invisible while passing every
        // check above, so it is checked as its own thing.
        var labels: [String] = []
        func collectLabels(_ v: UIView) {
            if let label = v as? UILabel, titles.contains(label.text ?? "") {
                // Clipping is `laid-out width < the width the text needs`, which
                // is the only test that distinguishes "small label" from
                // "truncated label".
                let needed = label.intrinsicContentSize.width
                let clipped = label.bounds.width + 0.5 < needed
                labels.append(String(
                    format: "%@[w=%.1f/need%.1f,a=%.2f%@%@]",
                    label.text ?? "nil", label.bounds.width, needed, label.alpha,
                    label.isHidden ? ",HIDDEN" : "", clipped ? ",CLIPPED" : ""
                ))
                if clipped {
                    offenders.append(String(
                        format: "'%@' clipped %.1f<%.1f", label.text ?? "nil", label.bounds.width, needed
                    ))
                }
                if label.isHidden { offenders.append("'\(label.text ?? "nil")' label hidden") }
            }
            v.subviews.forEach(collectLabels)
        }
        collectLabels(tabBar)
        // The capsule clips ON PURPOSE (it is a rounded material with a scroll
        // view inside it), so the walk starts at its superview: what must not
        // clip is anything BETWEEN the bar and the screen.
        //
        // The walk stops AT the navigation bar. The bar lives in its subtree
        // now, so `view` is not on the ancestor chain at all and stopping there
        // would never stop — but walking all the way to the window is just as
        // wrong the other way: `UILayoutContainerView` and `UITransitionView`
        // clip on purpose, and reporting them buries the one clip that would
        // actually cut a segment off. What can crop the capsule is what sits
        // between it and its host.
        var node = tabBar.superview
        while let current = node, !(current is UINavigationBar), !(current is UIWindow) {
            if current.clipsToBounds { offenders.append("\(type(of: current)) clipsToBounds") }
            if current.layer.mask != nil { offenders.append("\(type(of: current)) masked") }
            node = current.superview
        }
        // Six, not three: each segment carries a regular/semibold pair so
        // selection can change weight without re-measuring the row.
        // Two labels per segment — a regular/semibold pair that crossfades —
        // so the expected count follows the tab count rather than a constant.
        let expectedLabels = titles.count * 2
        if labels.count != expectedLabels {
            offenders.append("label count \(labels.count) != \(expectedLabels)")
        }
        for expected in titles where labels.filter({ $0.hasPrefix(expected) }).count != 2 {
            offenders.append("'\(expected)' not drawn twice")
        }
        // Visible is not the same as reachable: something left over the bar (an
        // undismissed dim, a stale transition container) would pass every check
        // above and still swallow every tap. Collect the segment buttons by
        // walking — they sit several materials deep, and a path spelled out by
        // index would break the day the capsule gains a layer.
        var buttons: [UIButton] = []
        func collectButtons(_ v: UIView) {
            if let button = v as? UIButton { buttons.append(button) }
            v.subviews.forEach(collectButtons)
        }
        collectButtons(tabBar)
        if buttons.count != titles.count {
            offenders.append("segment count \(buttons.count) != \(titles.count)")
        }
        // The selection pill must frame the segment it claims to select — badge
        // and all. This is checkable rather than a matter of taste, and it is
        // the one defect a screenshot hides until a badge changes a width: the
        // segment grows to fit "Following 99" and the lens keeps its old size,
        // leaving the count outside its own pill.
        if let alignment = tabBar.debugLensAlignment {
            let drift = max(
                abs(alignment.lens.minX - alignment.segment.minX),
                abs(alignment.lens.width - alignment.segment.width)
            )
            if drift > 0.5 {
                offenders.append(String(
                    format: "lens off by %.1f (lens %.1fx%.1f@%.1f vs segment %.1fx%.1f@%.1f)",
                    drift, alignment.lens.width, alignment.lens.height, alignment.lens.minX,
                    alignment.segment.width, alignment.segment.height, alignment.segment.minX
                ))
            }
        }
        // Hit-tested from the WINDOW, because a bar inside the navigation bar
        // is not reachable from this screen's `view` at all and testing there
        // would call every segment unreachable — a false alarm indistinguishable
        // from the real thing. The side bar items go through the same path and
        // answer the same question, because the risk this arrangement
        // introduces is precisely that a title view sized wrong sits over one.
        //
        // ⚠️ Deferred one turn of the run loop. This is called from a
        // transition's completion, and UIKit's own `TouchBlocker` is still
        // installed over the whole window at that instant — a window-level hit
        // test run inline reports EVERYTHING unreachable, every time. (The
        // earlier `view`-rooted test never saw it: the blocker is a sibling
        // above `view`, not inside it.) One hop later it is gone and the
        // reading is of the screen, not of the transition.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var late: [String] = []
            defer {
                if !late.isEmpty {
                    print("[tabsaudit \(label)] REACHABILITY: " + late.joined(separator: " | "))
                }
            }
            guard let window = view.window else { return }
            for (index, button) in buttons.enumerated() {
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                let hit = window.hitTest(point, with: nil)
                let reachable = hit.map { $0 === button || $0.isDescendant(of: button) } ?? false
                if !reachable {
                    late.append("segment \(index) unreachable (hit=\(hit.map { "\(type(of: $0))" } ?? "nil"))")
                }
            }
            for (name, item) in [("compose", composeItem), ("context", contextItem)] {
                guard let itemView = item.value(forKey: "view") as? UIView else {
                    late.append("\(name) item has no view")
                    continue
                }
                let point = itemView.convert(
                    CGPoint(x: itemView.bounds.midX, y: itemView.bounds.midY), to: window
                )
                let hit = window.hitTest(point, with: nil)
                let reachable = hit.map { $0 === itemView || $0.isDescendant(of: itemView) } ?? false
                if !reachable {
                    late.append("\(name) item unreachable (hit=\(hit.map { "\(type(of: $0))" } ?? "nil"))")
                }
                if itemView.frame.intersects(tabBar.convert(tabBar.bounds, to: itemView.superview)) {
                    late.append("\(name) item OVERLAPS the capsule")
                }
            }
        }
        print("[tabsaudit \(label)] sel=\(tabBar.selectedIndex) labels=\(labels.joined(separator: " ")) "
            + (offenders.isEmpty ? "clean" : "OFFENDERS: " + offenders.joined(separator: " | ")))
    }

    /// `-foryou-trace-chrome`: samples the chrome's window-space position every
    /// frame while a hero transition is alive, so "does it move?" is a number.
    private func debugTraceChrome() {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-trace-chrome") else { return }
        let link = CADisplayLink(target: self, selector: #selector(debugSampleChrome))
        link.add(to: .main, forMode: .common)
    }

    @objc private func debugSampleChrome() {
        // Samples ALWAYS, not only while a transition is live: the resting
        // position is the baseline every other reading is judged against, and a
        // snap at teardown is only visible as "settled != during the drag".
        guard let window = view.window else { return }
        let phase = activeTransition == nil ? "rest" : "flight"
        let tabs = tabBar.convert(tabBar.bounds, to: window)
        let safeTop = view.safeAreaInsets.top
        let bar = navigationController?.navigationBar
        let barRect = bar.map { $0.convert($0.bounds, to: window) } ?? .zero
        // The title-slot question, in numbers: how wide is the capsule allowed
        // to be, where do the side items start and end, and is the capsule
        // scrolling its own content (which is what silently crops a badge)?
        let leftRect = (composeItem.value(forKey: "view") as? UIView)
            .map { $0.convert($0.bounds, to: window) } ?? .zero
        let rightRect = (navigationItem.rightBarButtonItem?.value(forKey: "view") as? UIView)
            .map { $0.convert($0.bounds, to: window) } ?? .zero
        let leftEnd = leftRect.maxX
        let rightStart = rightRect.minX
        // The height the capsule has to match, and where the item's own glass
        // sits — "same height" is only right if they also share a centre line.
        let itemH = leftRect.height
        let itemY = leftRect.minY
        let overflow = tabBar.debugOverflow
        // The square-flash check, as a number rather than an impression: a
        // capsule holds radius == height/2 on every frame it is drawn. The
        // display link starts in `viewDidLoad`, so the first sample is the first
        // frame this screen has ever had.
        let shape = tabBar.debugCapsuleShape
        let lensDrift = tabBar.debugLensAlignment.map {
            max(abs($0.lens.minX - $0.segment.minX), abs($0.lens.width - $0.segment.width))
        } ?? -1
        let lensRect = tabBar.debugLensAlignment?.lens ?? .zero
        // What the nav bar is actually drawing its item capsules with, by class
        // and geometry — the search space for a dynamic height match.
        if ProcessInfo.processInfo.arguments.contains("-foryou-dump-bar"), let bar {
            var rows: [String] = []
            func walk(_ v: UIView, _ depth: Int) {
                guard depth < 8 else { return }
                let r = v.convert(v.bounds, to: window)
                if r.height > 1, r.width > 1 {
                    rows.append(String(format: "%d:%@ %.0fx%.0f@%.0f,%.0f%@",
                                       depth, "\(type(of: v))", r.width, r.height, r.minX, r.minY,
                                       v is UIVisualEffectView ? " EFFECT" : ""))
                }
                v.subviews.forEach { walk($0, depth + 1) }
            }
            walk(bar, 0)
            print("[bardump] " + rows.joined(separator: " | "))
        }
        let round = shape.height > 0 && abs(shape.radius - shape.height / 2) < 0.01
        print(String(
            format: "[chrome:%@] tabsX=%.1f tabsW=%.1f tabsY=%.2f tabsH=%.2f itemH=%.2f itemY=%.2f "
                + "leftEnd=%.1f rightStart=%.1f slot=%.1f overflow=%.1f safeT=%.2f navY=%.2f navH=%.2f "
                + "lensW=%.1f lensX=%.1f drift=%.2f r=%.2f/%.2f glass=%@ CAPSULE=%@",
            phase, tabs.minX, tabs.width, tabs.minY, tabs.height, itemH, itemY,
            leftEnd, rightStart, rightStart - leftEnd, overflow, safeTop,
            barRect.minY, barRect.height,
            lensRect.width, lensRect.minX, lensDrift,
            shape.radius, shape.height, shape.hasEffect ? "on" : "off", round ? "yes" : "NO"
        ))
    }

    /// Re-opens the feed for the next scripted cycle, if any are left.
    ///
    /// Repetition is the point: a state leak that survives ONE return is a bug
    /// anyone would catch, so the ones that reach a release are the ones that
    /// need several round trips to show. Driven off the completed return rather
    /// than a timer, so each cycle starts from a genuinely settled grid.
    func debugAdvanceGrabCycleIfNeeded() {
        guard Self.remainingGrabCycles > 0 else { return }
        Self.remainingGrabCycles -= 1
        let index = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-foryou-open")
            .flatMap { $0 + 1 < ProcessInfo.processInfo.arguments.count
                ? Int(ProcessInfo.processInfo.arguments[$0 + 1]) : nil } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            openFeed(from: viewModel.format, at: index)
        }
    }

    /// `-foryou-open <index>` taps a tile once content has landed (the sim
    /// injects no taps); `-foryou-source <trending|recent|following>` drives the
    /// drop-down (a `UIMenu` needs a real tap to open); and
    /// `-foryou-grab-cycles <n>` repeats the whole open→grab→return round trip
    /// `n` more times, for hunting state that only leaks after several returns.
    private func installDebugHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        var openDelay = 0.5
        if let position = arguments.firstIndex(of: "-foryou-grab-cycles"),
           position + 1 < arguments.count, let count = Int(arguments[position + 1]) {
            Self.remainingGrabCycles = count
        }
        // `-foryou-context <entertainment|work|focus|gaming>` drives the lens.
        // A `UIMenu` needs a real tap to open, so this is the only way to reach
        // a non-default context from a script.
        if let position = arguments.firstIndex(of: "-foryou-context"),
           position + 1 < arguments.count,
           let context = ContentContext(rawValue: arguments[position + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.applyContext(context)
            }
        }
        // `-foryou-switch-format a,b,...` taps the format segments in order,
        // ~0.8s apart, through the very path a finger drives (`select` ->
        // `.valueChanged`). The reported bug needs a *sequence* of switches
        // before the dismissal, so the sequence has to be reproducible.
        if let position = arguments.firstIndex(of: "-foryou-switch-format"),
           position + 1 < arguments.count {
            let names = arguments[position + 1].split(separator: ",").map(String.init)
            // The tile tap must come AFTER the switches, or the repro runs out
            // of order and proves nothing.
            openDelay = 1.5 + 0.8 * Double(names.count)
            for (step, name) in names.enumerated() {
                // Product names first, content-shape names kept as aliases so
                // scripts written against the three-tab layout still drive the
                // page they meant. "short" is gone with its tab.
                let format: GalleryFilter.Format? = switch name {
                case "discover", "media", "gallery": .media
                case "following", "activity": .activity
                default: nil
                }
                guard let format, let index = ForYouPagerView.pageOrder.firstIndex(of: format) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + 0.8 * Double(step)) { [weak self] in
                    self?.tabBar.select(index)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: attempt)
    }
    #endif
}
