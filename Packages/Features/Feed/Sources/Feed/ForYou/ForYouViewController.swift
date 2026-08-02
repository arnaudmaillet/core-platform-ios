import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import MediaPlayback
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
        .title("Activity"), .title("Gallery"), .title("Short")
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

    /// The tray's offset from the view's raw bottom edge. Owned rather than
    /// delegated to the safe-area guide; see `syncTrayPosition`.
    private var trayBottomConstraint: NSLayoutConstraint!

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
        prewarm: @escaping ([PostID]) async -> Void
    ) {
        self.viewModel = viewModel
        self.makeSnapFeed = makeSnapFeed
        self.prewarm = prewarm
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
        navigationItem.title = nil
        navigationItem.largeTitleDisplayMode = .never
        // Native bar items on both sides.
        //
        // Partly product, partly a probe: a large title renders in the CONTENT
        // area rather than the bar, so it participates in the layout the hero
        // flight animates over, and the question was whether its passes were
        // invalidating views mid-transition. Plain bar items lay out in the bar
        // itself and cannot, so if the dismissal's frame-0 artifact survives
        // this it is not the header — which is a real answer either way.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            style: .plain, target: self, action: #selector(headerLeftTapped)
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Filters"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .plain, target: self, action: #selector(headerRightTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Search"

        pager.pin(to: view)
        // The tray floats over the pages, so they must be able to scroll their
        // last row clear of it.
        pager.trayClearance = InlineFilterTrayView.height + InlineFilterTrayView.spacingBelow * 2

        view.addSubview(trayView)
        // Pinned to the view's RAW bottom with a constant this screen owns, not
        // to `safeAreaLayoutGuide.bottomAnchor`. The safe area animates through a
        // pop — and worse, it reads a few points off its resting value while the
        // pop is in flight (measured: bottom inset 86 mid-flight against 83 at
        // rest), so a tray tied to it sits 3pt high for the whole drag and snaps
        // down when the layout finally settles. `syncTrayPosition` tracks the
        // safe area only while nothing is flying, which makes the constant a
        // *resting* measurement the gesture cannot disturb.
        trayBottomConstraint = trayView.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -InlineFilterTrayView.spacingBelow
        )
        NSLayoutConstraint.activate([
            trayView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            trayView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            trayView.heightAnchor.constraint(equalToConstant: InlineFilterTrayView.height),
            trayBottomConstraint
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
        debugTraceChrome()
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
            // Donate-then-park, run at card-build time so the card flies the
            // very layer the tile was already rendering.
            hoistLive: { [weak self] view, rect, space, radius in
                self?.hoistForDismissal(view, at: rect, in: space, cornerRadius: radius) ?? false
            },
            poseHoisted: { [weak self] rect, space, radius in
                self?.poseHostedSurface(at: rect, in: space, cornerRadius: radius)
            },
            releaseHoisted: { [weak self] in self?.releaseHoistedForCancel() },
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
            self?.restoreTrayAfterTransition()
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
            self?.debugAuditTray("returned")
            self?.debugAdvanceGrabCycleIfNeeded()
            #endif
        }
        transition.onDismissalCancelled = { [weak self] in
            // The feed is staying up, so put the bar back down — it is behind
            // the restored page by now, so nothing renders the change.
            self?.tabBarController?.setTabBarHidden(true, animated: false)
            self?.tabBarController?.tabBar.alpha = 1
            self?.restoreTrayAfterTransition()
            #if DEBUG
            self?.debugAuditTray("cancelled")
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
            self?.restoreTrayAfterTransition()
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncTrayPosition()
    }

    /// Re-pins the tray to the CURRENT safe area — but only while no flight is
    /// in progress.
    ///
    /// This is the whole fix for the tray's landing snap. A pop animates the safe
    /// area, and mid-flight it does not merely interpolate, it reads a few points
    /// off its own resting value: measured at a bottom inset of 86 during the
    /// drag against 83 once settled. Anything pinned to the safe-area guide
    /// therefore sits 3pt out of place for the length of the gesture and corrects
    /// the instant the layout settles — a small, very visible jump right at the
    /// end of the hero.
    ///
    /// Skipping the update while a flight is alive means the constant in force
    /// during a gesture is always the last *resting* measurement, so there is
    /// nothing left to correct at teardown. The tray is then immune to the
    /// transition by construction rather than by having its own animation
    /// cancelled.
    /// Rebuilds the tray's appearance after any transition ends.
    ///
    /// Called on a completed hero return, a cancelled grab, and every appearance
    /// — all three, because the failure it repairs has been seen after an
    /// interactive dismissal and a cancelled grab reaches none of the completion
    /// callbacks. It is idempotent and costs a layout pass, so running it when
    /// nothing was wrong is not worth guarding against.
    private func restoreTrayAfterTransition() {
        (trayView as? TransitionRestorable)?.restoreAfterTransition()
    }

    /// Points the segment row at the view model's format, without echoing the
    /// change back out as a user selection.
    private func syncFormatRowSelection() {
        guard let index = ForYouPagerView.pageOrder.firstIndex(of: viewModel.format) else { return }
        formatRow.select(index, notify: false)
        pager.setActivePage(viewModel.format, animated: false)
    }

    private func syncTrayPosition() {
        guard activeTransition == nil else { return }
        let target = -(view.safeAreaInsets.bottom + InlineFilterTrayView.spacingBelow)
        // Guarded: assigning inside a layout pass schedules another one.
        guard abs(trayBottomConstraint.constant - target) > 0.01 else { return }
        trayBottomConstraint.constant = target
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

    /// Placeholders: these exist to put real bar items in the header, not to
    /// add features. Wired to nothing on purpose rather than to a half-built
    /// destination.
    @objc private func headerLeftTapped() {}
    @objc private func headerRightTapped() {}

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
        syncFormatRowSelection()
        restoreTrayAfterTransition()
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

    /// `-foryou-audit-tray`: reports any view in the tray's subtree that is not
    /// fully visible or not reachable by a tap, at the end of every dismissal.
    ///
    /// "Did the transition leak a hidden state into the tray?" is answerable
    /// exactly, so it is answered exactly instead of by squinting at a
    /// screenshot: walk the subtree for `alpha < 1`, `isHidden` or a zero-area
    /// frame, then hit-test each segment to prove nothing is sitting over it.
    /// Pair with `-foryou-grab-cycles` — a leak that survives one return is one
    /// anybody would catch, so the interesting ones need several round trips.
    func debugAuditTray(_ label: String) {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-audit-tray") else { return }
        var offenders: [String] = []
        func walk(_ view: UIView, _ path: String) {
            let name = "\(path)/\(type(of: view))"
            if view.isHidden { offenders.append("\(name) isHidden") }
            if view.alpha < 0.999 { offenders.append(String(format: "%@ alpha=%.3f", name, view.alpha)) }
            if view.frame.width == 0 || view.frame.height == 0 {
                offenders.append("\(name) zero-frame")
            }
            view.subviews.forEach { walk($0, name) }
        }
        walk(trayView, "tray")
        // Every label the tray is drawing, with its text and width. A segment
        // whose title has gone missing or collapsed to zero width is invisible
        // while passing every alpha/isHidden check above, so it has to be
        // checked as its own thing.
        var labels: [String] = []
        func collectLabels(_ v: UIView) {
            if let label = v as? UILabel {
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
                if label.alpha < 0.999 { offenders.append("'\(label.text ?? "nil")' label alpha") }
            }
            v.subviews.forEach(collectLabels)
        }
        collectLabels(trayView)
        // A clipping ancestor is exactly what would cut the outer segments off,
        // and none of them has any business clipping: the capsules are shaped
        // with `cornerConfiguration` precisely so they never need to.
        var node: UIView? = trayView
        while let current = node, current !== view {
            if current.clipsToBounds { offenders.append("\(type(of: current)) clipsToBounds") }
            if current.layer.mask != nil { offenders.append("\(type(of: current)) masked") }
            node = current.superview
        }
        if labels.count != 3 { offenders.append("label count \(labels.count) != 3") }
        for expected in ["Activity", "Gallery", "Short"] where !labels.contains(where: { $0.hasPrefix(expected) }) {
            offenders.append("missing '\(expected)'")
        }
        // Visible is not the same as reachable: something left over the tray
        // (an undismissed dim, a stale transition container) would pass every
        // check above and still swallow every tap. Hit-test each segment's
        // centre and confirm the tray is what answers.
        for (index, segment) in ["Activity", "Gallery", "Short"].enumerated() {
            let row = formatRow
            guard index < row.subviews.first?.subviews.count ?? 0,
                  let button = row.subviews.first?.subviews[index] as? UIButton
            else { continue }
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
            let hit = view.hitTest(point, with: nil)
            let reachable = hit.map { $0 === button || $0.isDescendant(of: button) } ?? false
            if !reachable {
                offenders.append("\(segment) unreachable (hit=\(hit.map { "\(type(of: $0))" } ?? "nil"))")
            }
        }
        print("[trayaudit \(label)] sel=\(formatRow.selectedIndex) labels=\(labels.joined(separator: " ")) "
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
        let tray = trayView.convert(trayView.bounds, to: window)
        let safeBottom = view.safeAreaInsets.bottom
        let bar = navigationController?.navigationBar
        let barRect = bar.map { $0.convert($0.bounds, to: window) } ?? .zero
        // Find whatever is actually drawing the big "For You" — it is not in the
        // 54pt compact bar, so measuring `navigationBar` alone proves nothing.
        var titleRect = CGRect.zero
        var titleOwner = "none"
        func findTitle(_ v: UIView) {
            if let label = v as? UILabel, label.text == "For You", label.bounds.height > 20 {
                titleRect = label.convert(label.bounds, to: window)
                titleOwner = "\(type(of: label.superview ?? label))"
            }
            v.subviews.forEach(findTitle)
        }
        findTitle(window)
        // The navigation bar's ENTIRE subtree, not just its direct children: an
        // item that slides inside a container at a fixed position would
        // otherwise go unseen.
        var rows: [String] = []
        func walkBar(_ v: UIView, _ depth: Int) {
            guard depth < 6 else { return }
            let r = v.convert(v.bounds, to: window)
            if r.width > 1, r.height > 1 {
                rows.append(String(format: "%.0f:%.1f/%.1f", Double(depth), r.minX, r.minY))
            }
            v.subviews.forEach { walkBar($0, depth + 1) }
        }
        if let bar { walkBar(bar, 0) }
        let items = rows.joined(separator: ",")
        print(String(
            format: "[chrome:%@] trayY=%.2f trayH=%.2f safeB=%.2f navY=%.2f titleY=%.2f t=%@ items=%@",
            phase, tray.minY, tray.height, safeBottom, barRect.minY,
            titleRect.minY, NSCoder.string(for: view.transform), items
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
        // `-foryou-switch-format a,b,...` taps the format segments in order,
        // ~0.8s apart, through the very path a finger drives (`select(notify:)`
        // -> `onSelect`). The reported bug needs a *sequence* of switches before
        // the dismissal, so the sequence has to be reproducible.
        if let position = arguments.firstIndex(of: "-foryou-switch-format"),
           position + 1 < arguments.count {
            let names = arguments[position + 1].split(separator: ",").map(String.init)
            // The tile tap must come AFTER the switches, or the repro runs out
            // of order and proves nothing.
            openDelay = 1.5 + 0.8 * Double(names.count)
            for (step, name) in names.enumerated() {
                let format: GalleryFilter.Format? = switch name {
                case "activity": .activity
                case "media", "gallery": .media
                case "short": .short
                default: nil
                }
                guard let format, let index = ForYouPagerView.pageOrder.firstIndex(of: format) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + 0.8 * Double(step)) { [weak self] in
                    self?.formatRow.select(index, notify: true)
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
