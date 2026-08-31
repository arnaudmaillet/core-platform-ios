import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The PLACE PROFILE that sits BENEATH a semantic-cluster feed (Case B of the
/// cluster-gallery milestone, redesigned to read like a profile page):
/// tapping a City/Country/Region cluster on the map lands on the snap feed
/// with this screen already on the stack under it, and a downward grab on the
/// feed morphs the active post into its Gallery tile here.
///
/// The page is a profile-shaped column:
/// - a HERO BANNER wearing the place's TOP post (highest engagement — the
///   same ranking the Gallery leads with, so banner, pin face and first tile
///   are one post);
/// - a two-metric band: the place's aggregated REACTIONS and VIEWS. No
///   avatar, no bio, no edit/share — a place is not an account;
/// - three tabs under the metrics — **Gallery** (the popularity grid),
///   **Shorts** (the place's video posts), **Activity** (a chronological
///   stream of check-ins and posts) — a `PagedTabBar` over a
///   `HorizontalPagerView`, the same pairing the profile's relationship
///   screen ships.
/// The follow-this-place heart keeps the top-right navigation slot.
///
/// It remains an ordinary navigation citizen — plain title ("Paris • City
/// Cluster"), tab bar visible, native edge-pop back to the map — because
/// every special behaviour of the flow lives in the TRANSITIONS, not in the
/// screen: the two-VC stack insertion is the map's, the vertical morph is
/// the zoom stack's, and this type only has to host its column and answer
/// the `ZoomTransitionSource` questions about the Gallery grid.
final class PlaceProfileViewController: UIViewController {
    /// The Gallery tab's grid — the flight anchor every dismissal lands on.
    private let page: ForYouGridPage
    /// The Shorts tab: the same grid machinery over the place's videos only.
    private let shortsPage: ForYouGridPage
    /// The Activity tab: newest-first check-ins/posts derived from members.
    private let activityList = PlaceActivityListView()

    private let bannerView = UIImageView()
    private let bannerScrim = GradientScrimView()
    private let reactionsMetric = PlaceMetricView(title: "Reactions")
    private let viewsMetric = PlaceMetricView(title: "Views")
    private let tabBar = PagedTabBar(titles: ["Gallery", "Shorts", "Activity"], style: .floating)
    private var pager: HorizontalPagerView!

    /// The floating header: banner + metrics + tab bar in one host that
    /// RIDES THE ACTIVE PAGE'S OFFSET (the profile page's mechanics, adopted
    /// wholesale). The pages fill the screen and scroll themselves; this
    /// host sits above them, moved by its top constraint, and stops moving
    /// when the tab bar reaches the navigation bar — the sticky dock.
    private let headerHost = UIView()
    private var headerTopConstraint: NSLayoutConstraint?
    /// The place's display title ("Paris • City Cluster") — worn as the HERO
    /// TITLE on the banner while the header is expanded, and crossfading into
    /// the navigation bar's title slot as the banner scrolls under the chrome.
    /// The navigation item's own `title` stays empty for the whole life of
    /// the screen: the name is either on the banner or in `navTitleLabel`,
    /// never in both places at full strength.
    private let placeName: String
    /// The banner's hero identity: the place kind whispered above the name.
    private let heroKindLabel = UILabel()
    private let heroNameLabel = UILabel()
    /// The docked replacement, alpha-driven from the same scroll ramp the
    /// identity fade runs on — the two are complements, so the name is
    /// always exactly once on screen.
    private let navTitleLabel = UILabel()
    /// The three pages under their hosted-header contract, pager order.
    private var hostedPages: [any PlaceProfileHostedPage] = []
    /// Which page the header is riding. Adopted at tab-tap time (the
    /// destination takes the offset BEFORE it travels) and confirmed on
    /// swipe settle.
    private var activeIndex = 0

    private let postIDs: [PostID]
    private let imagePipeline: ImagePipeline
    private let loadPosts: () async throws -> [GalleryPost]
    /// Opens a tapped tile's post over this profile — wired by the builder to
    /// `presentSnapFeedHero`, so a tile-opened post gets the full hero pair
    /// (flight up, grab back to this very tile) with no new machinery.
    private let openPost: (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void

    /// The post the OVERLYING feed is currently showing — the landing anchor
    /// for a dismissal into this screen. Injected (weakly, by the builder)
    /// so this screen never has to know what a feed is.
    var activePostID: (() -> PostID?)?

    /// The header's follow-this-place toggle, when the caller's subject has a
    /// followable identity (`ClusterGalleryFollowing`); nil hides the button.
    private let following: ClusterGalleryFollowing?
    private let followButton = UIButton(configuration: .plain())

    /// The tile a dismissal is currently flying to. Starts at the cluster's
    /// representative (the feed's first post) and re-points to whatever the
    /// feed settled on when a dismissal stages.
    private var anchorID: PostID
    private var loadTask: Task<Void, Never>?

    // MARK: - The map return flight

    /// Produces a FRESH flight source for the cluster marker this page
    /// belongs to — assigned by the builder
    /// (`FeedFeatureBuilding.makeClusterGallery`), resolved lazily because
    /// the marker's face, ring and presence can all churn while this page is
    /// buried under the feed. `nil` — or a `nil` answer — keeps the plain
    /// slide: the fallback dismissal for a marker the map no longer shows.
    var mapReturn: (() -> (any ZoomTransitionSource)?)?

    /// The page's own hero return to the map — created once, then installed
    /// as the stack's delegate whenever this page is top, so BOTH the back
    /// button and the horizontal grab fly home to the marker instead of
    /// sliding. Retained here (the controller holds its destination weakly).
    private var mapReturnTransition: ZoomTransitionController?
    /// Whoever owned the delegate slot before this page's first install —
    /// handed the slot back when the page pops for good.
    private weak var mapReturnPreviousDelegate: (any UINavigationControllerDelegate)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installMapReturnIfTop()
        #if DEBUG
        scheduleDebugPopIfRequested()
        #endif
    }

    /// Installs the hero return each time this page becomes the top screen.
    /// The transition is built ONCE (its grab attaches a pan; a rebuild per
    /// appearance would stack recognizers) from the first source `mapReturn`
    /// yields; the DELEGATE install repeats, because every feed pushed above
    /// takes the slot and hands back whatever it captured.
    private func installMapReturnIfTop() {
        guard let nav = navigationController, nav.topViewController === self else { return }
        if mapReturnTransition == nil, let source = mapReturn?() {
            let transition = ZoomTransitionController(source: source, destination: self)
            transition.attachInteractiveDismissal(to: view, axes: [.horizontal]) { [weak nav] in
                nav?.popViewController(animated: true)
            }
            transition.onSourceReturned = { [weak self, weak nav] in
                // Landed on the map: the flow is over, the slot goes back to
                // whoever owned it before this page existed.
                guard let self, let nav else { return }
                if nav.delegate === self.mapReturnTransition {
                    nav.delegate = self.mapReturnPreviousDelegate
                }
            }
            mapReturnTransition = transition
        }
        guard let transition = mapReturnTransition, nav.delegate !== transition else { return }
        if mapReturnPreviousDelegate == nil {
            mapReturnPreviousDelegate = nav.delegate
        }
        nav.delegate = transition
    }

    #if DEBUG
    private var didScheduleDebugPop = false

    /// `-maps-place-pop-demo`: pops this page ~1.5s after it becomes top —
    /// the sim can't tap the back button, and the non-interactive pop is
    /// exactly the leg that proves the hero return animator is installed.
    private func scheduleDebugPopIfRequested() {
        guard !didScheduleDebugPop,
              ProcessInfo.processInfo.arguments.contains("-maps-place-pop-demo")
        else { return }
        didScheduleDebugPop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let nav = self.navigationController,
                  nav.topViewController === self else { return }
            nav.popViewController(animated: true)
        }
    }
    #endif
    private var bannerTask: Task<Void, Never>?

    /// How many posts seed a feed opened from a tile — the same window (and
    /// the same reason) as For You's.
    private static let seedWindow = 40
    private static let bannerHeight: CGFloat = 220

    init(
        postIDs: [PostID],
        placeName: String = "",
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        following: ClusterGalleryFollowing? = nil,
        loadPosts: @escaping () async throws -> [GalleryPost],
        openPost: @escaping (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void
    ) {
        self.postIDs = postIDs
        self.placeName = placeName
        self.imagePipeline = imagePipeline
        self.following = following
        self.loadPosts = loadPosts
        self.openPost = openPost
        self.anchorID = postIDs.first ?? PostID("")
        self.page = ForYouGridPage(
            imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback
        )
        self.shortsPage = ForYouGridPage(
            imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        loadTask?.cancel()
        bannerTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureHeader()
        configureTabs()
        page.render(.loading)
        shortsPage.render(.loading)
        page.onItemTapped = { [weak self] index in self?.openTile(at: index, in: self?.page) }
        shortsPage.onItemTapped = { [weak self] index in self?.openTile(at: index, in: self?.shortsPage) }
        configureFollowButton()
    }

    // MARK: - Layout (floating header over full-screen pages)

    private func configureHeader() {
        // The PAGES fill the screen and scroll themselves; the header floats
        // over them (added second, so it draws above the content sliding
        // under it) and is moved by its top constraint from whichever page
        // is being read.
        hostedPages = [page, shortsPage, activityList]
        pager = HorizontalPagerView(pages: [page, shortsPage, activityList])
        pager.pin(to: view)

        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        let top = headerHost.topAnchor.constraint(equalTo: view.topAnchor)
        headerTopConstraint = top

        bannerView.contentMode = .scaleAspectFill
        bannerView.clipsToBounds = true
        bannerView.backgroundColor = .secondarySystemBackground
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(bannerView)
        bannerScrim.translatesAutoresizingMaskIntoConstraints = false
        bannerView.addSubview(bannerScrim)

        // The HERO TITLE: the place's name at the banner's foot, over the
        // legibility scrim — the identity leads the page, not the chrome.
        // `.label` over the background-tinted scrim keeps contrast in both
        // appearances; the soft shadow covers the strip where the scrim is
        // still mostly image.
        let (heroName, heroKind) = Self.heroTitleComponents(of: placeName)
        heroKindLabel.text = heroKind?.uppercased()
        heroKindLabel.font = .preferredFont(forTextStyle: .caption1)
        heroKindLabel.textColor = .secondaryLabel
        heroKindLabel.isHidden = heroKind == nil
        heroNameLabel.text = heroName
        heroNameLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title1).pointSize, weight: .bold
        )
        heroNameLabel.textColor = .label
        heroNameLabel.adjustsFontSizeToFitWidth = true
        heroNameLabel.minimumScaleFactor = 0.6
        for label in [heroKindLabel, heroNameLabel] {
            label.layer.shadowColor = UIColor.systemBackground.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 6
            label.layer.shadowOffset = .zero
        }
        let heroTitle = UIStackView(arrangedSubviews: [heroKindLabel, heroNameLabel])
        heroTitle.axis = .vertical
        heroTitle.spacing = 2
        heroTitle.translatesAutoresizingMaskIntoConstraints = false
        bannerView.addSubview(heroTitle)

        // The docked twin, in the navigation bar's title slot from day one —
        // at alpha 0 while the hero is on the banner; the scroll ramp
        // crossfades the two (`applyHeaderOffset`). The item's own `title`
        // is never set, so nothing else can draw the name at full strength.
        //
        // ⚠️ The label rides inside a WRAPPER, and the wrapper is what the
        // bar gets. iOS 26's navigation bar animates its title slot through
        // snapshots and NORMALIZES the hosted view's alpha around push/pop
        // (measured: the label arrived at alpha 1 after the pop into this
        // screen, with nothing of ours having written it) — so the driven
        // knob has to live one level below the view UIKit manages.
        navTitleLabel.text = placeName
        navTitleLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold
        )
        navTitleLabel.alpha = 0
        navTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let navTitleHost = UIView()
        navTitleHost.addSubview(navTitleLabel)
        NSLayoutConstraint.activate([
            navTitleLabel.topAnchor.constraint(equalTo: navTitleHost.topAnchor),
            navTitleLabel.leadingAnchor.constraint(equalTo: navTitleHost.leadingAnchor),
            navTitleLabel.trailingAnchor.constraint(equalTo: navTitleHost.trailingAnchor),
            navTitleLabel.bottomAnchor.constraint(equalTo: navTitleHost.bottomAnchor),
        ])
        navigationItem.titleView = navTitleHost

        let metrics = UIStackView(arrangedSubviews: [reactionsMetric, viewsMetric])
        metrics.distribution = .fillEqually
        metrics.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(metrics)
        self.metricsBand = metrics

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(tabBar)

        // ⚠️ Stretchy banner, the profile's own mechanism: the host is moved
        // by its TOP CONSTRAINT rather than a transform precisely so this
        // works — the banner's top is pinned `lessThanOrEqualTo` the view's
        // top at required priority over its natural host-top equality, so a
        // pull-down (the host travelling below rest) stretches the banner
        // from the viewport's top edge instead of dragging it away and
        // exposing the background behind.
        let bannerRestingTop = bannerView.topAnchor.constraint(equalTo: headerHost.topAnchor)
        bannerRestingTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            top,
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerRestingTop,
            bannerView.topAnchor.constraint(lessThanOrEqualTo: view.topAnchor),
            bannerView.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            // The BOTTOM is the fixed edge (host.top + bannerHeight), so a
            // stretched banner grows upward while the metrics hold still.
            bannerView.bottomAnchor.constraint(
                equalTo: headerHost.topAnchor, constant: Self.bannerHeight
            ),
            bannerScrim.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor),
            bannerScrim.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor),
            bannerScrim.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor),
            bannerScrim.heightAnchor.constraint(equalToConstant: 80),
            // The hero title rides the banner's FIXED bottom edge (see the
            // stretch note above), so a pull-down stretches the image behind
            // it while the name holds its seat over the scrim.
            heroTitle.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 16),
            heroTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: bannerView.trailingAnchor, constant: -16
            ),
            heroTitle.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -10),
            metrics.topAnchor.constraint(
                equalTo: headerHost.topAnchor, constant: Self.bannerHeight + 12
            ),
            metrics.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor, constant: 16),
            metrics.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor, constant: -16),
            // Both edges, not leading-only: a `.floating` bar SPANS its host
            // (its intrinsic width is `noIntrinsicMetric`), so an unpinned
            // trailing edge collapses it to zero width.
            tabBar.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 8),
            tabBar.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
        ])
    }

    private var metricsBand: UIStackView!

    private func configureTabs() {
        // The header rides the ACTIVE page's offset — every page reports,
        // the coordinator listens to one.
        for (index, hosted) in hostedPages.enumerated() {
            hosted.onVerticalScroll = { [weak self] offset in
                guard let self, index == activeIndex else { return }
                applyHeaderOffset(offset)
            }
        }
        // Tap → the destination takes its aligned position BEFORE it
        // travels, and the header adopts it immediately — so the page
        // sliding in is already where it belongs.
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let destination = tabBar.selectedIndex
            guard destination != activeIndex, hostedPages.indices.contains(destination)
            else { return }
            hostedPages[destination].setVerticalOffset(alignedOffset(for: destination))
            activeIndex = destination
            pager.setActivePage(destination, animated: true)
            applyHeaderOffset(hostedPages[destination].verticalOffset)
        }, for: .valueChanged)
        // Swipe → lens, every frame — and the neighbours are settled every
        // frame too: mid-swipe both pages are on screen, and a neighbour
        // arriving at a stale offset is a header jump the viewer watches.
        pager.onProgress = { [weak self] progress in
            guard let self else { return }
            tabBar.setProgress(progress)
            for (index, hosted) in hostedPages.enumerated() where index != activeIndex {
                hosted.setVerticalOffset(alignedOffset(for: index))
            }
        }
        pager.onSettled = { [weak self] index in
            guard let self, hostedPages.indices.contains(index) else { return }
            activeIndex = index
            tabBar.select(index)
            // Re-read where the landed page ACTUALLY is — a short page takes
            // as much of the shared offset as it has content for, and a
            // header riding a stale number stays hidden over a page sitting
            // at its top.
            applyHeaderOffset(hostedPages[index].verticalOffset)
        }
    }

    // MARK: - The scroll coordinator (the profile page's arithmetic)

    /// The height the header takes at rest — what the pages are inset by so
    /// their content starts below it rather than behind it.
    private var headerHeight: CGFloat {
        headerHost.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// How far the header travels before the tab bar reaches the navigation
    /// bar — the moment it docks and stops climbing.
    private var headerTravel: CGFloat {
        max(0, headerHeight - PagedTabBar.height - view.safeAreaInsets.top)
    }

    /// The offset that puts a page's FIRST ROW directly under the navigation
    /// bar — a tab-bar slot further than `headerTravel`, because the pages
    /// are inset by the header's whole height, tab bar included.
    private var contentFloor: CGFloat {
        max(0, headerHeight - view.safeAreaInsets.top)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Idempotent per value — the pages guard their own writes.
        let header = headerHeight
        for hosted in hostedPages {
            hosted.setHostedInsets(top: header, bottom: view.safeAreaInsets.bottom)
            // Room to hold ANY position the header can be in, so a tab
            // switch moves the chrome by nothing.
            hosted.setMinimumScrollTravel(contentFloor)
        }
        applyHeaderOffset(hostedPages.indices.contains(activeIndex)
            ? hostedPages[activeIndex].verticalOffset : 0)
    }

    /// Moves the header from the active page's offset, and fades the
    /// identity content (banner, metrics) as it slips under the translucent
    /// navigation bar — position-driven, both directions.
    ///
    /// Negative travel is NOT clamped, deliberately (the profile's rule):
    /// a pull-down at rest carries the header down with the content, and
    /// the banner's viewport-top pin turns that travel into stretch.
    private func applyHeaderOffset(_ travelled: CGFloat) {
        headerTopConstraint?.constant = -min(travelled, headerTravel)
        let alpha = Self.identityAlpha(travelled: travelled, dockLine: headerTravel)
        bannerView.alpha = alpha
        metricsBand?.alpha = alpha
        // The name's two homes are COMPLEMENTS on one ramp: as the hero
        // title (a banner subview, riding `bannerView.alpha`) fades out
        // under the chrome, the navigation title fades in by exactly the
        // amount the hero gave up — expanded shows the banner name only,
        // docked shows the inline name only, and mid-ramp the crossfade
        // sums to one.
        navTitleLabel.alpha = 1 - alpha
    }

    /// The identity fade's ramp: opaque until the last stretch of travel,
    /// gone exactly at the dock — where the metrics would otherwise go on
    /// drawing through the transparent bar.
    static func identityAlpha(travelled: CGFloat, dockLine: CGFloat, ramp: CGFloat = 80) -> CGFloat {
        guard dockLine > 0, ramp > 0 else { return 1 }
        return min(1, max(0, (dockLine - travelled) / ramp))
    }

    /// Splits the gallery title's "Name • Kind Cluster" shape into the hero
    /// title's two lines: the name big, the kind whispered above it. A title
    /// with no separator is all name — the hero simply has no kind line.
    static func heroTitleComponents(of title: String) -> (name: String, kind: String?) {
        guard let range = title.range(of: " • ") else { return (title, nil) }
        let name = String(title[..<range.lowerBound])
        let kind = String(title[range.upperBound...])
        return (name, kind.isEmpty ? nil : kind)
    }

    /// Where a page should sit, given where the screen currently is — the
    /// profile pager's rule verbatim: below the dock line the offset belongs
    /// to the SCREEN (every page must agree or the header teleports on a tab
    /// switch); above it, to the TAB (each keeps its own place, floored so
    /// its first row is never left under the chrome).
    private func alignedOffset(for index: Int) -> CGFloat {
        Self.alignedOffset(
            current: hostedPages[activeIndex].verticalOffset,
            pageOwn: hostedPages[index].verticalOffset,
            dockLine: headerTravel,
            contentFloor: contentFloor
        )
    }

    static func alignedOffset(
        current: CGFloat, pageOwn: CGFloat, dockLine: CGFloat, contentFloor: CGFloat
    ) -> CGFloat {
        guard dockLine > 0, current >= dockLine else { return current }
        return max(pageOwn, contentFloor)
    }

    /// Starts the one hydration this screen ever does. Called by the builder
    /// at CREATION, not on first appearance: the profile spends its early
    /// life invisible beneath the feed (the two-VC insertion never even loads
    /// a mid-stack view), and the first thing anyone sees of it is the
    /// landing of a dismissal — which must find tiles, not a skeleton.
    /// Idempotent; re-entry is a no-op.
    func beginLoading() {
        guard loadTask == nil else { return }
        loadViewIfNeeded()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let posts = Self.ranked(try await loadPosts())
                guard !Task.isCancelled else { return }
                render(posts)
            } catch {
                guard !Task.isCancelled else { return }
                // The members were already open in the feed above, so a failed
                // hydration here is almost certainly transient — say so
                // plainly rather than rendering a dead end.
                page.render(.failed(message: "Couldn't load this place's posts."))
                shortsPage.render(.failed(message: "Couldn't load this place's posts."))
            }
        }
    }

    /// One place fans the hydrated corpus out to every surface of the page,
    /// so they can never disagree about what the place contains.
    private func render(_ ranked: [GalleryPost]) {
        page.render(ranked.isEmpty
            ? .empty(.init(title: "No posts here yet"))
            : .content(ranked))
        let shorts = Self.shorts(in: ranked)
        shortsPage.render(shorts.isEmpty
            ? .empty(.init(title: "No shorts here yet"))
            : .content(shorts))
        activityList.render(Self.activity(from: ranked))
        let totals = Self.aggregatedMetrics(of: ranked)
        reactionsMetric.setValue(totals.reactions)
        viewsMetric.setValue(totals.views)
        renderBanner(for: Self.bannerPost(in: ranked))
    }

    /// The hero banner wears the TOP post's cover. A coverless top post (a
    /// text check-in) keeps the neutral fill — honest, and never a broken
    /// image.
    private func renderBanner(for post: GalleryPost?) {
        guard let url = post?.thumbnailURL else { return }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            guard let self, let image = try? await imagePipeline.image(for: url),
                  !Task.isCancelled else { return }
            UIView.transition(
                with: bannerView, duration: 0.25, options: [.transitionCrossDissolve]
            ) { self.bannerView.image = image }
        }
    }

    // MARK: - The page's pure rules (tested directly)

    /// The profile's one ordering: POPULARITY descending — the place leads
    /// with what it is known for, not what happened last. The trending rule
    /// verbatim (reactions, then recency, then id, so ties are stable),
    /// applied HERE so the screen owns its ordering contract. Client-side
    /// because no ranking RPC exists (`dev/BACKEND_GAPS.md` §14/§18); it
    /// matches the map above by construction — the cluster's pin wears its
    /// most-liked member's face, which is this page's banner AND its first
    /// Gallery tile.
    static func ranked(_ posts: [GalleryPost]) -> [GalleryPost] {
        DiscoverySource.trending.ordering(posts)
    }

    /// The banner's subject: the top post of the ranking — "the previous
    /// cycle's top post" once cycles exist on the wire; until then the
    /// highest-engagement member IS the standing cycle winner.
    static func bannerPost(in ranked: [GalleryPost]) -> GalleryPost? {
        ranked.first
    }

    /// The Shorts tab's corpus: the place's video posts, ranking preserved.
    static func shorts(in ranked: [GalleryPost]) -> [GalleryPost] {
        ranked.filter { $0.kind == .video }
    }

    /// The place's aggregated counters. Missing values count as zero rather
    /// than poisoning the sum — a counter the read-model never projected is
    /// absence, not information.
    static func aggregatedMetrics(of posts: [GalleryPost]) -> (reactions: Int64, views: Int64) {
        posts.reduce(into: (reactions: Int64(0), views: Int64(0))) { totals, post in
            totals.reactions += post.reactionCount ?? 0
            totals.views += post.viewCount ?? 0
        }
    }

    /// The Activity tab's stream: one event per member, NEWEST first — the
    /// one surface of this page that is chronological, because "what is
    /// happening here" is a different question from "what is this place
    /// known for". The event vocabulary comes from the post's kind: words
    /// are a check-in, stills are shared, videos are posted.
    static func activity(from posts: [GalleryPost]) -> [PlaceActivityEvent] {
        posts.map { post in
            let kind: PlaceActivityEvent.Kind = switch post.kind {
            case .text: .checkIn
            case .photo: .photo
            case .video: .short
            }
            return PlaceActivityEvent(
                id: post.id,
                authorName: post.authorName ?? "Someone",
                kind: kind,
                timestampMS: post.publishedAtMS
            )
        }
        .sorted { ($0.timestampMS, $0.id.rawValue) > ($1.timestampMS, $1.id.rawValue) }
    }

    /// What the Gallery grid currently shows, in its rendered order — for the
    /// tests that pin the popularity ranking without reaching into the page.
    var renderedPosts: [GalleryPost] { page.posts }
    /// The Shorts grid's rendered corpus, same purpose.
    var renderedShorts: [GalleryPost] { shortsPage.posts }
    /// The Activity stream as rendered, same purpose.
    var renderedActivity: [PlaceActivityEvent] { activityList.events }
    /// The tab strip's titles, pinned by tests against silent drift.
    var tabTitles: [String] { tabBar.currentTitles }

    // MARK: - Follow (header trailing item)

    /// The header's trailing item: heart + "Follow" flipping to filled heart
    /// + "Following". A custom view rather than a plain `UIBarButtonItem`
    /// because the design pairs the icon WITH a label, and a bar item shows
    /// one or the other.
    private func configureFollowButton() {
        guard let following else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        followButton.configuration = configuration
        // The bar squeezes a custom view before it truncates the TITLE; let
        // the long nav title give way instead — "Following" must never wrap
        // into "Follow-ing".
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.titleLabel?.numberOfLines = 1
        followButton.addAction(UIAction { [weak self] _ in
            guard let self, let following = self.following else { return }
            self.renderFollowState(following.toggle())
        }, for: .primaryActionTriggered)
        renderFollowState(following.isFollowing())
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: followButton)
    }

    /// One place decides both states' looks, so they can't drift: outline
    /// heart + tinted "Follow" against filled heart + neutral "Following"
    /// (the resting state whispers; the call to action doesn't).
    private func renderFollowState(_ isFollowing: Bool) {
        guard var configuration = followButton.configuration else { return }
        configuration.image = UIImage(systemName: isFollowing ? "heart.fill" : "heart")
        var title = AttributedString(isFollowing ? "Following" : "Follow")
        title.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        configuration.attributedTitle = title
        configuration.baseForegroundColor = isFollowing ? .secondaryLabel : .tintColor
        followButton.configuration = configuration
        followButton.accessibilityLabel = isFollowing ? "Unfollow this place" : "Follow this place"
    }

    // MARK: - Opening a tile

    private func openTile(at index: Int, in grid: ForYouGridPage?) {
        guard let grid else { return }
        let posts = grid.posts
        guard posts.indices.contains(index) else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = grid.hero(for: tapped.id, in: view)
        let appearance = grid.heroAppearance(for: tapped.id)
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: .tile,
            frame: { [weak grid] space in grid?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak grid] in grid?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak grid] concealed in
                grid?.setHeroHidden(concealed, for: tapped.id)
            },
            depthView: { [weak grid] in grid }
        )
        openPost(self, origin, stream.map(\.id))
    }
}

