import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The Explore tab's surface: a full-bleed `MKMapView` that re-queries
/// lightweight pins whenever the user settles a pan/zoom, and applies the
/// result as a minimal identity diff so untouched markers never flicker.
///
/// This VC is a thin MapKit dispatcher — the query, cancellation, and diffing
/// live in `MapsViewModel`; the region→viewport math lives in `MapViewport`.
/// The pin-tap hero transition and the live-preview video pool arrive in Step B
/// (the `didSelect` and annotation-view seams are marked below).
final class MapsViewController: UIViewController {
    /// The places pinned to the dock (#1598).
    private let dockedPlaces = MapDockedPlacesStore()
    #if DEBUG
    /// `-maps-offer-country` ran (#1600).
    var didDebugOfferCountry = false
    #endif
    /// Internal (not private) only for the +QA hooks.
    let viewModel: MapsViewModel
    /// Sources the filter bar's scrollable favorites section (fail-open:
    /// empty just hides the section).
    let favoritesRepository: any MapFavoritesProviding
    var favoritesTask: Task<Void, Never>?
    /// Reads and writes the pinned set behind the favorites section — the one
    /// place the never-curated fallback is resolved, shared with the profile
    /// screen's pin button so the two cannot disagree about what a pin means.
    /// Internal (not private) only for the +QA hooks.
    let pinService: MapProfilePinService
    /// What the favorites section currently shows — the seed material when a
    /// first pin/unpin materializes the store from the fallback.
    var currentFavorites: [MapFavorite] = []
    /// What the sub-filter row currently shows — the full-list sheet's data.
    /// Internal so the extensions (+MapViewDelegate, +QA) reach it; only the
    /// gate transitions here and in +MapViewDelegate write it.
    var currentSubFilterOptions: [MapSubFilterOption] = []
    let imagePipeline: ImagePipeline
    /// The baked animated-icon catalogue, or `nil` where the surface has none.
    ///
    /// Separate from `imagePipeline` on purpose. Icons are decoded WHOLE
    /// (downsampling a sprite grid lands every frame boundary mid-pixel) and
    /// budgeted by BYTES rather than by count (a sheet is up to 1.7 MB, so the
    /// pipeline's `countLimit = 300` would never evict), and they must not go
    /// through `decodeDownsampled` at all — that call never returns on HEIC
    /// under concurrent load in the iOS 26 simulator.
    /// Internal (not private) only for the +QA hooks.
    let iconCatalog: (any AnimatedIconProviding)?
    /// Baked previews of a MEDIA post's own footage — the decode-session-free
    /// alternative to attaching a player. Separate catalogue from the icons'
    /// because the two have different cell sizes and very different byte costs
    /// (2.71 MB resident per preview against 0.07 MB per icon), so one budget
    /// could not serve both without the cheap one being evicted by the dear one.
    /// Internal (not private) only for the +QA hooks.
    let previewCatalog: AnimatedIconCatalog?
    /// Re-dresses every marker when the device changes its motion policy.
    ///
    /// ⚠️ Read at INSTALL time, so this is not optional: without it a field
    /// dressed before the user enabled Low Power keeps animating at full rate
    /// for the rest of the session — the exact failure the setting exists to
    /// prevent. And it must RE-DRESS rather than "reinstall if not running",
    /// which can only promote a marker and never demote one.
    private let iconPolicyBag = NotificationTokens()
    /// The player pool: the Shop's country cards play from it, and the debug
    /// readout tells DECODERS from surfaces with it (internal for +QA).
    var videoPool: VideoPlaybackController?
    #if DEBUG
    /// Internal (not private) only for the +QA hooks.
    var iconDebugHUD: MapIconDebugHUD?
    #endif
    /// Builds the snap feed a pin/cluster tap expands into (reuses the Feed
    /// feature via `FeedFeatureBuilding.makeSnapFeedViewController`).
    let makeSnapFeed: ([PostID]) -> UIViewController
    /// Pushes that same feed with the platform's own slide, for a marker with
    /// nothing to fly. Goes through the feed's `pushSnapFeed` seam rather than
    /// this controller calling `pushViewController` itself: the pushed feed
    /// refuses the stack's native edge pop, so the swipe-back has to be
    /// attached and retained with it, and that belongs where the other two
    /// surfaces already get it.
    /// The last argument builds the screen a VERTICAL dismissal lands on
    /// (the semantic cluster's place page), or `nil` for a plain marker
    /// (#2015: every non-media marker opens this way now).
    let pushPlainSnapFeed: ([PostID], UIViewController, ((UIViewController) -> UIViewController)?) -> Void
    /// The same window built for a CLOSE, pushing nothing — what a feed opened
    /// by a hero uses when the viewer has paged onto a post it cannot fly.
    /// Injected like its push-shaped sibling: Maps depends on FeedInterface and
    /// never on Feed.
    let makeRevealGeometry:
        (UIViewController, TextRevealOrigin, (() -> Void)?) -> RevealGeometry
    /// Builds the place gallery a HIERARCHY cluster's feed dismisses into
    /// (`FeedFeatureBuilding.makeClusterGallery`): (member ids, the place
    /// itself, the feed about to cover it, the map-return flight source) →
    /// the gallery screen, which is the vertical close's landing
    /// (`CardCloseLanding`) and the flight's registered intermediate
    /// (`ZoomTransitionSource`, refusing any hero). The whole `MapPlace` travels (not
    /// just its `galleryTitle`) so the builder can wire the header's follow
    /// toggle to this place's identity; the country code (ISO alpha-2, "" at
    /// sea) is the marker's — the one its flag border wears — for the page's
    /// flag and subtitle; the marker's centre names a city to the server,
    /// whose posts the page lists past the pins (#643); the last argument
    /// stages the page's OWN dismissal back to the cluster marker
    /// (`makeMapReturnSource`).
    let makeClusterGallery: (
        [PostID], MapPlace, String, CLLocationCoordinate2D, UIViewController,
        @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
        ((UIViewController) -> RevealGeometry?)?
    ) -> UIViewController
    /// Warms the given posts into the shared cache so a tap opens instantly.
    let prewarm: ([PostID]) async -> Void
    /// Opens someone's profile (the sub-filter sheet's Profile swipe). A
    /// closure, not a router: the Maps package stays navigation-agnostic —
    /// the shell decides that this means the `.profile` route, exactly as it
    /// does for the avatar and compose bar items.
    let openProfile: (ProfileID, ProfileIdentityStub?) -> Void
    /// Starts (or resumes) a thread with someone the map surfaces — the pill
    /// menu's Send Message. Injected for the same reason as `openProfile`:
    /// Maps stays ignorant of routes and of the Messages feature.
    let openConversation: (ProfileID, ProfileIdentityStub?) -> Void
    /// The current viewport's prefetch, cancelled when the map settles elsewhere.
    var prewarmTask: Task<Void, Never>?
    /// Starts a post's page player at touch-down on its marker (#646).
    let warmPlayback: (PostID, TimeInterval?) -> (any FeedPlaybackWarm)?
    /// The player a finger on a marker started, until the post opens or the
    /// touch gives up.
    var playbackWarm: (postID: PostID, warm: any FeedPlaybackWarm)?
    /// How long a touch that ended without opening keeps its warm player: the
    /// tap is recognised on touch-up, in the same turn or the next.
    static let warmOpenWindow: TimeInterval = 0.6
    /// Prerolls ONE post page player, paused on its first frame (#654).
    let prerollPlayback: (PostID, TimeInterval?) -> (any FeedPlaybackWarm)?
    /// The one prerolled player: the marker nearest the centre at the last
    /// idle settle. Promoted to `playbackWarm` when that marker is touched.
    var idlePreroll: (postID: PostID, warm: any FeedPlaybackWarm)?
    var idlePrerollWork: DispatchWorkItem?
    /// How long the map has to rest before a player is spent on it.
    static let idlePrerollDelay: TimeInterval = 0.6
    /// How long a preroll waits for its tap before it is let go (#654).
    ///
    /// ⚠️ PAUSED IS NOT FREE. Nothing decodes, but its renderer stays on the
    /// shared video clock (`VideoFrameClock`), which ticks at the screen's
    /// rate while any renderer is registered — a cheap "new frame?" check,
    /// still a wake per refresh. A map left alone gets 20 s of it, then
    /// nothing until the viewer moves it or comes back to it.
    static let idlePrerollLifetime: TimeInterval = 20
    var idlePrerollExpiry: DispatchWorkItem?
    /// Set when a preroll timed out; cleared by the next settle or return, so
    /// a map left alone is not re-prerolled every 20 s by stray refreshes.
    var idlePrerollRested = false
    /// Tries left this rest when the feed had nothing to preroll yet — the
    /// map warms its visible posts' data on the same settle, so the first ask
    /// can beat it (measured: `hydrated=false`, then nothing for 25 s).
    var idlePrerollRetries = 0
    static let idlePrerollRetryLimit = 3
    static let idlePrerollRetryDelay: TimeInterval = 1.5
    /// Runaway guard: clustering already bounds the visible set to a handful, but
    /// cap the sweep in case it runs during a pre-cluster frame.
    static let prewarmCap = 16
    /// Read once: `reconcileClustersForSettle` runs on every settle, in release too.
    static let reconcileThrottleEnabled = ProcessInfo.processInfo.arguments.contains("-maps-reconcile-throttle")
    /// The flight in progress, held for its life; its close-out is the
    /// session's (`HeroPushSession`).
    var activeSession: HeroPushSession?
    /// The "one flight at a time" latch, and the flight's controller.
    /// Internal (not private) only for the +QA hooks.
    var activeTransition: ZoomTransitionController? { activeSession?.controller }
    /// The card-shaped close that rides alongside the flight, for the posts
    /// the flight cannot carry (see `attachCardCloseAlongsideFlight`). Held
    /// because `UINavigationController.delegate` is weak and nothing else
    /// would keep this driver alive to see its own swipe; released by its
    /// `onFeedPopped`.
    var cardClose: InteractiveSlideDismissal?
    /// True from the moment a plain push is fired until the map is back on
    /// screen. It does for that path exactly what `activeTransition` does for
    /// the flight: the instant-tap recognizer and MapKit's own `didSelect` can
    /// both fire for ONE tap, and without a guard the second one pushes a
    /// second copy of the feed.
    /// Whether the map may be touched, and whether a tap may open anything —
    /// see `MapOpenGate`. It replaces two booleans that were set in three
    /// branches and released from five unrelated places, and it is the ONLY
    /// thing that writes the map's interaction.
    /// Internal so the extensions (+MapViewDelegate, +QA) reach it; only the
    /// gate transitions here and in +MapViewDelegate write it.
    var openGate = MapOpenGate() {
        didSet {
            applyMapInteraction()
            #if DEBUG
            // `-maps-log-gate`: every state the map's lock passes through.
            //
            // ⚠️ WITHOUT IT, "the map is dead to taps" and "the map is fine" look
            // identical from outside — which is exactly how a reversed present
            // bricked it for a whole session without anyone being able to say
            // what had happened.
            if oldValue != openGate,
               ProcessInfo.processInfo.arguments.contains("-maps-log-gate") {
                print("[gate] \(oldValue.state) -> \(openGate.state) "
                      + "canOpen=\(openGate.canOpen ? "Y" : "n") "
                      + "inert=\(openGate.mapIsInert ? "Y" : "n")")
            }
            // The soak's clock is the gate, not a timer: "the map is ready
            // again" has exactly one honest definition and this is it.
            if oldValue.canOpen == false, openGate.canOpen { advanceSoakIfNeeded() }
            #endif
        }
    }
    /// Chooses which ≤3 visible video pins autoplay.
    let videoCoordinator: MapVideoPlaybackCoordinator
    /// Runs the pins' staggered pop-in/pop-out and owns the in-flight
    /// animators — including the marker-reclaim that keeps a fast filter
    /// flip-flop from doubling a pin (see `MapAnnotationPopChoreographer`).
    lazy var popChoreographer = MapAnnotationPopChoreographer(mapView: mapView)
    private let appObservers = NotificationTokens()
    #if DEBUG
    /// Internal (not private) only for the +QA hooks.
    var didDebugOpenPin = false
    /// `-maps-soak <cycles>`: opens a marker, closes it, opens the next, N times.
    ///
    /// ⚠️ THE MAP WAS THE ONE SURFACE WITH NO SOAK, and the reason was
    /// mechanical: every `-maps-open-*` hook is a ONE-SHOT LATCH
    /// (`didDebugOpenPin`), so nothing could iterate this seam at all. Every
    /// leak, every stuck lock and every retained driver on the map→post→map
    /// round trip was therefore unmeasurable by construction, whatever the
    /// census said.
    ///
    /// Deterministic order, by post id: MapKit's own annotation order is
    /// undefined, and a soak that opens a different sequence on every run
    /// compares two different runs.
    ///
    /// Internal (not private) only for the +QA hooks, like the three below.
    var soakCyclesRemaining = 0
    var soakCursor = 0
    /// Bumped every time a cycle starts, so a watchdog can tell "still on the
    /// cycle I was watching" from "already moved on".
    var soakGeneration = 0
    /// One pending re-check at a time, so a shut gate cannot stack timers.
    var soakRetryScheduled = false
    #endif

