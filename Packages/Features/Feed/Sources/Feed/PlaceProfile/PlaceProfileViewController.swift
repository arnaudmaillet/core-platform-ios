import CoreModels
import CoreNavigation
import CoreStorage
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
/// - two tabs under the metrics — **Discover** (the popularity grid) and
///   **Activity** (the same posts as CARDS, newest first) — a `PagedTabBar`
///   over a `HorizontalPagerView`, the same pairing the profile's
///   relationship screen ships. Deliberately For You's own vocabulary and
///   shapes: its Discover is a media grid and its Following is a card list,
///   which is exactly this pair for one place.
/// The follow-this-place heart and a "..." menu keep the top-right slots.
///
/// It remains an ordinary navigation citizen — plain title ("Paris • City
/// Cluster"), tab bar visible, native edge-pop back to the map — because
/// every special behaviour of the flow lives in the TRANSITIONS, not in the
/// screen: the two-VC stack insertion is the map's, the vertical morph is
/// the zoom stack's, and this type only has to host its column and answer
/// the `ZoomTransitionSource` questions about the Gallery grid.
final class PlaceProfileViewController: UIViewController {
    /// The Discover tab's grid — the flight anchor every dismissal lands on.
    private let page: ForYouGridPage
    /// The Activity tab: the SAME component For You's "Following" is — a
    /// `ForYouGridPage` in `.list` style — over the same corpus in
    /// chronological order. Not a bespoke list: a place's activity is posts,
    /// and a viewer who reads them as cards on For You must read them as the
    /// same cards here.
    private let activityPage: ForYouGridPage

    private let bannerView = UIImageView()
    private let bannerScrim = GradientScrimView()
    private let reactionsMetric = PlaceMetricView(title: "Reactions")
    private let viewsMetric = PlaceMetricView(title: "Views")

    /// The tab titles, one source for both selector copies.
    private static let tabTitles = ["Discover", "Activity"]
    /// ⚠️ TWO selectors, and that is the profile screen's hard-won shape
    /// (`ProfileViewController`): one view cannot be in two places, and the
    /// hand-over is a CROSSFADE — for a quarter of a second both are on
    /// screen, one shrinking away and one growing in, which is not a state a
    /// re-parented view can express at any price. `inlineBar` lives in the
    /// header's slot; `dockedBar` rides the navigation bar's LEADING group,
    /// beside the back chevron.
    private let inlineBar = PagedTabBar(titles: tabTitles, style: .navigationTitle)
    private let dockedBar = PagedTabBar(titles: tabTitles, style: .navigationTitle)
    private var selectorBars: [PagedTabBar] { [inlineBar, dockedBar] }
    /// The fixed-height seat the inline selector sits in. It keeps its height
    /// when the selector fades out, so the header's own height — and every
    /// number derived from it — does not change at the dock.
    private let inlineBarSlot = UIView()
    private var selectorBarItem: UIBarButtonItem?
    private var isBarDocked = false
    private var isMirroringSelection = false
    private var lastDockingTravel: CGFloat = 0
    private var pager: HorizontalPagerView!

    /// The floating header: banner + metrics + tab bar in one host that
    /// RIDES THE ACTIVE PAGE'S OFFSET (the profile page's mechanics, adopted
    /// wholesale). The pages fill the screen and scroll themselves; this
    /// host sits above them, moved by its top constraint, and stops moving
    /// when the tab bar reaches the navigation bar — the sticky dock.
    private let headerHost = UIView()
    private var headerTopConstraint: NSLayoutConstraint?
    /// The place's display title ("Paris • City Cluster") — worn as the HERO
    /// TITLE on the banner, and nowhere else.
    ///
    /// ⚠️ THE NAME DOES NOT DOCK, and that is a consequence rather than a
    /// preference. `installLeadingSelector` must overwrite `titleView` with a
    /// zero-sized view: a nil or sized title keeps a central reservation that
    /// collapses the leading group into a `•••` below 440pt. So the docked
    /// name and the docked selector cannot both exist, and the profile screen
    /// faced the identical choice and made the identical call — once the
    /// selector docks, a name up there is competing with the one control the
    /// chrome exists to hold.
    private let placeName: String
    /// The banner's hero identity: the place kind whispered above the name.
    private let heroKindLabel = UILabel()
    private let heroNameLabel = UILabel()
    /// The two pages under their hosted-header contract, pager order.
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

    /// The PICTURE that post is showing, for the same reason and from the same
    /// place. A landing that no longer aims at the settled post has to carry it
    /// anyway — the card takes off from a full screen the viewer is looking at,
    /// and arriving as the first tile's photograph without passing through
    /// theirs is a cut.
    var activeCover: (() -> UIImage?)?

    /// The header's follow-this-place toggle, when the caller's subject has a
    /// followable identity (`ClusterGalleryFollowing`); nil hides the button.
    private let following: ClusterGalleryFollowing?
    /// The two trailing items, held so the bar's group is composed in one
    /// place — see `configureNavigationItems`. Either can be nil: the heart
    /// needs a follow seam, the balance needs a wallet.
    private var followItem: UIBarButtonItem?
    private var walletItem: UIBarButtonItem?
    /// The viewer's spendable balance, in the same face it wears on the map,
    /// For You, the profile and the post screen.
    private let walletBadge = WalletBadgeButton()
    private let wallet: WalletStore?
    /// Vends the wallet/claim sheet the badge presents — shell-owned, because
    /// it is the same sheet every other badge opens and the five must never
    /// diverge. Nil leaves the badge display-only.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    /// Held in a bag rather than a property: a main-actor screen's `deinit`
    /// is nonisolated and may not even read one to unregister it.
    private let walletObservers = NotificationObserverBag()
    /// The follow state as last rendered, so the dock hand-over can redraw
    /// the button without asking the caller's store again.
    private var followState = false

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
    /// The map's way home — see `FeedFeatureBuilding.makeClusterGallery`.
    /// This page is the only screen that leaves for the map: a post opened
    /// from it goes home to its own tile on both axes.
    ///
    /// Handed a closure that draws this page, so the flight can dissolve what
    /// is on screen into the marker's face instead of cutting to it.
    var mapReturn: ((@escaping () -> UIImage?) -> (any ZoomTransitionSource)?)?