// MARK: - The landing side of the cluster feed's vertical grab

extension PlaceProfileViewController: ZoomTransitionSource {
    /// The whole column recedes; the navigation title stays grounded.
    var zoomPresenterDepthView: UIView? { view }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        guard let hero = page.hero(for: anchorID, in: container) else {
            return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: 96)
        }
        return hero.frame
    }

    var zoomSourceIsOnScreen: Bool {
        page.isPostVisible(anchorID)
    }

    func makeZoomFlightCard() -> any ZoomFlightCard {
        let appearance = page.heroAppearance(for: anchorID)
        return PostGridFlightCard(
            post: page.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile
        )
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        page.setHeroHidden(hidden, for: anchorID)
        if !hidden {
            page.endHeroFreeze()
        }
    }

    /// Re-anchor on the post the feed settled on and BRING ITS TILE INTO
    /// VIEW — on the GALLERY tab, whatever tab was up: the flight lands on a
    /// grid tile, and landing over the Activity list would put the card down
    /// on a surface that has no tile for it. The opposite scrolling rule
    /// from `ForYouGridZoomSource` (which pins the departure tile and adopts
    /// the post into it), and deliberately: this grid has never been seen
    /// when the first dismissal stages — the viewer arrived from a map pin,
    /// not from a tile — so there is no departure context to preserve and
    /// the honest landing is the post's own place in the ranking.
    func zoomSourceWillStageDismissal() {
        if activeIndex != 0 {
            // Adopt the Gallery tab through the same alignment rule as a tap,
            // so the header does not move for the switch.
            page.setVerticalOffset(alignedOffset(for: 0))
            activeIndex = 0
            applyHeaderOffset(page.verticalOffset)
        }
        tabBar.select(0)
        pager.setActivePage(0, animated: false)
        page.beginHeroFreeze()
        if let active = activePostID?(), page.post(for: active) != nil {
            anchorID = active
        }
        page.revealPost(anchorID)
        // Visible for the whole return: the card is landing ON this tile.
        page.setHeroHidden(true, for: anchorID, conceals: false)
    }

    var zoomLandingMediaIsReady: Bool {
        page.isLandingPlaybackReady(for: anchorID)
    }

    func zoomFinalizeLanding() {
        page.finalizeLandingLayout(for: anchorID)
    }

    func zoomAdoptLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        page.adoptLivePlayback(view, for: anchorID)
    }

    /// A landing post the grid does not hold (hydration raced the grab, or
    /// the feed paged past the members somehow) still needs a card to fly —
    /// a plain dark square, which is what a missing cover renders as anyway.
    private static func placeholder(id: PostID) -> GalleryPost {
        GalleryPost(
            id: id, kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }
}