    /// Internal (not private) only for the +QA hooks.
    let mapView = MKMapView()
    /// The world's country borders and the chosen one — see `CountryLayer`.
    /// Internal (not private) only for the +QA hooks.
    let countryLayer = CountryLayer()
    /// Which countries this account has unlocked — only their posts are on
    /// the map. Nil: every country is open (the fleet, until the backend
    /// carries unlocks).
    /// Internal (not private) only for the +QA hooks.
    let countryAccess: (any CountryAccess)?
    /// Where the device is: the locate button and the "See posts around you"
    /// card (`MapLocationControls`). Nil shows neither.
    let locator: (any CurrentCountryLocating)?
    /// What the Shop's Boosts sells (the ×100 cartridge pack); nil sells none.
    let stakePacks: (any StakePackSelling)?
    /// What the Shop's Profile shelf sells (#944); nil sells none.
    let profileItems: (any ProfileItemSelling)?
    /// Whether the viewer has an account. A guest follows no one, so the
    /// favourites dock and the people rows stay empty for them.
    let isMember: @MainActor () -> Bool
    /// The country each pin stands in, looked up once per post: the atlas
    /// test is point-in-polygon, and the reconcile runs on every settle.
    var pinCountries: [PostID: String] = [:]
    /// A pick waiting to become a flight and an offer (`mapTapped`).
    var pendingOffer: DispatchWorkItem?
    /// The open offer, if any.
    /// The marker the instant tap just opened, and when: MapKit's own
    /// selection of it lands about 0.3 s later and must not open it twice (#760).
    var instantTap: (annotation: ObjectIdentifier, at: CFTimeInterval)?