    /// The tile a flight left THIS page from, and which tab it sat on — nil
    /// whenever the open post did not come from here (the map's Case B, where
    /// the viewer arrived from a marker and has never seen this grid).
    ///
    /// It is the whole of what distinguishes the two card-shaped closes: one
    /// has somewhere the viewer actually was, the other does not.
    private var tileDeparture: (id: PostID, isActivity: Bool)?


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
        assertAppTabBar()
        // ⚠️ THE BELT FOR A CONCEALED ROW, and it has to live here.
        //
        // A window opened from a row hides that row for as long as it is in
        // the air, and only the reveal's own completion pays it back. Every
        // other way off the pushed post — an unwind, a `popToRoot`, a
        // `setViewControllers` — leaves the row invisible for the rest of the
        // session, and the driver's own `onFeedPopped` cannot cover it because
        // this page takes the delegate slot back before `didShow` reaches it.
        // Whatever happened above, nothing on THIS page may be hidden while it
        // is the screen: the same blanket rule the map applies to its markers.
        clearLandingConcealment()
        // The flight that left here is over, whichever way it ended. A stale
        // departure would answer for the NEXT close — including the map's Case
        // B, whose whole point is that it has no departure on this page.
        tileDeparture = nil
        installMapReturnIfTop()
        syncAutoplay()
        #if DEBUG
        scheduleDebugPopIfRequested()
        scheduleDebugDrivesIfRequested()
        #endif
    }

    /// This screen shows the app's dock, so it says so itself.
    ///
    /// ⚠️ NOT REDUNDANT with the restores the feed above it runs, and the
    /// reason is a collision between two things this page does. The feed's
    /// dismissal driver puts the bar back from its `didShow` — and UIKit
    /// delivers `didShow` AFTER the appearing screen's `viewDidAppear`, which
    /// is exactly where `installMapReturnIfTop` below takes the navigation
    /// delegate for this page's own return flight. So the driver that was
    /// going to restore the dock is no longer the delegate when the news
    /// arrives, and never hears that the feed left (measured with
    /// `-grab-log`: one `didShow SnapFeedViewController` for the push, and
    /// none at all for the landing).
    ///
    /// Rather than forbid the hand-over, or make the flight forward someone
    /// else's bookkeeping, the screen that OWNS the bottom of the display
    /// asserts it — the rule the map root and the profile already follow. In
    /// `viewDidAppear`, never `viewWillAppear`: UIKit runs the latter at
    /// interactive-pop BEGIN, so a restore there would raise the dock over a
    /// feed still on screen and strand it there when the grab is released
    /// short of the threshold.
    private func assertAppTabBar() {
        guard let tabBarController else { return }
        tabBarController.tabBar.alpha = 1
        guard tabBarController.isTabBarHidden else { return }
        tabBarController.setTabBarHidden(false, animated: false)
    }

    /// Installs the hero return each time this page becomes the top screen.
    /// The transition is built ONCE (its grab attaches a pan; a rebuild per
    /// appearance would stack recognizers) from the first source `mapReturn`
    /// yields; the DELEGATE install repeats, because every feed pushed above
    /// takes the slot and hands back whatever it captured.
    /// This page as one picture, for the flight home to dissolve into the
    /// marker's face.
    ///
    /// ⚠️ A SNAPSHOT, which this codebase is otherwise wary of — a text hero
    /// once tried photographing a page to impersonate it and the attempt is
    /// recorded as a warning. This is the other use: not a stand-in pretending
    /// to be a live screen, but one operand of a fade whose other half is a
    /// 44pt icon. Nothing is impersonated and nothing outlives the transition.
    ///
    /// `afterScreenUpdates: false` on purpose: it must not force a layout pass
    /// on the first frame of a gesture the finger is already driving, and what
    /// is already on screen is exactly what the viewer is leaving.
    private func departureStill() -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    private func installMapReturnIfTop() {
        guard let nav = navigationController, nav.topViewController === self else { return }
        if mapReturnTransition == nil,
           let source = mapReturn?({ [weak self] in self?.departureStill() }) {
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
    private var didScheduleDebugDrives = false

    /// `-maps-place-pop-demo`: pops this page ~1.5s after it becomes top —
    /// the sim can't tap the back button, and the non-interactive pop is
    /// exactly the leg that proves the hero return animator is installed.
    /// `-maps-place-tab <index>` selects a tab and `-maps-place-scroll <pt>`
    /// drives the active page's offset — the two gestures this screen is
    /// read by, neither of which the simulator can inject. The scroll runs
    /// last and later, so a run can ask for "the Activity tab, docked".
    private func scheduleDebugDrivesIfRequested() {
        guard !didScheduleDebugDrives else { return }
        didScheduleDebugDrives = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> Double? {
            guard let position = arguments.firstIndex(of: flag),
                  position + 1 < arguments.count else { return nil }
            return Double(arguments[position + 1])
        }
        if let index = value("-maps-place-tab").map(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.inlineBar.debugSimulateTap(at: index)
            }
        }
        if let offset = value("-maps-place-scroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                debugScrollActivePage(to: CGFloat(offset))
                print("[place] scrolled to \(offset) docked=\(isBarDocked)"
                    + " inline=\(inlineBar.alpha) dockedBar=\(dockedBar.alpha)"
                    + " item=\(debugDockedSelectorItemPresent)")
            }
        }
        // `-maps-place-open-tile <index>`: opens a post from whichever tab is
        // up, which is the gesture that decides where a dismissal has to come
        // BACK to. Runs after the tab drive so a run can ask for "open the
        // third post of the Activity list" — the case where the departure
        // screen and the landing screen can disagree, and the only way to see
        // that disagreement is to leave from the tab that is not the default.
        if let index = value("-maps-place-open-tile").map(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                guard let self else { return }
                let grid = hostedPages.indices.contains(activeIndex)
                    ? hostedPages[activeIndex] as? ForYouGridPage : nil
                // The ELECTION, not just the tap: a text row that opens with
                // no window is a plain push, and a plain push looks like a
                // perfectly good animation. Only the line says which happened.
                let post = grid?.posts.indices.contains(index) == true
                    ? grid?.posts[index] : nil
                let window = post.flatMap { p in grid.flatMap { textRowReveal(for: p, in: $0) } }
                print("[place] opening tile \(index) from tab \(activeIndex)"
                    + " posts=\(grid?.posts.count ?? -1)"
                    + " post=\(post?.id.rawValue ?? "nil")"
                    + " hero=\(post.flatMap { grid?.heroAppearance(for: $0.id) } != nil)"
                    + " window=\(window != nil)")
                openTile(at: index, in: grid)
            }
        }
        // `-maps-place-tile-dismiss <seconds>`: grabs the feed that tile just
        // opened, back to this page. The flight is `presentSnapFeedHero`'s, not
        // this screen's, so the harness reaches it the only way anything can —
        // `debugMostRecent`, which is exactly the "present one screen and
        // dismiss that one" usage it exists for. Delay is absolute rather than
        // chained off the open so a run can settle a page first.
        if let after = value("-maps-place-tile-dismiss") {
            // ⚠️ ITS OWN AXIS, not the process-wide `-zoom-demo-grab-vertical`.
            // A run that reaches this page by a VERTICAL grab and then leaves
            // the post above it HORIZONTALLY needs both in one process, and a
            // single global flag cannot say that — which is how the escape leg
            // went unscripted while the flag was set for the leg before it.
            // Horizontal by default: that is the escape this hook exists for.
            let axis: ZoomDismissAxis =
                arguments.contains("-maps-place-tile-dismiss-vertical") ? .vertical : .horizontal
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[place] scripting tile-feed dismissal axis=\(axis)")
                ZoomTransitionController.debugMostRecent?.debugScriptedGrab(axis: axis)
            }
        }
    }

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
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        loadPosts: @escaping () async throws -> [GalleryPost],
        openPost: @escaping (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void
    ) {
        self.postIDs = postIDs
        self.placeName = placeName
        self.imagePipeline = imagePipeline
        self.following = following
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.loadPosts = loadPosts
        self.openPost = openPost
        self.anchorID = postIDs.first ?? PostID("")
        self.page = ForYouGridPage(
            imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback
        )
        self.activityPage = ForYouGridPage(
            imagePipeline: imagePipeline, style: .list, videoPlayback: videoPlayback
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
        activityPage.render(.loading)
        page.onItemTapped = { [weak self] index in self?.openTile(at: index, in: self?.page) }
        activityPage.onItemTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.activityPage)
        }
        // The comment chip opens the post, not the thread — deliberately, for
        // now. Landing ON the comments needs the pushed feed itself
        // (`openComments(for:revealingFrom:)`), and this screen never holds
        // it: `openPost` hands an origin across the feature seam and the
        // builder constructs the destination. Widening that seam for a
        // secondary affordance is the wrong trade; a chip that opens the post
        // is honest, where a chip that did nothing would not be.
        activityPage.onItemCommentsTapped = { [weak self] index in
            self?.openTile(at: index, in: self?.activityPage)
        }
        // The card band's own "..." stays dark here: the reporting and
        // social-graph seams are not threaded into this screen, and a menu
        // whose rows cannot act is worse than no control. An empty answer is
        // how `PostAuthorBandView` is told to hide it.
        activityPage.authorMenuActions = { _ in [] }
        configureNavigationItems()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncAutoplay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Off screen, this page holds no claim on the shared player pool —
        // the feed pushed above it is about to want every loan.
        for hosted in hostedPages { (hosted as? ForYouGridPage)?.setAutoplayActive(false) }
    }

    /// Exactly one page may drive playback: two grids competing for one pool
    /// is how a working set of six turns into a queue nobody wins. For You's
    /// pager makes the same call from the same three places (settle, tab tap,
    /// appearance).
    private func syncAutoplay() {
        for (index, hosted) in hostedPages.enumerated() {
            (hosted as? ForYouGridPage)?.setAutoplayActive(index == activeIndex)
        }
    }

    // MARK: - Layout (floating header over full-screen pages)

    private func configureHeader() {
        // The PAGES fill the screen and scroll themselves; the header floats
        // over them (added second, so it draws above the content sliding
        // under it) and is moved by its top constraint from whichever page
        // is being read.
        hostedPages = [page, activityPage]
        pager = HorizontalPagerView(pages: [page, activityPage])
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

        let metrics = UIStackView(arrangedSubviews: [reactionsMetric, viewsMetric])
        metrics.distribution = .fillEqually
        metrics.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(metrics)
        self.metricsBand = metrics

        inlineBarSlot.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(inlineBarSlot)
        // ⚠️ SPREAD, not hugged. A `.navigationTitle` bar hugs its titles by
        // default — right in a bar item, where the capsule is sized to what
        // it holds, and wrong in the page, where two tabs then huddle in the
        // middle of a full-width slot. `fillsWidth` gives the hugging bar the
        // floating bar's ARRANGEMENT (fillEqually, pinned to both ends)
        // without its type ramp, so the docked and inline copies stay the
        // same control at two sizes. The profile's inline copy does exactly
        // this, for exactly this reason.
        inlineBar.fillsWidth = true
        inlineBar.translatesAutoresizingMaskIntoConstraints = false
        inlineBarSlot.addSubview(inlineBar)

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
            // ⚠️ A SLOT WITH A STATED HEIGHT, not the selector itself. The
            // inline bar fades out at the dock, and a header whose height
            // followed it would shrink under every number derived from it
            // (`headerHeight`, and through it the pages' inset and the dock
            // line) at the exact moment the dock is being decided.
            inlineBarSlot.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 8),
            inlineBarSlot.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            inlineBarSlot.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            inlineBarSlot.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
            inlineBarSlot.heightAnchor.constraint(equalToConstant: Self.selectorSlotHeight),
            // Both edges, not leading-only: `fillsWidth` gives a hugging
            // `.navigationTitle` bar the floating bar's ARRANGEMENT
            // (fillEqually, pinned to both ends) without its type ramp, so an
            // unpinned trailing edge would collapse it to zero width.
            inlineBar.topAnchor.constraint(equalTo: inlineBarSlot.topAnchor),
            inlineBar.leadingAnchor.constraint(
                equalTo: inlineBarSlot.leadingAnchor, constant: 16
            ),
            inlineBar.trailingAnchor.constraint(
                equalTo: inlineBarSlot.trailingAnchor, constant: -16
            ),
        ])
    }

    /// The inline selector's seat: the bar's own height plus the gap that
    /// separates it from the first row of content.
    private static let selectorSlotHeight = PagedTabBar.Style.navigationTitle.height + 16
    /// The crossfade's length and the size the leaving copy shrinks to —
    /// the profile screen's measured pair, shared so the two screens that
    /// perform the same hand-over cannot drift apart.
    private static let dockTransition: TimeInterval = 0.26
    private static let dockZoomScale: CGFloat = 0.88

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
        // BOTH copies answer a tap — whichever the finger reached — and both
        // are told the outcome, so the invisible one is already correct when
        // it fades in rather than catching up afterwards.
        for bar in selectorBars {
            bar.addAction(UIAction { [weak self, weak bar] _ in
                guard let self, let bar else { return }
                let destination = bar.selectedIndex
                mirrorSelection(to: destination)
                guard destination != activeIndex, hostedPages.indices.contains(destination)
                else { return }
                hostedPages[destination].setVerticalOffset(alignedOffset(for: destination))
                activeIndex = destination
                syncAutoplay()
                pager.setActivePage(destination, animated: true)
                applyHeaderOffset(hostedPages[destination].verticalOffset)
            }, for: .valueChanged)
        }
        // Swipe → lens, every frame — and the neighbours are settled every
        // frame too: mid-swipe both pages are on screen, and a neighbour
        // arriving at a stale offset is a header jump the viewer watches.
        pager.onProgress = { [weak self] progress in
            guard let self else { return }
            for bar in selectorBars { bar.setProgress(progress) }
            for (index, hosted) in hostedPages.enumerated() where index != activeIndex {
                hosted.setVerticalOffset(alignedOffset(for: index))
            }
        }
        pager.onSettled = { [weak self] index in
            guard let self, hostedPages.indices.contains(index) else { return }
            activeIndex = index
            mirrorSelection(to: index)
            syncAutoplay()
            // Re-read where the landed page ACTUALLY is — a short page takes
            // as much of the shared offset as it has content for, and a
            // header riding a stale number stays hidden over a page sitting
            // at its top.
            applyHeaderOffset(hostedPages[index].verticalOffset)
        }
    }

    /// Keeps the two selector copies on one selection. Re-entrancy guarded:
    /// `select` fires `.valueChanged`, and the action above mirrors, which
    /// would select again.
    private func mirrorSelection(to index: Int) {
        guard !isMirroringSelection else { return }
        isMirroringSelection = true
        defer { isMirroringSelection = false }
        for bar in selectorBars where bar.selectedIndex != index {
            bar.select(index)
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
        max(0, headerHeight - Self.selectorSlotHeight - view.safeAreaInsets.top)
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
        updateBarDocking(travelled: travelled)
    }

    /// Hands the selector between the header and the navigation bar as the
    /// header reaches the dock line.
    private func updateBarDocking(travelled: CGFloat) {
        guard isViewLoaded else { return }
        // How far the header moved since the last callback. Callbacks arrive
        // per displayed frame, so this is a velocity in the only unit that
        // matters here: distance the viewer sees between one frame and the
        // next.
        let step = travelled - lastDockingTravel
        lastDockingTravel = travelled
        let shouldDock = DockThreshold.isDocked(
            travelled: travelled, dockLine: headerTravel, step: step, wasDocked: isBarDocked
        )
        guard shouldDock != isBarDocked else { return }
        isBarDocked = shouldDock
        applyDockedAppearance(animated: DockThreshold.isAnimated(step: step))
    }

    /// The hand-over itself: a crossfade with a small zoom, never a move.
    ///
    /// Scale is by TRANSFORM only — these capsules derive their corner radius
    /// from their own bounds, so resizing toward a target would need the
    /// radius re-derived every frame.
    private func applyDockedAppearance(animated: Bool) {
        let leaving = isBarDocked ? inlineBar : dockedBar
        let arriving = isBarDocked ? dockedBar : inlineBar
        let shrunk = CGAffineTransform(scaleX: Self.dockZoomScale, y: Self.dockZoomScale)

        leaving.isHidden = false
        arriving.isHidden = false
        // ⚠️ The BAR ITEM's own visibility, not just the view's: UIKit draws
        // the system glass capsule for the item, and hiding only the view
        // inside it leaves an empty pill beside the back chevron.
        if arriving === dockedBar { setSelectorItemPresent(true) }
        // The arriving copy starts small — but ONLY when it is arriving from
        // nothing. A hand-over reversed half way through finds it already
        // part grown, and snapping it back is what turns a change of mind
        // into a stutter.
        if arriving.alpha < 0.01 { arriving.transform = shrunk }

        let settle = {
            leaving.alpha = 0
            leaving.transform = shrunk
            arriving.alpha = 1
            arriving.transform = .identity
        }
        // ⚠️ Whichever copy ends up invisible is HIDDEN, not merely
        // transparent — a navigation bar owns its items' alpha around pushes
        // and pops, so one parked at alpha 0 comes back at full strength over
        // an un-scrolled page. `isHidden` is not a property UIKit touches.
        let settleVisibility = { [weak self] in
            leaving.isHidden = true
            if leaving === self?.dockedBar { self?.setSelectorItemPresent(false) }
        }

        guard animated else {
            // ⚠️ Stop whatever is in flight FIRST. This path is taken because
            // the scroll is too fast to animate through, and a hand-over
            // already running would go on interpolating over the values just
            // written — the flash, arriving a frame late. Setting model
            // values does not cancel a running animation; removing it does.
            for bar in selectorBars { bar.layer.removeAllAnimations() }
            settle()
            settleVisibility()
            return
        }
        UIView.animate(
            withDuration: Self.dockTransition,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: settle,
            completion: { [weak self] _ in
                guard let self else { return }
                // The dock state can have flipped back while this was
                // running, in which case a later call already owns the two
                // bars and this completion would hide the one now arriving.
                guard (isBarDocked ? inlineBar : dockedBar) === leaving else { return }
                settleVisibility()
            }
        )
    }

    /// ⚠️ `isHidden`, NOT membership. Rewriting `leftBarButtonItems` hands
    /// UIKit the group again, which tears the platters down and rebuilds them
    /// EMPTY (measured on the profile screen at 0x44 beside a healthy
    /// trailing item). Hiding an item leaves the group alone.
    private func setSelectorItemPresent(_ present: Bool) {
        selectorBarItem?.isHidden = !present
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
                let members = try await loadPosts()
                guard !Task.isCancelled else { return }
                render(members)
            } catch {
                guard !Task.isCancelled else { return }
                // The members were already open in the feed above, so a failed
                // hydration here is almost certainly transient — say so
                // plainly rather than rendering a dead end.
                page.render(.failed(message: "Couldn't load this place's posts."))
                activityPage.render(.failed(message: "Couldn't load this place's posts."))
            }
        }
    }

    /// One place fans the hydrated corpus out to every surface of the page,
    /// so they can never disagree about what the place contains.
    private func render(_ members: [GalleryPost]) {
        // ⚠️ THE TWO TABS NO LONGER SHOW THE SAME POSTS, only the same place.
        // Discover is a GRID of covers and drops what has none; Activity is a
        // column of cards and keeps everything. One hydration still fans out to
        // both, so they can only disagree about what this line says they
        // disagree about.
        let gallery = Self.gallery(members)
        page.render(gallery.isEmpty
            ? .empty(.init(title: "No photos or videos here yet"))
            : .content(gallery))
        let recent = Self.chronological(members)
        activityPage.render(recent.isEmpty
            ? .empty(.init(title: "Nothing has happened here yet"))
            : .content(recent))
        // ⚠️ THE WHOLE CORPUS, not the gallery's. These are the PLACE's
        // numbers, and a check-in with no photograph is still something that
        // happened here — dropping it from a total because a grid cannot draw
        // it would make the place look quieter than it is.
        let totals = Self.aggregatedMetrics(of: members)
        reactionsMetric.setValue(totals.reactions)
        viewsMetric.setValue(totals.views)
        renderBanner(for: Self.bannerPost(in: gallery))
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

    /// Discover's corpus: the ranking, minus what a GRID cannot draw.
    ///
    /// ⚠️ MEDIA ONLY (product call). A text post has no cover, so as a tile it
    /// is a coloured rectangle with a caption at a size nobody reads — and this
    /// grid is the place's shop window. Its words are not lost: Activity shows
    /// every kind, as cards, at a size where they are the point.
    ///
    /// Kept as a filter over `ranked` rather than a filter at the source,
    /// because the ORDER is the same contract either way — and because the
    /// numbers and the Activity column are still drawn from the whole corpus.
    static func gallery(_ posts: [GalleryPost]) -> [GalleryPost] {
        ranked(posts).filter { $0.kind != .text }
    }

    /// The banner's subject: the top post of the GALLERY — "the previous
    /// cycle's top post" once cycles exist on the wire; until then the
    /// highest-engagement member IS the standing cycle winner.
    ///
    /// ⚠️ Asked of the gallery rather than of the whole corpus, so that the
    /// three faces this page and the map show for one place stay the same
    /// picture: the cluster's pin wears its most-liked MEDIA member, which is
    /// this banner and Discover's first tile. Passed the full corpus instead,
    /// a place whose loudest post is a check-in would show a neutral banner
    /// over a grid whose first tile is the photograph the pin is wearing.
    static func bannerPost(in ranked: [GalleryPost]) -> GalleryPost? {
        ranked.first
    }

    /// The Activity tab's corpus: every member, NEWEST first — the one
    /// surface of this page that is chronological, because "what is happening
    /// here" is a different question from "what is this place known for".
    /// Every KIND travels: a place's activity is its posts, so the cards show
    /// words, stills and video exactly as For You's own card tab does.
    static func chronological(_ posts: [GalleryPost]) -> [GalleryPost] {
        DiscoverySource.recent.ordering(posts)
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

    /// What the Discover grid currently shows, in its rendered order — for
    /// the tests that pin the popularity ranking without reaching into the
    /// page.
    var renderedPosts: [GalleryPost] { page.posts }
    /// The Activity cards as rendered, same purpose.
    var renderedActivity: [GalleryPost] { activityPage.posts }
    /// The tab strip's titles, pinned by tests against silent drift. Read off
    /// the INLINE copy; `mirrorSelection` is what keeps the docked one equal.
    var tabTitles: [String] { inlineBar.currentTitles }

    // MARK: - The navigation bar

    /// The bar, left to right: back chevron · selector (docked only) ·
    /// dynamic space · points balance · Follow.
    private func configureNavigationItems() {
        configureFollowButton()
        configureWalletBadge()
        applyTrailingItems()
        // ⚠️ AFTER the trailing items, and that ordering is load-bearing:
        // `installLeadingSelector` measures the bar's whole budget to size
        // its capsule, and a trailing group installed afterwards would leave
        // it sized against a bar that no longer exists.
        selectorBarItem = navigationItem.installLeadingSelector(dockedBar)
        // The inline copy owns the un-scrolled state, so the item leaves the
        // bar until the header docks.
        setSelectorItemPresent(isBarDocked)
        applyDockedAppearance(animated: false)
    }

    /// ⚠️ INDEX 0 IS THE RIGHTMOST. The heart keeps the corner it has always
    /// had and the balance sits inboard of it — the same order the map puts
    /// its coin inboard of the bell.
    ///
    /// ⚠️ EACH IN ITS OWN BUBBLE. `sharesBackground = false` is UIKit's
    /// opt-out from the one glass pill a trailing group otherwise draws
    /// around everything in it. Left sharing, a balance and a heart read as
    /// one segmented control with a divider nobody drew.
    private func applyTrailingItems() {
        let items = [followItem, walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        navigationItem.rightBarButtonItems = items
    }

    /// The viewer's spendable points, in the toolbar — the fifth host of one
    /// badge (the map, For You, the profile, the post screen, and here).
    ///
    /// Built in this package rather than through the shell's
    /// `WalletBadgeInstaller`, for the reason the post screen is: a pushed
    /// screen owns its own navigation item, and what the installer exists to
    /// share — the freshness rules — is two closures here.
    private func configureWalletBadge() {
        guard let wallet else { return }
        // A badge with no sheet behind it is a read-out, not a control.
        walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
        walletBadge.addAction(
            UIAction { [weak self] _ in
                guard let self, let sheet = self.makeWalletSheet?() else { return }
                self.present(sheet, animated: true)
            },
            for: .primaryActionTriggered
        )
        // ⚠️ A GROWN COUNT NEEDS A FRESH WRAPPER. Re-assigning the same item
        // hands the bar the same wrapper at the same frozen size (measured on
        // the post screen: "120" still came back wrapped), so a new item is
        // the only thing a bar measures anew.
        walletBadge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            self.walletItem = self.makeWalletItem()
            self.applyTrailingItems()
        }
        walletItem = makeWalletItem()
        refreshWalletBadge()
        // Spends and claims wherever they happen — a boost in the feed pushed
        // over this page, a claim taken on the map beneath it.
        walletObservers.add(NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWalletBadge() }
        })
    }

    private func makeWalletItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: walletBadge)
        item.accessibilityLabel = "Points balance"
        return item
    }

    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            // A badge with no sheet to open must not advertise a claim the
            // viewer has no way to take from here.
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    /// The trailing heart, and nothing but the heart.
    ///
    /// ⚠️ A PLAIN BAR ITEM, where this was a custom view carrying a label.
    /// The word is gone on purpose — the state is already in the fill, and a
    /// titled item is charged its whole word against the bar's budget
    /// (`LeadingSelectorBudget.wantedWidth`), which is width the docked
    /// selector then does not have: measured, "Activity" came back clipped to
    /// "Activi" on a 402pt device with the label up. A glyph item costs the
    /// 44pt every glyph costs, and UIKit draws it as the same bubble the
    /// map's bell and the profile's tray wear.
    private func configureFollowButton() {
        guard let following else { return }
        let item = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in
            guard let self, let following = self.following else { return }
            self.renderFollowState(following.toggle())
        })
        followItem = item
        renderFollowState(following.isFollowing())
    }

    /// One place decides both states' looks, so they can't drift: the outline
    /// heart calls, the filled one rests. The word that used to sit beside it
    /// is gone (see `configureFollowButton`), so the FILL is the whole of the
    /// state — which is why the label a screen reader hears still says both
    /// words.
    private func renderFollowState(_ isFollowing: Bool) {
        followState = isFollowing
        followItem?.image = UIImage(systemName: isFollowing ? "heart.fill" : "heart")
        followItem?.tintColor = isFollowing ? .secondaryLabel : .tintColor
        followItem?.accessibilityLabel = isFollowing
            ? "Unfollow this place" : "Follow this place"
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
        // The page's own card style, translated into the one the seam speaks
        // — `ExternalHeroZoomSource` makes the same trip in the other
        // direction. Two enums with the same cases on purpose: one is this
        // feature's, the other crosses the interface.
        let flightStyle: SnapFeedHeroStyle = appearance?.style == .listMedia ? .listMedia : .tile
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            // ⚠️ ASKED, not assumed. A card's cover is a wide row, not a
            // square tile, and the literal `.tile` this used to pass was only
            // ever right because every page here was a grid. The page that
            // drew the thing knows what shape it drew.
            style: flightStyle,
            frame: { [weak grid] space in grid?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak grid] in grid?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak grid] concealed in
                grid?.setHeroHidden(concealed, for: tapped.id)
            },
            depthView: { [weak grid] in grid },
            // A row with no media has nothing to fly, and `hasHero` above is
            // already false for it — which used to mean the platform's plain
            // slide, on the one surface in the app where a text post did not
            // get the window every other list gives it. This is that window.
            textReveal: textRowReveal(for: tapped, in: grid)
        )
        // Remembered for the CLOSE. A flight opened from this page has a tile
        // to go home to, which is exactly what tells that close apart from the
        // map's Case B — see `cardCloseGeometry`. Cleared when this page is the
        // screen again (`viewDidAppear`), so a stale departure can never answer
        // for a later flight that came from somewhere else.
        tileDeparture = (id: tapped.id, isActivity: grid === activityPage)
        openPost(self, origin, stream.map(\.id))
    }

    /// Which posts on this screen are even CANDIDATES for a window.
    ///
    /// Pure and apart from the view for the reason the other two rules on this
    /// screen are: both ways of getting it wrong are silent. A media row handed
    /// a window would open a card onto a photograph the card does not draw; a
    /// text row denied one keeps the plain push, which is a perfectly good
    /// slide and looks like nothing is broken — which is exactly how it went
    /// unnoticed on this surface in the first place.
    ///
    /// `onListTab` rather than "which tab is up": Discover is a GRID, whose
    /// text posts are tiles with no caption to open out of, and a future third
    /// tab must not inherit a window by sitting at the right index.
    static func textWindowIsAvailable(for post: GalleryPost, onListTab: Bool) -> Bool {
        onListTab && post.kind == .text
    }

    /// The window a TEXT row opens through, or nil for anything that is not
    /// one — which keeps the plain push as the honest floor.
    ///
    /// Only the Activity tab can produce one: it is the `.list` page, and
    /// Discover is `.grid`, whose text posts are tiles with no caption to open
    /// out of. Asked of the page that was actually tapped rather than assumed,
    /// so a future third tab cannot inherit a window it cannot draw.
    ///
    /// ⚠️ MARKER-SHAPED, not row-shaped, and that is a deliberate trade. A
    /// row's caption normally lets the window align the page to it — the
    /// effect that reads as the card growing — but that alignment is only
    /// honest while the row and the page are the SAME post, and this feed is a
    /// PAGER. So the window takes the same answers the map's marker takes
    /// (`alignsPageToSource: false`, no cut, no borrowed band): the page holds
    /// still and the card opens over it. Never mis-aimed, at the cost of the
    /// growth effect.
    ///
    /// ⚠️ IT LANDS ON THE POST THE VIEWER TAPPED, always — even several pages
    /// on, even onto a photograph.
    ///
    /// This was briefly re-pointed at the settled post, on the reasoning that a
    /// window opened from WORDS has nothing a text row can receive once the
    /// viewer is on a picture. That reasoning was answering the wrong
    /// complaint. What made a paged close look like no animation at all was a
    /// forwarded pop returning nil and stranding the grab
    /// (`InteractiveSlideDismissal`'s decline rule); with that fixed the window
    /// runs either way, and re-pointing bought nothing but a list that appeared
    /// to shuffle. A scroll is not a reorder in the code and IS one to the eye:
    /// the post that was under the card is replaced by another, which is
    /// exactly what the product rule for this ranked tab forbids.
    ///
    /// So the fade is the answer, and the machinery already gives it:
    /// `RevealStage.swapFractions` puts an empty beat between the page and the
    /// card, so the departing media dissolves out and the original's words
    /// dissolve in with nothing drawn over anything. That beat is also why this
    /// is legal at all — neither half of the fade ever has text on both sides.
    private func textRowReveal(
        for post: GalleryPost, in grid: ForYouGridPage
    ) -> TextRevealOrigin? {
        // ⚠️ THE MODEL SAYS WHAT THE POST IS, the page only says whether it can
        // be described. Asking `heroAppearance` for the first half conflates
        // "has no media" with "has no realized cell", and an off-screen MEDIA
        // row would answer the same as a text one. The rect stays a question
        // for the page — a window needs somewhere to open from, and nil there
        // is the documented plain-push floor.
        guard Self.textWindowIsAvailable(for: post, onListTab: grid === activityPage),
              grid.rowFrame(for: post.id, in: grid) != nil
        else { return nil }
        let anchor = post.id
        return TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                return activityPage.textRowFrame(for: anchor, in: space)
                    ?? activityPage.rowFrame(for: anchor, in: space)
            },
            captionEnd: nil,
            depthView: { [weak self] in self?.pager },
            makeDismissStandIn: { [weak self] _ in
                // The settled post is deliberately ignored: this window closes
                // onto the row it opened from, whatever the viewer paged to.
                self?.activityPage.makeDismissStandIn(for: anchor)
            },
            alignsPageToSource: false,
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            setConcealed: { [weak self] concealed in
                self?.activityPage.setRevealConcealed(concealed, for: anchor)
            },
            // The row may have scrolled away under the open post — a hydration
            // or an engagement decoration re-realizes this list — and an
            // unrealized row answers nil for its rect, which sends the window
            // to a centred fallback that on screen is indistinguishable from a
            // working close. Bringing it back is all this does; the SETTLED
            // post is deliberately unused, see the note above.
            willStageDismissal: { [weak self] _ in
                guard let self else { return }
                view.layoutIfNeeded()
                activityPage.beginHeroFreeze()
                activityPage.revealPost(anchor)
                view.layoutIfNeeded()
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                activityPage.endHeroFreeze()
                if !committed { activityPage.clearRevealConcealment() }
            }
        )
    }
}