#if DEBUG
extension PlaceProfileViewController {
    /// The header's live top-constraint constant — negative while collapsed,
    /// positive under a pull-down.
    var debugHeaderConstant: CGFloat { headerTopConstraint?.constant ?? 0 }
    /// The dock line, as the coordinator computed it for this layout.
    var debugHeaderTravel: CGFloat { headerTravel }
    var debugIdentityAlpha: CGFloat { bannerView.alpha }
    var debugNavTitleAlpha: CGFloat { navTitleLabel.alpha }
    var debugHeroName: String? { heroNameLabel.text }
    var debugHeroKind: String? { heroKindLabel.isHidden ? nil : heroKindLabel.text }
    var debugNavTitleText: String? { navTitleLabel.text }
    /// Drives the active page to a travel offset through the same path a
    /// finger's scroll reports through.
    func debugScrollActivePage(to offset: CGFloat) {
        hostedPages[activeIndex].setVerticalOffset(offset)
        applyHeaderOffset(hostedPages[activeIndex].verticalOffset)
    }
}
#endif

// MARK: - The hosted-header contract

/// What a page owes the floating header's coordinator: report travel, take a
/// travel offset, and reserve room. One shape for both page kinds, so the
/// coordinator rides whichever is active without caring which it is.
@MainActor
protocol PlaceProfileHostedPage: UIView {
    var onVerticalScroll: ((CGFloat) -> Void)? { get set }
    var verticalOffset: CGFloat { get }
    func setVerticalOffset(_ offset: CGFloat)
    func setHostedInsets(top: CGFloat, bottom: CGFloat)
    func setMinimumScrollTravel(_ travel: CGFloat)
}