    weak var offerSheet: CountryUnlockSheetViewController?
    /// The open offer's camera bookkeeping — where the map was before it,
    /// whether closing flies back there, whether a cancelled close reframes
    /// (`MapCountryOfferState`).
    var offerState = MapCountryOfferState()
    /// The filter-pill carousel floating above the tab bar. The map's first
    /// bottom overlay: pinned to the safe area (the map itself is full-bleed
    /// and draws under the floating tab bar).
    /// Internal (not private) only for the +QA hooks.
    let filterBar = MapFilterBarView()
    /// The dynamic refinement row directly above `filterBar` — people under
    /// Friends/Following, place categories under Places; hidden otherwise.
    /// Internal (not private) only for the +QA hooks.
    let subFilterBar = MapSubFilterBarView()
    /// Vertical stack of [subFilterBar, filterBar]: hiding an arranged
    /// subview animates as a smooth collapse, and the main bar keeps its seat
    /// above the tab bar (it's the stack's bottom edge that is pinned).
    /// Internal (not private) only for the +QA hooks.
    let barsStack = UIStackView()
    /// The row above the filter bars: the locate button, or the "See posts
    /// around you" card while nothing is open (guest mode §3.1).
    let locationControls = MapLocationControlsView()

    // MARK: The text bubble (#2203; every build since #2299)

    /// The text marker nearest the map's centre opens a bubble round it with
    /// its author and words (`MapTextBubbleView`).
    /// The marker the bubble speaks for.
    var textBubbleFeatured: (any MKAnnotation)?
    /// The text posts' words, as they arrive.
    var textBubblePosts: [PostID: GalleryPost] = [:]
    /// The bubble's next pick, waiting for the map to rest a moment.
    var textBubbleSettle: DispatchWorkItem?
    /// The posts' words, asked for together; and one already in hand.
    let loadTextPosts: ([PostID]) async -> [PostID: GalleryPost]
    let heldTextPost: (PostID) -> GalleryPost?
    /// A tap asked where the device is: fly to its country once it is known.
    var fliesToCurrentCountry = false

    // MARK: Guest location lock (#564)