// MARK: - The close a flight cannot carry

/// What a TEXT post closes onto when it was opened by a FLIGHT.
///
/// ⚠️ THE PRESENTATION WAS CHOSEN AT THE TAP, and the feed is a pager: a
/// media-faced marker opens with a hero, the viewer swipes to a text post,
/// and now there is no media for that hero to fly. The map attaches a
/// card-shaped driver alongside the flight for exactly this
/// (`attachCardCloseAlongsideFlight`) and asks this screen where to land it.
///
/// ⚠️ THERE IS NO DEPARTURE TILE HERE, which is what makes this simpler than
/// For You's version of the same close. That screen departs FROM a grid tile
/// and must MOVE the landed post into the slot it left, or the close lands
/// somewhere the viewer never was. This flight departed from a map marker and
/// this grid has never been seen — so nothing has to be swapped anywhere. The
/// close simply brings the landing post's own tile on screen and lands on it.
extension PlaceProfileViewController: CardCloseLanding {
    func cardCloseGeometry(dismissing feed: UIViewController) -> RevealGeometry? {
        // A flight that left THIS page has a tile to go back to. Answered
        // first, because it is the case with somewhere the viewer actually was
        // — everything below is for the flight that arrived from a marker.
        if let tileDeparture {
            return tileCardCloseGeometry(dismissing: feed, departure: tileDeparture)
        }
        // ⚠️ THE FIRST TILE, like the flight beside it — the same product rule,
        // for the same reason: this grid arrived from a marker and the viewer
        // has never seen it, so there is nowhere on it they were.
        //
        // It used to hunt for the next landable MEDIA after the settled post
        // (`nextLandableMedia`), which was the honest answer while a text post
        // had a tile of its own to be "after". Discover is media-only now, so
        // the settled text post is not in that array at all and the lookup
        // returned nil for every one of these closes — a dead branch that read
        // as a plain slide. Asking for the first tile needs no lookup.
        guard let landed = activePostID?(), let first = page.posts.first else { return nil }
        stageDiscoverLanding(revealing: first.id, sizedTo: view.bounds)
        let substitute = first
        stageDiscoverLanding(revealing: substitute.id, sizedTo: nil)
        guard page.rowFrame(for: substitute.id, in: page) != nil else {
            debugLogLanding("no realized tile for \(substitute.id.rawValue)")
            return nil
        }
        anchorID = substitute.id
        debugLogLanding("landing \(landed.rawValue) on FIRST tile \(substitute.id.rawValue)")
        let origin = TextRevealOrigin(
            rowFrame: { [weak self] space in
                self?.page.rowFrame(for: substitute.id, in: space)
            },
            // A tile has no caption to cut against, so no veil — the same
            // answer the map's marker gives, and for the same reason.
            captionEnd: nil,
            depthView: { [weak self] in self?.pager },
            makeDismissStandIn: { [weak self] _ in
                // The CLONE: a free-standing tile drawn from the substitute's
                // own model, which loads its own cover. Sized from the slot it
                // is landing on.
                self?.page.makeTileStandIn(for: substitute, slotOf: substitute.id)
            },
            // ⚠️ FALSE, like the marker's. Aligning a full page to a small
            // tile slides it most of the screen's width; the page holds still
            // and the window closes over it.
            alignsPageToSource: false,
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            cornerRadius: PostGridTileCell.mosaicCornerRadius,
            // The tile's own floor, so the beat where the window carries
            // neither picture is the colour of the brick it lands on.
            fill: PostGridTileCell.fillColor(for: substitute),
            setConcealed: { [weak self] concealed in
                self?.page.setRevealConcealed(concealed, for: substitute.id)
            },
            willStageDismissal: { [weak self] _ in
                self?.stageDiscoverLanding(revealing: substitute.id, sizedTo: nil)
            },
            dismissalDidEnd: { [weak self] committed in
                self?.page.endHeroFreeze()
                if !committed { self?.page.clearRevealConcealment() }
            }
        )
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
    }