extension ForYouGridPage: PlaceProfileHostedPage {}
extension PlaceActivityListView: PlaceProfileHostedPage {}

// MARK: - Header pieces

/// One column of the metrics band: a compact count over its caption — the
/// profile header's metric shape, minus everything an account has and a
/// place doesn't.
private final class PlaceMetricView: UIView {
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        valueLabel.font = .preferredFont(forTextStyle: .title2).withBoldTrait()
        valueLabel.textAlignment = .center
        valueLabel.text = "—"
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = title
        let column = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ value: Int64) {
        valueLabel.text = CountFormatter.compactString(for: value)
        accessibilityValue = valueLabel.text
    }
}

/// The banner's legibility scrim: clear at the top, background-colored at the
/// bottom, so the metrics band below never fights the cover for contrast.
private final class GradientScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    private func applyColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor.systemBackground.withAlphaComponent(0).cgColor,
            UIColor.systemBackground.withAlphaComponent(0.85).cgColor,
        ]
    }
}

private extension UIFont {
    func withBoldTrait() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - The map return flight's destination half
//
// This screen is BOTH sides of a zoom now, deliberately: the SOURCE of the
// tile flights above it (the extension near the top), and the DESTINATION of
// its own dismissal to the map — the whole page lifts off and the marker's
// card (built by `MapPinZoomSource`, the marker's exact twin) flies home to
// the cluster. The two conformances share no members, so neither can
// impersonate the other.
extension PlaceProfileViewController: ZoomTransitionDestination {
    /// The card lifts from the whole page.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect {
        view.convert(view.bounds, to: container)
    }

    /// The flying card is the MARKER's face — the source builds it; this
    /// page has no per-post chrome to ride along.
    func zoomFlightChrome() -> UIView? { nil }

    func setZoomContentHidden(_ hidden: Bool) {
        view.isHidden = hidden
    }

    func zoomTransitionDidEnd() {}

    var isReadyForInteractiveDismissal: Bool { true }

    /// TRUE ONLY WHILE THE HERO RETURN IS INSTALLED. The default (`true`,
    /// "this screen owns its dismissal") tells `NativePopPolicy` to refuse
    /// the native edge pop — correct when the grab below is armed, and
    /// exactly wrong for the fallback case where `mapReturn` yielded nothing
    /// and the native slide IS the dismissal.
    var zoomOwnsInteractiveDismissal: Bool { mapReturnTransition != nil }

    /// A rightward drag means "previous tab" everywhere but the first one —
    /// the profile pager's own rule. The back button flies from any tab.
    func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        activeIndex == 0
    }

    /// Freeze the tab pager while a grab drives, so the drag that is flying
    /// the page home cannot also page it sideways.
    func setContentScrollEnabled(_ enabled: Bool) {
        pager.isPagingEnabled = enabled
    }
}