    /// A guest without location roams the world at country level (#1907,
    /// `MapDepthClamp`), with the bar's "Allow location" as the way out
    /// (`GuestLocationOffering`). See `guestLocationLocked(isMember:permission:)`.
    var isGuestLocked = false
    /// Told when the guest's location offer comes or goes (#1907).
    var onGuestLocationOfferChange: ((Bool) -> Void)?
    /// The dark veil over the locked map, above the map and below the bars, so
    /// the location card stays on top of it.
    /// The deepest band the viewer may reach (#1907): the country band for
    /// a guest without location, everything otherwise.
    lazy var depthClamp = MapDepthClamp(mapView: mapView)
    /// The world view is framed once the map has a size: framed in
    /// `viewDidLoad`, before it has one, MapKit picks a continent instead.
    var needsWorldView = false
    /// The bars' offset from the view's raw bottom edge; see `syncBarsPosition`.
    var barsBottomConstraint: NSLayoutConstraint!
    /// In-flight people fetch for the sub-filter row; superseded on every
    /// primary change so a slow list can't populate a stale row.
    var subFilterLoadTask: Task<Void, Never>?
    /// Logical sub-filter-bar visibility — tracked separately from
    /// `isHidden`, which lags behind during the fade-out.
    var isSubFilterBarVisible = false
    /// The row's session memory — the people caches, the viewer's order and
    /// deletions per primary, the mutes — and its pure rules
    /// (`MapSubFilterRowMemory`).
    var subFilterMemory = MapSubFilterRowMemory()
    /// The dock's and the rows' people on the device (#1776): the screen
    /// opens on them, then revalidates. Set by the builder before the view
    /// loads; nil keeps them for the session.
    var peopleCache: MapPeopleLocalCache?
    /// What the people row is currently SHOWING — the yardstick a refresh
    /// measures itself against. Nil whenever the row holds something else
    /// (place categories) or nothing at all.
    var renderedSubFilterRow: MapSubFilterRowState?
    /// The raw pin model, updated from each diff. Clustering is computed from
    /// this: the map itself never holds raw pins, only the engine's markers, so
    /// the query/diff layer stays a pure model feed with no MapKit coupling.
    var pins: [PostID: MapPin] = [:]
    /// The engine's markers currently on the map, keyed by a stable identity: a
    /// `MapAnnotation` single keys off its post id (`p:<id>`), a
    /// `MapComputedCluster` off a synthetic id (`c:<n>`) it keeps for life so it
    /// survives representative churn (see `reconcileClusters`). Excludes markers
    /// mid fade-out — those live in the pop choreographer until it retires them.
    var displayed: [String: MKAnnotation] = [:]
    /// Marker collision size in screen points — the pin footprint plus a hair
    /// of margin, so two markers that would touch are grouped instead.
    static let clusterCellPoints = MapAnnotationView.side + 8
    /// Mints stable, content-free identities for cluster markers. A cluster's
    /// natural id (its representative) churns as the Top-K set shifts; a marker
    /// keeps this synthetic id for its whole life on the map instead
    /// (see `reconcileClusters` / `MapClusterTracker`).
    var clusterMarkerSeq = 0
    /// Which band markers the last layout hid behind a stronger neighbour —
    /// the engine's hysteresis memory, handed back on every reconcile (see
    /// `MapClusterEngine.Occlusion`).
    var bandOcclusion = MapClusterEngine.Occlusion()

    /// Debounce so a continuous pan fires one query on settle, not per frame.
    var pendingQuery: DispatchWorkItem?
    static let settleDelay: TimeInterval = 0.25

    /// True between `regionWillChange` and `regionDidChange` — i.e. while a
    /// zoom/pan is animating. The cluster layout depends on the zoom level, so
    /// it is recomputed on the settle, not mid-flight.
    var isRegionTransitioning = false
    /// A diff folded into the model during a transition still owes a layout;
    /// this asks the settle to run one.
    var layoutPending = false
    /// The SNAPPED zoom the last settle-driven reconcile ran at, and when it
    /// ran. Together they tell a pure pan from a zoom.
    ///
    /// ⚠️ Snapped zoom, not the region's span. `MKMapView` fits whatever span
    /// you hand `setRegion` to the view's aspect ratio, so `region.span` is
    /// never bit-identical to what was set and `==` on it is always false — the
    /// first version of this throttle fired exactly zero times for that reason,
    /// and read as "the optimisation does nothing" rather than "the predicate is
    /// broken". Snapped zoom is also the engine's ACTUAL input, so this asks the
    /// question that decides the layout instead of a proxy for it.
    var lastSettleSnappedZoom: Double?
    var lastSettleReconcileAt: CFTimeInterval = 0
    var trailingSettleReconcile: DispatchWorkItem?
    /// The floor between two settle-driven reconciles during a pure pan.
    /// 100 ms bounds the staleness at six frames, and a pure pan cannot change
    /// the layout anyway — see `reconcileClustersForSettle`.
    static let panReconcileInterval: CFTimeInterval = 0.1
    #if DEBUG
    /// Cheap "did the corpus move" probe for the churn readout only.
    var lastReconciledPinFingerprint = 0
    #endif
    /// The annotations THIS reconcile put on the map, awaiting their views.
    ///
    /// ⚠️ `didAdd` IS NOT "SOMETHING NEW HAPPENED". MapKit calls it for every
    /// view it realizes — including the whole visible set when the map comes
    /// back from a push — so popping in whatever it hands over meant the entire
    /// map scale-and-faded in again on every return, with nothing having
    /// changed. Only what this screen actually added is an arrival.
    var pendingPopIn: Set<ObjectIdentifier> = []