    func clearLandingConcealment() {
        // BOTH channels, on BOTH pages: the flight hid the departure at the
        // push and only its own return puts that back, so a visit that ends on
        // a text post — closed by the card driver — would leave it blank. Which
        // page held it depends on which tab the viewer opened from, and by the
        // time this runs that is no longer a question worth asking.
        for hosted in hostedPages {
            guard let grid = hosted as? ForYouGridPage else { continue }
            grid.clearRevealConcealment()
            grid.clearHeroConcealment()
            grid.endHeroFreeze()
        }
    }

    /// The close for a flight this page itself opened: home to the very tile
    /// the viewer tapped, on the tab they tapped it on.
    ///
    /// ⚠️ NO SUBSTITUTION, and that is the whole difference from the sibling
    /// above. That one departed from a MAP MARKER onto a grid the viewer has
    /// never seen, so it is free to pick the nearest landable tile — there is
    /// no "where they were" to honour. Here there is one, they chose it, and
    /// the product rule for this screen is that the arrival is always the post
    /// the flight opened. A ranked list is also not free to be re-pointed into.
    ///
    /// ⚠️ THE FLIGHT'S CONCEALMENT COMES OFF FIRST, before anything is
    /// measured. The push hid the departure through the HERO channel
    /// (`setHeroHidden`), and only the flight's own return leg pays that back —
    /// a return this close is replacing. Left alone the window shrinks onto a
    /// hole, and the restore must land a beat BEFORE the window retires, never
    /// after: at the landing rect the cell and the window are identical, so
    /// swapping them inside one transaction is invisible while doing it in two
    /// is a flash of empty grid.
    ///
    /// The REVEAL's own channel then takes over and hides the same cell for the
    /// length of the close, which is what stops it showing beside the window.
    /// (That channel used to resolve a list-row cell only, so on the Discover
    /// grid both its hide and its restore landed on nothing — fixed in
    /// `setRevealConcealed`, which now switches on the cell like the hero
    /// channel beside it always has.)
    private func tileCardCloseGeometry(
        dismissing feed: UIViewController, departure: (id: PostID, isActivity: Bool)
    ) -> RevealGeometry? {
        let grid = departure.isActivity ? activityPage : page
        grid.clearHeroConcealment()
        if departure.isActivity {
            stageActivityLanding(for: departure.id, sizedTo: nil)
        } else {
            stageDiscoverLanding(revealing: departure.id, sizedTo: nil)
        }
        guard let post = grid.post(for: departure.id),
              grid.rowFrame(for: departure.id, in: grid) != nil
        else {
            debugLogLanding("no realized departure for \(departure.id.rawValue)")
            return nil
        }
        debugLogLanding("landing on its own departure \(departure.id.rawValue)"
            + " tab=\(departure.isActivity ? "activity" : "discover")")
        let anchor = departure.id
        let onList = departure.isActivity
        let origin = TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                let grid = onList ? activityPage : page
                return grid.rowFrame(for: anchor, in: space)
            },
            // No cut on either tab: a tile has no caption to cut against, and
            // an Activity row's caption belongs to the DEPARTURE post while the
            // page being closed may be showing a different one.
            captionEnd: nil,
            depthView: { [weak self] in self?.pager },
            makeDismissStandIn: { [weak self] _ in
                guard let self else { return nil }
                // The settled post is deliberately ignored — this window closes
                // onto what the viewer opened.
                return onList
                    ? activityPage.makeDismissStandIn(for: anchor)
                    : page.makeTileStandIn(for: post, slotOf: anchor)
            },
            // ⚠️ FALSE on both tabs, for the two reasons this file already
            // gives: a full page aligned to a small tile slides most of the
            // screen's width, and a caption measured on one post cannot align
            // a page showing another.
            alignsPageToSource: false,
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            cornerRadius: onList ? nil : PostGridTileCell.mosaicCornerRadius,
            fill: onList ? nil : PostGridTileCell.fillColor(for: post),
            setConcealed: { [weak self] concealed in
                guard let self else { return }
                (onList ? activityPage : page).setRevealConcealed(concealed, for: anchor)
            },
            willStageDismissal: { [weak self] _ in
                guard let self else { return }
                // And again, for the same reason: the pass that SETS an offset
                // does not realize the cells at it.
                (onList ? activityPage : page).clearHeroConcealment()
                if onList {
                    stageActivityLanding(for: anchor, sizedTo: nil)
                } else {
                    stageDiscoverLanding(revealing: anchor, sizedTo: nil)
                }
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                let grid = onList ? activityPage : page
                grid.endHeroFreeze()
                if !committed { grid.clearRevealConcealment() }
            }
        )
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: imagePipeline)
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
        let card = PostGridFlightCard(
            post: page.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile
        )
        // ⚠️ AND THE PICTURE THE VIEWER IS LEAVING, dissolved into it.
        //
        // The landing is the first tile now, which is almost never the post on
        // screen — so the card would take off wearing a photograph the viewer
        // has not seen, from the first frame. That is the cut the blend channel
        // exists for. Nil when they never paged, which leaves the flight
        // exactly the single-pictured one it has always been.
        if let settled = activePostID?(), settled != anchorID {
            card.setDeparturePicture(activeCover?())
        }
        return card
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
            // Adopt the Discover tab through the same alignment rule as a
            // tap, so the header does not move for the switch.
            page.setVerticalOffset(alignedOffset(for: 0))
            activeIndex = 0
            applyHeaderOffset(page.verticalOffset)
            syncAutoplay()
        }
        mirrorSelection(to: 0)
        pager.setActivePage(0, animated: false)
        page.beginHeroFreeze()
        // ⚠️ THE FIRST TILE, whatever the viewer paged to (product call).
        //
        // This flight came from a MAP MARKER: the viewer has never seen this
        // grid, so there is no place on it they were, and no reason to arrive
        // in the middle of it. Landing on the settled post's own tile — what
        // this did — meant tapping a cluster, swiping twice and closing put the
        // page down scrolled to an arbitrary row, with everything above it
        // unseen. The first tile is the page introducing itself.
        //
        // A post opened FROM this page is the opposite case and keeps the
        // opposite rule: it lands on the very tile that was tapped, through
        // `ExternalHeroZoomSource`, which never asks this source anything.
        if let first = page.posts.first?.id {
            anchorID = first
        }
        debugLogLanding("flight from \(activePostID?()?.rawValue ?? "nil")"
            + " to FIRST tile \(anchorID.rawValue)"
            + " blend=\(activePostID?() != anchorID && activeCover?() != nil)")
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

    // MARK: - The Activity card a text post closes onto

    /// Where a TEXT-faced cluster's feed goes home: the post's own CARD on the
    /// Activity tab, described as a reveal origin.
    ///
    /// ⚠️ A REVEAL, NOT A HERO FLIGHT, and the difference is not a preference.
    /// The zoom stack refuses this post three separate ways — the hero grab
    /// declines a `.card` dismissal outright, the slide forwards to a flight
    /// delegate only for `.hero`, and the one flight card this feature owns
    /// (`PostGridFlightCard`) has no style that can carry a caption, so it
    /// would fly a blank rounded rect. That is precisely the
    /// "hero animation about nothing" this codebase already rejected once for
    /// the map's text markers. The reveal's stand-in is a REAL
    /// `PostGridListRowCell` carrying this post's own words, author and age,
    /// floating free under the finger — the card morph, with nothing
    /// impersonated.
    ///
    /// Returns nil when the Activity tab has no card for the post, which is
    /// what selects the plain-slide fallback.
    ///
    /// ⚠️ IT STAGES BEFORE IT MEASURES, and it has to. A `RevealGeometry`
    /// takes the caption's cut, the caption's top and the author band as
    /// VALUES — read the moment it is built — while only the rect is a
    /// closure the transition re-asks later. This page is off-stack and
    /// unsized when the driver asks, so its cards do not exist yet and every
    /// one of those numbers would be zero. `sizedTo` is the bar the caller
    /// measures in; giving the view that size and laying it out is what makes
    /// the row real enough to describe.
    func activityCardRevealOrigin(sizedTo bounds: CGRect) -> TextRevealOrigin? {
        // ⚠️ THE FIRST ROW, whatever the viewer paged to — the same product
        // rule the flight and the Discover close beside it now follow, and for
        // the same reason: this list arrived from a MARKER, the viewer has
        // never seen it, so there is nowhere on it they were.
        //
        // It used to re-point at the settled post. That was the honest answer
        // while "where they are" meant something here; from a marker it does
        // not, and it put the page down scrolled to an arbitrary row with
        // everything above it unseen.
        //
        // ⚠️ Settled BEFORE anything is measured, because every caption field
        // below is read as a VALUE off this row.
        let anchor = activityPage.posts.first?.id ?? anchorID
        guard activityPage.post(for: anchor) != nil else {
            debugLogLanding("no post for \(anchor.rawValue)")
            return nil
        }
        stageActivityLanding(for: anchor, sizedTo: bounds)
        // Nothing to describe — no cell for this post even after staging.
        guard activityPage.rowFrame(for: anchor, in: activityPage) != nil else {
            debugLogLanding("no realized row for \(anchor.rawValue)"
                + " bounds=\(view.bounds.size) posts=\(activityPage.posts.count)")
            return nil
        }
        debugLogLanding("staged \(anchor.rawValue)"
            + " row=\(activityPage.rowFrame(for: anchor, in: activityPage).map(\.debugDescription) ?? "nil")")
        return TextRevealOrigin(
            rowFrame: { [weak self] space in
                guard let self else { return nil }
                // The text row's own rect, falling back to the whole row —
                // the two-step For You's own close uses, because a row that
                // carries media has no text rect to give.
                return activityPage.textRowFrame(for: anchor, in: space)
                    ?? activityPage.rowFrame(for: anchor, in: space)
            },
            captionEnd: activityPage.textRowCaptionEnd(for: anchor),
            depthView: { [weak self] in self?.pager },
            captionTop: activityPage.textRowCaptionTop(for: anchor),
            authorBand: activityPage.textRowAuthorBand(for: anchor),
            makeDismissStandIn: { [weak self] _ in
                self?.activityPage.makeDismissStandIn(for: anchor)
            },
            // No cornerRadius and no fill: a ROW must take the card's own
            // values (`TextRevealInstaller` reads them from PostGrid). Only a
            // map marker, which is a disc in its own tint, overrides them.
            // ⚠️ THE PAGE FILLS THE WINDOW — see `RevealPageFit.covering`.
            //
            // Held still it stayed at full size while the window shrank around
            // it: a keyhole panning over a photograph, filmed on this screen.
            // It fitted INSIDE the window for a while instead, which stopped
            // the truncation and started the other half of it — on the release
            // spring, where the window's aspect leaves the page's, the media
            // sat letterboxed with the card's ground above and below it.
            // Filmed too.
            //
            // The invariant every report has agreed on is the simple one: the
            // media fills the transition window, always. That is covering, and
            // it is what the marker has used all along.
            pageFit: .covering,
            setConcealed: { [weak self] concealed in
                // The reveal's OWN channel, never `setHeroHidden` — the two
                // conceal flags are deliberately separate.
                self?.activityPage.setRevealConcealed(concealed, for: anchor)
            },
            // Re-asserted once the page is really on the stack and sized by
            // the transition's own container: idempotent by construction, and
            // the only chance to correct anything the off-stack staging got
            // wrong about a width it had to be told.
            willStageDismissal: { [weak self] _ in
                self?.stageActivityLanding(for: anchor, sizedTo: nil)
            },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                activityPage.endHeroFreeze()
                // A cancelled close leaves the row concealed under a page that
                // sprang back, and the viewer may then leave by the chevron.
                if !committed { activityPage.clearRevealConcealment() }
            }
        )
    }

    /// `-grab-log`: why a text close did or did not get its card. The two
    /// outcomes are indistinguishable on screen — a plain slide is what a
    /// refusal looks like, and it is also a perfectly good animation — so the
    /// reason has to be said out loud or a regression here is invisible.
    private func debugLogLanding(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-grab-log") else { return }
        print("[place-landing] \(message())")
        #endif
    }

    /// Puts this page on its Activity tab with `anchor`'s card on screen —
    /// the landing a text close aims at.
    ///
    /// `sizedTo` is for the off-stack call, where the view has no bounds of
    /// its own yet; pass nil once the transition's container owns the size.
    /// Idempotent: it is run once to measure and again to land.
    private func stageActivityLanding(for anchor: PostID, sizedTo bounds: CGRect?) {
        loadViewIfNeeded()
        if let bounds, view.bounds.size != bounds.size {
            view.frame = bounds
        }
        // ⚠️ A PASS BEFORE THE PAGER IS TOUCHED. `setActivePage` moves a
        // scroll view by PAGE WIDTH, and a pager that has never been laid out
        // has none — so the offset it computes is zero and page 1 is never
        // brought on, whatever it was asked for. Measured: the landing row
        // stayed unrealized on the first ask and only appeared on the second,
        // one run loop later, which sent every close to the fallback slide.
        view.layoutIfNeeded()
        if activeIndex != 1 {
            activityPage.setVerticalOffset(alignedOffset(for: 1))
            activeIndex = 1
            applyHeaderOffset(activityPage.verticalOffset)
            syncAutoplay()
        }
        mirrorSelection(to: 1)
        pager.setActivePage(1, animated: false)
        // ⚠️ LAY OUT BEFORE REVEALING, and this ordering is the whole of it.
        // `revealPost` asks the collection view for the landing row's layout
        // attributes; on a page that has only just been given a size those
        // are nil, so the scroll goes nowhere and the row is never realized —
        // measured as "no realized row" on the FIRST ask and a correct row on
        // the second, which is what made the close silently fall back to a
        // slide every time.
        view.layoutIfNeeded()
        activityPage.beginHeroFreeze()
        activityPage.revealPost(anchor)
        // And again: cells at the landed offset are realized by the pass
        // AFTER it is set, never by the one that set it.
        view.layoutIfNeeded()
    }

    /// Puts this page on its Discover tab with `anchor`'s tile on screen.
    /// Same shape and same two layout traps as `stageActivityLanding`.
    private func stageDiscoverLanding(revealing anchor: PostID, sizedTo bounds: CGRect?) {
        loadViewIfNeeded()
        if let bounds, view.bounds.size != bounds.size { view.frame = bounds }
        view.layoutIfNeeded()
        if activeIndex != 0 {
            page.setVerticalOffset(alignedOffset(for: 0))
            activeIndex = 0
            applyHeaderOffset(page.verticalOffset)
            syncAutoplay()
        }
        mirrorSelection(to: 0)
        pager.setActivePage(0, animated: false)
        page.beginHeroFreeze()
        page.revealPost(anchor)
        view.layoutIfNeeded()
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
    /// The band's two numbers as rendered — the place's own totals, which are
    /// deliberately NOT the gallery's (see `render`).
    /// Which post a dismissal from the MAP is currently aimed at. The rule it
    /// pins is a product one — always the first — and its violation is a page
    /// that lands scrolled to an arbitrary row, which looks like a scroll
    /// position rather than like a bug.
    var debugLandingAnchor: PostID { anchorID }
    var debugMetrics: (reactions: Int64, views: Int64) {
        (reactionsMetric.debugValue, viewsMetric.debugValue)
    }
    var debugHeroName: String? { heroNameLabel.text }
    var debugHeroKind: String? { heroKindLabel.isHidden ? nil : heroKindLabel.text }
    /// The selector hand-over, as the two copies actually stand: the inline
    /// one owns the un-scrolled state, the docked one the scrolled state.
    var debugIsBarDocked: Bool { isBarDocked }
    var debugInlineSelectorAlpha: CGFloat { inlineBar.alpha }
    var debugDockedSelectorAlpha: CGFloat { dockedBar.alpha }
    var debugDockedSelectorItemPresent: Bool { selectorBarItem.map { !$0.isHidden } ?? false }
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
        stored = value
        valueLabel.text = CountFormatter.compactString(for: value)
        accessibilityValue = valueLabel.text
    }

    #if DEBUG
    /// The raw total, before `CountFormatter` rounds it into something a
    /// column can hold. A test asserting "57" against "57" through the
    /// formatter would pass just as well against "57.4K".
    private(set) var debugValue: Int64 = 0
    private var stored: Int64 {
        get { debugValue }
        set { debugValue = newValue }
    }
    #else
    private var stored: Int64 = 0
    #endif
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
    /// ⚠️ FALSE, and this is the member that exists BECAUSE of this screen.
    ///
    /// Conforming to this protocol used to be read across the shell as "a
    /// full-bleed surface that covers the dock" — a question it never asked.
    /// This page flies home to a map marker like a snap surface AND shows the
    /// app's tab bar like the ordinary navigation citizen it is, which is
    /// what made the two come apart: the day it gained this conformance, the
    /// shell started hiding the dock underneath it and the restores that run
    /// on the way back stopped firing.
    var concealsAppTabBar: Bool { false }

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
    /// the profile pager's own rule. The back button flies from any tab. And
    /// on a card's carousel with a photograph to its left, the carousel is
    /// the tenant and wins its own territory.
    func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        let point = self.view.convert(location, from: view)
        let isPushed = navigationController.map { $0.viewControllers.first !== self } ?? false
        // ⚠️ THE EDGE IS NOT THE FIRST TAB'S PRIVILEGE. This asked only "am I on
        // the first tab" and refused everything else outright — including the
        // leading strip, which `HorizontalPagerScrollView` had already yielded
        // as the platform's own. Two surfaces both giving the drag up leaves it
        // claimed by nobody: on the Activity tab a rightward swipe did nothing
        // at all, from anywhere. Reported.
        guard PagedScreenDismissalPolicy.allowsDismissal(
            atX: point.x, activeIndex: activeIndex, isPushed: isPushed
        ) else { return false }
        // On the strip the answer is already yes — it is absolute, the way the
        // pager treats it. Elsewhere the drag may still belong to a carousel
        // under the finger.
        //
        // ⚠️ `-1`: the drag is RIGHTWARD and pages run the other way to the
        // finger. Both rules ask the same question — what else could this
        // drag be for — see `MediaCarouselTouchRouting`.
        guard point.x > PagedScreenDismissalPolicy.edgeZone else { return true }
        return MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: point, in: self.view, towardsPageDelta: -1
        )
    }

    /// Freeze the tab pager while a grab drives, so the drag that is flying
    /// the page home cannot also page it sideways.
    func setContentScrollEnabled(_ enabled: Bool) {
        pager.isPagingEnabled = enabled
    }
}
