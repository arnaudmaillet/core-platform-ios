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
    /// Loads a post's first page of comments into the panel's synchronous
    /// cache. Optional so the other entry points need not supply one.
    private let prefetchTopComments: ((PostID) async -> Void)?
    /// Posts whose first page of comments has been asked for. A set, because
    /// the reconcile that feeds it runs at ~30Hz while a finger is moving and
    /// the same three cards are on screen for most of it.
    private var warmedComments: Set<PostID> = []
    /// How this screen leaves itself. Weak, and held by the composition root —
    /// the screen never builds a destination, it names one.
    private weak var router: (any Router)?
    /// Files a row's Report. Nil withholds the row entirely: an action that
    /// cannot act is not offered.
    private let reporting: (any ContentReporting)?
    /// Unfollows a row's author. Nil withholds that row for the same reason.
    ///
    /// ⚠️ Both tabs here are served by `timeline.v1.GetFollowingFeed` — there
    /// is no discovery corpus (see `DiscoverySource`) — so every author on this
    /// screen is one the viewer follows, which is what makes UNFOLLOW the
    /// honest verb rather than a toggle that has to ask first.
    private let socialGraph: (any SocialGraphWriting)?

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

    /// The flight attached to a screen that was opened as a WINDOW, held only
    /// so it outlives this function.
    ///
    /// ⚠️ NOT `activeTransition`, and the distinction is a bug I shipped for
    /// one commit. That property is the guard on `openFeed` — "one flight at a
    /// time" — and is cleared by the flight's own completion hooks. A window
    /// opening has no such completion, so storing this one there left it set
    /// for ever: every later tile tap returned at the guard and did nothing.
    /// Reported as the screen breaking after a few open/close cycles.
    private var cardPathFlight: ZoomTransitionController?

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
        prefetchTopComments: ((PostID) async -> Void)? = nil,
        router: (any Router)? = nil,
        reporting: (any ContentReporting)? = nil,
        socialGraph: (any SocialGraphWriting)? = nil
    ) {
        self.viewModel = viewModel
        self.makeSnapFeed = makeSnapFeed
        self.prewarm = prewarm
        self.prefetchTopComments = prefetchTopComments
        self.router = router
        self.reporting = reporting
        self.socialGraph = socialGraph
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
        // Native bar items on both sides; the selector joins the LEADING group
        // behind the compose glyph, so the centre stays empty and flexible.
        navigationItem.leftBarButtonItem = composeItem
        navigationItem.rightBarButtonItem = contextItem
        navigationItem.installLeadingSelector(tabBar)
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
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onPageSettled = { [weak self] format in
            self?.viewModel.setFormat(format)
        }
        pager.onItemTapped = { [weak self] format, index in
            self?.openFeed(from: format, at: index)
        }
        pager.onItemCommentsTapped = { [weak self] format, index in
            self?.openFeed(from: format, at: index, showingComments: true)
        }
        pager.onWarmRequested = { [weak self] posts in self?.warmVisible(posts) }
        pager.onNearEnd = { [weak self] in self?.viewModel.loadNextPageIfNeeded() }
        pager.onRefresh = { [weak self] in self?.viewModel.refresh() }
        // An ordinary push onto whatever stack this screen is on — the app's
        // one profile destination, reached the way every other author tap
        // reaches it. The screen names the route; it never builds the profile.
        pager.onAuthorTapped = { [weak self] post in
            guard let id = post.authorID else { return }
            // The stub is what the row already drew, handed forward so the
            // pushed screen titles itself in the push's own frame instead of
            // after its own round trip.
            self?.router?.route(to: .profile(id, stub: post.authorIdentityStub))
        }
        pager.authorMenuActions = { [weak self] context in
            self?.authorMenuActions(for: context) ?? []
        }

        viewModel.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            pager.render(snapshot)
            prewarmVisible()
            #if DEBUG
            auditPostMenu()
            #endif
        }
        viewModel.onCorpusReset = { [weak self] in
            self?.pager.invalidateIncrementalUpdates()
            // A new corpus is new posts under old ids' places; what was warmed
            // says nothing about what is on screen now.
            self?.warmedComments.removeAll()
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
        viewModel.onNewPostsChange = { [weak self] ids in
            self?.pager.setNewPosts(ids, for: ForYouViewModel.badgedTab)
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

    /// One row: `[count] [glyph] Mode`.
    ///
    /// ⚠️ The count used to be parenthesised into the title — "Work (3)" — which
    /// put a number where a name goes and made the rows read as five sentences
    /// rather than five choices. It is a badge, so it is drawn as one, in the
    /// only slot a menu row has for it: see `ContextMenuRowIcon` for why the
    /// pill and the glyph have to be a single image, and why every row reserves
    /// the pill's width even at zero.
    private func makeContextAction(_ context: ContentContext) -> UIAction {
        UIAction(
            title: context.title,
            image: ContextMenuRowIcon.image(
                count: contextCounts[context] ?? 0,
                symbol: context.symbol,
                traits: traitCollection
            )
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
    /// The feed this grid opens, reused across pushes when it can be.
    ///
    /// Held by THIS controller rather than by the builder on purpose. A single
    /// shared instance would be a bug the moment two tabs want a feed at once
    /// — the Maps pin path pushes onto its own navigation stack and can be on
    /// screen while this one is — so the cache belongs to the call site, and
    /// every other entry point keeps building its own.
    /// The interactive swipe-to-pop for TEXT posts, which push natively.
    ///
    /// The same object the menu-pushed timeline uses, for the same reason: a
    /// page with no hero still needs a way back by hand, and the system's own
    /// gesture is edge-only and disabled by the feed's custom back item. It
    /// scrubs the pop 1:1 and releases on the shared contract, so a text post
    /// and a media post feel the same in the hand even though only one of them
    /// flies.
    private let textSlideDismissal = InteractiveSlideDismissal()

    /// STRONG, and that is the whole mechanism: the reference has to outlive
    /// the pop. Held weakly it would be released the moment the navigation
    /// controller let go, and the next tap would rebuild exactly what this
    /// exists to avoid.
    private var reusableFeed: SnapFeedViewController?

    /// The cache is an OPTIMISATION, not state: under real pressure, give it
    /// back. This is the ONLY thing that drops it — a tab switch does not.
    ///
    /// # Why a cached feed is cheap to keep
    /// The reason to drop it would be the media it holds, except it holds
    /// none. Being popped runs the FEED's own `viewDidDisappear`, which
    /// resigns its active cell and calls `VideoPlaybackController.stop`: the
    /// item is replaced with nil, the renderer is invalidated and unhooked
    /// from the display link, and the `AVPlayer` returns to a pool that is
    /// app-wide rather than this screen's. By the time anything here could
    /// release a player, the players are already gone.
    ///
    /// What is left is a view hierarchy, and that measured as nothing: phys
    /// footprint after a tab-away was 83/75/82 MB holding it against 75/86/74
    /// MB dropping it — fully overlapping, and in both directions. So it is
    /// kept, and the next tap stays a re-point rather than a rebuild. A tab
    /// switch was never the signal that means "give something back"; this is.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        releaseCachedFeed()
    }

    /// Never drops a feed that is still on screen; a detached one costs the
    /// next tap a rebuild and nothing else.
    private func releaseCachedFeed() {
        guard reusableFeed?.navigationController == nil else { return }
        #if DEBUG
        if reusableFeed != nil, ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[feed-reuse] RELEASED cached feed")
        }
        #endif
        reusableFeed = nil
    }

    /// Re-aims the cached feed at this window, or builds one if there is no
    /// usable instance. `repoint` refuses while the controller is still in a
    /// navigation stack, which is the case that must not be reused.
    ///
    /// Internal, not private, so the cache's lifetime is unit-testable without
    /// driving a whole hero flight — the rules that matter (a push must not
    /// drop it, leaving the tab must) are lifecycle-ordering rules, and those
    /// are exactly what a sim run is worst at pinning.
    func snapFeed(for ids: [PostID]) -> UIViewController {
        if let cached = reusableFeed, cached.repoint(to: ids) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
                print("[feed-reuse] REPOINTED to \(ids.prefix(3).map(\.rawValue))")
            }
            #endif
            return cached
        }
        let feed = makeSnapFeed(ids)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[feed-reuse] BUILT fresh for \(ids.prefix(3).map(\.rawValue))")
        }
        #endif
        reusableFeed = feed as? SnapFeedViewController
        return feed
    }

    /// **THE TEXT REVEAL**: opens a text post with a clip-window
    /// reveal instead of UIKit's slide. `-text-reveal-plain` compares the
    /// unmatched variant (the window opens over a page that never moves);
    /// `-text-reveal-log` prints the rects both legs measured.
    ///
    /// ASSIGNED ON EVERY TEXT PUSH, including with `nil`, and that is not
    /// defensive — `textSlideDismissal` is one retained instance shared by
    /// every plain push this screen makes, and the branch it lives in is taken
    /// by more than text rows (a media row scrolled out of the viewport lands
    /// here too). A geometry left over from the previous tap would aim the
    /// next post's reveal at a row that has nothing to do with it.
    ///
    /// Whether a row can be revealed is asked of the GRID, not of the post's
    /// kind: `textRowFrame` answers only for a realized, on-screen text row,
    /// which is the same question the reveal has to answer again at dismissal.
    /// One predicate, so the two legs cannot disagree about whether this
    /// transition exists.
    /// Returns whether the reveal is armed — the caller uses it to leave the
    /// tab bar alone, because a reveal takes the bar down ITSELF.
    ///
    /// The bar FLOATS: it draws over the grid without insetting it (measured on
    /// an iPhone 17 Pro — bar at y 791 height 83, while the grid reserves 34),
    /// so it covers the bottom 26pt of the very row a reveal departs from.
    /// Hidden before the push, as every plain push does it, that 26pt is the
    /// card's whole metric line snapping into existence one frame after the
    /// mask opens: the card the viewer tapped is not the card that starts
    /// growing. Driven by the flight instead, the bar is fully in place on
    /// frame 0 and dissolves as the page grows past it.
    @discardableResult
    /// `presenting` is whether this call is setting up an OPENING. False when a
    /// screen that was opened by a flight rebuilds the geometry at the grab,
    /// for a post it has since paged to — see `attachCardCloseAlongsideFlight`.
    /// A reveal must not claim a push that has already happened.
    private func installTextReveal(
        feed: UIViewController, format: GalleryFilter.Format, postID: PostID,
        presenting: Bool = true
    ) -> Bool {
        // Cleared together: a stale geometry from the previous post would be
        // read by the next close, and a stale `revealPresents` would put a
        // reveal over a flight's opening.
        textSlideDismissal.revealGeometry = nil
        textSlideDismissal.revealPresents = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // ⚠️ THE POST THE CLOSE FLIES TO IS NOT ALWAYS THE ONE THAT OPENED.
        //
        // The feed is a pager: open a post, swipe to the next, and the card the
        // viewer is entitled to land on is the one they ENDED on. Every hook
        // below used to be bound to the id captured at the tap, so a dismissal
        // after any paging flew home to the wrong card — showing another post's
        // words, at another post's height, and revealing a row the viewer had
        // not been reading.
        //
        // A captured `var` rather than a parameter, because the hooks are
        // escaping closures that all have to see the same answer, and the
        // answer is decided between them: `willStageDismissal` adopts the
        // landed post into the departure slot and rewrites this, and everything
        // downstream — the rect, the stand-in, the concealment — reads it back.
        // It is the same shape `ForYouGridZoomSource.anchorID` already has for
        // the hero.
        var anchorID = postID
        func sourceFrame(_ space: UICoordinateSpace) -> CGRect? {
            pager.page(for: format)?.textRowFrame(for: anchorID, in: space)
        }
        /// The rect this window closes onto — the text row's, and the ROW's
        /// when the anchor turns out not to be a text row at all.
        ///
        /// ⚠️ THE ANCHOR CAN CHANGE KIND UNDER THIS WINDOW. It is re-pointed at
        /// whatever the viewer paged to, and `textRowFrame` refuses a row with
        /// media on purpose (a row with a hero flies instead of opening as a
        /// window). So a window that ends on a photograph asked for a rect,
        /// was told nil, and closed into the middle of the screen.
        ///
        /// Deliberately only for the CLOSE: the opening is still gated on a
        /// real text row, which is what decides that this window exists at all.
        func closingFrame(_ space: UICoordinateSpace) -> CGRect? {
            let page = pager.page(for: format)
            return page?.textRowFrame(for: anchorID, in: space)
                ?? page?.rowFrame(for: anchorID, in: space)
        }
        guard TextRevealInstaller.isEnabled,
              let page = pager.page(for: format),
              sourceFrame(view) != nil
        else { return false }
        // The grid's inset state at each stage of a round trip. It exists
        // because a rect alone cannot say why a landing missed, and the first
        // run's did: departure y=741, landing y=625.
        let trace = arguments.contains("-text-reveal-log")
        func log(_ stage: String) {
            guard trace else { return }
            print("[text-reveal] \(stage) \(page.debugInsetState)")
        }
        log("atTap        ")
        if trace, let rect = sourceFrame(view) {
            // The row's rect BEFORE the push hides the tab bar. Compared with
            // the animator's `source=`, this says whether the grid moved
            // between the tap and the opening — which is what a pre-opening
            // jump would be.
            print("[text-reveal] atTap  row=\(NSCoder.string(for: rect))")
        }
        // THE LANDING SETTLES BEFORE THE POP DOES, and the first run without
        // this is why the line exists: the close measured its landing at
        // y=625 for a row that had departed from y=741 — 116pt out, which is
        // this grid's own `adjustedContentInset.top`.
        //
        // The grid's cells live inside the tab bar's safe area. The bar is
        // hidden while the post is up, so the row's rect only returns to what
        // it will actually be once the bar is back — and putting it back at
        // alpha 0 BEFORE the pop is triggered settles the layout while
        // nothing is in flight. Inside the transition instead, the bar comes
        // back as a row of empty glass capsules that never paint (measured on
        // the hero path, which restores it at grab-begin for this exact
        // reason). The pop then drives its alpha from 0, so it fades in with
        // the grid rather than switching on after it.
        textSlideDismissal.onWillBeginPop = { [weak self] in
            log("beginPop  pre")
            self?.showTabBar(alpha: 0)
            log("beginPop post")
        }
        textSlideDismissal.revealReturningChrome = tabBarController?.tabBar
        // The GEOMETRY is not built here — see `TextRevealInstaller`. A
        // profile draws the same row and must open it the same way, and two
        // hand-written copies of thirteen fields agree only on the day they
        // are written. What stays is what genuinely differs between the two
        // screens: which chrome comes back, and what has to settle first.
        // The OPENING is the reveal's — see `revealPresents`. Set alongside
        // the geometry rather than derived from it, because a media post will
        // carry a geometry too and must still open with its flight.
        textSlideDismissal.revealPresents = presenting
        textSlideDismissal.revealGeometry = TextRevealInstaller.geometry(
            feed: feed,
            origin: TextRevealOrigin(
                rowFrame: { space in closingFrame(space) },
                // Read ONCE, at staging, and deliberately not re-asked at
                // dismissal: `applyPendingReveal` may have scrolled the row,
                // and a row that scrolled out is not realized to answer. The
                // cut is a property of the caption, not of where the row
                // happens to be.
                captionEnd: page.textRowCaptionEnd(for: postID),
                // The gallery recedes; the tray and the title stay grounded —
                // the same view the hero's depth cue rides, for the same
                // reason.
                depthView: { [weak self] in self?.pager },
                captionTop: page.textRowCaptionTop(for: postID),
                // Borrowed by the destination for the flight, so the window
                // shows the header the card does instead of a blank strip.
                authorBand: page.textRowAuthorBand(for: postID),
                // What the CLOSE carries home. Built from the post rather than
                // read off the page, so a viewer who scrolled the comments
                // still lands on the card they came from — see
                // `RevealDismissCardView`.
                makeDismissStandIn: { [weak page] in page?.makeDismissStandIn(for: anchorID) },
                // The reveal's OWN concealment slot, not the hero's — see
                // `ForYouGridPage.revealConcealedPostID`. Applied on every
                // dequeue too, so a row that recycles mid-flight comes back
                // still hidden.
                setConcealed: { [weak page] concealed in
                    page?.setRevealConcealed(concealed, for: anchorID)
                },
                presentationDidEnd: { [weak self] landed in
                    // The flight faded the bar to nothing; take it down for
                    // real now, under the landed page where the frame change
                    // cannot be seen. A REVERSED opening never showed the
                    // page, so the bar goes back to being the grid's.
                    self?.tabBarController?.setTabBarHidden(landed, animated: false)
                    self?.tabBarController?.tabBar.alpha = 1
                },
                // Pin the grid's inset before the landing rect is read. The pop
                // animates the safe area and this collection view adds it to
                // its own inset, so an unpinned grid keeps drifting under a
                // close that has already measured where it is going.
                willStageDismissal: { [weak self, weak page, weak feed] in
                    log("freeze    pre")
                    page?.beginHeroFreeze()
                    // ⚠️ THE CARD THE VIEWER ENDED ON TAKES THE DEPARTURE SLOT,
                    // before anything measures where the close is going.
                    //
                    // The slot is where they left from and is still exactly
                    // where they left it, so the swap costs no scrolling and
                    // the card flies home to the frame it launched from. The
                    // alternative — flying to wherever the landed post happens
                    // to sit — moves the whole grid under a viewer who is
                    // holding it.
                    //
                    // Ordered first: `anchorID` is what the rect, the stand-in
                    // and the concealment all resolve through, and every one of
                    // them is read after this.
                    if let landed = (feed as? SnapFeedViewController)?.activePostID,
                       landed != anchorID,
                       page?.adoptForClose(
                           landed, intoSlotOf: anchorID,
                           orInsert: self?.viewModel.post(for: landed),
                           // This close CARRIES the row, so the row stands aside.
                           standingIn: true
                       ) == true {
                        // ⚠️ AND THE CONCEALMENT MOVES WITH THE SWAP.
                        //
                        // The window has been standing in for the row it opened
                        // from since the opening — that row is hidden, which is
                        // what stops the same post being on screen twice. The
                        // swap has just put a DIFFERENT post in that slot, and
                        // the flag still names the old one: the card the viewer
                        // is returning to was visible under the window they
                        // were dragging, while the card they had left sat
                        // hidden somewhere further down.
                        //
                        // Reported from the first case tried — open text A,
                        // page to text B, drag — and visible for the whole
                        // gesture, so no end-of-close sweep can answer it. The
                        // handover is `adoptForClose`'s, so both drivers get it
                        // from one place.
                        anchorID = landed
                    }
                    log("freeze   post")
                },
                dismissalDidEnd: { [weak self, weak page] committed in
                    page?.endHeroFreeze()
                    // ⚠️ NOTHING IS BROUGHT IN HERE any more.
                    //
                    // The card's metric line used to be faded up once the card
                    // was alone, because "the page never had one". That is true
                    // of the reveal's PUSH and irrelevant to this leg: a
                    // dismissal's window carries `RevealDismissCardView`, a
                    // whole row including that line, so the viewer had been
                    // looking at it for the length of the flight. Dropping it
                    // to zero and bringing it back is a blink of something
                    // already on screen — reported exactly that way.
                    // A cancelled swipe leaves the post on screen, so the bar
                    // restored at grab-begin has to go back down — unanimated
                    // and behind the page that sprang back, where nothing
                    // renders the change. Committed pops leave it up;
                    // `onFeedPopped` takes it from there.
                    guard !committed else { return }
                    self?.tabBarController?.setTabBarHidden(true, animated: false)
                }
            ),
            pipeline: page.bandImagePipeline
        )
        return true
        #else
        return false
        #endif
    }

    // MARK: - The row's "..."

    /// The rows this screen can service, in the order they read.
    ///
    /// Each is gated on the seam that performs it, so a build wired without a
    /// social graph shows a Report-only menu rather than an Unfollow that
    /// silently does nothing — and a build wired with neither shows no control
    /// at all, because `PostAuthorBandView` hides it on an empty answer.
    private func authorMenuActions(
        for context: ForYouGridPage.AuthorMenuContext
    ) -> [PostCardMenuAction] {
        var actions: [PostCardMenuAction] = []
        if socialGraph != nil {
            let handle = context.post.authorHandle ?? ""
            actions.append(.unfollow { [weak self] in
                // The handle is not in the ROW (the card names its author right
                // above it) but it is in the confirmation, where the card may
                // already be gone from under the viewer's thumb.
                self?.unfollow(context.authorID, handle: handle)
            })
        }
        if reporting != nil {
            actions.append(.report { [weak self] in
                self?.presentReportReasons(for: context)
            })
        }
        return actions
    }

    /// Unfollows, clears the author off the surface, and says so.
    ///
    /// The rows go only once the graph has ACCEPTED. Removing them optimistically
    /// would mean putting them back on a failure — a list that empties and
    /// refills itself under the reader is worse than one that waits a moment.
    private func unfollow(_ id: ProfileID, handle: String) {
        guard let socialGraph else { return }
        Task { [weak self] in
            do {
                try await socialGraph.setFollowing(false, for: id)
                guard let self else { return }
                // This surface is the following feed, so an author who is no
                // longer followed has nothing left on it. Without this the
                // action reads as having failed.
                viewModel.removeAuthor(id)
                let name = handle.isEmpty ? "this author" : "@\(handle)"
                ToastView.present("Unfollowed \(name)", symbol: "person.badge.minus", in: view)
            } catch {
                self?.presentFailure("Couldn't unfollow. Try again.")
            }
        }
    }

    private func presentReportReasons(for context: ForYouGridPage.AuthorMenuContext) {
        ReportReasonSheet.present(
            from: self, subject: "this post", sourceView: context.anchor
        ) { [weak self] reason in
            self?.report(context.post.id, reason: reason)
        }
    }

    /// Files the report and reports the outcome EITHER WAY — a report the user
    /// believes was filed but wasn't is the worst outcome here.
    private func report(_ postID: PostID, reason: ReportReason) {
        guard let reporting else { return }
        Task { [weak self] in
            do {
                // The surface names WHERE this was raised, which is a triage
                // signal in its own right: the same post reported from a feed
                // and from a profile are different reports.
                try await reporting.report(.post(postID), reason: reason, surface: "ios.foryou")
                guard let self else { return }
                ToastView.present("Report sent", symbol: "flag.fill", in: view)
            } catch {
                self?.presentFailure("Couldn't send this report. Try again.")
            }
        }
    }

    #if DEBUG
    /// `-post-menu-audit`: prints the rows a card's "..." would offer here.
    ///
    /// The composition is the thing worth checking and the thing a screenshot
    /// cannot show: a menu is a system surface, and whether a row exists
    /// depends on wiring three packages away. Printing it proves the seams
    /// reached this screen — a missing Unfollow means the composition root
    /// handed over no social graph, not that the menu is broken.
    func auditPostMenu() {
        guard ProcessInfo.processInfo.arguments.contains("-post-menu-audit"),
              let post = pager.posts(for: .activity).first(where: { $0.authorID != nil }),
              let authorID = post.authorID
        else { return }
        let rows = authorMenuActions(
            for: ForYouGridPage.AuthorMenuContext(
                post: post, authorID: authorID, anchor: UIView()
            )
        )
        print("[post-menu-audit] foryou rows=\(rows.map(\.title))")
    }
    #endif

    /// Failures are alerts, not toasts: a report or an unfollow that did not
    /// happen is something the viewer has to know in order to retry.
    private func presentFailure(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func openFeed(
        from format: GalleryFilter.Format, at index: Int, showingComments: Bool = false
    ) {
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
        let feed = snapFeed(for: Array(ids))
        // Hand the feed the projection this grid already holds, so its first
        // page configures at push time rather than when its own fetch returns.
        // Measured at ~0.69s of empty destination without it.
        if let seedable = feed as? SnapFeedViewController {
            seedable.seedProjection(GalleryPostProjection.seedModels(
                from: Array(posts[index...].prefix(Self.seedWindow))
            ))
            // A COLLECTION opens on the page the card was showing.
            //
            // The flight already carries the right photograph — the row's cover
            // and hero rect are the CURRENT page's — so a destination that
            // opened at page one would land the flight on a different image
            // than the one that flew. The card knows the page; nothing
            // downstream can work it out.
            // ⚠️ INCLUDING PAGE ZERO, and the `page > 0` this replaces is the
            // whole of a defect.
            //
            // Zero was treated as "no instruction" on the reasoning that a
            // destination opens at its first page anyway. It does not: the feed
            // controller is REUSED, and its carousel deliberately keeps its page
            // across a re-configure carrying the same attachments — that guard
            // is what stops a second hydration yanking a viewer's carousel back
            // to page one. So a post opened at page two, dismissed, then opened
            // again from page ONE arrived still showing page two.
            //
            // An absent instruction and an instruction to go to zero are
            // different things, and only one of them was expressible.
            if let page = pager.page(for: viewModel.format)?.currentMediaPage(atIndex: index) {
                seedable.openMediaPage(page, for: tapped.id)
                #if DEBUG
                if CarouselPlaybackAudit.isEnabled {
                    print("[sync] card asked page=\(page)")
                }
                #endif
            }
            // A post opened FROM ITS COMMENT COUNT arrives with the thread
            // already up. Handed over with the page instruction rather than
            // acted on here, for the same reason: this screen knows what was
            // pressed, and only the destination knows when it is safe to spend
            // the engagement's layout.
            if showingComments {
                // WHERE the thread's window opens from: the media rect the
                // flight is about to fly, so the thread is revealed out of the
                // photograph rather than arriving over it.
                seedable.openComments(
                    for: tapped.id,
                    revealingFrom: pager.page(for: format)?.hero(for: tapped.id, in: view)?.frame
                )
            }
            // …and the traffic runs the other way too, live. The card behind
            // follows the post's carousel, which is what makes the dismissal
            // land on the photograph the viewer is actually looking at rather
            // than on the one they opened with.
            let format = viewModel.format
            seedable.onMediaPageChanged = { [weak self] id, page in
                self?.pager.page(for: format)?.setMediaPage(page, for: id)
            }
        }

        // The feed owns the whole screen: hide the bar with the push. Managed
        // by hand rather than via `hidesBottomBarWhenPushed`, because that
        // flag's choreography does not scrub with a custom interactive pop —
        // the bar arrives at pop-begin and stands over the feed for the length
        // of a grab.
        //
        // Re-tested since, on the plain `UIPercentDrivenInteractiveTransition`
        // the text path uses, on the theory that the earlier verdict came from
        // the pin's free-floating interaction controller and might not survive
        // a percent driver. It survives. Wired up, the bar was at its resting
        // position and fully opaque in the FIRST frame after pop-begin and did
        // not move again while the scrub ran 0.000 → 0.150 — captured
        // composited over the feed's own author pill, mid-drag.
        //
        // The reason is structural, which is why no amount of driving fixes it:
        // the tab bar lives in the TAB BAR CONTROLLER's view, above the
        // navigation controller, so it is not in the transition's container and
        // not on the timeline the percent driver scrubs. UIKit animates it
        // beside the transition, not inside it.
        //
        // Worth recording what it got right, because it is the half this
        // screen had wrong: cancel and commit both settled correctly by
        // themselves. Only the mid-drag frames were unusable.
        // ARMED FIRST, because the next line is the one it changes: a reveal
        // drives the bar down on its own curve (`RevealPresentAnimator`), and
        // hiding it here would take it away before the opening starts — which
        // is the 26pt of card that used to pop into existence one frame in.
        //
        // Hiding it and putting it back was tried and is worse: UIKit runs its
        // own show/hide animation on the bar, and a second one fighting it left
        // the bar sitting fully opaque OVER the landed page for ~0.25s.
        let revealing = installTextReveal(feed: feed, format: format, postID: tapped.id)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-text-reveal-log") {
            // Which driver opened the screen, said once. Everything downstream
            // reads differently depending on this answer.
            //
            // ⚠️ "not the reveal" is TWO outcomes, not one: a flight, and the
            // plain push a row that is not realized falls back to. Printing
            // them as one made a harness run where the row had not been
            // realized look like a text post opening with a hero, which is a
            // defect that does not exist.
            print("[text-reveal] open reveal=\(revealing)"
                + " post=\(tapped.id.rawValue) kind=\(tapped.kind)")
        }
        #endif
        if !revealing {
            tabBarController?.setTabBarHidden(true, animated: true)
        }

        guard let page = pager.page(for: format),
              let destination = feed as? any ZoomTransitionDestination,
              // A reveal never also flies a hero. For a TEXT row this changes
              // nothing — it has no hero to fly — and for OPTION A it is what
              // sends a media row down the window's path instead.
              !revealing,
              page.hero(for: tapped.id, in: view) != nil
        else {
            // No hero available — a text-only row has no media to fly, and a
            // destination without the seam can't be flown to. A plain push is
            // the honest fallback; it is still the same feed.
            //
            // A full-surface interactive swipe stands in for the flight's
            // grab. It owns the dismissal from here, so the native edge
            // gesture stays out of its way (see `NativePopGestureEnabler`) —
            // the two would otherwise both try to drive one pop.
            (feed as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
            textSlideDismissal.attach(to: feed, axes: [.horizontal, .vertical])
            textSlideDismissal.onFeedPopped = { [weak self] _ in
                // The flight that rode along with this window is over with the
                // screen — released here rather than in one of its own hooks,
                // because it may never have flown anything at all.
                self?.cardPathFlight = nil
                // Completed pops only — a cancelled swipe reports nothing here,
                // which is exactly why this is a safe place to reveal from.
                // `viewWillAppear` normally gets there first via the
                // transition's completion; this is the backstop for the case
                // where its `topViewController` guard declined.
                self?.revealTabBar(animated: true)
                self?.restoreChromeAfterTransition()
                // The mirror of the hero path's backstop: this window may have
                // ended on a MEDIA post, whose close is the flight's, and a
                // flight that was cancelled or superseded leaves its hide
                // behind. Idempotent when nothing is hidden.
                self?.pager.page(for: format)?.clearHeroConcealment()
                // Close the playback handoff opened before the push.
                //
                // On the hero path the transition closes it (`onSourceReturned`
                // / `onPresentationCancelled`), but a plain push has no
                // transition and so had nobody to close it: `handoffID` stayed
                // set for the life of the page, permanently exempting that post
                // from both starting and stopping. Reproduced with
                // `-grid-playback-log` — `handoff=post-new-02` still on the
                // pool three samples after the grid was back.
                //
                // The handoff is still OPENED on this path, deliberately: it is
                // what stops the grid's players while the post covers them
                // (`viewWillDisappear` declines to, since a push must not stop
                // a flight's video). It just has to be closed at the other end.
                //
                // Completed pops only, which is what this callback is: a
                // cancelled swipe leaves the post on screen, where the grid
                // underneath should stay stopped.
                self?.pager.endPlaybackHandoff()
            }
            // ⚠️ AND THE FLIGHT RIDES ALONG, for the post this screen may end
            // on — the mirror of `attachCardCloseAlongsideFlight`.
            //
            // A text post opened this feed as a window, and the feed is a
            // PAGER: swipe to a photograph and the post being dismissed has a
            // hero to fly after all. Attached BEFORE the slide installs, so the
            // slide saves this controller as the delegate it displaced and can
            // forward a hero pop straight back to it.
            if let page = pager.page(for: format) {
                attachFlightAlongsideCardClose(feed: feed, page: page, tappedID: tapped.id)
            }
            textSlideDismissal.arbitratesWithHeroGrab = true
            // A new life for this screen: recapture whoever owns the stack.
            textSlideDismissal.install(on: navigationController, startingPresentation: true)
            navigationController.pushViewController(feed, animated: true)
            #if DEBUG
            // `-text-swipe-demo <peak>`: walks the exact begin/update/release
            // path a finger drives. The simulator injects no touches, so this
            // is the only way the scrub itself gets exercised — a peak below
            // the release threshold must spring back, above it must pop.
            let arguments = ProcessInfo.processInfo.arguments
            if let position = arguments.firstIndex(of: "-text-swipe-demo"),
               position + 1 < arguments.count,
               let peak = Double(arguments[position + 1]) {
                Task { @MainActor [textSlideDismissal] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await textSlideDismissal.debugPerformSwipe(peakProgress: CGFloat(peak))
                }
            }
            #endif
            return
        }
        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tapped.id,
            // Injected rather than imported: the source stays a grid concept
            // and never learns what a feed is.
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID },
            // And the post itself, for a landing this page no longer holds.
            landedModel: { [weak self] id in self?.viewModel.post(for: id) },
            activeMediaPage: { [weak feed] in (feed as? SnapFeedViewController)?.activeMediaPage },
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
        // A flight is staging, and it attaches its own grab below — so this
        // screen owns its dismissal and the native edge pop must stay out of
        // its way. Stated rather than left at the default: the controller is
        // reused, and the previous presentation may have said otherwise.
        (feed as? SnapFeedViewController)?.zoomOwnsInteractiveDismissal = true
        // The bar's alpha is driven 1:1 by the grab (and by the flight's spring
        // on a tap-back), so it is revealed by the hand instead of appearing
        // after the card has already landed.
        transition.returningSourceChrome = tabBarController?.tabBar
        transition.onSourceReturned = { [weak self, weak page] in
            // A card-shaped close that was cancelled left a row hidden under
            // the page; if the viewer then left by this flight instead, nothing
            // else would put it back. See `clearRevealConcealment`.
            page?.clearRevealConcealment()
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
        // Pay the destination's first layout and raster HERE — see
        // `prepareForHeroPresentation`. In the tap's own frame a stall is
        // invisible; in the flight's first frames it is the pause.
        (feed as? SnapFeedViewController)?
            .prepareForHeroPresentation(in: navigationController.view.bounds)
        navigationController.pushViewController(feed, animated: true)
        // ⚠️ THE OTHER DRIVER RIDES ALONG, for the post this screen may end on.
        //
        // A flight opened this feed, and the feed is a PAGER: swipe to a
        // text-only post and there is no media left for a hero to carry home.
        // The card-shaped close is attached here so that case has a driver at
        // all — the two grabs gate on `zoomDismissalKind` from opposite sides,
        // so exactly one of them claims any drag.
        //
        // AFTER the push, deliberately: `install` takes the navigation delegate
        // slot, and taking it before would hand this opening's animator to a
        // driver with no flight to offer. Taking it after leaves the flight
        // controller as `savedDelegate`, which is where a hero pop is forwarded
        // back to.
        attachCardCloseAlongsideFlight(feed: feed, format: format, departureID: tapped.id)
        #if DEBUG
        zoomProfilerNote("push returned")
        #endif

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
    /// Attaches the hero close to a screen that was opened as a WINDOW, for the
    /// case where the viewer pages onto a post that has media.
    ///
    /// The mirror of `attachCardCloseAlongsideFlight`, and it needs no
    /// equivalent of that one's `prepareForSwipe`: a flight resolves everything
    /// it carries through its source, which already adopts the landed post at
    /// staging and declines a landing it cannot fly to.
    ///
    /// Nothing here touches the opening. The controller is installed as the
    /// navigation delegate and then immediately shadowed by the slide, which is
    /// exactly what makes the window's own push survive — and what leaves this
    /// controller reachable, as `savedDelegate`, when a hero pop is forwarded.
    private func attachFlightAlongsideCardClose(
        feed: UIViewController, page: ForYouGridPage, tappedID: PostID
    ) {
        guard let navigationController,
              let destination = feed as? any ZoomTransitionDestination else { return }
        let source = ForYouGridZoomSource(
            page: page,
            tappedID: tappedID,
            activePostID: { [weak feed] in (feed as? SnapFeedViewController)?.activePostID },
            landedModel: { [weak self] id in self?.viewModel.post(for: id) },
            activeMediaPage: { [weak feed] in (feed as? SnapFeedViewController)?.activeMediaPage },
            depthView: pager
        )
        let transition = ZoomTransitionController(source: source, destination: destination)
        cardPathFlight = transition
        transition.returningSourceChrome = tabBarController?.tabBar
        navigationController.delegate = transition
        transition.attachInteractiveDismissal(to: feed.view) { [weak self] in
            // The same bar choreography the flight path states at length: back
            // at alpha 0 before the pop, so the drag fades it in.
            self?.showTabBar(alpha: 0)
            self?.navigationController?.popViewController(animated: true)
        }
    }

    /// Attaches the card-shaped close to a screen that was opened by a FLIGHT,
    /// for the case where the viewer pages onto a post that has no media.
    ///
    /// Nothing here changes an opening: no geometry is built and
    /// `revealPresents` stays false, so the slide has nothing to say about a
    /// push that has already happened. What it gains is a grab that can claim a
    /// drag when the destination says the post on screen travels as a card, and
    /// a hook to build that card's geometry at the moment it does.
    private func attachCardCloseAlongsideFlight(
        feed: UIViewController, format: GalleryFilter.Format, departureID: PostID
    ) {
        guard let navigationController else { return }
        textSlideDismissal.arbitratesWithHeroGrab = true
        textSlideDismissal.attach(to: feed, axes: [.horizontal, .vertical])
        // ⚠️ ADOPT FIRST, BUILD SECOND, and the order is not stylistic.
        //
        // The geometry's caption cut, its band and its stand-in are all read
        // off the landed post's ROW, so that row has to be in the departure
        // slot before any of them is asked for — otherwise they describe a card
        // sitting somewhere off screen. `adoptPost` is what puts it there.
        // ⚠️ ONCE. A swipe asks twice — when the grab claims the screen, and
        // again when the pop it triggers asks for an animator — and a second
        // swap would put the two cards back where they started.
        var hasPrepared = false
        textSlideDismissal.prepareForDismissal = { [weak self, weak feed] in
            guard !hasPrepared else { return }
            guard let self, let feed,
                  let page = pager.page(for: format),
                  let landed = (feed as? SnapFeedViewController)?.activePostID
            else { return }
            // ⚠️ ONLY FOR A CLOSE THAT CARRIES A CARD.
            //
            // This runs from the pop as well as from the grab, and a pop is
            // every dismissal there is — including a hero's. Doing this work
            // for one is not merely wasted: it CONCEALS the row below, and a
            // flight that lands on a hidden row reads as no animation at all.
            // Reported exactly that way, as the hero having stopped working.
            //
            // Asked of the same authority the two grabs gate on, so the three
            // can never disagree about what the post is.
            guard (feed as? any ZoomTransitionDestination)?.zoomDismissalKind == .card
            else { return }
            hasPrepared = true
            if landed != departureID {
                page.adoptPost(
                    landed, intoSlotOf: departureID, orInsert: self.viewModel.post(for: landed)
                )
            }
            installTextReveal(feed: feed, format: format, postID: landed, presenting: false)
            // ⚠️ AND HIDE THE ROW, which on this path nothing else has.
            //
            // A reveal normally conceals the row it departed from at the
            // OPENING — "the row goes the moment the window takes its place" —
            // and its close only puts it back. This screen was opened by a
            // FLIGHT, so no opening ever hid anything: without this the card
            // flies home over a grid already showing the same card, and the
            // landing has nothing to reveal. Measured as a close whose trace
            // carried a single `conceal=false` and no `conceal=true` at all.
            //
            // Last, because `adoptPost` deliberately un-hides both swapped
            // cells — the hero's requirement, since a flight LANDS on one of
            // them — and this is the opposite need.
            page.setRevealConcealed(true, for: landed)
        }
        // ⚠️ AND WHATEVER ANIMATED THE CLOSE, NO ROW STAYS HIDDEN.
        //
        // The concealment above is paid back by the reveal's own completion —
        // when the reveal is what runs. It is not the only thing that can: this
        // screen is closed by two grabs and by a back button, the preparation
        // above runs for all of them, and a pop that ends up animated by
        // anything else leaves the row it hid with nobody to put it back.
        //
        // Measured on a back-button close from a deep text landing: the row was
        // concealed, the close was animated by something that never ran the
        // reveal's completion, and the feed came back with a HOLE where the
        // post the viewer had just been reading should have been — permanently,
        // since nothing else on this screen ever revisits that flag.
        //
        // This is the backstop, not the mechanism: it fires on completed pops
        // only, by which point the grid is on screen and any row it still holds
        // hidden is a bug by definition.
        textSlideDismissal.onFeedPopped = { [weak self] _ in
            // Both concealments, because a close can be finished by a driver
            // that did not start it: the flight hides the tapped row's media at
            // the push and only its OWN return puts it back, so a visit that
            // ends on a text post — closed by the card driver — leaves that row
            // blank for good. See `clearHeroConcealment`.
            self?.pager.page(for: format)?.clearRevealConcealment()
            self?.pager.page(for: format)?.clearHeroConcealment()
            self?.cardPathFlight = nil
        }
        textSlideDismissal.install(on: navigationController, startingPresentation: true)
    }

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
        sweepAbandonedTransition()
        // ⚠️ NOTHING ON THIS SCREEN MAY BE INVISIBLE ONCE IT IS BACK.
        //
        // The concealments a close uses belong to a transition, and every one
        // of them is put back by the driver that applied it — when that driver
        // is the one that finishes. It often is not: the feed is a PAGER, so a
        // post opened by a FLIGHT (which hides the tapped row's media so the
        // card flies alone) can be closed by the CARD driver, whose return leg
        // knows nothing about a hide it did not make. The row came back with
        // its caption and a blank rectangle where its photograph belonged, and
        // it stayed that way — one more row per round trip that ended on
        // another kind of post. Reported after several iterations, which is
        // exactly how it accumulates.
        //
        // Tied to this moment rather than to a driver's callback because this
        // is the one fact all the paths share: the grid is on screen again, so
        // no flight is in the air, so nothing here is legitimately hidden.
        // `viewDidAppear` lands after the transition coordinator has finished,
        // so it cannot race a landing.
        pager.clearFlightConcealments()
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
    /// The post has finished covering this screen, so anything that would
    /// have been a visible jump can happen now.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Deliberately here rather than at `viewWillDisappear`: that fires as
        // the transition BEGINS, and the grid is visible behind an expanding
        // hero card for the whole flight. Moving it then is the jump this
        // avoids — just later in the animation.
        pager.applyPendingReveal()
    }

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
        switch TabBarRevealPolicy.timing(hasActiveFlight: activeTransition != nil,
                                         isTransitioning: transitionCoordinator != nil,
                                         isInteractive: transitionCoordinator?.isInteractive == true) {
        case .immediately:
            // A tab switch back, or a back-button pop: nothing here can be
            // taken back, so revealing now simply runs the bar alongside it.
            revealTabBar(animated: animated)
            return
        case .whenTransitionCommits:
            // A swipe on the plain-push fallback for a text-only row. This
            // runs at pop-BEGIN, which for a scrub is a question and not yet
            // an answer — so hand the reveal to the gesture's release (see
            // `TabBarRevealPolicy`).
            revealTabBarIfSwipeCommits()
            return
        case .drivenByFlight:
            break
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

    /// Puts the bar back on the far side of a scrubbed pop — but only if the
    /// finger meant it.
    ///
    /// Both blocks below run for a CANCELLED transition too, which is the
    /// entire point: that is the case that used to leave the bar stranded over
    /// a feed that had sprung back.
    private func revealTabBarIfSwipeCommits() {
        guard let coordinator = transitionCoordinator else { return }
        // The release. The outcome is decided here and the pop's tail is still
        // running, so the bar comes in WITH the screen rather than onto it.
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            self?.revealTabBar(animated: true)
        }
        // Backstop for a scrub that never reports a release — a gesture the
        // system cancels outright, or an interaction handed off to a
        // non-interactive finish. Idempotent against the notifier above.
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard TabBarRevealPolicy.shouldReveal(afterTransitionCancelled: context.isCancelled)
            else { return }
            self?.revealTabBar(animated: true)
        }
    }

    /// Reveals the bar at full opacity, idempotently.
    ///
    /// Two owners can reach this on a completed pop — the transition's
    /// completion above, and `onFeedPopped` — and their order is not
    /// guaranteed. Whichever arrives first animates; the second finds the bar
    /// already shown and does nothing, so the reveal can never double up. The
    /// backstop is deliberate: a bar stuck hidden is a far worse failure than a
    /// redundant call, and it is the failure this method's guard makes
    /// impossible.
    private func revealTabBar(animated: Bool) {
        guard let tabBarController else { return }
        tabBarController.tabBar.alpha = 1
        guard tabBarController.isTabBarHidden else { return }
        tabBarController.setTabBarHidden(false, animated: animated)
    }

    /// Releases a flight that ended by a route it never heard about.
    ///
    /// `activeTransition` is the "one flight at a time" latch `openFeed` checks,
    /// and it is cleared by the flight's own callbacks — `onSourceReturned` and
    /// `onPresentationCancelled`. Neither fires when the feed leaves the stack
    /// some other way: a screen pushed ABOVE it that pops to root, or a
    /// multi-pop that unwinds past it. The latch then stays set forever and
    /// `openFeed` returns early on every future tap.
    ///
    /// What that looks like is not a stuck transition — nothing is animating —
    /// but a grid that scrolls perfectly and opens nothing, which is why it
    /// reads as broken selection rather than as navigation state. Found by the
    /// stress harness: after one round trip through a profile, every later
    /// cycle's tap left the stack depth unchanged.
    ///
    /// Safe in `viewDidAppear` specifically: a flight still in progress has not
    /// finished appearing, so reaching here with the latch set and this screen
    /// on top means there is nothing left to finish.
    private func sweepAbandonedTransition() {
        guard activeTransition != nil, navigationController?.topViewController === self else {
            return
        }
        navigationController?.delegate = nil
        activeTransition = nil
        // The same close-out the callbacks do, for the same reason: whatever
        // the flight was holding down has to come back up.
        showTabBar(alpha: 1)
        restoreChromeAfterTransition()
        pager.endPlaybackHandoff()
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
        let visible = Array(viewModel.posts(for: viewModel.format).prefix(12))
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        Task { [prewarm] in await prewarm(Array(ids)) }
        // TEXT posts also prefetch their first page of comments, and only text
        // posts do.
        //
        // A text post's page IS its comments — it opens straight into comment
        // layout — so without this the hero flight carries a skeleton and the
        // real rows swap in after landing. A media post opens onto its media
        // and its comments are a secondary surface, so warming those would be
        // a dozen extra requests to remove nothing visible.
        //
        // Before the tap is the only useful moment: the panel mounts during
        // `prepareForHeroPresentation`, in the same turn as the push, so a
        // fetch started there cannot land in time however light it is.
        // The PAGE's list, not the view model's. They are not the same order:
        // the page groups the arrivals into their own "New" section and shows
        // them first, so the view model's leading 12 skipped every arrival —
        // and the arrivals are exactly the posts a viewer opens first. It is
        // also the list `openFeed` indexes into, so warming from it means
        // warming the post that will actually be tapped.
        let onPage = pager.posts(for: viewModel.format).prefix(12)
        let textIDs = onPage.filter { $0.kind == .text }.map(\.id)
        guard !textIDs.isEmpty else { return }
        warm(textIDs, immediate: false)
    }

    /// Warms what the viewer can actually see — see
    /// `ForYouGridPage.onWarmRequested`, which decides WHEN by riding the
    /// autoplay reconcile and its fling gate.
    ///
    /// ⚠️ EVERY KIND NOW, not just text. The rule this replaces was sound when
    /// it was written — "a media post opens onto its media and its comments are
    /// a secondary surface, so warming those would be a dozen extra requests to
    /// remove nothing visible" — and the comment count broke it: pressing it
    /// opens a media post STRAIGHT INTO its thread, where an unwarmed page
    /// shows a skeleton for the length of the flight and resolves after it.
    ///
    /// What keeps the request count honest is no longer the kind but the
    /// VISIBILITY: the ahead-of-time pass above still warms text posts down the
    /// page, and everything else is warmed only once its card is on screen and
    /// the feed is not being flung.
    private func warmVisible(_ posts: [GalleryPost]) {
        warm(posts.map(\.id), immediate: true)
    }

    /// ⚠️ TWO QUEUES, AND THE DIFFERENCE IS THE WHOLE FEATURE.
    ///
    /// `immediate` is what the viewer is LOOKING AT: one task per post, started
    /// now. Serial is wrong here — the first version ran every warm through one
    /// `for` loop, so the post whose card filled the screen waited behind
    /// eleven others down the page and was still fetching when the chip was
    /// pressed. The trace says it plainly: `asking [… post-new-04]` with the
    /// opened post LAST.
    ///
    /// Everything else is a queue, and it claims an id only when it REACHES
    /// it. Claiming the whole batch up front is how the ahead-of-time pass
    /// starved the visible one: it had already put its name on every post on
    /// the page, so when a card came into view there was nothing left to ask
    /// for and nothing to jump the queue with.
    private func warm(_ ids: [PostID], immediate: Bool) {
        guard let prefetchTopComments else { return }
        #if DEBUG
        // `-warm-log`: what was asked for and when it answered. It exists to
        // tell "the warm never ran" from "the warm ran and the tap beat it" —
        // two failures that look identical on screen, both a skeleton.
        let trace = ProcessInfo.processInfo.arguments.contains("-warm-log")
        #endif
        guard immediate else {
            let queued = ids.filter { !warmedComments.contains($0) }
            guard !queued.isEmpty else { return }
            Task { @MainActor in
                for id in queued where self.warmedComments.insert(id).inserted {
                    #if DEBUG
                    if trace { print("[warm] queued \(id.rawValue)") }
                    #endif
                    await prefetchTopComments(id)
                }
            }
            return
        }
        for id in ids where warmedComments.insert(id).inserted {
            #if DEBUG
            if trace { print("[warm] asking \(id.rawValue)") }
            #endif
            Task {
                await prefetchTopComments(id)
                #if DEBUG
                if trace { print("[warm] ready \(id.rawValue)") }
                #endif
            }
        }
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

    /// Steps the active page down the corpus, reporting at each stop what the
    /// page thinks SHOULD be playing.
    ///
    /// The independent half matters as much as the scrolling: the page
    /// recomputes the visible video rows and their distance from the viewport
    /// centre from geometry, and `[grid-rank]` reports what the coordinator
    /// actually chose. Agreement between two answers derived separately is the
    /// evidence; the coordinator agreeing with itself would be none.
    private func scheduleScrollDemo(steps: Int) {
        var attempts = 0
        func begin() {
            attempts += 1
            // Wait for content: a page with nothing in it scrolls nowhere, and
            // a fixed delay silently no-ops under `-mock-latency`.
            guard let page = pager.page(for: viewModel.format), page.debugScrollableHeight > 0 else {
                if attempts < 80 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: begin) }
                return
            }
            for step in 0...steps {
                // 2.5s a stop: a start is asynchronous (the URL resolves, then
                // the player attaches), so a shorter dwell reports the previous
                // stop's answer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(step)) { [weak self] in
                    guard let self, let page = pager.page(for: viewModel.format) else { return }
                    let target = min(page.debugScrollableHeight,
                                     CGFloat(step) * page.debugViewportHeight * 0.6)
                    print("[foryou-scroll] step \(step)/\(steps) y=\(Int(target)) "
                          + "expect=\(page.debugVisibleVideoRanking.map { "\($0.id)@\($0.distance)" })")
                    page.debugScroll(toY: target)
                }
            }
        }
        begin()
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
        // `-foryou-scroll-demo <steps>` walks the active page down the corpus,
        // pausing long enough at each stop for playback to settle. The only way
        // to exercise autoplay's ranking under scroll: the reconcile that
        // decides which videos play is driven by scroll callbacks, and the
        // simulator injects no touches.
        if let position = arguments.firstIndex(of: "-foryou-scroll-demo"),
           position + 1 < arguments.count, let steps = Int(arguments[position + 1]) {
            scheduleScrollDemo(steps: steps)
        }
        // `-foryou-expand <index> [delay]`: presses a row's "Show more". Polls
        // for content rather than firing on a delay, for the same reason
        // `-foryou-open` does — a fixed wait silently no-ops under
        // `-mock-latency`.
        //
        // The optional delay is for FILMING it. A capture has to be started
        // after the app has settled or it is mostly launch, and by then the
        // default one-second press has already happened: three recordings in a
        // row caught nothing but the expanded end state.
        if let position = arguments.firstIndex(of: "-foryou-expand"),
           position + 1 < arguments.count, let index = Int(arguments[position + 1]) {
            let delay = position + 2 < arguments.count
                ? (Double(arguments[position + 2]) ?? 1.0)
                : 1.0
            var attempts = 0
            func attempt() {
                attempts += 1
                let page = pager.page(for: viewModel.format)
                if page?.debugTapShowMore(atIndex: index) == true {
                    print("[foryou-expand] expanded row \(index)")
                    return
                }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[foryou-expand] NOTHING TO EXPAND at row \(index)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attempt)
        }
        // `-foryou-carousel <row> <page>`: swipes a collection row's pages.
        // Polls for the same reason `-foryou-expand` does — the row has to be
        // realized and its pages built, and a fixed delay silently no-ops.
        if let position = arguments.firstIndex(of: "-foryou-carousel"),
           position + 2 < arguments.count,
           let index = Int(arguments[position + 1]),
           let page = Int(arguments[position + 2]) {
            var attempts = 0
            func attempt() {
                attempts += 1
                if pager.page(for: viewModel.format)?
                    .debugScrollCarousel(atIndex: index, toPage: page) == true {
                    print("[foryou-carousel] row \(index) → page \(page)")
                    return
                }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[foryou-carousel] NO COLLECTION at row \(index)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
        }
        // `-foryou-open-comments N` is `-foryou-open N` through the comment
        // count instead of the card, so the shorter route is exercised by the
        // same waiting-for-content machinery rather than by a second one.
        let viaComments = arguments.firstIndex(of: "-foryou-open-comments")
        guard let position = viaComments ?? arguments.firstIndex(of: "-foryou-open"),
              position + 1 < arguments.count,
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
            // Through the page's own selection path, so a scripted open runs
            // the same code a tap does — including the scroll-into-view
            // bookkeeping that `openFeed` alone would skip.
            if viaComments != nil {
                if pager.page(for: format)?.debugTapComments(at: index) != true {
                    print("[foryou-comments] row \(index) has no comment chip to press")
                }
            } else if pager.page(for: format)?.debugSelectItem(at: index) != true {
                openFeed(from: format, at: index)
            }
            // `-zoom-repeat`: open, pop, open again (twice over). The hero's
            // stall has only ever been measured on the FIRST push of a
            // process, which cannot distinguish per-push cost from one-time
            // warm-up of whatever the push touches first. Two more rounds
            // separate them.
            if ProcessInfo.processInfo.arguments.contains("-zoom-repeat") {
                for round in 1...2 {
                    let base = 3.0 * Double(round)
                    DispatchQueue.main.asyncAfter(deadline: .now() + base) { [weak self] in
                        self?.navigationController?.popViewController(animated: true)
                    }
                    // A DIFFERENT tile each round. Reopening the same one
                    // cannot tell a re-pointed feed from a stale one — both
                    // render the same post — so the harness would pass while
                    // reuse served the previous window.
                    // `-zoom-repeat-same` reopens the SAME tile, which is what
                    // a re-entry bug needs: a different tile exercises a fresh
                    // window and hides state the previous flight left behind.
                    let reopen = ProcessInfo.processInfo.arguments.contains("-zoom-repeat-same")
                        ? index : index + round
                    DispatchQueue.main.asyncAfter(deadline: .now() + base + 1.5) { [weak self] in
                        self?.openFeed(from: format, at: reopen)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: attempt)
    }
    #endif
}

// MARK: - The mode menu, offered elsewhere

/// The app's tab bar offers this screen's lens menu under a long press. It is
/// the SAME menu object the navigation bar's own item carries — same rows, same
/// pills, same glyphs — so the two can never drift into disagreeing about what
/// the modes are or how much is waiting under each.
extension ForYouViewController: ForYouModeMenuProviding {
    func makeModeMenu() -> UIMenu {
        makeContextMenu()
    }
}

#if DEBUG
extension ForYouViewController: DebugItemSelectable {
    /// Taps the active page's first item through its own delegate method, so
    /// the stress harness exercises the hero rather than a router push.
    func debugSelectFirstItem() -> Bool {
        pager.page(for: viewModel.format)?.debugSelectItem(at: 0) ?? false
    }
}
#endif