    /// A sensible default until location permission / deep-linking lands: central
    /// Paris at neighbourhood zoom (also where the mock dataset seeds its pins).
    /// Internal (not private) only for the +QA hooks.
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        span: MKCoordinateSpan(latitudeDelta: 0.09, longitudeDelta: 0.09)
    )

    init(
        viewModel: MapsViewModel,
        favoritesRepository: any MapFavoritesProviding,
        pinService: MapProfilePinService,
        imagePipeline: ImagePipeline,
        iconCatalog: (any AnimatedIconProviding)? = nil,
        previewCatalog: AnimatedIconCatalog? = nil,
        videoPlayback: VideoPlaybackController,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController,
        pushPlainSnapFeed: @escaping ([PostID], UIViewController, ((UIViewController) -> UIViewController)?) -> Void,
        makeRevealGeometry: @escaping
            (UIViewController, TextRevealOrigin, (() -> Void)?) -> RevealGeometry,
        makeClusterGallery: @escaping (
            [PostID], MapPlace, String, CLLocationCoordinate2D, UIViewController,
        @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
            ((UIViewController) -> RevealGeometry?)?
        ) -> UIViewController,
        prewarm: @escaping ([PostID]) async -> Void,
        warmPlayback: @escaping (PostID, TimeInterval?) -> (any FeedPlaybackWarm)? = { _, _ in nil },
        prerollPlayback: @escaping (PostID, TimeInterval?) -> (any FeedPlaybackWarm)? = { _, _ in nil },
        openProfile: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
        openConversation: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
        countryAccess: (any CountryAccess)? = nil,
        stakePacks: (any StakePackSelling)? = nil,
        profileItems: (any ProfileItemSelling)? = nil,
        isMember: @escaping @MainActor () -> Bool = { true },
        locator: (any CurrentCountryLocating)? = nil,
        loadTextPosts: @escaping ([PostID]) async -> [PostID: GalleryPost] = { _ in [:] },
        heldTextPost: @escaping (PostID) -> GalleryPost? = { _ in nil }
    ) {
        self.loadTextPosts = loadTextPosts
        self.heldTextPost = heldTextPost
        self.isMember = isMember
        self.locator = locator
        self.countryAccess = countryAccess
        self.stakePacks = stakePacks
        self.profileItems = profileItems
        self.viewModel = viewModel
        self.favoritesRepository = favoritesRepository
        self.pinService = pinService
        self.imagePipeline = imagePipeline
        self.iconCatalog = iconCatalog
        self.previewCatalog = previewCatalog
        self.videoCoordinator = MapVideoPlaybackCoordinator(pool: videoPlayback)
        self.videoPool = videoPlayback
        self.makeSnapFeed = makeSnapFeed
        self.pushPlainSnapFeed = pushPlainSnapFeed
        self.makeRevealGeometry = makeRevealGeometry
        self.makeClusterGallery = makeClusterGallery
        self.prewarm = prewarm
        self.warmPlayback = warmPlayback
        self.prerollPlayback = prerollPlayback
        self.openProfile = openProfile
        self.openConversation = openConversation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        installIconPolicyObserver()
        #if DEBUG
        installIconDebugHUD()
        installNavigationSweep()
        installNavigationDrag()
        installZoomSweep()
        #endif
        // No title, deliberately: the map is the tab's whole surface and
        // names itself; the header band belongs to its controls — the
        // compose "+", the wallet badge, the bell. (The tab bar still says
        // "Explore"; that label lives on `UITab`, not here.)
        // ⚠️ THE BAR WEARS A TRANSPARENT APPEARANCE, STATED. Every other
        // screen keeps UIKit's default and is bare because its list hides the
        // top edge effect (`prefersClearTopEdge`). This screen has no scroll
        // view for the bar to track — measured with a probe: no `UIScrollView`
        // under `MKMapView` on iOS 27, `contentScrollView(for: .top)` nil — and
        // with nothing to track UIKit fell back to the bar's own material: a
        // 116pt `_UIBarBackground` slab with a hard edge, the one header in
        // the app still wearing one. Stated transparent, the slab is gone.
        //
        // What remains under the status bar is MapKit's: `_MKMapContentView`
        // hosts a `ScrollEdgeEffectView` of its own (402x156, soft), with no
        // public switch — only private `_setScrollEdgeEffectViewInteraction…`
        // selectors, which this app does not call. Hidden by a class-name walk
        // in a probe it vanished, so that is the whole of the gradient; it is
        // MapKit's to draw and stays.
        let bare = UINavigationBarAppearance()
        bare.configureWithTransparentBackground()
        navigationItem.standardAppearance = bare
        navigationItem.scrollEdgeAppearance = bare
        navigationItem.compactAppearance = bare
        configureMapView()
        bindViewModel()
        observeAppLifecycle()
        observeFavoriteChanges()
        observeDockedPlaces()
        restorePeople()
        loadFavorites()
        prefetchPeople()
        mapView.setRegion(Self.defaultRegion, animated: false)
        // The pins of the last viewports, on the first frame (#893): offline,
        // the map is not empty; online, the first query revalidates them in
        // place. Not under the locked guest veil, which shows no pins.
        if !isGuestLocked {
            viewModel.restoreStoredPins()
        }
        #if DEBUG
        runDebugLaunchHooks()
        #endif
    }

    override func viewDidLayoutSubviews() {
        #if DEBUG
        // ⚠️ Every pass, not once. `viewDidLoad` adds the map and its chrome
        // AFTER this HUD, so a single `addSubview` puts the instrument
        // underneath the thing it is instrumenting — and the failure looks like
        // the flag not working rather than like a z-order.
        if let iconDebugHUD { view.bringSubviewToFront(iconDebugHUD) }
        #endif
        super.viewDidLayoutSubviews()
        syncBarsPosition()
        frameWorldIfNeeded()
    }

    /// The bars' offset is DERIVED from the safe area, so it has to be
    /// recomputed whenever the safe area moves — not only when something else
    /// happens to schedule a layout pass.
    ///
    /// Measured: a feed pushed plainly hides the tab bar (bottom inset 83 → 34),
    /// the bars re-pin 49pt lower while the map is off screen, and the bar comes
    /// back on the completed pop — restoring the inset without invalidating this
    /// view's layout. Nothing then re-ran `syncBarsPosition`, so the map came
    /// back with its filter pills sitting exactly behind the restored tab bar:
    /// present, laid out, and invisible. The flight path never showed it: the
    /// bars' constant is frozen at its resting value for the whole flight.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncBarsPosition()
    }

    /// Re-pins the filter bars to the CURRENT safe area, but only while no hero
    /// flight is in progress — see `barsBottomConstraint` for why that matters.
    func syncBarsPosition() {
        guard activeTransition == nil else { return }
        let target = -(view.safeAreaInsets.bottom + Spacing.sm)
        // Guarded: assigning inside a layout pass schedules another one.
        guard abs(barsBottomConstraint.constant - target) > 0.01 else { return }
        barsBottomConstraint.constant = target
    }

    /// Ends every animation left frozen at `speed == 0` on `view` and its
    /// subviews, landing each on its model value.
    ///
    /// ⚠️ A FINGER-DRIVEN CLOSE LEFT THE WHOLE MAP DEAD TO TOUCH. A custom
    /// interactive pop runs UIKit's coordinated changes (the tab bar coming
    /// back, the safe area moving with it) inside a PAUSED animation context,
    /// and MapKit answers the inset change by adding its own
    /// `__mapkit_edgeInsetsSentinel` to the map's layer with those paused
    /// settings. UIKit resumes the animations it tracks when the transition
    /// finishes; this one it never resumes. A view with a UIKit animation in
    /// flight is not hit-tested into, so every touch on the map stopped at
    /// `MKMapView` itself and was never delivered — markers, pans, pinches,
    /// all of it, until relaunch. The chevron's pop is not interactive, its
    /// sentinel runs at speed 1 and is gone in 0.2 s, which is why only the
    /// grab broke the map. Measured 2026-09-26: speed 0, `fillMode` both,
    /// still attached seconds after `viewDidAppear`.
    ///
    /// Removing an animation reports it stopped to its delegate, which is what
    /// hands the map its touches back. Every transition is over by
    /// `viewDidAppear`, so nothing legitimately paused can be caught here.
    private static func releaseFrozenAnimations(in view: UIView) {
        let layer = view.layer
        for key in layer.animationKeys() ?? [] where layer.animation(forKey: key)?.speed == 0 {
            layer.removeAnimation(forKey: key)
        }
        for subview in view.subviews {
            releaseFrozenAnimations(in: subview)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A tab root always shows the bar (#769).
        ensureAppTabBarAsTabRoot()
        #if DEBUG
        debugOfferCountryIfRequested()
        #endif
        // Kick the first query; coalesces with any region-settle callback.
        scheduleQuery()
        // Any marker a departed flow concealed comes back now. The window
        // reveal hides the tapped marker and un-hides it on ITS return leg —
        // but a feed that dismissed INTO the place page never runs that leg,
        // and the page's own pop landed on a map missing its cluster
        // (recorded on video, 2026-08-31). Every transition is over by
        // `viewDidAppear`, so a blanket un-hide can't flash under a flying
        // card; a hero return has already un-hidden its own marker and this
        // is a no-op there.
        for annotation in mapView.annotations {
            mapView.view(for: annotation)?.isHidden = false
        }
        Self.releaseFrozenAnimations(in: mapView)
        // ⚠️ AND THE GATE, for the same reason and in the same place: every
        // transition is over by here. It is the backstop for endings nobody
        // wired — a place page popping home, a multi-pop, a cross-tab return —
        // and it is what makes a forgotten release a frame of dead map rather
        // than a session of it.
        openGate.appearedAtRoot()
        // WHEN ON THE MAP, THE TAB BAR IS ALWAYS THERE. The map is a tab ROOT:
        // there is no state in the product where an on-screen map has no dock
        // under it, so it asserts one rather than trusting whichever departing
        // flow was supposed to hand it back. The flows above hide the bar on
        // their way out and each restores it on exactly one of its several
        // endings; a path nobody wired — the place page popping home, which the
        // shell's restores skipped while it was read as a full-bleed surface —
        // left the map docked to nothing.
        //
        // `viewDidAppear` and NOT `viewWillAppear`: UIKit runs the latter at
        // interactive-pop BEGIN, so an unconditional restore there would show
        // the bar over the feed and strand it there when the grab is cancelled.
        // By here every transition is over and the assertion is safe.
        //
        // Through UIKit, on its animation, a turn later (an inline un-hide from
        // `viewDidAppear` was measured never to render) — and never an alpha:
        // native chrome is UIKit's (see `TabBarRevealPolicy`). Normally a
        // no-op: the feed's close has shown the bar already.
        barsStack.alpha = 1
        tabBarController?.showTabBarNativelyNextTurn()
        releaseStaleTransitionNextTurn()
    }

    /// ⚠️ THE BACKSTOP'S MISSING HALF. Everything above is put back on any
    /// return, whoever finished it — but not the flight itself. A return that
    /// reached neither `onSourceReturned` nor a close's `dismissalDidEnd` left
    /// `activeTransition` set for the rest of the session: the previews never
    /// resumed (`viewWillAppear` skips them while a flight is up) and the bars
    /// stayed frozen at their in-flight inset.
    ///
    /// A turn later, and only if still set: the normal close-outs run at the
    /// stack's `didShow`, which UIKit delivers AFTER this appearance, and
    /// releasing the controller before it would free it mid-callback.
    private func releaseStaleTransitionNextTurn() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let stale = activeSession,
                  let nav = navigationController, nav.topViewController === self,
                  nav.transitionCoordinator == nil
            else { return }
            stale.close(.abandoned)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Tab became frontmost: resume previews. NOT while a hero transition
        // is alive — under a push, this fires the moment a pop *begins*, and
        // an interactive grab can cancel; the completed return resumes via
        // the transition's onSourceReturned instead.
        // ⚠️ THE GATE IS NOT RELEASED HERE, and it used to be. UIKit runs
        // `viewWillAppear` at interactive-pop BEGIN, so from the first
        // millimetre of a grab until it was cancelled the map believed nothing
        // was open — a tap in that window opened a second post over the first.
        // `viewDidAppear` is where every transition is genuinely over, and this
        // file already says so three comments below for the tab bar.
        guard activeTransition == nil else {
            // A return, though, owes the bottom chrome back.
            //
            // The FILTER BARS are this screen's own views, inside its view:
            // back at full opacity now, where the flight's dim veils them and
            // the presenter's recede carries them — a fade of their own would
            // double the dim. Their constant was frozen at its resting value
            // for the flight (`syncBarsPosition`), so they already sit where the
            // dock will have them. A cancelled grab takes them down again.
            //
            // The TAB BAR is UIKit's: shown through its API, on its animation,
            // once the close is committed — at the release for a grab, after
            // the landing for a pop nobody announced. The feed asks for the
            // same thing itself (`SnapFeedViewController.revealDockBeforePop`);
            // whichever comes first shows it. See `TabBarRevealPolicy`.
            barsStack.alpha = 1
            revealBottomChromeWhenAllowed(returnsFromFullBleed: true) { [weak self] _ in
                self?.tabBarController?.showTabBarNatively()
            }
            return
        }
        // ⚠️ NOT UNDER A FINGER (#1594): a grab of the screen over the map
        // brings it back on the release that commits — see `MapPreviewResume`.
        let coordinator = transitionCoordinator
        MapPreviewResume.whenSettled(
            isInteractive: coordinator?.isInteractive ?? false,
            notifyWhenInteractionEnds: { ended in
                coordinator?.notifyWhenInteractionChanges { context in ended(context.isCancelled) }
            },
            resume: { [weak self] in self?.resumePreviews() }
        )
    }

    /// The map's previews back on: the surface shown, playback refreshed, the
    /// idle preroll armed.
    private func resumePreviews() {
        videoCoordinator.setSurfaceVisible(true)
        idlePrerollRested = false
        refreshVideoPlayback()
        scheduleIdlePreroll()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tab hidden: stop previews. During a feed push this is a no-op —
        // presentSnapFeed already covered the surface (keeping the donor).
        guard activeTransition == nil else { return }
        videoCoordinator.setSurfaceVisible(false)
        endIdlePreroll()
    }

    /// Re-reads the people rail whenever the pinned set changes — including
    /// when it changed on ANOTHER screen. A profile's pin button writes the
    /// same store, and this map may already be loaded behind it: without this
    /// the rail would keep yesterday's list until the tab was rebuilt, which
    /// reads as the button having done nothing.
    private func observeFavoriteChanges() {
        appObservers.add(NotificationCenter.default.addObserver(
            forName: MapFavoritesStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Read the category HERE, off the notification, rather than
            // carrying the notification across the isolation hop: a
            // `Notification` is not `Sendable`, its category is.
            let changed = MapFavoritesStore.changedCategory(in: notification)
            // ⚠️ ONLY the surface that shows the rail that changed.
            //
            // The dock's carousel and the sub-filter row are different lists
            // in different bars, and waking both on every write meant editing
            // one rebuilt the other — a carousel that flashed because someone
            // was removed from a row it does not show.
            MainActor.assumeIsolated {
                guard let self else { return }
                switch changed {
                case .dock:
                    self.loadFavorites()
                case .friends, .following:
                    // ...and only when that rail is the one on screen.
                    guard let primary = self.filterBar.selectedFilter,
                          MapSubFilterRowMemory.railCategory(for: primary) == changed else { return }
                    self.updateSubFilterBar(for: primary)
                case nil:
                    // Not one of ours (or a post carrying no category):
                    // refresh both rather than guess wrong. Both surfaces
                    // refuse an update that would not change them, so the
                    // cost of being cautious here is a comparison.
                    self.loadFavorites()
                    self.filterBar.selectedFilter.map { self.updateSubFilterBar(for: $0) }
                }
            }
        })
        // Followed PLACES are a different store with one consumer here: the
        // Places row's Favorites refinement. A gallery header's toggle writes
        // it while this map sits loaded beneath the whole Case-B stack, so
        // popping back must find the refinement re-applied, not yesterday's
        // pins. The view model no-ops unless that refinement is active.
        appObservers.add(NotificationCenter.default.addObserver(
            forName: MapPlaceFollowStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewModel.followedPlacesChanged() }
        })
    }

    // MARK: - Docked places (#1598)

    /// The places pinned from their page, in the dock after the people.
    private func loadDockedPlaces() {
        filterBar.setDockedPlaces(isMember() ? dockedPlaces.entries : [])
    }

    /// Any screen's pin (the place page's row) re-reads the dock; a tap on
    /// a docked place flies the map there.
    private func observeDockedPlaces() {
        filterBar.onPlaceTapped = { [weak self] entry in self?.fly(to: entry) }
        loadDockedPlaces()
        appObservers.add(NotificationCenter.default.addObserver(
            forName: MapDockedPlacesStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadDockedPlaces() }
        })
    }

    /// Flies to a docked place: a country framed as the shop frames it (its
    /// offer when locked), a city centred at the city band.
    private func fly(to entry: MapDockedPlacesStore.Entry) {
        guard let url = URL(string: entry.url), let link = PlaceLink(url: url) else { return }
        switch link {
        case .country(let code):
            showCountry(code)
        case .city(let latitude, let longitude, _, _):
            let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            // The map's own neighbourhood zoom, the one it opens at.
            mapView.setRegion(MKCoordinateRegion(center: centre, span: Self.defaultRegion.span), animated: true)
        }
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        appObservers.add(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.videoCoordinator.setSurfaceVisible(false)
                self?.endIdlePreroll()
            }
        })
        appObservers.add(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Back from Settings with location allowed: unlocked (#564).
                self?.updateGuestLock(animated: true)
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.videoCoordinator.setSurfaceVisible(true)
                self.refreshVideoPlayback()
            }
        })
    }

    private func configureMapView() {
        mapView.delegate = self
        // Once, and never again — see `MapBaseConfiguration`.
        mapView.preferredConfiguration = MapBaseConfiguration.make()
        mapView.showsCompass = true
        mapView.register(
            MapAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MapAnnotationView.reuseIdentifier
        )
        mapView.register(
            MapClusterAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MapClusterAnnotationView.reuseIdentifier
        )
        mapView.pin(to: view)
        #if DEBUG
        installChromeTrace()
        #endif
        configureFilterBar()
        configureCountries()
    }

    // MARK: - Pill menu destinations — state here, behaviour in `MapsViewController+PillMenu.swift`
    var favoritesRetries = 0

    // MARK: - The picture the viewer is leaving

    /// What a flight home to `annotation` has to dissolve away, asked when the
    /// dismissal stages.
    ///
    /// The ARRIVAL is `postIDs(of:).first` — the marker's representative, which
    /// is also the post the flight opened from, because that is the order the
    /// feed was seeded in. The map never substitutes: the marker the viewer
    /// tapped has not moved and is what they expect to fall back onto, so what
    /// adapts is the card's departure face, never its landing.
    func returnCover(
        to annotation: any MKAnnotation, leaving feed: UIViewController?
    ) -> MapReturnCover {
        let settled = feed as? any SnapFeedSettleReporting
        let departure = settled?.settledPostID
        let arrival = Self.postIDs(of: annotation).first
        let cover = MapReturnCover.resolve(
            departure: departure,
            arrival: arrival,
            mediaPage: settled?.settledMediaPage,
            // ⚠️ THE FEED'S OWN STILL FIRST, and the map's thumbnail only as a
            // fallback.
            //
            // Both are "the departure's picture" and they are not
            // interchangeable in the card. The card takes off FULL SCREEN and
            // aspect-fills whatever it is handed: the page's own still is
            // already that shape, so it lands 1:1 and reads as the picture the
            // viewer is looking at, anchored in the window. A marker's
            // thumbnail is a small square — filled into a 402x874 card it is a
            // magnified fragment, which is the crop this was reported as.
            //
            // The fallback still earns its place, though it earns it less
            // often than it used to: a video page answers now, so what is left
            // here is a text page and an unrealized cell, where a marker's
            // cover is better than nothing.
            picture: { [weak self] id in
                settled?.settledCoverImage ?? self?.cachedPicture(for: id)
            }
        )
        #if DEBUG
        // `-zoom-blend-log`: which row of the product rule this flight took.
        //
        // Worth a channel of its own because the rows fail in opposite,
        // equally quiet ways — `none` where a blend was due is a cut nobody
        // reads as a bug, and a blend where `none` was due is a slightly soft
        // landing. The ids are printed too: a `none` is only correct if the
        // two of them actually match.
        if ProcessInfo.processInfo.arguments.contains("-zoom-blend-log") {
            print("[zoom-blend] departure=\(departure?.rawValue ?? "nil")"
                + " arrival=\(arrival?.rawValue ?? "nil") cover=\(cover.debugRow)")
        }
        #endif
        return cover
    }

    /// A post's cover, if it is already in memory.
    ///
    /// A rendered marker first: it holds the decoded image the viewer has been
    /// looking at, and reading it costs nothing. Otherwise the pipeline's cache,
    /// which is a peek and never a fetch — resolving a cover is on the first
    /// frame of a gesture, and a flight that waited on the network would stall
    /// under the finger.
    private func cachedPicture(for postID: PostID) -> UIImage? {
        if let annotation = displayed[Self.singleIdentity(postID)],
           let view = mapView.view(for: annotation),
           let image = (view as? MapAnnotationView)?.heroImage {
            return image
        }
        guard let url = pins[postID]?.thumbnailURL else { return nil }
        return imagePipeline.cachedImage(for: url)
    }

    /// The same answer, allowed to take as long as a fetch — the row
    /// `cachedPicture` had to decline.
    ///
    /// Every member of a cluster is a post the map knows the URL of, but only
    /// the representative ever had a marker, so the others were never fetched:
    /// paging into one and dismissing is precisely the case that comes back
    /// empty. Reports at most once, and only if it actually got a picture, so
    /// the flight's own `none` stands when this comes back with nothing.
    func awaitReturnCover(
        to annotation: any MKAnnotation,
        leaving feed: UIViewController?,
        then report: @escaping (MapReturnCover) -> Void
    ) {
        guard let departure = (feed as? any SnapFeedSettleReporting)?.settledPostID,
              departure != Self.postIDs(of: annotation).first,
              pins[departure]?.isText == false,
              let url = pins[departure]?.thumbnailURL
        else { return }
        Task { [imagePipeline] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            report(.picture(image))
        }
    }

    /// Re-points and re-faces a marker already on the map for a recomputed item.
    func update(_ annotation: any MKAnnotation, to item: MapClusterEngine.Item) {
        if let cluster = annotation as? MapComputedCluster {
            cluster.apply(item)
            (mapView.view(for: cluster) as? MapClusterAnnotationView)?
                .configure(
                    with: cluster, dress: dress(for: cluster), imagePipeline: imagePipeline,
                    iconCatalog: iconCatalog, previewCatalog: previewCatalog
                )
        } else if let single = annotation as? MapAnnotation {
            single.update(pin: item.representative)
            single.hierarchyPlace = item.hierarchyPlace
            (mapView.view(for: single) as? MapAnnotationView)?
                .configure(
                    with: item.representative, dress: dress(for: single), imagePipeline: imagePipeline,
                    iconCatalog: iconCatalog, previewCatalog: previewCatalog
                )
        }
        textBubbleMarkerChanged(annotation)
    }

    /// Screen points per map point at the current region — the projection the
    /// engine grids in. Guarded so a zero-width rect (before first layout)
    /// can't divide by zero.
    var currentZoomScale: Double {
        let mapWidth = mapView.visibleMapRect.size.width
        guard mapWidth > 0 else { return 0 }
        return Double(mapView.bounds.width) / mapWidth
    }

    /// The camera viewport's diagonal in km — what the dynamic hierarchy
    /// banding compares H3 cell spans against. Flat-earth arithmetic (111 km
    /// per degree, longitude scaled by the latitude's cosine) is exact
    /// enough at banding scales.
    var currentViewportDiagonalKm: Double {
        MapDepthClamp.diagonalKm(of: mapView.region)
    }

}

extension MapsViewController {
    /// Re-dresses every icon-bearing marker when the device changes its motion
    /// policy — Low Power on or off, Reduce Motion on or off, thermal pressure.
    ///
    /// ⚠️ RE-CONFIGURES rather than reinstalling. A "reinstall if not already
    /// running" guard can only ever PROMOTE a marker, so it silently ignores
    /// every change INTO Low Power or Reduce Motion, which is the direction
    /// that matters. Clearing `representedID` first is what makes `configure`
    /// do its work instead of early-returning on an unchanged pin.
    fileprivate func installIconPolicyObserver() {
        guard iconCatalog != nil else { return }
        for token in AnimatedIconView.observePolicyChanges({ [weak self] in
            guard let self else { return }
            for annotation in self.mapView.annotations {
                (self.mapView.view(for: annotation) as? MapAnnotationView)?.redressIcon()
                (self.mapView.view(for: annotation) as? MapClusterAnnotationView)?.redressIcon()
            }
        }) {
            iconPolicyBag.add(token)
        }
    }
}

#if DEBUG
// MARK: - QA wrappers
//
// Thin doors for `MapsViewController+QA.swift` onto methods with side effects,
// which stay private.
extension MapsViewController {
    func debugUpdateSubFilterBar(for filter: MapFilter?) { updateSubFilterBar(for: filter) }
    func debugPresentSubFilterSheet() { presentSubFilterSheet() }
    func debugTogglePinnedFavorite(_ favorite: MapFavorite) { togglePinnedFavorite(favorite) }
    func debugShowCountry(_ code: String) { showCountry(code) }
    func debugOffer(_ country: CountryAtlas.Country) { offer(country) }
    func debugBeginPlaybackWarm(for annotation: MapAnnotation) { beginPlaybackWarm(for: annotation) }
    func debugGateAppearedAtRoot() { openGate.appearedAtRoot() }
}
#endif

extension MapsViewController: GuestLocationOffering {
    var offersGuestLocation: Bool { isGuestLocked }

    func allowGuestLocation() {
        guard let permission = locator?.permission else { return }
        locationControlTapped(permission)
    }
}

extension MapsViewController: MapViewerRefreshing {
    /// Signed in or out: the dock and the people rows were someone else's.
    func viewerDidChange() {
        // A guest who signed up while locked: unlocked at once (#564).
        updateGuestLock(animated: true)
        subFilterMemory.forgetPeople()
        loadFavorites()
        // The docked places are the profile's own too (#1598).
        loadDockedPlaces()
        prefetchPeople()
    }
}
