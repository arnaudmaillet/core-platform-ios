import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
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
    private let viewModel: MapsViewModel
    /// Sources the filter bar's scrollable favorites section (fail-open:
    /// empty just hides the section).
    private let favoritesRepository: any MapFavoritesProviding
    private var favoritesTask: Task<Void, Never>?
    /// Reads and writes the pinned set behind the favorites section — the one
    /// place the never-curated fallback is resolved, shared with the profile
    /// screen's pin button so the two cannot disagree about what a pin means.
    private let pinService: MapProfilePinService
    /// What the favorites section currently shows — the seed material when a
    /// first pin/unpin materializes the store from the fallback.
    private var currentFavorites: [MapFavorite] = []
    /// What the sub-filter row currently shows — the full-list sheet's data.
    private var currentSubFilterOptions: [MapSubFilterOption] = []
    private let imagePipeline: ImagePipeline
    /// The baked animated-icon catalogue, or `nil` where the surface has none.
    ///
    /// Separate from `imagePipeline` on purpose. Icons are decoded WHOLE
    /// (downsampling a sprite grid lands every frame boundary mid-pixel) and
    /// budgeted by BYTES rather than by count (a sheet is up to 1.7 MB, so the
    /// pipeline's `countLimit = 300` would never evict), and they must not go
    /// through `decodeDownsampled` at all — that call never returns on HEIC
    /// under concurrent load in the iOS 26 simulator.
    private let iconCatalog: (any AnimatedIconProviding)?
    /// Baked previews of a MEDIA post's own footage — the decode-session-free
    /// alternative to attaching a player. Separate catalogue from the icons'
    /// because the two have different cell sizes and very different byte costs
    /// (2.71 MB resident per preview against 0.07 MB per icon), so one budget
    /// could not serve both without the cheap one being evicted by the dear one.
    private let previewCatalog: AnimatedIconCatalog?
    /// Re-dresses every marker when the device changes its motion policy.
    ///
    /// ⚠️ Read at INSTALL time, so this is not optional: without it a field
    /// dressed before the user enabled Low Power keeps animating at full rate
    /// for the rest of the session — the exact failure the setting exists to
    /// prevent. And it must RE-DRESS rather than "reinstall if not running",
    /// which can only promote a marker and never demote one.
    private let iconPolicyBag = MapNotificationBag()
    #if DEBUG
    /// Kept only so the debug readout can distinguish DECODERS from surfaces.
    private var videoPool: VideoPlaybackController?
    #endif
    #if DEBUG
    private var iconDebugHUD: MapIconDebugHUD?
    #endif
    /// Builds the snap feed a pin/cluster tap expands into (reuses the Feed
    /// feature via `FeedFeatureBuilding.makeSnapFeedViewController`).
    private let makeSnapFeed: ([PostID]) -> UIViewController
    /// Pushes that same feed with the platform's own slide, for a marker with
    /// nothing to fly. Goes through the feed's `pushSnapFeed` seam rather than
    /// this controller calling `pushViewController` itself: the pushed feed
    /// refuses the stack's native edge pop, so the swipe-back has to be
    /// attached and retained with it, and that belongs where the other two
    /// surfaces already get it.
    private let pushPlainSnapFeed: ([PostID], UIViewController) -> Void
    /// Pushes the feed as a WINDOW growing out of a marker — the text pin's
    /// path. Injected like its plain sibling, and for the same reason: the
    /// pushed screen's gestures and its transition are the feed's own. The
    /// last argument builds the screen a VERTICAL dismissal lands on (the
    /// semantic cluster's place page), or `nil` for a plain marker.
    private let revealSnapFeed: (
        [PostID], UIViewController, TextRevealOrigin,
        ((UIViewController) -> UIViewController)?
    ) -> Void
    /// The same window built for a CLOSE, pushing nothing — what a feed opened
    /// by a hero uses when the viewer has paged onto a post it cannot fly.
    /// Injected like its push-shaped sibling: Maps depends on FeedInterface and
    /// never on Feed.
    private let makeRevealGeometry:
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
    /// flag and subtitle; the last argument stages the page's OWN dismissal
    /// back to the cluster marker (`makeMapReturnSource`).
    private let makeClusterGallery: (
        [PostID], MapPlace, String, UIViewController,
        @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
        ((UIViewController) -> RevealGeometry?)?
    ) -> UIViewController
    /// Warms the given posts into the shared cache so a tap opens instantly.
    private let prewarm: ([PostID]) async -> Void
    /// Opens someone's profile (the sub-filter sheet's Profile swipe). A
    /// closure, not a router: the Maps package stays navigation-agnostic —
    /// the shell decides that this means the `.profile` route, exactly as it
    /// does for the avatar and compose bar items.
    private let openProfile: (ProfileID, ProfileIdentityStub?) -> Void
    /// Starts (or resumes) a thread with someone the map surfaces — the pill
    /// menu's Send Message. Injected for the same reason as `openProfile`:
    /// Maps stays ignorant of routes and of the Messages feature.
    private let openConversation: (ProfileID) -> Void
    /// The current viewport's prefetch, cancelled when the map settles elsewhere.
    private var prewarmTask: Task<Void, Never>?
    /// Starts a post's page player at touch-down on its marker (#646).
    private let warmPlayback: (PostID, TimeInterval?) -> (any FeedPlaybackWarm)?
    /// The player a finger on a marker started, until the post opens or the
    /// touch gives up.
    private var playbackWarm: (postID: PostID, warm: any FeedPlaybackWarm)?
    /// How long a touch that ended without opening keeps its warm player: the
    /// tap is recognised on touch-up, in the same turn or the next.
    static let warmOpenWindow: TimeInterval = 0.6
    /// Prerolls ONE post page player, paused on its first frame (#654).
    private let prerollPlayback: (PostID, TimeInterval?) -> (any FeedPlaybackWarm)?
    /// The one prerolled player: the marker nearest the centre at the last
    /// idle settle. Promoted to `playbackWarm` when that marker is touched.
    private var idlePreroll: (postID: PostID, warm: any FeedPlaybackWarm)?
    private var idlePrerollWork: DispatchWorkItem?
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
    private var idlePrerollExpiry: DispatchWorkItem?
    /// Set when a preroll timed out; cleared by the next settle or return, so
    /// a map left alone is not re-prerolled every 20 s by stray refreshes.
    private var idlePrerollRested = false
    /// Tries left this rest when the feed had nothing to preroll yet — the
    /// map warms its visible posts' data on the same settle, so the first ask
    /// can beat it (measured: `hydrated=false`, then nothing for 25 s).
    private var idlePrerollRetries = 0
    static let idlePrerollRetryLimit = 3
    static let idlePrerollRetryDelay: TimeInterval = 1.5
    /// Runaway guard: clustering already bounds the visible set to a handful, but
    /// cap the sweep in case it runs during a pre-cluster frame.
    private static let prewarmCap = 16
    /// Read once: `reconcileClustersForSettle` runs on every settle, in release too.
    private static let reconcileThrottleEnabled = ProcessInfo.processInfo.arguments.contains("-maps-reconcile-throttle")
    /// The flight in progress, held for its life; its close-out is the
    /// session's (`HeroPushSession`).
    private var activeSession: HeroPushSession?
    /// The "one flight at a time" latch, and the flight's controller.
    private var activeTransition: ZoomTransitionController? { activeSession?.controller }
    /// The card-shaped close that rides alongside the flight, for the posts
    /// the flight cannot carry (see `attachCardCloseAlongsideFlight`). Held
    /// because `UINavigationController.delegate` is weak and nothing else
    /// would keep this driver alive to see its own swipe; released by its
    /// `onFeedPopped`.
    private var cardClose: InteractiveSlideDismissal?
    /// True from the moment a plain push is fired until the map is back on
    /// screen. It does for that path exactly what `activeTransition` does for
    /// the flight: the instant-tap recognizer and MapKit's own `didSelect` can
    /// both fire for ONE tap, and without a guard the second one pushes a
    /// second copy of the feed.
    /// Whether the map may be touched, and whether a tap may open anything —
    /// see `MapOpenGate`. It replaces two booleans that were set in three
    /// branches and released from five unrelated places, and it is the ONLY
    /// thing that writes the map's interaction.
    private var openGate = MapOpenGate() {
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
    private let videoCoordinator: MapVideoPlaybackCoordinator
    /// Runs the pins' staggered pop-in/pop-out and owns the in-flight
    /// animators — including the marker-reclaim that keeps a fast filter
    /// flip-flop from doubling a pin (see `MapAnnotationPopChoreographer`).
    private lazy var popChoreographer = MapAnnotationPopChoreographer(mapView: mapView)
    private let appObservers = MapNotificationBag()
    #if DEBUG
    private var didDebugOpenPin = false
    #if DEBUG
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
    private var soakCyclesRemaining = 0
    private var soakCursor = 0
    /// Bumped every time a cycle starts, so a watchdog can tell "still on the
    /// cycle I was watching" from "already moved on".
    private var soakGeneration = 0
    /// One pending re-check at a time, so a shut gate cannot stack timers.
    private var soakRetryScheduled = false
    #endif
    #endif

    private let mapView = MKMapView()
    /// The world's country borders and the chosen one — see `CountryLayer`.
    private let countryLayer = CountryLayer()
    /// Which countries this account has unlocked — only their posts are on
    /// the map. Nil: every country is open (the fleet, until the backend
    /// carries unlocks).
    private let countryAccess: (any CountryAccess)?
    /// Where the device is: the locate button and the "See posts around you"
    /// card (`MapLocationControls`). Nil shows neither.
    private let locator: (any CurrentCountryLocating)?
    /// What the Shop's Boosts sells (the ×100 cartridge pack); nil sells none.
    private let stakePacks: (any StakePackSelling)?
    /// Whether the viewer has an account. A guest follows no one, so the
    /// favourites dock and the people rows stay empty for them.
    private let isMember: @MainActor () -> Bool
    /// The country each pin stands in, looked up once per post: the atlas
    /// test is point-in-polygon, and the reconcile runs on every settle.
    private var pinCountries: [PostID: String] = [:]
    /// A pick waiting to become a flight and an offer (`mapTapped`).
    private var pendingOffer: DispatchWorkItem?
    /// The open offer, if any.
    /// The marker the instant tap just opened, and when: MapKit's own
    /// selection of it lands about 0.3 s later and must not open it twice (#760).
    private var instantTap: (annotation: ObjectIdentifier, at: CFTimeInterval)?

    private weak var offerSheet: CountryUnlockSheetViewController?
    /// Where the map was before the offer flew it to its country.
    private var offerCamera: MKMapCamera?
    /// Whether closing the offer flies the map back to `offerCamera`.
    private var offerReturns = true
    /// The open offer's close has already flown the map back — a cancelled
    /// close then frames the country again.
    private var offerFlewBack = false
    /// The filter-pill carousel floating above the tab bar. The map's first
    /// bottom overlay: pinned to the safe area (the map itself is full-bleed
    /// and draws under the floating tab bar).
    private let filterBar = MapFilterBarView()
    /// The dynamic refinement row directly above `filterBar` — people under
    /// Friends/Following, place categories under Places; hidden otherwise.
    private let subFilterBar = MapSubFilterBarView()
    /// Vertical stack of [subFilterBar, filterBar]: hiding an arranged
    /// subview animates as a smooth collapse, and the main bar keeps its seat
    /// above the tab bar (it's the stack's bottom edge that is pinned).
    private let barsStack = UIStackView()
    /// The row above the filter bars: the locate button, or the "See posts
    /// around you" card while nothing is open (guest mode §3.1).
    private let locationControls = MapLocationControlsView()
    /// A tap asked where the device is: fly to its country once it is known.
    private var fliesToCurrentCountry = false

    // MARK: Guest location lock (#564)

    /// A guest without location sees a locked showcase: the whole world under
    /// a dark veil, nothing to pan, zoom or tap — only the "See posts around
    /// you" card above it. See `guestLocationLocked(isMember:permission:)`.
    private(set) var isGuestLocked = false
    /// The dark veil over the locked map, above the map and below the bars, so
    /// the location card stays on top of it.
    private let guestVeil = UIView()
    /// The world view is framed once the map has a size: framed in
    /// `viewDidLoad`, before it has one, MapKit picks a continent instead.
    private var needsWorldView = false
    /// The bars' offset from the view's raw bottom edge; see `syncBarsPosition`.
    private var barsBottomConstraint: NSLayoutConstraint!
    /// In-flight people fetch for the sub-filter row; superseded on every
    /// primary change so a slow list can't populate a stale row.
    private var subFilterLoadTask: Task<Void, Never>?
    /// Logical sub-filter-bar visibility — tracked separately from
    /// `isHidden`, which lags behind during the fade-out.
    private var isSubFilterBarVisible = false
    /// Session cache of the people rows, prefetched at screen load so a
    /// primary tap renders its sub-filter row SYNCHRONOUSLY — the row must
    /// never wait on the social graph. Keyed by `.friends` / `.following`.
    private var peopleCache: [MapFilter: [MapFavorite]] = [:]
    /// Everyone a primary COULD offer — the social graph behind it, ignoring
    /// curation. Kept apart from `peopleCache` since the rails became curated
    /// lists: the row is what the viewer kept, the catalogue is what the
    /// sheet offers them to add back, and an empty row must still be able to
    /// present a full sheet.
    private var catalogueCache: [MapFilter: [MapFavorite]] = [:]
    /// What the people row is currently SHOWING — the yardstick a refresh
    /// measures itself against. Nil whenever the row holds something else
    /// (place categories) or nothing at all.
    private var renderedSubFilterRow: MapSubFilterRowState?
    /// The viewer's manual sub-filter order per primary, set by dragging rows
    /// in the full-list sheet. Session-scoped: it outlives primary switches
    /// and background refreshes, not the process.
    private var subFilterOrder: [MapFilter: [MapSubFilter]] = [:]
    /// Refinements deleted in the sheet's edit mode, per primary — the social
    /// graph still returns them, so the row has to remember they're gone.
    private var subFilterHidden: [MapFilter: Set<MapSubFilter>] = [:]
    /// Accounts muted from the sheet's swipe action. Session-local, like the
    /// conversation list's mute: `social_graph.v1` has no mute concept, and
    /// muting can't filter the map either until `RadarPin` carries an author
    /// id (the same Phase-2 gate as the filter header). Today it marks the
    /// row, and nothing more — a deliberately honest half of the feature.
    private var mutedProfiles: Set<ProfileID> = []
    /// The raw pin model, updated from each diff. Clustering is computed from
    /// this: the map itself never holds raw pins, only the engine's markers, so
    /// the query/diff layer stays a pure model feed with no MapKit coupling.
    private var pins: [PostID: MapPin] = [:]
    /// The engine's markers currently on the map, keyed by a stable identity: a
    /// `MapAnnotation` single keys off its post id (`p:<id>`), a
    /// `MapComputedCluster` off a synthetic id (`c:<n>`) it keeps for life so it
    /// survives representative churn (see `reconcileClusters`). Excludes markers
    /// mid fade-out — those live in the pop choreographer until it retires them.
    private var displayed: [String: MKAnnotation] = [:]
    /// Marker collision size in screen points — the pin footprint plus a hair
    /// of margin, so two markers that would touch are grouped instead.
    private static let clusterCellPoints = MapAnnotationView.side + 8
    /// Mints stable, content-free identities for cluster markers. A cluster's
    /// natural id (its representative) churns as the Top-K set shifts; a marker
    /// keeps this synthetic id for its whole life on the map instead
    /// (see `reconcileClusters` / `MapClusterTracker`).
    private var clusterMarkerSeq = 0
    /// Which band markers the last layout hid behind a stronger neighbour —
    /// the engine's hysteresis memory, handed back on every reconcile (see
    /// `MapClusterEngine.Occlusion`).
    private var bandOcclusion = MapClusterEngine.Occlusion()

    /// Debounce so a continuous pan fires one query on settle, not per frame.
    private var pendingQuery: DispatchWorkItem?
    private static let settleDelay: TimeInterval = 0.25

    /// True between `regionWillChange` and `regionDidChange` — i.e. while a
    /// zoom/pan is animating. The cluster layout depends on the zoom level, so
    /// it is recomputed on the settle, not mid-flight.
    private var isRegionTransitioning = false
    /// A diff folded into the model during a transition still owes a layout;
    /// this asks the settle to run one.
    private var layoutPending = false
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
    private var lastSettleSnappedZoom: Double?
    private var lastSettleReconcileAt: CFTimeInterval = 0
    private var trailingSettleReconcile: DispatchWorkItem?
    /// The floor between two settle-driven reconciles during a pure pan.
    /// 100 ms bounds the staleness at six frames, and a pure pan cannot change
    /// the layout anyway — see `reconcileClustersForSettle`.
    private static let panReconcileInterval: CFTimeInterval = 0.1
    #if DEBUG
    /// Cheap "did the corpus move" probe for the churn readout only.
    private var lastReconciledPinFingerprint = 0
    #endif
    /// The annotations THIS reconcile put on the map, awaiting their views.
    ///
    /// ⚠️ `didAdd` IS NOT "SOMETHING NEW HAPPENED". MapKit calls it for every
    /// view it realizes — including the whole visible set when the map comes
    /// back from a push — so popping in whatever it hands over meant the entire
    /// map scale-and-faded in again on every return, with nothing having
    /// changed. Only what this screen actually added is an arrival.
    private var pendingPopIn: Set<ObjectIdentifier> = []

    /// A sensible default until location permission / deep-linking lands: central
    /// Paris at neighbourhood zoom (also where the mock dataset seeds its pins).
    private static let defaultRegion = MKCoordinateRegion(
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
        pushPlainSnapFeed: @escaping ([PostID], UIViewController) -> Void,
        revealSnapFeed: @escaping (
            [PostID], UIViewController, TextRevealOrigin,
            ((UIViewController) -> UIViewController)?
        ) -> Void,
        makeRevealGeometry: @escaping
            (UIViewController, TextRevealOrigin, (() -> Void)?) -> RevealGeometry,
        makeClusterGallery: @escaping (
            [PostID], MapPlace, String, UIViewController,
        @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
            ((UIViewController) -> RevealGeometry?)?
        ) -> UIViewController,
        prewarm: @escaping ([PostID]) async -> Void,
        warmPlayback: @escaping (PostID, TimeInterval?) -> (any FeedPlaybackWarm)? = { _, _ in nil },
        prerollPlayback: @escaping (PostID, TimeInterval?) -> (any FeedPlaybackWarm)? = { _, _ in nil },
        openProfile: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
        openConversation: @escaping (ProfileID) -> Void,
        countryAccess: (any CountryAccess)? = nil,
        stakePacks: (any StakePackSelling)? = nil,
        isMember: @escaping @MainActor () -> Bool = { true },
        locator: (any CurrentCountryLocating)? = nil
    ) {
        self.isMember = isMember
        self.locator = locator
        self.countryAccess = countryAccess
        self.stakePacks = stakePacks
        self.viewModel = viewModel
        self.favoritesRepository = favoritesRepository
        self.pinService = pinService
        self.imagePipeline = imagePipeline
        self.iconCatalog = iconCatalog
        self.previewCatalog = previewCatalog
        self.videoCoordinator = MapVideoPlaybackCoordinator(pool: videoPlayback)
        #if DEBUG
        self.videoPool = videoPlayback
        #endif
        self.makeSnapFeed = makeSnapFeed
        self.pushPlainSnapFeed = pushPlainSnapFeed
        self.revealSnapFeed = revealSnapFeed
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
        loadFavorites()
        prefetchPeople()
        mapView.setRegion(Self.defaultRegion, animated: false)
        #if DEBUG
        // `-maps-wide-region`: open zoomed out far enough that the mock pins
        // collapse into clusters — for screenshotting/driving cluster UI in
        // the sim, where pinch gestures can't be injected. Under dissolve
        // banding (~77 km diagonal) this is the CITY band.
        if ProcessInfo.processInfo.arguments.contains("-maps-wide-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta *= 6
            region.span.longitudeDelta *= 6
            mapView.setRegion(region, animated: false)
        }
        // `-maps-tight-region`: open at level 13 (span 0.045°, ~6.4 km
        // diagonal), framing almost the same pins as the default view. Both
        // are LOCAL-band views under dissolve banding (a city-scale viewport
        // dissolves the city): individual posts and generic proximity
        // clusters, all in neutral rings. The city-band A/B is a region-scale
        // framing (e.g. `-maps-set-region 48.7,2.5,1.6`). Screenshotable in
        // the sim, where a pinch can't be injected.
        if ProcessInfo.processInfo.arguments.contains("-maps-tight-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta = 0.045
            region.span.longitudeDelta = 0.045
            mapView.setRegion(region, animated: false)
        }
        // `-maps-country-region`: open at the COUNTRY band. Dissolve banding
        // keeps a country marker only while the viewport diagonal exceeds
        // ~2261 km (2.7 × the res-1 span), so this is a Europe-scale framing:
        // countries roll up into amber markers — the top of the nesting
        // ladder, unreachable by the ×6 wide region (city band).
        if ProcessInfo.processInfo.arguments.contains("-maps-country-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta = 20
            region.span.longitudeDelta = 20
            mapView.setRegion(region, animated: false)
        }
        // `-maps-set-region <lat>,<lng>,<spanDegrees>`: open anywhere at any
        // scale — the generic hook the European hierarchy sweep drives (the
        // sim can't inject a continent's worth of panning). Example:
        // `-maps-set-region 41.39,2.17,0.09` opens on Barcelona at the city
        // band.
        if let region = Self.debugSetRegion {
            mapView.setRegion(region, animated: false)
        }
        // `-maps-camera-distance <metres>`: pull the camera back to that
        // distance above the current centre — how the widest zoom is reached
        // in the sim (no pinch), and past what a region's span can say (a span
        // is capped at 180°/360°, a camera is not). The standard map clamps
        // it at ~26 300 km (see `MapBaseConfiguration`). Applied after
        // `-maps-set-region`, so the two compose,
        // and a second after launch: written in `viewDidLoad`, before the map
        // has a size, MapKit framed a continent instead. Logs what MapKit
        // kept. `-maps-camera-pitch <degrees>` tilts the same camera.
        if let value = Self.debugArgumentValue("-maps-camera-distance"),
           let distance = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let camera = mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
                camera.centerCoordinateDistance = distance
                if let pitch = Self.debugArgumentValue("-maps-camera-pitch").flatMap(Double.init) {
                    camera.pitch = pitch
                }
                mapView.setCamera(camera, animated: false)
                print(String(
                    format: "[maps-camera] asked=%.0f kept=%.0f pitch=%.0f span=%.2f",
                    distance, mapView.camera.centerCoordinateDistance, mapView.camera.pitch,
                    mapView.region.span.latitudeDelta
                ))
            }
        }
        // `-maps-select-filter <token>`: selects a filter pill (~1.5s after
        // launch, once the first unfiltered settle has painted) — drives the
        // filtered-query path in the sim, where taps can't be injected.
        // Tokens are `MapFilter.wireToken` (friends/following/pinned/nearby/
        // profile:<id>).
        if let token = Self.debugArgumentValue("-maps-select-filter"),
           let filter = MapFilter(wireToken: token) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.filterBar.setSelectedFilter(filter)
                self.viewModel.filterChanged(filter)
                self.updateSubFilterBar(for: filter)
            }
        }
        // `-maps-select-filter-2 <token|all>`: a SECOND primary selection at
        // ~3.5s — drives primary-to-primary switches (sub-row cross-dissolve)
        // and, with `all`, the fade-out path.
        if let token = Self.debugArgumentValue("-maps-select-filter-2") {
            let second: MapFilter? = token == "all" ? nil : MapFilter(wireToken: token)
            if second != nil || token == "all" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self else { return }
                    self.filterBar.setSelectedFilter(second)
                    self.viewModel.filterChanged(second)
                    self.updateSubFilterBar(for: second)
                }
            }
        }
        // `-maps-toggle-subfilter <profileID>`: adds or removes that profile
        // from the ACTIVE primary's rail ~5s in, while the map is on screen —
        // the edit the profile's star makes from another screen, which is the
        // one path that has to animate rather than flash. Pair with
        // `-maps-select-filter friends|following`.
        if let id = Self.debugArgumentValue("-maps-toggle-subfilter") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self,
                      let primary = filterBar.selectedFilter,
                      let category = Self.railCategory(for: primary) else { return }
                let profile = ProfileID(id)
                let pinService = pinService
                Task {
                    var categories = await pinService.categories(for: profile)
                    let wasOn = categories.contains(category)
                    categories.formSymmetricDifference([category])
                    print("[maps] sub-filter toggle: \(id) \(wasOn ? "leaves" : "joins") \(category)")
                    await pinService.setCategories(categories, for: profile)
                }
            }
        }
        // `-maps-subfilter-remove <profileID>`: fires that pill's context-menu
        // Remove ~5s in, through the same routing a long press does
        // (`MapSubFilterBarView.perform`). The menu itself needs a long press
        // the simulator cannot deliver, and this is the path that flashed:
        // the removal restacks, then the rail write it commits comes back
        // round as a refresh.
        if let id = Self.debugArgumentValue("-maps-subfilter-remove") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                print("[maps] sub-filter menu: Remove \(id)")
                subFilterBar.perform(.unpin, on: .profile(ProfileID(id)))
            }
        }
        // `-maps-subfilter-menu-audit <profileID>`: prints the pill's
        // long-press menu ~5s in — its title and its verbs, in order. The menu
        // needs a long press the simulator cannot deliver, so this is how a
        // scripted run sees what it would contain (the same instrument
        // `-profile-menu-audit` is for the profile's overflow menu).
        if let id = Self.debugArgumentValue("-maps-subfilter-menu-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let menu = self?.subFilterBar.menu(for: .profile(ProfileID(id))) else {
                    print("[maps] pill menu: no pill for \(id)")
                    return
                }
                // A person's name is the FIRST section's action now, not the
                // root title: it is the header the viewer taps. Print both,
                // plus what the pill actually carries — the header used to be
                // built correctly and never reach the screen.
                let sections = menu.children.compactMap { $0 as? UIMenu }
                let header = sections.first?.children.compactMap { $0 as? UIAction }.first
                let verbs = sections.last?.children
                    .compactMap { ($0 as? UIAction)?.title } ?? []
                let separated = sections.count > 1 || !menu.title.isEmpty
                // `installed*` is read off the pill WITHOUT opening anything:
                // the header is installed when the cell is configured, so the
                // name and handle are already on it before any thumb lands.
                let installed = self?.subFilterBar
                    .debugInstalledMenuTitle(for: .profile(ProfileID(id))) ?? "<none>"
                let installedSubtitle = self?.subFilterBar
                    .debugInstalledMenuSubtitle(for: .profile(ProfileID(id))) ?? "<none>"
                print("[maps] pill menu: header=\"\(header?.title ?? menu.title)\" "
                    + "subtitle=\"\(header?.subtitle ?? "")\" "
                    + "headerTappable=\(header != nil) headerImage=\(header?.image != nil) "
                    + "separator=\(separated) verbs=\(verbs) "
                    + "installedHeader=\"\(installed)\" "
                    + "installedSubtitle=\"\(installedSubtitle)\"")
            }
        }
        // `-maps-subfilter-menu-open <profileID>`: presents that pill's
        // long-press menu ~5s in, so the header can be screenshotted.
        if let id = Self.debugArgumentValue("-maps-subfilter-menu-open") {
            // The delay is a knob because WHEN the menu opens is the whole
            // question: opened late everything has settled, opened while the
            // row is still hydrating it shows what a fast thumb would see.
            let delay = Self.debugArgumentValue("-maps-subfilter-menu-open-after")
                .flatMap(Double.init) ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.subFilterBar.debugPresentMenu(for: .profile(ProfileID(id)))
            }
        }
        // `-maps-tap-subfilter <profileID>`: taps a refinement pill ~6s in,
        // after `-maps-select-subfilter` has had its turn — so the pair shows
        // a selected pill being toggled back off.
        if let id = Self.debugArgumentValue("-maps-tap-subfilter") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.subFilterBar.debugTap(.profile(ProfileID(id)))
            }
        }
        // `-maps-open-subfilter-sheet`: presents the sub-filter full-list
        // sheet ~3s in (the header's organize tap). Pair with
        // `-maps-select-filter friends|following|pinned`.
        if ProcessInfo.processInfo.arguments.contains("-maps-open-subfilter-sheet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.presentSubFilterSheet()
            }
        }
        // `-maps-pin-favorite <profileID>`: toggles that profile in the
        // pinned-favorites store ~2s in (the long-press menu's mutation,
        // which can't be driven by injected touches). Pair with
        // `-maps-reset-favorites` for deterministic runs.
        if let id = Self.debugArgumentValue("-maps-pin-favorite") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.togglePinnedFavorite(MapFavorite(profileID: ProfileID(id), title: ""))
            }
        }
        // `-maps-select-subfilter <profile:ID|place:token>[,…]`: selects
        // refinement pills ~3s in (after the sub-filter row has loaded).
        // Several comma-separated tokens select several at once — the row and
        // the query then carry their union. Pair with
        // `-maps-select-filter friends|following|pinned`.
        if let tokens = Self.debugArgumentValue("-maps-select-subfilter") {
            let subFilters = Set(tokens.split(separator: ",").compactMap { token -> MapSubFilter? in
                if token.hasPrefix("profile:") {
                    .profile(ProfileID(String(token.dropFirst("profile:".count))))
                } else if token.hasPrefix("place:") {
                    .placeCategory(String(token.dropFirst("place:".count)))
                } else {
                    nil
                }
            })
            if !subFilters.isEmpty {
                // ⚠️ 3 s IS THE EARLIEST, NOT THE PROOF. It keeps this hook's
                // place on the timeline its siblings are laid against
                // (`-maps-tap-subfilter` at 6 s toggles what this selected),
                // but "the row has loaded by then" was a guess: on a slow load
                // the query was filtered while the bar carried no such pill,
                // and the row landing afterwards (`setOptions`) cleared the
                // selection — a filtered map with nothing selected, silently.
                // So it also waits for the bar to actually carry every
                // requested pill, in the row the controller means to show.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    QAWait.until("-maps-select-subfilter \(tokens)", timeout: 20, { [weak self] in
                        guard let self else { return true }
                        let intended = Set(currentSubFilterOptions.map(\.subFilter))
                        return subFilters.allSatisfy {
                            intended.contains($0) && subFilterBar.entity(for: $0) != nil
                        }
                    }) { [weak self] in
                        guard let self else { return }
                        subFilterBar.setSelectedSubFilters(subFilters)
                        viewModel.subFiltersChanged(subFilters)
                    }
                }
            }
        }
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
    private func syncBarsPosition() {
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
                          Self.railCategory(for: primary) == changed else { return }
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
        // Above the map, below the bars (added next) — so the location card
        // sits on top of it (#564).
        guestVeil.backgroundColor = UIColor.black.withAlphaComponent(Self.guestVeilAlpha)
        guestVeil.isUserInteractionEnabled = false
        guestVeil.alpha = 0
        guestVeil.pin(to: view)
        #if DEBUG
        installChromeTrace()
        #endif
        configureFilterBar()
        configureCountries()
    }

    #if DEBUG
    /// `-maps-camera-log`: the settled camera — distance, pitch, how much of
    /// the world's width is on screen, the region MapKit reports (and so the
    /// viewport the query is built from). Pairs with `-maps-zoom-sweep`.
    private func logSettledCamera() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-camera-log") else { return }
        let region = mapView.region
        print(String(
            format: "[maps-camera] settled distance=%.0f pitch=%.0f worldFraction=%.3f center=%.2f,%.2f span=%.2fx%.2f",
            mapView.camera.centerCoordinateDistance, mapView.camera.pitch,
            mapView.visibleMapRect.width / MKMapRect.world.width,
            region.center.latitude, region.center.longitude,
            region.span.latitudeDelta, region.span.longitudeDelta
        ))
    }
    #endif

    // MARK: - Countries

    /// The world's borders, and picking a LOCKED country: a tap lifts it at
    /// once, then the map flies to it and its offer rises. An unlocked
    /// country does nothing under a tap — the map stays the map.
    private func configureCountries() {
        countryLayer.access = countryAccess
        countryLayer.onMapTapped = { [weak self] country in self?.mapTapped(country) }
        countryLayer.onTouchDown = { [weak self] in self?.cancelPendingOffer() }
        countryLayer.onMapGesture = { [weak self] in self?.mapMovedByUser() }
        countryLayer.onLockedCountryTapped = { [weak self] country in self?.offer(country) }
        countryLayer.onCountryTapped = { [weak self] country in self?.showCountry(country.code) }
        countryLayer.install(on: mapView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(countryAccessChanged), name: .countryAccessDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentCountryChanged), name: .currentCountryDidChange, object: nil
        )
        updateGuestLock(animated: false)
        updateLocationControls()
        #if DEBUG
        // `-open-country-shop` / `-offer-country XX` / `-show-country XX`: the
        // shop, a locked country's offer, or the shop's "go to" — once the map
        // is on screen and the borders are in (a tap the sim can't place).
        let arguments = ProcessInfo.processInfo.arguments
        let code = { (flag: String) in
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if countryAccess != nil, arguments.contains("-open-country-shop") || code("-offer-country") != nil
            || code("-show-country") != nil {
            QAWait.until("country QA hook", timeout: 20, { [weak self] in
                guard let self else { return true }
                return view.window != nil && countryLayer.hasBorders && presentedViewController == nil
            }) { [weak self] in
                guard let self else { return }
                if let shown = code("-show-country") {
                    showCountry(shown.uppercased())
                } else if let offered = code("-offer-country"), let country = CountryAtlas.shared.country(code: offered) {
                    offer(country)
                } else {
                    presentCountryShop()
                }
            }
        }
        #endif
    }

    /// Whether this map sells countries — the Explore header shows the shop's
    /// door only then.
    var sellsCountries: Bool { countryAccess != nil }

    /// The Shop, over the map — opened by the Explore header's storefront
    /// (`MapCountryShopHosting`). A row takes you to its country.
    func presentCountryShop() {
        guard let countryAccess, presentedViewController == nil else { return }
        let shop = CountryShopViewController.sheet(access: countryAccess, stakePacks: stakePacks) { [weak self] code in
            self?.dismiss(animated: true) { self?.showCountry(code) }
        }
        present(shop, animated: true)
    }

    /// Goes to a country from the shop: lifted and framed, and a locked one
    /// makes its offer (framed above the sheet).
    private func showCountry(_ code: String) {
        guard let country = CountryAtlas.shared.country(code: code) else { return }
        if let countryAccess, !countryAccess.isUnlocked(code) {
            offer(country)
            return
        }
        countryLayer.select(code)
        frame(country, bottomInset: 0)
    }

    /// Frames a country's mainland in the part of the map left visible
    /// between the header and `bottomInset` from the bottom.
    private func frame(_ country: CountryAtlas.Country, bottomInset: CGFloat) {
        let box = country.mainlandBounds
        let corner = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon))
        let opposite = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon))
        let rect = MKMapRect(
            x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
            width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y)
        )
        let insets = UIEdgeInsets(
            top: view.safeAreaInsets.top + Spacing.xxl, left: Spacing.xxl,
            bottom: max(bottomInset, view.safeAreaInsets.bottom) + Spacing.xl, right: Spacing.xxl
        )
        // ⚠️ NOT `setVisibleMapRect(_:edgePadding:)`: with the sheet's tall
        // bottom padding it zoomed out ~3.7x too far (Spain above its offer
        // came out a third of the band it was given). The visible rect is
        // worked out here instead: the scale that fits the country in the
        // band, and the band's centre on the country's.
        let size = mapView.bounds.size
        let band = CGSize(
            width: max(size.width - insets.left - insets.right, 1),
            height: max(size.height - insets.top - insets.bottom, 1)
        )
        let scale = max(rect.width / band.width, rect.height / band.height)
        let visible = MKMapRect(
            x: rect.midX - (insets.left + band.width / 2) * scale,
            y: rect.midY - (insets.top + band.height / 2) * scale,
            width: size.width * scale, height: size.height * scale
        )
        mapView.setVisibleMapRect(visible, animated: true)
    }

    /// A tap on the map, not on a marker.
    ///
    /// - With an offer open, the tap closes it and the map goes back to where
    ///   it was: tapping away is "no thanks".
    /// - On a locked country: it lifts NOW, like a marker's selection, and the
    ///   flight and the offer follow `offerDelay` later unless another finger
    ///   lands first (`cancelPendingOffer`): the second tap of a double-tap
    ///   zoom, or the start of a pan, undoes the pick.
    /// - Anywhere else: whatever is lifted lowers.
    private func mapTapped(_ country: CountryAtlas.Country?) {
        if offerSheet != nil {
            closeOffer(returning: true)
            return
        }
        guard let country, let countryAccess, !countryAccess.isUnlocked(country.code) else {
            countryLayer.select(nil)
            return
        }
        countryLayer.select(country.code)
        let pending = DispatchWorkItem { [weak self] in
            self?.pendingOffer = nil
            self?.offer(country)
        }
        pendingOffer = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offerDelay, execute: pending)
    }

    /// Long enough for a double tap's second touch to land, short enough to
    /// read as one gesture: the lift is instant, the flight follows.
    private static let offerDelay: TimeInterval = 0.3

    /// A finger landed while a pick waited for its flight: it was the start
    /// of something else (a double-tap zoom, a pan). The pick is undone.
    private func cancelPendingOffer() {
        guard let pendingOffer else { return }
        pendingOffer.cancel()
        self.pendingOffer = nil
        countryLayer.select(nil)
    }

    /// The user moved the map. A waiting pick is dropped, and an open offer
    /// closes WHERE THE USER TOOK THE MAP: no flight back to the camera it
    /// left from, since the user has just chosen another place to look.
    private func mapMovedByUser() {
        cancelPendingOffer()
        if offerSheet != nil { closeOffer(returning: false) }
    }

    /// Lifts a locked country, flies the map to it above its sheet, and
    /// presents what unlocking it would open. The camera it left from is kept:
    /// closing the offer flies back to it.
    private func offer(_ country: CountryAtlas.Country) {
        // ⚠️ FROM ONE LOCKED COUNTRY STRAIGHT TO ANOTHER (#760): the open
        // offer takes the new country in place — outline, camera, sheet — and
        // the camera it left from stays the first one's, so closing returns
        // home. It used to bail here, and MapKit's own selection then closed
        // the first offer: the second tap only reached neutral.
        if let open = offerSheet, !open.isLeaving {
            switchOffer(open, to: country)
            return
        }
        guard let countryAccess, presentedViewController == nil else { return }
        if offerCamera == nil { offerCamera = mapView.camera.copy() as? MKMapCamera }
        countryLayer.select(country.code)
        let sheet = CountryUnlockSheetViewController(country: country, access: countryAccess)
        // Wrapped BEFORE its view loads: the measure counts its toolbar.
        let presented = sheet.wrappedInSheet()
        // The country being sold stands ABOVE the sheet, not under it.
        sheet.loadViewIfNeeded()
        frame(country, bottomInset: offerBottomInset(sheet))
        bindOffer(sheet)
        offerSheet = sheet
        present(presented, animated: true)
    }

    /// The open offer's callbacks, for the country it shows NOW — read off
    /// the sheet, so a switch (`switchOffer`) never leaves them on the first.
    private func bindOffer(_ sheet: CountryUnlockSheetViewController) {
        sheet.onClosing = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerClosing(sheet.country)
        }
        sheet.onCloseCancelled = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerCloseCancelled(sheet.country, sheet: sheet)
        }
        sheet.onDismissed = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerDidClose(sheet.country)
        }
    }

    /// The open offer moves to `country` without closing (#760).
    private func switchOffer(_ sheet: CountryUnlockSheetViewController, to country: CountryAtlas.Country) {
        guard country.code != sheet.country.code else { return }
        #if DEBUG
        OfferLog.note("switch \(sheet.country.code) -> \(country.code)")
        #endif
        countryLayer.select(country.code)
        sheet.show(country)
        frame(country, bottomInset: offerBottomInset(sheet))
    }

    /// The band left above an offer's sheet, where its country is framed.
    private func offerBottomInset(_ sheet: CountryUnlockSheetViewController) -> CGFloat {
        sheet.sheetHeight + view.safeAreaInsets.bottom
    }

    /// Closes the open offer. `returning`: whether the map flies back to the
    /// camera it had before the offer.
    private func closeOffer(returning: Bool) {
        // Already on its way down (and the map already on its way back): a
        // tap or a pan now is the user's, not a second close.
        guard let offerSheet, !offerSheet.isLeaving else { return }
        offerReturns = returning
        #if DEBUG
        OfferLog.note("close requested returning=\(returning)")
        #endif
        offerSheet.dismiss(animated: true)
    }

    /// The offer is closing — by a tap or a pan on the map, a swipe on its
    /// sheet, or an unlock — and the sheet has only just started down
    /// (`OfferCloseFlight`): what the map does runs alongside it.
    ///
    /// - Unlocked: nothing yet. The map stays on the country, whose posts are
    ///   the reward (`offerDidClose`).
    /// - Otherwise the country lowers, and the map flies back to where it was
    ///   (unless the user moved it away from the offer themselves).
    private func offerClosing(_ country: CountryAtlas.Country) {
        guard !(countryAccess?.isUnlocked(country.code) ?? false) else { return }
        countryLayer.select(nil)
        #if DEBUG
        OfferLog.note("closing: flying back=\(offerReturns && offerCamera != nil)")
        #endif
        guard offerReturns, let offerCamera else { return }
        offerFlewBack = true
        mapView.setCamera(offerCamera, animated: true)
    }

    /// A close went out and the sheet came back up (`OfferCloseFlight`):
    /// the country lifts again, framed above it if the map had left.
    private func offerCloseCancelled(_ country: CountryAtlas.Country, sheet: CountryUnlockSheetViewController) {
        #if DEBUG
        OfferLog.note("close cancelled: reframing=\(offerFlewBack)")
        #endif
        countryLayer.select(country.code)
        if offerFlewBack { frame(country, bottomInset: offerBottomInset(sheet)) }
        offerFlewBack = false
        offerReturns = true
    }

    /// The offer is gone. Whatever the map does about it began at
    /// `offerClosing`; an unlocked country's lift fades once its posts have
    /// had a moment on screen.
    private func offerDidClose(_ country: CountryAtlas.Country) {
        offerSheet = nil
        offerCamera = nil
        offerReturns = true
        offerFlewBack = false
        guard countryAccess?.isUnlocked(country.code) ?? false else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.countryLayer.selectedCode == country.code else { return }
            self?.countryLayer.select(nil)
        }
    }

    @objc private func countryAccessChanged() {
        countryLayer.refreshStyles()
        reconcileClusters()
        updateLocationControls()
    }

    // MARK: - Location (guest mode §3.1)

    /// The card while nothing is open and location isn't allowed — the one
    /// thing that would open a country; the locate button otherwise.
    private func updateLocationControls() {
        guard let locator else {
            locationControls.apply(.none)
            return
        }
        let permission = locator.permission
        // The locked guest map's one way out, with or without country access
        // (the fleet has none yet) — #564.
        if isGuestLocked {
            locationControls.apply(.card(permission))
            return
        }
        guard let countryAccess else {
            locationControls.apply(.none)
            return
        }
        locationControls.apply(
            countryAccess.hasNoOpenCountry && permission != .allowed ? .card(permission) : .button(permission)
        )
    }

    /// Asks in context — the only place location is ever asked for — or, once
    /// denied, sends the person to Settings, the only place it can change.
    private func locationControlTapped(_ permission: LocationPermission) {
        switch permission {
        case .denied:
            guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settings)
        case .notAsked:
            fliesToCurrentCountry = true
            locator?.requestPermission()
        case .allowed:
            if let code = locator?.currentCountry {
                showCountry(code)
            } else {
                fliesToCurrentCountry = true
            }
            locator?.requestPermission()
        }
    }

    /// How dark the locked guest map is (#564).
    static let guestVeilAlpha: CGFloat = 0.55

    /// Whether a viewer sees the locked guest showcase: a guest whose location
    /// is not allowed. Members are never locked, and neither is a map with no
    /// locator (`permission` nil): without the card there would be no way out.
    /// Pure, for tests.
    static func guestLocationLocked(isMember: Bool, permission: LocationPermission?) -> Bool {
        guard !isMember, let permission else { return false }
        return permission != .allowed
    }

    /// The map's interaction, from BOTH gates: an open transition (`inert`)
    /// and the guest lock. Pure, for tests.
    static func mapIsInteractive(inert: Bool, guestLocked: Bool) -> Bool {
        !(inert || guestLocked)
    }

    /// Re-reads the lock and applies it: the veil, the world view, the map's
    /// interaction, the pills and the compass. Unlocking fades the veil out
    /// and flies to the current country once it is known.
    private func updateGuestLock(animated: Bool) {
        let locked = Self.guestLocationLocked(isMember: isMember(), permission: locator?.permission)
        guard locked != isGuestLocked || (locked && guestVeil.alpha == 0) else { return }
        let wasLocked = isGuestLocked
        isGuestLocked = locked
        applyMapInteraction()
        mapView.showsCompass = !locked
        // Meaningless on a locked map; the card is what matters.
        filterBar.isHidden = locked
        if locked {
            subFilterBar.isHidden = true
            pendingQuery?.cancel()
            needsWorldView = true
            frameWorldIfNeeded()
        }
        let veilAlpha: CGFloat = locked ? 1 : 0
        if animated {
            UIView.animate(withDuration: 0.3) { self.guestVeil.alpha = veilAlpha }
        } else {
            guestVeil.alpha = veilAlpha
        }
        updateLocationControls()
        guard wasLocked, !locked else { return }
        // Unlocked: to the viewer's country, as the card promised.
        if let code = locator?.currentCountry {
            fliesToCurrentCountry = false
            showCountry(code)
        } else {
            fliesToCurrentCountry = true
            scheduleQuery()
        }
    }

    /// The whole world, without animation — on the first frame, so a locked
    /// map never flashes Paris first.
    private func frameWorldIfNeeded() {
        guard needsWorldView, isGuestLocked, mapView.bounds.width > 0 else { return }
        needsWorldView = false
        mapView.setVisibleMapRect(.world, animated: false)
    }

    @objc private func currentCountryChanged() {
        updateGuestLock(animated: true)
        updateLocationControls()
        // The country left behind closes again (decision 10): it no longer
        // stands selected as if it were open — unless its offer is up.
        if let selected = countryLayer.selectedCode, selected != locator?.currentCountry,
           countryAccess?.isUnlocked(selected) == false, presentedViewController == nil {
            countryLayer.select(nil)
        }
        guard fliesToCurrentCountry, let code = locator?.currentCountry else { return }
        fliesToCurrentCountry = false
        showCountry(code)
    }

    /// Whether `pin`'s post is OPEN to the viewer: its country is unlocked (or
    /// there is nothing locked at all). A pin just offshore is its coast's
    /// (`CountryAtlas.country(owning:)`); one on the open sea is open.
    ///
    /// A post in a locked country is still on the map — its country's markers
    /// wear its busiest posts, darkened under a lock — but it never opens.
    private func isInUnlockedCountry(_ pin: MapPin) -> Bool {
        guard let countryAccess else { return true }
        let code = countryCode(of: pin)
        return code.isEmpty || countryAccess.isUnlocked(code)
    }

    /// The country `pin`'s post stands in (ISO alpha-2), "" at sea. Cached per
    /// post: the point-in-polygon walk is the expensive half of the question,
    /// and a reconcile asks it of every pin.
    private func countryCode(of pin: MapPin) -> String {
        if let cached = pinCountries[pin.postID] { return cached }
        let coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        let code = CountryAtlas.shared.country(owning: coordinate)?.code ?? ""
        pinCountries[pin.postID] = code
        return code
    }

    /// The country `annotation`'s marker speaks for (ISO alpha-2, "" at sea):
    /// its REPRESENTATIVE's — a city's is its country's, as its flag border.
    private func countryCode(of annotation: any MKAnnotation) -> String {
        let cluster = annotation as? MapComputedCluster
        guard let pin = cluster?.representative ?? (annotation as? MapAnnotation)?.pin else { return "" }
        return countryCode(of: pin)
    }

    /// What `annotation`'s marker wears around its face: the flag border and
    /// badge of the place it speaks for, and the lock of a locked country —
    /// see `MapMarkerDress`. The country is the REPRESENTATIVE's: a city's
    /// border wears its country's flag, and every member of a locked marker is
    /// locked (`reconcileClusters` never lays out open and locked posts
    /// together).
    private func dress(for annotation: any MKAnnotation) -> MapMarkerDress {
        let cluster = annotation as? MapComputedCluster
        guard let pin = cluster?.representative ?? (annotation as? MapAnnotation)?.pin else { return .neutral }
        let code = countryCode(of: pin)
        return MapMarkerDress.resolve(
            kind: Self.dressKind(of: annotation),
            countryCode: code,
            isLocked: !isInUnlockedCountry(pin)
        )
    }

    /// The hierarchy depth `annotation`'s dress speaks for, or nil for a
    /// local marker. A band's group of one (a lone `MapAnnotation`) speaks
    /// for its place exactly like a band cluster: at a band, every marker
    /// wears a place's dress — at the country band only countries, at the
    /// city band only cities.
    static func dressKind(of annotation: any MKAnnotation) -> MapPlace.Kind? {
        hierarchyPlace(of: annotation)?.kind
    }

    /// The city or country `annotation`'s marker IS, or nil for a local one —
    /// the ONE answer both presentations (`openAnnotation`'s reveal and
    /// `presentSnapFeed`'s hero) and the dress ask, so "does this marker have
    /// a place page" and "does it wear a place's dress" can never disagree.
    ///
    /// ⚠️ A BAND'S GROUP OF ONE COUNTS. Both routes used to ask
    /// `annotation as? MapComputedCluster` alone, so a country or city with a
    /// single post in view — dressed as its place, the mock world's ninety-four
    /// one-post countries among them — opened as a plain pin, and its vertical
    /// dismissal landed on the map where Paris's lands on its page.
    static func hierarchyPlace(of annotation: any MKAnnotation) -> MapPlace? {
        switch annotation {
        case let cluster as MapComputedCluster: cluster.hierarchyPlace
        case let single as MapAnnotation: single.hierarchyPlace
        default: nil
        }
    }

    /// What a tap on a marker does: open its posts, or — for a locked
    /// country's — offer the country. Pure, so the routing is pinned without
    /// a live map.
    enum MarkerTap: Equatable {
        case open
        case offer(countryCode: String)
    }

    static func markerTap(for dress: MapMarkerDress, countryCode: String) -> MarkerTap {
        dress.isLocked && !countryCode.isEmpty ? .offer(countryCode: countryCode) : .open
    }

    private func configureFilterBar() {
        barsStack.axis = .vertical
        barsStack.spacing = Spacing.xs
        barsStack.clipsToBounds = false
        view.addSubview(barsStack)
        barsStack.translatesAutoresizingMaskIntoConstraints = false
        // Pinned to the view's RAW bottom with a constant this screen owns, not to
        // `safeAreaLayoutGuide.bottomAnchor`. The safe area animates through a pop
        // — measured here climbing 34 -> 64 -> 76.33 before settling at 83 — and
        // anything tied to it rides that animation and then corrects, which showed
        // up as the bars landing at 741.67 and snapping to 735.00. `syncBarsPosition`
        // tracks the safe area only while nothing is flying, so the constant in
        // force during a gesture is always a resting measurement. The resting
        // geometry is unchanged: the safe-area bottom still sits above the floating
        // tab bar, which is what rests the pills directly over it.
        barsBottomConstraint = barsStack.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -Spacing.sm
        )
        NSLayoutConstraint.activate([
            barsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barsBottomConstraint,
            subFilterBar.heightAnchor.constraint(equalToConstant: MapSubFilterBarView.barHeight),
            filterBar.heightAnchor.constraint(equalToConstant: MapFilterBarView.barHeight)
        ])
        barsStack.addArrangedSubview(locationControls)
        barsStack.addArrangedSubview(subFilterBar)
        barsStack.addArrangedSubview(filterBar)
        locationControls.onTap = { [weak self] permission in self?.locationControlTapped(permission) }
        // Resting state: no refinement row until a primary that has one.
        subFilterBar.isHidden = true
        subFilterBar.alpha = 0

        filterBar.onFilterChanged = { [weak self] filter in
            self?.viewModel.filterChanged(filter)
            self?.updateSubFilterBar(for: filter)
        }
        subFilterBar.imagePipeline = imagePipeline
        subFilterBar.onSubFiltersChanged = { [weak self] subFilters in
            self?.viewModel.subFiltersChanged(subFilters)
        }
        subFilterBar.onExpandTapped = { [weak self] in
            self?.presentSubFilterSheet()
        }
        // The pill long-press menu. Every destination is resolved here — the
        // bar reports which verb was chosen and knows nothing beyond that.
        subFilterBar.onViewProfile = { [weak self] favorite in
            self?.openProfile(favorite)
        }
        subFilterBar.onSendMessage = { [weak self] favorite in
            self?.openConversation(favorite.profileID)
        }
        subFilterBar.isMuted = { [weak self] profileID in
            self?.mutedProfiles.contains(profileID) ?? false
        }
        subFilterBar.onToggleMute = { [weak self] favorite in
            self?.mutedProfiles.formSymmetricDifference([favorite.profileID])
        }
        subFilterBar.onViewDetails = { [weak self] category in
            self?.isolateSubFilter(.placeCategory(category))
        }
        subFilterBar.onShare = { [weak self] option in
            self?.presentShareSheet(for: option)
        }
        subFilterBar.onUnpinSubFilter = { [weak self] subFilter in
            self?.removeSubFilterFromRow(subFilter)
        }
    }

    // MARK: - Sub-filter row

    /// Warms the people cache once at screen load (both lists in parallel),
    /// so the first Friends/Following tap already has its row in memory.
    private func prefetchPeople() {
        guard isMember() else { return }
        let repository = favoritesRepository
        Task { [weak self] in
            async let friends = repository.friends()
            async let following = repository.following()
            let (friendsList, followingList) = await (friends, following)
            guard let self else { return }
            self.catalogueCache[.friends] = friendsList
            self.catalogueCache[.following] = followingList
            // The rows themselves may be curated subsets; resolve them from
            // the same lists rather than assuming the graph IS the row.
            self.peopleCache[.friends] = await self.people(for: .friends)
            self.peopleCache[.following] = await self.people(for: .following)
        }
    }

    /// Repopulates (or hides) the refinement row for a newly selected
    /// primary. UI first, data second: the row renders SYNCHRONOUSLY from
    /// the session cache (0ms — never awaiting the network), then a
    /// background refresh re-renders only if the list actually changed and
    /// the selection hasn't moved on.
    private func updateSubFilterBar(for filter: MapFilter?) {
        subFilterLoadTask?.cancel()
        switch filter {
        case .friends, .following:
            guard let primary = filter else { return } // matched .some above
            // 1) Instant, and ALWAYS applied — not only when the cache has
            // something. Whatever is on screen belongs to the primary the
            // viewer just LEFT, so an empty target has to clear it rather than
            // inherit it. (It did inherit it: switching to an empty rail left
            // the previous primary's pills up.)
            applyPeopleRow(peopleCache[primary] ?? [], for: primary)
            // A guest follows no one: the row stays empty, nothing is fetched.
            guard isMember() else { return }
            // 2) Refresh behind it (also the cold path pre-prefetch, where
            // the row fills in when data lands).
            let repository = favoritesRepository
            subFilterLoadTask = Task { [weak self] in
                guard let people = await self?.people(for: primary) else { return }
                let catalogue = primary == .friends
                    ? await repository.friends()
                    : await repository.following()
                guard let self, !Task.isCancelled else { return }
                self.catalogueCache[primary] = catalogue
                self.peopleCache[primary] = people
                guard self.filterBar.selectedFilter == primary else { return }
                self.applyPeopleRow(people, for: primary)
            }
        case .pinned:
            renderedSubFilterRow = nil
            showSubFilterRow(MapSubFilterOption.placeCategories)
        default:
            // All / a favorite: no refinement dimension.
            renderedSubFilterRow = nil
            currentSubFilterOptions = []
            setSubFilterBar(visible: false)
        }
    }

    /// Renders a people row for `primary`, or retires it — skipping only when
    /// the row is ALREADY showing exactly this.
    ///
    /// The comparison is against what is rendered, never against a cache: see
    /// `MapSubFilterRowUpdate` for the switch-to-an-empty-primary bug that
    /// distinction exists to prevent.
    private func applyPeopleRow(_ people: [MapFavorite], for primary: MapFilter) {
        let incoming = makeRowState(primary: primary, people: people)
        let update = MapSubFilterRowUpdate.resolve(rendered: renderedSubFilterRow, incoming: incoming)
        #if DEBUG
        // Which path a row edit took is invisible in a screenshot — a diff and
        // a cross-dissolve land on the same pixels and differ only in how they
        // got there. Printed alongside the toggle hook that provokes it.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-maps-toggle-subfilter") || arguments.contains("-maps-subfilter-remove") {
            let style = switch update {
            case .show(let options, let style): "show(\(options.count) pills, \(style))"
            case .hide: "hide"
            case .unchanged: "unchanged"
            }
            print("[maps] sub-filter row update: \(style) at \(CACurrentMediaTime())")
        }
        #endif
        switch update {
        case .unchanged:
            return
        case .hide:
            renderedSubFilterRow = incoming
            currentSubFilterOptions = []
            setSubFilterBar(visible: false)
        case .show(let options, let style):
            renderedSubFilterRow = incoming
            showSubFilterRow(options, style: style)
        }
    }

    /// One entry point for populating the row, choosing the right
    /// transition: hidden → set content and fade the bar in; already
    /// visible → cross-dissolve the pills in place (a hard swap while
    /// on-screen reads as a snap).
    private func showSubFilterRow(
        _ options: [MapSubFilterOption], style: MapSubFilterRowUpdate.Style = .swap
    ) {
        let options = orderedByPreference(options)
        currentSubFilterOptions = options
        guard isSubFilterBarVisible else {
            subFilterBar.setOptions(options)
            setSubFilterBar(visible: true)
            return
        }
        switch style {
        case .swap:
            // A different primary's list: one surface out, one in.
            subFilterBar.transition(to: options)
        case .diff:
            // The SAME list, edited — someone was added or removed from this
            // rail while the viewer was looking at it. Only the pills that
            // changed may move: cross-dissolving the row for a one-pill edit
            // is a flash, and it takes the scroll position and the selection
            // with it. `restack` is the animated diffable apply the organize
            // sheet already commits through.
            subFilterBar.restack(to: options)
            pruneSubFilterSelection(to: options)
        }
    }

    /// Drops any applied refinement whose pill just left the row. A selection
    /// can't outlive its pill: the map would stay filtered by someone the
    /// viewer can no longer see or unselect.
    ///
    /// Only the diff path needs this — a swap resets the selection with the
    /// content, and the organize sheet prunes as it commits.
    private func pruneSubFilterSelection(to options: [MapSubFilterOption]) {
        let surviving = Set(options.map(\.subFilter))
        let stillApplied = subFilterBar.selectedSubFilters.intersection(surviving)
        guard stillApplied != subFilterBar.selectedSubFilters else { return }
        subFilterBar.setSelectedSubFilters(stillApplied)
        viewModel.subFiltersChanged(stillApplied)
    }

    /// The header's organize button: the row's full contents as a searchable
    /// native bottom sheet, purely for arranging what the row carries. It
    /// applies nothing — the sheet edits a buffer and hands back a list on
    /// Done, or hands back nothing at all on Cancel.
    private func presentSubFilterSheet() {
        // Gated on the CATALOGUE, not on the row: an empty row is exactly when
        // the sheet matters most (the "+" is the only way back), and the only
        // sheet worth refusing is one with nothing in either section.
        guard !allSubFilterOptions().isEmpty else { return }
        // Only the primaries that HAVE a refinement dimension get a sheet —
        // and the primary's own name is the sheet's title.
        guard let title = subFilterTitle(for: filterBar.selectedFilter) else { return }
        let sheet = MapSubFilterSheetViewController.makeSheet(
            title: title,
            // The sheet shows the whole catalogue split in two: what the bar
            // carries, and everything else this primary could offer.
            all: allSubFilterOptions(),
            activeSubFilters: currentSubFilterOptions.map(\.subFilter),
            imagePipeline: imagePipeline,
            rowActions: MapSubFilterSheetViewController.RowActions(
                openProfile: { [weak self] favorite in self?.openProfile(favorite) },
                toggleMute: { [weak self] favorite in
                    self?.mutedProfiles.formSymmetricDifference([favorite.profileID])
                },
                isMuted: { [weak self] id in self?.mutedProfiles.contains(id) ?? false }
            ),
            onOptionsChanged: { [weak self] options in
                self?.adoptSubFilterOptions(options)
            }
        )
        present(sheet, animated: true)
    }

    /// The primary's display name — the sheet's title, and the test for
    /// whether a primary has a refinement dimension at all (All and the
    /// favorite pills answer nil, and get no sheet).
    private func subFilterTitle(for filter: MapFilter?) -> String? {
        switch filter {
        case .friends: "Friends"
        case .following: "Following"
        case .pinned: "Places"
        default: nil
        }
    }

    /// Every refinement the current primary can offer, edits ignored — the
    /// catalogue the sheet splits into Active and Available.
    private func allSubFilterOptions() -> [MapSubFilterOption] {
        switch filterBar.selectedFilter {
        case .friends, .following:
            guard let primary = filterBar.selectedFilter else { return [] }
            return MapSubFilterOption.people(catalogueCache[primary] ?? [])
        case .pinned:
            return MapSubFilterOption.placeCategories
        default:
            return []
        }
    }

    /// The sheet's Profile swipe. Maps stays navigation-agnostic (the tab
    /// coordinator owns routing), so this hands the shell an id plus the
    /// identity it already has on screen — the destination renders its header
    /// from the stub instead of flashing empty while the profile loads.
    private func openProfile(_ favorite: MapFavorite) {
        openProfile(
            favorite.profileID,
            favorite.handle.map {
                ProfileIdentityStub(handle: $0, displayName: favorite.title, isFollowing: true)
            }
        )
    }

    // MARK: - Pill menu destinations

    /// "Remove from Sub-filters": drop the refinement from the row, routed
    /// through the SAME adopt path the organize sheet commits on. That is what
    /// keeps one removal consistent everywhere — the hidden set is recomputed
    /// (so the next background refresh can't resurrect it), the order memory
    /// is rewritten, an applied refinement whose pill just left is dropped
    /// from the selection, and an emptied row retires itself.
    private func removeSubFilterFromRow(_ subFilter: MapSubFilter) {
        let remaining = currentSubFilterOptions.filter { $0.subFilter != subFilter }
        guard remaining.count != currentSubFilterOptions.count else { return }
        adoptSubFilterOptions(remaining)
    }

    /// "View Details" on a place category. There is no place-detail screen in
    /// the app — place categories are client-side vocabulary, not entities the
    /// BFF can describe — so this does the most honest thing the surface can:
    /// isolates that category on the map, dropping every other refinement.
    /// Swap the body for a push once a real destination exists.
    private func isolateSubFilter(_ subFilter: MapSubFilter) {
        let only: Set<MapSubFilter> = [subFilter]
        guard subFilterBar.selectedSubFilters != only else { return }
        subFilterBar.setSelectedSubFilters(only, reveal: subFilter)
        viewModel.subFiltersChanged(only)
    }

    /// "Share". Like the snap feed's share, this offers what the model
    /// actually carries: no canonical web URL for a profile or a place
    /// category exists on the wire yet, so the display name (and a person's
    /// `@handle`) stand in until one does.
    private func presentShareSheet(for option: MapSubFilterOption) {
        var items: [Any] = [option.sheetTitle]
        if let subtitle = option.sheetSubtitle { items.append(subtitle) }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = subFilterBar
        present(activity, animated: true)
    }

    /// The sheet's committed arrangement, landing once when the viewer taps
    /// Done. The horizontal row restacks as the sheet slides away, so what is
    /// revealed is already right, and the edits are remembered for this
    /// primary so a later Friends → Places → Friends round trip doesn't
    /// silently rebuild the repository's list over the viewer's.
    /// Session-scoped and in memory: these are viewing preferences, not state
    /// the backend knows about. Cancel never reaches here at all.
    private func adoptSubFilterOptions(_ options: [MapSubFilterOption]) {
        let surviving = Set(options.map(\.subFilter))
        currentSubFilterOptions = options

        if let primary = filterBar.selectedFilter {
            subFilterOrder[primary] = options.map(\.subFilter)
            // Hidden is simply "in the catalogue but not in the row" —
            // recomputed rather than accumulated, so a promotion out of the
            // Available section un-hides in the same stroke a demotion hides.
            // Without it the next background refresh would resurrect every
            // removed row: they are still in the social graph.
            subFilterHidden[primary] = Set(allSubFilterOptions().map(\.subFilter))
                .subtracting(surviving)
            // ...and for a PEOPLE row the arrangement is now curation, not a
            // session preference: the same list the profile's star writes.
            // Persisting it here is what makes "+ → add → Done" survive the
            // next launch, and what keeps the two editors from disagreeing.
            if let category = Self.railCategory(for: primary) {
                let ids = options.compactMap(\.favorite?.profileID)
                pinService.setCuratedList(ids, in: category)
            }
        }
        // A refinement can't outlive its pill: any applied refinement whose
        // row left the bar is dropped from the selection.
        let stillApplied = subFilterBar.selectedSubFilters.intersection(surviving)
        if stillApplied != subFilterBar.selectedSubFilters {
            subFilterBar.setSelectedSubFilters(stillApplied)
            viewModel.subFiltersChanged(stillApplied)
        }
        // Emptying the row leaves the "+" standing rather than retiring the
        // bar: the viewer has just curated everyone off, and the one thing
        // they will want next is a way to put someone back.
        subFilterBar.restack(to: options)
        setSubFilterBar(visible: true)
        // ⚠️ RECORD what was just rendered — do not clear it.
        //
        // Clearing looked harmless ("let the next refresh apply whatever it
        // finds") and was the flash: every edit here writes the rail, the
        // store's change notification re-runs the refresh, and a nil yardstick
        // makes that refresh a `.swap` — so the pill the viewer removed
        // animated out politely and the whole row cross-dissolved on top of
        // it. With the state recorded, the refresh resolves to `.unchanged`
        // (or at worst a `.diff`), and the removal is the only thing that
        // moves.
        renderedSubFilterRow = filterBar.selectedFilter.flatMap { primary in
            Self.railCategory(for: primary) == nil
                ? nil // Places: not a people row, so it has no state to compare
                : makeRowState(primary: primary, people: options.compactMap(\.favorite))
        }
    }

    /// Re-applies the viewer's edits to a freshly built option list: deleted
    /// rows stay gone, known items keep their dragged seats, anything the
    /// refresh added lands at the end (the sort is written as two passes
    /// because `sorted(by:)` is not stable — a rank-or-`Int.max` comparator
    /// would shuffle the newcomers).
    private func orderedByPreference(_ options: [MapSubFilterOption]) -> [MapSubFilterOption] {
        guard let primary = filterBar.selectedFilter else { return options }
        let hidden = subFilterHidden[primary] ?? []
        let options = hidden.isEmpty ? options : options.filter { !hidden.contains($0.subFilter) }
        guard let order = subFilterOrder[primary], !order.isEmpty else { return options }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let known = options.filter { rank[$0.subFilter] != nil }
            .sorted { rank[$0.subFilter, default: 0] < rank[$1.subFilter, default: 0] }
        let newcomers = options.filter { rank[$0.subFilter] == nil }
        return known + newcomers
    }

    /// Pin/unpin a person pill. The rule — including materializing the
    /// never-curated fallback on the first write — belongs to
    /// `MapProfilePinService`, which the profile screen's pin button shares;
    /// the rail then refreshes off the store's change notification rather than
    /// here, so a pin made anywhere lands the same way.
    private func togglePinnedFavorite(_ favorite: MapFavorite) {
        let pinService = pinService
        let id = favorite.profileID
        // These pills ARE the dock, so that is the rail this toggles — the
        // sub-filter rows are edited from the row itself (and from a profile's
        // star), not from here.
        Task {
            var categories = await pinService.categories(for: id)
            if categories.contains(.dock) {
                categories.remove(.dock)
            } else {
                categories.insert(.dock)
            }
            await pinService.setCategories(categories, for: id)
        }
    }

    /// Pure cross-dissolve show/hide. Structure (`isHidden`, stack layout)
    /// always lands OUTSIDE animation blocks: animating `isHidden` on the
    /// arranged subview made the stack interpolate the freshly-laid-out
    /// pills from zero frames — the accordion unfold. The main bar never
    /// moves either way (the stack's BOTTOM is pinned; the row grows upward
    /// into free map space), so nothing but opacity needs animating.
    private func setSubFilterBar(visible: Bool) {
        guard visible != isSubFilterBarVisible else { return }
        isSubFilterBarVisible = visible
        if visible {
            // Un-collapse and lay out at full width while still transparent…
            UIView.performWithoutAnimation {
                subFilterBar.isHidden = false
                barsStack.layoutIfNeeded()
            }
            // …then fade the finished row in, in place (spring-settled,
            // zero bounce — opacity never overshoots).
            UIView.mapBarFade { self.subFilterBar.alpha = 1 }
        } else {
            UIView.mapBarFade(
                { self.subFilterBar.alpha = 0 },
                completion: { _ in
                    // Collapse only after the fade settles — and only if a
                    // re-show didn't land while the fade-out was in flight.
                    guard !self.isSubFilterBarVisible else { return }
                    self.subFilterBar.isHidden = true
                }
            )
        }
    }

    /// Loads the DOCK: the carousel of people pills in the main bar, visible
    /// whatever primary is selected. The curated `.dock` list when there is
    /// one, else the followed profiles — what this carousel has always shown.
    /// Fail-open: an empty result leaves the bar with just its primaries.
    ///
    /// Deliberately NOT scoped to the active primary. The dock is the
    /// top-level filter, and a top-level filter that changes contents when you
    /// pick a primary is a different control wearing the same pills. The two
    /// sub-filter ROWS are where a primary's own people live — see
    /// `people(for:)`.
    private func loadFavorites() {
        #if DEBUG
        // Which surface a write woke is the whole question when the complaint
        // is "the other bar flashed", and it is invisible in a screenshot.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-maps-toggle-subfilter") || arguments.contains("-maps-subfilter-remove")
            || arguments.contains("-maps-pin-favorite") {
            print("[maps] dock reload requested")
        }
        #endif
        favoritesTask?.cancel()
        guard isMember() else {
            currentFavorites = []
            filterBar.setFavorites([])
            return
        }
        let repository = favoritesRepository
        let curated = pinService.curatedProfileIDs(in: .dock)
        favoritesTask = Task { [weak self] in
            let people = if let curated {
                await repository.profiles(for: curated)
            } else {
                await repository.following()
            }
            guard let self, !Task.isCancelled else { return }
            self.currentFavorites = people
            self.filterBar.setFavorites(people)
        }
    }

    /// The row's state as the refresh describes it — built in ONE place, so
    /// what an edit records and what a refresh compares against cannot drift
    /// into disagreeing.
    private func makeRowState(primary: MapFilter, people: [MapFavorite]) -> MapSubFilterRowState {
        MapSubFilterRowState(
            primary: primary,
            people: people,
            hasCatalogue: MapSubFilterOption.rowSurvivesEmpty(
                catalogue: MapSubFilterOption.people(catalogueCache[primary] ?? [])
            )
        )
    }

    /// The rail a people primary curates. Places have no rail — their
    /// refinements are a fixed client-side vocabulary, not a list of accounts.
    private static func railCategory(for primary: MapFilter) -> MapFavoriteCategory? {
        switch primary {
        case .friends: .friends
        case .following: .following
        default: nil
        }
    }

    /// The people a primary's sub-filter row shows: the viewer's curated list
    /// for that row when they have one, else the graph behind it.
    ///
    /// The Friends row additionally INTERSECTS with the live mutual set, so
    /// someone who stops following back leaves the row even though the viewer
    /// once put them there — the row means "friends", and it keeps meaning
    /// that. Their dock pill and their Following row entry are untouched, and
    /// they come back here if they follow back again (the stored list is never
    /// edited for this — see `MapProfilePinService`).
    private func people(for primary: MapFilter) async -> [MapFavorite] {
        let repository = favoritesRepository
        guard let curated = pinService.curatedProfileIDs(in: primary == .friends ? .friends : .following)
        else {
            return primary == .friends ? await repository.friends() : await repository.following()
        }
        let people = await repository.profiles(for: curated)
        guard primary == .friends else { return people }
        let mutuals = Set(await repository.friends().map(\.profileID))
        return people.filter { mutuals.contains($0.profileID) }
    }

    /// Fades both filter bars with the tab bar around the snap-feed flight:
    /// they belong to the map's resting chrome, and lingering pills under a
    /// flying hero card read as debris. Mirrors the manual tab-bar
    /// choreography (hide at lift-off, restore only on the completed pop).
    private func setFilterBar(hidden: Bool) {
        UIView.animate(withDuration: 0.2) { [barsStack] in
            barsStack.alpha = hidden ? 0 : 1
        }
    }

    #if DEBUG
    /// `-maps-trace-chrome`: samples the filter bars' window position every frame,
    /// so "do they move during the grab, and do they snap at the end?" is a number
    /// rather than an impression. Same instrument that found both For You defects.
    private func installChromeTrace() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-trace-chrome") else { return }
        // Weak-target proxy, not `target: self`: a display link retains its
        // target, so the direct form pinned this controller for the life of
        // the process. The proxy dies with the controller; the link retires
        // itself on the next tick.
        let proxy = MapsChromeTraceProxy(target: self)
        CADisplayLink(target: proxy, selector: #selector(MapsChromeTraceProxy.tick))
            .add(to: .main, forMode: .common)
    }

    @objc fileprivate func sampleChrome() {
        guard let window = view.window else { return }
        let bars = barsStack.convert(barsStack.bounds, to: window)
        print(String(
            format: "[maps:%@] barsY=%.2f barsH=%.2f safeB=%.2f viewT=%@ mapT=%@",
            activeTransition == nil ? "rest" : "flight",
            bars.minY, bars.height, view.safeAreaInsets.bottom,
            NSCoder.string(for: view.transform), NSCoder.string(for: mapView.transform)
        ))
    }
    #endif

    private func bindViewModel() {
        viewModel.onDiff = { [weak self] diff in self?.handleDiff(diff) }
        // `onTileCount` is a "zoom in for more" hint hook; wired to UI later.
    }

    /// Folds a diff into the raw model, then re-lays-out the markers — unless a
    /// region change is animating, in which case the layout waits for the
    /// settle (`regionDidChange`), so markers are never restacked mid-flight.
    private func handleDiff(_ diff: MapAnnotationDiff) {
        for pin in diff.removed { pins[pin.postID] = nil }
        for pin in diff.added { pins[pin.postID] = pin }
        for pin in diff.updated { pins[pin.postID] = pin }
        if isRegionTransitioning {
            layoutPending = true
        } else {
            #if DEBUG
            MapChurnCounters.fromDiff += 1
            #endif
            reconcileClusters()
        }
    }

    /// The settle path's reconcile, throttled while the camera is purely panning.
    ///
    /// A pan at an unchanged span cannot change the layout: `MapClusterEngine`
    /// grids on ABSOLUTE `MKMapPoint`s with `cell = cellPoints / zoomScale`, so
    /// the viewport centre is not one of its inputs. Measured under
    /// `-maps-nav-drag` (60 Hz stepped pan, the cadence a finger produces):
    /// **55.6 reconciles/s producing 0 arrivals and 0 rebinds, costing 65 ms/s
    /// of main thread** — 6.5%, against 0.67% under `-maps-nav-sweep`, which
    /// calls `setRegion(animated:)` and so fires this delegate once per gesture
    /// instead of once per frame. The scripted sweep could not see this at all,
    /// and the first version of this analysis concluded there was nothing here.
    ///
    /// ⚠️ It DEFERS, it never drops. The trailing item always runs, so the
    /// layout converges even if the camera stops between two callbacks — a
    /// throttle that skipped the last callback would leave the map permanently
    /// wrong wherever the finger happened to lift.
    ///
    /// A zoom is never throttled. A changed span is exactly the case where the
    /// layout does move, and it is also the case the user is watching.
    private func reconcileClustersForSettle() {
        // The trailing item can land mid-flight, which the settle path never
        // could — `regionDidChangeAnimated` has just cleared the flag when it
        // calls in. Restacking mid-flight is exactly what `isRegionTransitioning`
        // exists to prevent, so hand it to the settle the same way a mid-flight
        // diff is handed over.
        if isRegionTransitioning {
            layoutPending = true
            return
        }
        // ⚠️ OFF BY DEFAULT — it is a MEASURED REGRESSION, kept only so the
        // experiment stays reproducible. `-maps-reconcile-throttle` enables it.
        //
        // It does exactly what it claims: 3 paired 60-second runs, fresh launch
        // per arm, under `-maps-nav-drag`.
        //
        //            reconcile/s   ms/s    cpu    frame    p95   hitches
        //   control       37.21   48.83  48.5%   21.13  38.58     20.87
        //   throttled      7.82   13.30  46.4%   22.01  40.46     28.23
        //
        // 79% of reconciles and 73% of their main-thread time removed — tight
        // across all three reps — and the frame, the p95 and the hitches all got
        // WORSE, every throttled rep above the control's mean. Removing work
        // from the main thread made the map stutter more.
        //
        // The likely mechanism is WHEN, not how much: the inline reconciles ran
        // synchronously inside the region-change callback, a moment the frame
        // had already conceded, while the trailing `asyncAfter` lands at an
        // arbitrary point that can be mid-frame. At 1.3 ms a piece, scheduling
        // dominates volume.
        //
        // ⚠️ A single earlier pair showed hitches 30.9 -> 17.2 and nearly shipped
        // as a 44% win. The control arm alone swings 17.4-27.7 between runs.
        // One pair could not have told these apart.
        guard Self.reconcileThrottleEnabled else {
            #if DEBUG
            MapChurnCounters.fromSettle += 1
            #endif
            reconcileClusters()
            return
        }
        let zoom = currentZoomScale
        guard zoom > 0 else { reconcileClusters(); return }
        let snapped = MapClusterEngine.snapZoom(zoom)
        let now = CACurrentMediaTime()
        let isPurePan = lastSettleSnappedZoom == snapped
        if isPurePan, now - lastSettleReconcileAt < Self.panReconcileInterval {
            #if DEBUG
            MapChurnCounters.settleThrottled += 1
            #endif
            // ⚠️ ARM ONCE. Cancel-and-reschedule is a DEBOUNCE, and a debounce
            // waits for quiet — under a 60 Hz pan the item is cancelled every
            // 16 ms and never fires at all. The first version did exactly that
            // and emptied the map: the opening reconcile ran before the first
            // query returned, every later one was starved, and the readout said
            // `markers 0.0` while every performance column improved. A throttle
            // arms on the first deferred call and lets it land.
            guard trailingSettleReconcile == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.trailingSettleReconcile = nil
                self?.reconcileClustersForSettle()
            }
            trailingSettleReconcile = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.panReconcileInterval - (now - lastSettleReconcileAt)),
                execute: work
            )
            return
        }
        trailingSettleReconcile?.cancel()
        trailingSettleReconcile = nil
        lastSettleSnappedZoom = snapped
        lastSettleReconcileAt = now
        #if DEBUG
        MapChurnCounters.fromSettle += 1
        #endif
        reconcileClusters()
    }

    private func flushPendingDiffs() {
        guard layoutPending else { return }
        layoutPending = false
        #if DEBUG
        MapChurnCounters.fromFlush += 1
        #endif
        reconcileClusters()
    }

    // MARK: - Querying

    private func scheduleQuery() {
        pendingQuery?.cancel()
        // Nothing to fetch for a locked showcase: the world is under the veil
        // (#564). Unlocking flies somewhere, and that settle queries.
        guard !isGuestLocked else { return }
        let work = DispatchWorkItem { [weak self] in self?.runQuery() }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func runQuery() {
        let region = mapView.region
        let viewport = MapViewport.make(
            centerLat: region.center.latitude,
            centerLng: region.center.longitude,
            latitudeSpan: region.span.latitudeDelta,
            longitudeSpan: region.span.longitudeDelta
        )
        viewModel.viewportChanged(viewport)
    }

    // MARK: - Clustering

    /// Re-lays-out the map from the current pin model: `MapClusterEngine`
    /// decides the markers (a `MapAnnotation` per lone pin, a
    /// `MapComputedCluster` per group), and this reconciles them against
    /// what's on screen — updating a surviving marker in place, adding the new,
    /// removing the gone.
    ///
    /// This replaces `MKMapView`'s own clustering, which degrades irreparably
    /// across pan+zoom (see `MapClusterEngine`): the map is handed finished
    /// markers with no `clusteringIdentifier`, so MapKit never runs the pass
    /// that breaks — it just draws each one where we place it.
    ///
    /// Stable markers are LEFT ON THE MAP and updated in place — never removed
    /// and re-added — so they don't flicker. Singles key off their post id
    /// (stable by nature); clusters are matched to the marker they most overlap
    /// (`MapClusterTracker`), because a cluster's representative churns as the
    /// Top-K set shifts and keying off it would fade a settled cluster out and a
    /// near-identical one back in.
    private func reconcileClusters() {
        #if DEBUG
        MapChurnCounters.reconciles += 1
        let reconcileStart = DispatchTime.now().uptimeNanoseconds
        let pinFingerprint = pins.count &* 31 &+ (pins.keys.first?.rawValue.hashValue ?? 0)
        if pinFingerprint == lastReconciledPinFingerprint { MapChurnCounters.withUnchangedPins += 1 }
        lastReconciledPinFingerprint = pinFingerprint
        defer {
            MapChurnCounters.recordReconcile(
                micros: Int((DispatchTime.now().uptimeNanoseconds - reconcileStart) / 1_000)
            )
        }
        #endif
        // ⚠️ A ZERO SCALE IS NOT A ZOOM, IT IS A NOT-YET. The engine's own
        // degenerate path ships EVERY pin as an unclustered single, and this
        // runs from `regionDidChangeAnimated`, which fires when the map is
        // re-attached — so one reconcile against a rect that has not resolved
        // exploded the whole map to member coordinates and re-collapsed a frame
        // later. Deferred instead: `layoutPending` is what the next real
        // layout drains.
        guard currentZoomScale > 0 else {
            layoutPending = true
            return
        }
        #if DEBUG
        // `-maps-no-clustering`: every pin becomes its own marker.
        //
        // ⚠️ It exists because the SHIPPING map cannot produce its own designed
        // worst case. `MapClusterEngine`'s proximity merge recomputes each
        // cluster's centroid, so merges CHAIN and a dense uniform field
        // collapses instead of packing the 64pt lattice — measured invariant at
        // 19 markers whether the corpus is fed 5x, 15x or 40x. The 128-marker
        // figure every budget in this feature is sized against is a GEOMETRIC
        // bound, and this flag is the only way to stand a field of that size in
        // front of the real renderer.
        //
        // It is not a product mode and must never become one: without the merge
        // the map has no answer for a dense city.
        let unclustered = ProcessInfo.processInfo.arguments.contains("-maps-no-clustering")
        #else
        let unclustered = false
        #endif

        // ⚠️ SORTED, because the proximity merge downstream is order-dependent
        // (see `proximityCluster`). A dictionary's values re-order whenever it is mutated, and
        // every return to this screen re-queries — so the markers moved on a map
        // nobody had panned.
        let ordered = pins.values.sorted { $0.postID.rawValue < $1.postID.rawValue }
        // ⚠️ OPEN AND LOCKED POSTS ARE NEVER GROUPED TOGETHER.
        //
        // A locked country's posts are on the map — its markers wear its
        // busiest posts, darkened under a lock — but a marker is ONE tap: it
        // opens every post it holds, or it offers a country. A group mixing
        // the two would either open locked posts or lock open ones. The engine
        // groups each side apart (`isOpen`); at a hierarchy band it also
        // decides their collisions — the open marker stays, the locked one is
        // hidden — and below the bands MapKit does (`MapMarkerDress
        // .lockedPriority`).
        let items = layOut(ordered, unclustered: unclustered)
        // A country whose marker is HIDDEN behind a stronger neighbour still
        // has posts: it is not an empty country, so it wears no flag disc.
        reportCountriesWithMarkers(items + bandOcclusion.hiddenItems)
        reconcile(items)
    }

    /// Tells the country layer which countries a post marker now stands for —
    /// every member's, so a country whose posts merged into a neighbour's
    /// marker does not also wear an empty country's disc.
    private func reportCountriesWithMarkers(_ items: [MapClusterEngine.Item]) {
        var codes = Set<String>()
        for item in items {
            for id in item.memberIDs {
                guard let pin = pins[id] else { continue }
                let code = countryCode(of: pin)
                if !code.isEmpty { codes.insert(code) }
            }
        }
        countryLayer.setCountriesWithMarkers(codes)
    }

    /// Reconciles `items` — the engine's layout — against the markers on the
    /// map. See `reconcileClusters`.
    private func reconcile(_ items: [MapClusterEngine.Item]) {
        var target = Set<String>()
        target.reserveCapacity(items.count)
        var toAdd: [MKAnnotation] = []

        // Singles: one pin, one identity — reuse or reclaim by post id.
        for item in items where !item.isCluster {
            let id = Self.singleIdentity(item.representative.postID)
            target.insert(id)
            if let existing = displayed[id] {
                update(existing, to: item)
            } else if let reclaimed = popChoreographer.reclaim(id) {
                update(reclaimed, to: item)
                displayed[id] = reclaimed
            } else {
                let annotation = Self.makeAnnotation(for: item)
                displayed[id] = annotation
                toAdd.append(annotation)
            }
        }

        // Clusters: match by shared membership so a marker persists through the
        // representative churn. Candidates are the shown clusters PLUS the ones
        // still fading out — matching a returning cluster to a departing marker
        // reclaims it instead of stacking a duplicate.
        let clusterItems = items.filter(\.isCluster)
        var candidates: [MapClusterTracker.Candidate] = []
        var candidateIsDeparting: [String: Bool] = [:]
        for (key, annotation) in displayed {
            guard let cluster = annotation as? MapComputedCluster else { continue }
            candidates.append(.init(key: key, members: Set(cluster.memberIDs)))
            candidateIsDeparting[key] = false
        }
        for (key, annotation) in popChoreographer.departingMarkers {
            guard let cluster = annotation as? MapComputedCluster else { continue }
            candidates.append(.init(key: key, members: Set(cluster.memberIDs)))
            candidateIsDeparting[key] = true
        }
        // ⚠️ SORTED BEFORE THE ASSIGN. `MapClusterTracker.assign` documents a
        // tie-break on the CANDIDATE INDEX — which is only deterministic if
        // the caller supplies a defined one, and both loops above walk
        // dictionaries.
        candidates.sort { $0.key < $1.key }

        let matches = MapClusterTracker.assign(
            incoming: clusterItems.map { Set($0.memberIDs) }, candidates: candidates
        )
        for (item, matchedKey) in zip(clusterItems, matches) {
            if let key = matchedKey {
                target.insert(key)
                if candidateIsDeparting[key] == true, let reclaimed = popChoreographer.reclaim(key) {
                    update(reclaimed, to: item)
                    displayed[key] = reclaimed
                } else if let existing = displayed[key] {
                    update(existing, to: item)
                }
            } else {
                clusterMarkerSeq += 1
                let key = "c:\(clusterMarkerSeq)"
                let annotation = Self.makeAnnotation(for: item)
                displayed[key] = annotation
                toAdd.append(annotation)
                target.insert(key)
            }
        }

        // Departures: the still-shown markers no target claimed. Hand them to
        // the choreographer to scale-and-fade out (mirroring the arrival),
        // which removes them from the map when the animation ends. They leave
        // `displayed` now — the choreographer is their sole owner until then.
        let departing = displayed.filter { !target.contains($0.key) }
        for id in departing.keys { displayed[id] = nil }
        // A marker that leaves before its view was ever realized is no longer
        // an arrival, and its identifier would otherwise sit in the set for the
        // life of the screen.
        for annotation in departing.values {
            pendingPopIn.remove(ObjectIdentifier(annotation as AnyObject))
        }
        popChoreographer.popOut(departing.map { (id: $0.key, annotation: $0.value) })

        #if DEBUG
        MapChurnCounters.added += toAdd.count
        MapChurnCounters.departed += departing.count
        #endif
        if !toAdd.isEmpty {
            pendingPopIn.formUnion(toAdd.map { ObjectIdentifier($0 as AnyObject) })
            mapView.addAnnotations(toAdd)
        }
        refreshVideoPlayback()
    }

    /// The engine's layout of `ordered` (see `reconcileClusters`).
    /// Singles go through the SAME reconciliation, so what
    /// `-maps-no-clustering` measures is the real marker lifecycle and not a
    /// parallel code path that happens to look similar.
    private func layOut(_ ordered: [MapPin], unclustered: Bool) -> [MapClusterEngine.Item] {
        // Nothing goes through the band: nothing is hidden behind anything.
        if ordered.isEmpty || unclustered { bandOcclusion = MapClusterEngine.Occlusion() }
        guard !ordered.isEmpty else { return [] }
        return unclustered
            ? ordered.map {
                MapClusterEngine.Item(
                    representative: $0, memberIDs: [$0.postID],
                    latitude: $0.latitude, longitude: $0.longitude, place: $0.place
                )
            }
            : MapClusterEngine.cluster(
                ordered,
                // Snapped, so an epsilon in the viewport cannot move every grid
                // line at once — see `MapClusterEngine.snapZoom`.
                zoomScale: MapClusterEngine.snapZoom(currentZoomScale),
                cellPoints: Double(Self.clusterCellPoints),
                // The semantic pre-pass's two banding inputs: the zoom level is
                // the FALLBACK for an H3-less corpus; the viewport diagonal
                // drives the dynamic cell-span rule (`MapHierarchyBanding`)
                // whenever the ladder carries H3 indexes.
                zoomLevel: MapViewport.zoomLevel(
                    forLongitudeSpan: mapView.region.span.longitudeDelta
                ),
                viewportDiagonalKm: currentViewportDiagonalKm,
                isOpen: { self.isInUnlockedCountry($0) },
                occlusion: &bandOcclusion
            )
    }

    private static func singleIdentity(_ postID: PostID) -> String { "p:" + postID.rawValue }

    /// The marker a FRESH engine item becomes — a group's cluster, or a lone
    /// pin carrying its band's place when it is one (`hierarchyPlace`).
    /// Static so the tests build markers the way the map does, and route them
    /// through the same `hierarchyPlace(of:)` a tap asks.
    static func makeAnnotation(for item: MapClusterEngine.Item) -> any MKAnnotation {
        item.isCluster
            ? MapComputedCluster(item)
            : MapAnnotation(pin: item.representative, hierarchyPlace: item.hierarchyPlace)
    }

    /// Splits a batch of realized views into the ones that are ARRIVING and the
    /// ones that are merely being drawn again.
    ///
    /// Pure and static for the same reason `stack(_:inserting:beneath:)` is:
    /// the rule needs no live `MKMapView`, and getting it wrong is invisible in
    /// a screenshot — it only shows up as a map that re-lands every time the
    /// viewer comes back to it.
    static func popPartition<View>(
        _ views: [View], pending: Set<ObjectIdentifier>,
        identity: (View) -> ObjectIdentifier?
    ) -> (arriving: [View], settled: [View]) {
        var arriving: [View] = []
        var settled: [View] = []
        for view in views {
            if let id = identity(view), pending.contains(id) {
                arriving.append(view)
            } else {
                settled.append(view)
            }
        }
        return (arriving, settled)
    }

    /// The place page's way home: a closure producing a FRESH flight source
    /// for `annotation`'s marker, resolved when the page stages its own
    /// dismissal — the marker's face, ring and even presence can all have
    /// changed since the tap, so nothing is captured beyond the annotation's
    /// identity. `nil` when the marker has left the map entirely, which is
    /// the page's cue to keep the plain slide (the fallback dismissal).
    /// `departureStill` draws the screen the flight is leaving — see the seam's
    /// own doc. Asked at STAGING, so it costs one render on the first frame of
    /// the gesture and nothing at all when the flight never happens.
    private func makeMapReturnSource(
        for annotation: any MKAnnotation
    ) -> (@escaping () -> UIImage?) -> (any ZoomTransitionSource)? {
        { [weak self, weak box = annotation as AnyObject] departureStill in
            guard let self, let box, let annotation = box as? any MKAnnotation,
                  self.mapView.annotations.contains(where: { ($0 as AnyObject) === box })
            else { return nil }
            let view = self.mapView.view(for: annotation)
            let thumbnail = (view as? MapClusterAnnotationView)?.heroImage
                ?? (view as? MapAnnotationView)?.heroImage
            let cluster = annotation as? MapComputedCluster
            return MapPinZoomSource(
                mapView: self.mapView,
                annotation: annotation,
                thumbnail: thumbnail,
                face: Self.face(of: annotation),
                dress: self.dress(for: annotation),
                // ⚠️ THE WHOLE DEPARTING SCREEN, not a post's cover. Every other
                // departure on this source is one post leaving another; here a
                // GRID is collapsing into an icon, and without an operand the
                // card wore that icon from the first frame — a full-screen page
                // cutting straight to a 44pt disc with nothing carried across.
                //
                // Resolved through the same channel a post's picture uses, so
                // the blend does not learn a second shape.
                departureCover: { departureStill().map { .picture($0) } ?? .none }
            )
        }
    }

    /// The place page's way home as a WINDOW onto the marker — the close a
    /// text post opened from that marker already takes (`markerRevealOrigin`).
    ///
    /// ⚠️ NOT THE HERO. The page used to fly home through `MapPinZoomSource`,
    /// whose card is the MARKER's face: under a grab the page was hidden
    /// outright and a marker-shaped sliver of it rode the finger over a black
    /// screen (filmed, 26 September 2026). A window keeps the page itself
    /// under the finger, shrinks it as it is dragged, and closes it onto the
    /// marker with the reveal's crossfade — "prendre le contenu de la fenêtre
    /// de lieu actuelle et au release faire notre hero transition habituelle".
    ///
    /// Asked at close time, so the marker's rect is where the map shows it
    /// now; nil once the marker is gone, which keeps the plain slide.
    private func makeMarkerClose(
        for annotation: any MKAnnotation
    ) -> (UIViewController) -> RevealGeometry? {
        { [weak self, weak box = annotation as AnyObject] page in
            guard let self, let box, let annotation = box as? any MKAnnotation,
                  self.mapView.annotations.contains(where: { ($0 as AnyObject) === box })
            else { return nil }
            // No "will close" chrome work: unlike a feed, the place page
            // SHOWS the dock (`concealsAppTabBar == false`), so there is
            // nothing to hide ahead of the window and nothing to bring back.
            return self.makeRevealGeometry(page, self.markerRevealOrigin(for: annotation), nil)
        }
    }

    // MARK: - The picture the viewer is leaving

    /// What a flight home to `annotation` has to dissolve away, asked when the
    /// dismissal stages.
    ///
    /// The ARRIVAL is `postIDs(of:).first` — the marker's representative, which
    /// is also the post the flight opened from, because that is the order the
    /// feed was seeded in. The map never substitutes: the marker the viewer
    /// tapped has not moved and is what they expect to fall back onto, so what
    /// adapts is the card's departure face, never its landing.
    private func returnCover(
        to annotation: any MKAnnotation, leaving feed: UIViewController?
    ) -> MapReturnCover {
        let settled = feed as? any SnapFeedSettleReporting
        let departure = settled?.settledPostID
        let arrival = Self.postIDs(of: annotation).first
        let cover = MapReturnCover.resolve(
            departure: departure,
            arrival: arrival,
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
    private func awaitReturnCover(
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
    private func update(_ annotation: any MKAnnotation, to item: MapClusterEngine.Item) {
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
    }

    /// Screen points per map point at the current region — the projection the
    /// engine grids in. Guarded so a zero-width rect (before first layout)
    /// can't divide by zero.
    private var currentZoomScale: Double {
        let mapWidth = mapView.visibleMapRect.size.width
        guard mapWidth > 0 else { return 0 }
        return Double(mapView.bounds.width) / mapWidth
    }

    /// The camera viewport's diagonal in km — what the dynamic hierarchy
    /// banding compares H3 cell spans against. Flat-earth arithmetic (111 km
    /// per degree, longitude scaled by the latitude's cosine) is exact
    /// enough at banding scales.
    private var currentViewportDiagonalKm: Double {
        let region = mapView.region
        let latKm = region.span.latitudeDelta * 111.0
        let lngKm = region.span.longitudeDelta * 111.0
            * max(0.01, cos(region.center.latitude * .pi / 180))
        return (latKm * latKm + lngKm * lngKm).squareRoot()
    }

    // MARK: - Live previews

    /// Recomputes the ≤3 video pins to autoplay: the on-screen, video-capable,
    /// LONE pins (a clustered post isn't its own marker), ranked by closeness
    /// to the viewport center.
    private func refreshVideoPlayback() {
        // The same moments decide the one preroll (#654): markers arrived, the
        // map settled, came back into view.
        scheduleIdlePreroll()
        let center = mapView.centerCoordinate
        let visibleRect = mapView.visibleMapRect
        var scored: [(distance: Double, candidate: MapVideoPlaybackCoordinator.Candidate)] = []
        for annotation in displayed.values {
            // The pin a marker SPEAKS FOR: itself when it is a lone pin, its
            // representative when it is a cluster.
            //
            // A cluster's face is one of its members' posts and representatives
            // are kind-neutral, so a video post leading a group is ordinary. It
            // could never play before, because the candidate's view was typed
            // to the lone-pin class — and on the mock corpus that meant nothing
            // ever played at all: every video pin in the default viewport was
            // inside a cluster.
            var spokenPin: MapPin?
            var host: (any MapVideoHost)?
            if let single = annotation as? MapAnnotation {
                spokenPin = single.pin
                host = mapView.view(for: single) as? MapAnnotationView
            } else if let group = annotation as? MapComputedCluster {
                spokenPin = group.representative
                host = mapView.view(for: group) as? MapClusterAnnotationView
            }
            // A locked country's marker plays nothing: it is a teaser, darkened,
            // and its post is not the viewer's to watch.
            guard let pin = spokenPin, let host,
                  isInUnlockedCountry(pin),
                  pin.kind == .video,
                  let url = pin.previewVideoURL,
                  visibleRect.contains(MKMapPoint(annotation.coordinate))
            else { continue }
            let candidate = MapVideoPlaybackCoordinator.Candidate(
                id: pin.postID, url: url, host: host
            )
            scored.append((Self.squaredDistance(annotation.coordinate, center), candidate))
        }
        let ranked = scored.sorted { $0.distance < $1.distance }.map(\.candidate)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-map-icon-hud-log") {
            let lone = displayed.values.compactMap { $0 as? MapAnnotation }
            let groups = displayed.values.compactMap { $0 as? MapComputedCluster }
            print("MAPVIDEO lone=\(lone.count) clusters=\(groups.count) "
                  + "loneVideo=\(lone.count { $0.pin.kind == .video }) "
                  + "clusterVideo=\(groups.count { $0.representative.kind == .video }) "
                  + "onScreen=\(scored.count) chosen=\(ranked.count)")
        }
        #endif
        videoCoordinator.update(candidates: ranked)
    }

    private static func squaredDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLng = a.longitude - b.longitude
        return dLat * dLat + dLng * dLng
    }

    // MARK: - Predictive prefetch

    /// Warms the full post behind every visible annotation — the first member for
    /// a cluster — so a tap opens the snap feed from cache with no metadata
    /// desync. Bounded by clustering (a handful of annotations) and capped;
    /// cancels the prior sweep so a fast pan never piles up speculative fetches.
    /// The ONLY place in this feature that writes the map's interaction.
    ///
    /// ⚠️ ONE WRITE, NOT FOUR FLAGS. `isUserInteractionEnabled` covers both
    /// halves at once — MapKit's own pan/pinch/rotate AND every marker's
    /// instant-tap recognizer, which is attached to the annotation VIEW.
    /// Hit-testing never descends into a view that is not interactive, so one
    /// write starves both; `isScrollEnabled` and friends would leave the marker
    /// recognizers live, which is exactly the "a second post opened over the
    /// first" case. Programmatic `selectAnnotation` is unaffected, so the DEBUG
    /// openers and any deep link still work.
    ///
    /// The map's own bar items go with it: they sit ABOVE the transition
    /// container, so neither the hero's shield nor the reveal's host covers
    /// them, and the bell pushes onto the very stack the flight is animating.
    private func applyMapInteraction() {
        let inert = openGate.mapIsInert
        // The guest lock rides the SAME write (#564): two writers of one
        // property would undo each other.
        mapView.isUserInteractionEnabled = Self.mapIsInteractive(inert: inert, guestLocked: isGuestLocked)
        navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = !inert }
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = !inert }
    }

    #if DEBUG
    /// Drives one soak cycle when the map is idle and cycles remain.
    ///
    /// Called from the gate's own idle transitions, which is the only honest
    /// "the map is ready again" signal there is — a fixed delay would race the
    /// spring's tail, and this file's history is full of measurements ruined by
    /// exactly that.
    private func advanceSoakIfNeeded() {
        guard soakCyclesRemaining > 0 else { return }
        // ⚠️ EVERY UNMET PRECONDITION RETRIES, and it took two goes to get this
        // right. The advance is EDGE-TRIGGERED on the gate, so any condition
        // that is merely not-yet-true at that instant loses the cycle and every
        // cycle after it — silently, because a soak that stops looks exactly
        // like a soak that finished.
        //
        // The first version retried only on an empty annotation list, which was
        // a guess. The trace named the real one: after popping home from the
        // place page the gate opens while the map is still off-window
        // (`window=n annotations=4`), one runloop turn before UIKit reattaches
        // it. Retrying on the conjunction covers both, and whatever the third
        // one turns out to be.
        guard openGate.canOpen, view.window != nil else { return scheduleSoakRetry() }
        // ⚠️ HIERARCHY MARKERS FIRST, and the ordering is the only way to reach
        // the place page at all. That page is carried beneath the feed of a
        // CITY or COUNTRY cluster and nothing else, and it is uncovered by a
        // vertical close — so a soak that takes markers in post-id order can
        // run for eight cycles without ever meeting one, which is what the
        // first three runs did. Post-id order still decides everything after,
        // because MapKit's own annotation order is undefined.
        let ordered = mapView.annotations
            .compactMap { annotation -> (id: String, hierarchy: Bool, value: any MKAnnotation)? in
                if let pin = annotation as? MapAnnotation {
                    (pin.pin.postID.rawValue, false, annotation)
                } else if let cluster = annotation as? MapComputedCluster {
                    (cluster.representative.postID.rawValue, cluster.isHierarchyMarker, annotation)
                } else { nil }
            }
            .sorted { ($0.hierarchy ? 0 : 1, $0.id) < ($1.hierarchy ? 0 : 1, $1.id) }
        // ⚠️ RETRY RATHER THAN DROP. The advance is edge-triggered on the gate,
        // so a map whose annotations have not been re-added yet — which is the
        // ordinary state one runloop turn after popping home — would lose that
        // cycle and every cycle after it, silently. The first place-page soak
        // ran exactly one of its six cycles this way.
        guard !ordered.isEmpty else { return scheduleSoakRetry() }
        let hierarchyCount = ordered.filter(\.hierarchy).count
        let target = (ordered[soakCursor % ordered.count].id,
                      ordered[soakCursor % ordered.count].value)
        soakCursor += 1
        soakCyclesRemaining -= 1
        print("[soak] cycle \(soakCursor) opening \(target.0) of \(ordered.count) markers"
              + " (\(hierarchyCount) hierarchy)")
        // One runloop turn, so this never runs inside the gate's own didSet.
        DispatchQueue.main.async { [weak self] in
            self?.mapView.selectAnnotation(target.1, animated: true)
        }
        soakGeneration += 1
        let generation = soakGeneration
        // ⚠️ A WATCHDOG PER CYCLE, because a soak that hangs reports nothing at
        // all — and "the round trip never came back" is the single most
        // important thing this harness can find. A cycle that has not returned
        // the map to idle by here is named, counted and force-closed, so the
        // run continues and the log says which marker did it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.soakGeneration == generation, !self.openGate.canOpen else { return }
            // ⚠️ RESTING ON THE PLACE PAGE IS NOT BEING STUCK. A vertical close
            // lands there on purpose and the map is one pop away, so the soak
            // pops and carries on. Calling that a hang is how a working route
            // gets reported as a broken one — which is exactly what the first
            // run of this path did, before the landing was even reported.
            let resting = self.openGate.isAtIntermediate
            print("[soak] cycle \(generation) \(resting ? "at the place page" : "STUCK")"
                  + " on \(target.0) — popping home")
            self.navigationController?.popToViewController(self, animated: false)
            self.openGate.appearedAtRoot()
        }
        // ⚠️ SCHEDULED FROM HERE AND NOT FROM A LANDING CALLBACK, because only
        // ONE of the three routes has one. `onDestinationShown` belongs to the
        // hero's transition controller; a reveal and a plain push have no such
        // hook on this side, and a soak that can only close a hero would stall
        // on the first text marker it met — which is exactly what the first run
        // did.
        //
        // ⚠️ BUT ON THE LANDING, NOT ON A CLOCK. It used to fire at a fixed
        // 2.5 s with no generation check: on a slow simulator the flight had
        // not landed, so the close grabbed a flight still presenting (or found
        // nothing to close), and a close that ran late could hit the NEXT
        // cycle's flight. It now waits for `soakFlightHasLanded` — which reads
        // each route's own landing, see there — and is keyed by this cycle's
        // generation, so a stale close is a no-op. Given up just before the
        // 12 s watchdog, which then names and force-closes the cycle.
        QAWait.until("[soak] close cycle \(generation) on \(target.0)", timeout: 10, { [weak self] in
            guard let self else { return true }
            return soakGeneration != generation || soakFlightHasLanded
        }) { [weak self] in
            guard let self, soakGeneration == generation else { return }
            closeSoakedFeed()
        }
    }

    /// Whether the soak's current flight is on screen and still — the moment a
    /// finger could close it.
    ///
    /// The hero reports its own landing (`onDestinationShown` →
    /// `destinationShown()` → `.open`). The reveal and the plain push have no
    /// landing hook on this side (see `MapOpenGate.appearedAtRoot`: they sit in
    /// `.presenting` for the whole round trip), so for those the landing is
    /// the stack itself: something other than the map on top and no push
    /// transition still running.
    private var soakFlightHasLanded: Bool {
        guard let nav = navigationController,
              nav.transitionCoordinator == nil,
              nav.topViewController !== self else { return false }
        switch openGate.state {
        case .open: return true
        case .presenting(let route): return route != .hero
        case .idle, .dismissing, .intermediate: return false
        }
    }

    /// Re-checks shortly, at most one pending check at a time.
    private func scheduleSoakRetry() {
        guard !soakRetryScheduled else { return }
        soakRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.soakRetryScheduled = false
            self?.advanceSoakIfNeeded()
        }
    }

    /// Closes whatever the soak opened, by the same path a finger would take on
    /// that route.
    ///
    /// The hero gets `debugScriptedGrab` — one release below the threshold and
    /// one above it, so a cycle exercises BOTH dismissal outcomes rather than
    /// only the happy path. The reveal and the plain push have no interactive
    /// script on this side, so they are popped, which is the chevron's own path
    /// through the same animator.
    private func closeSoakedFeed() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-soak") else { return }
        if let transition = activeTransition {
            // ⚠️ ALTERNATING AXES, because the two go to DIFFERENT SCREENS. A
            // horizontal close lands on the marker; a vertical one lands on the
            // place page a hierarchy marker carries beneath its feed — the
            // route that fires `dismissedToIntermediate`, leaves the gate in
            // `.intermediate`, and is then popped home by a second gesture. A
            // soak that only ever closes sideways never reaches it, which is
            // exactly what the first three runs did.
            transition.debugScriptedGrab(axis: soakCursor % 2 == 0 ? .horizontal : .vertical)
        } else if navigationController?.topViewController !== self {
            navigationController?.popViewController(animated: true)
        }
    }
    #endif

    private func prewarmVisiblePosts() {
        let visible = mapView.annotations(in: mapView.visibleMapRect)
        var ids: [PostID] = []
        var seen = Set<PostID>()
        func add(_ id: PostID) { if seen.insert(id).inserted { ids.append(id) } }
        for element in visible {
            // A locked marker never opens, so there is nothing to warm.
            if let pin = element as? MapAnnotation, isInUnlockedCountry(pin.pin) {
                add(pin.pin.postID)
            } else if let cluster = element as? MapComputedCluster, isInUnlockedCountry(cluster.representative) {
                cluster.memberIDs.forEach(add)
            }
        }
        guard !ids.isEmpty else { return }

        let batch = Array(ids.prefix(Self.prewarmCap))
        prewarmTask?.cancel()
        let prewarm = prewarm
        prewarmTask = Task { await prewarm(batch) }
    }
}

// MARK: - MKMapViewDelegate

extension MapsViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        countryLayer.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // A zoom/pan started: hold annotation mutations until it settles.
        isRegionTransitioning = true
        idlePrerollWork?.cancel()
        #if DEBUG
        OfferLog.note("region will change")
        #endif
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Settled. The zoom level changed, so re-lay-out the clusters now (with
        // the settled projection), fold in anything a mid-flight diff staged,
        // then request the next page.
        isRegionTransitioning = false
        #if DEBUG
        logSettledCamera()
        #endif
        reconcileClustersForSettle()
        flushPendingDiffs()
        scheduleQuery()
        idlePrerollRested = false
        idlePrerollRetries = 0
        scheduleIdlePreroll()
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Land the ARRIVALS: scale-and-fade in, staggered across the batch.
        // This still fires for pins panning into the rendered region, not only
        // for a fresh query — which is what makes the map feel populated rather
        // than stamped.
        //
        // ⚠️ BUT NOT FOR EVERY VIEW MapKit HANDS OVER. It realizes the whole
        // visible set when the map comes back from a push, so popping the batch
        // meant the entire map re-landed on every return with nothing having
        // changed. The others are settled instead — explicitly, because a
        // recycled view can still be carrying a cancelled pop's alpha.
        let batch = Self.popPartition(views, pending: pendingPopIn) { view in
            view.annotation.map { ObjectIdentifier($0 as AnyObject) }
        }
        for view in batch.arriving {
            view.annotation.map { pendingPopIn.remove(ObjectIdentifier($0 as AnyObject)) }
        }
        // ⚠️ ONLY WHAT HAS SOMETHING TO SHOW LANDS. The map adds annotations
        // first and fetches their pictures second, never awaited, so popping
        // the whole batch lands bare squares that fill in afterwards. A marker
        // that is not dressed yet is held at zero and let in by its own report
        // — see `MapMarkerDressing` and `MapAnnotationPop.hold`.
        let dressed = batch.arriving.filter { ($0 as? any MapMarkerDressing)?.isDressed ?? true }
        let undressed = batch.arriving.filter { !(($0 as? any MapMarkerDressing)?.isDressed ?? true) }
        popChoreographer.popIn(dressed)
        popChoreographer.hold(undressed)
        popChoreographer.settle(batch.settled)
        // Annotation views now exist (clustering is current) → bind autoplay and
        // warm the visible posts so a tap opens instantly.
        refreshVideoPlayback()
        prewarmVisiblePosts()
        #if DEBUG
        debugOpenFirstPinIfRequested(among: views)
        debugOpenFirstClusterIfRequested(among: views)
        #endif
    }

    #if DEBUG
    /// The value following a `-flag value` DEBUG launch argument, read from
    /// the process arguments and NOWHERE else.
    ///
    /// These hooks used to read `UserDefaults.standard.string(forKey:)`, which
    /// is a superset: it resolves the argument domain, but also every
    /// PERSISTED domain. Anything that had ever written `maps-select-filter`
    /// into a simulator's preference store — a stray `defaults write`, a
    /// device-level plist surviving an app reinstall — was then replayed on
    /// EVERY launch, scripting a filter selection with no launch argument
    /// present and leaving the map booted into a filtered state nobody asked
    /// for. Scanning the arguments makes the hooks strictly opt-in per launch,
    /// so the resting default is unfiltered by construction.
    /// `-maps-set-region <lat>,<lng>,<spanDegrees>`, parsed — nil without it.
    /// Read raw rather than through `debugArgumentValue`: a southern or
    /// western framing starts with a minus sign ("-33.4,151.2,40").
    static var debugSetRegion: MKCoordinateRegion? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-maps-set-region"),
              position + 1 < arguments.count else { return nil }
        let parts = arguments[position + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
            span: MKCoordinateSpan(latitudeDelta: parts[2], longitudeDelta: parts[2])
        )
    }

    static func debugArgumentValue(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        // A bare flag followed by another flag carries no value.
        guard !value.hasPrefix("-") else { return nil }
        return value
    }

    /// `-maps-open-first-pin`: taps a pin shortly after it appears so the hero
    /// transition into the snap feed can be driven/screenshotted in the sim.
    /// Prefers a video pin when any exists (with `-maps-force-video`), so
    /// live-media flights are exercised deterministically.
    ///
    /// `-maps-open-first-text-pin` picks a TEXT pin instead — the flight whose
    /// card carries the symbol face rather than a cover, which is otherwise
    /// only reachable by finding one of them by hand on the map.
    private func debugOpenFirstPinIfRequested(among views: [MKAnnotationView]) {
        let arguments = ProcessInfo.processInfo.arguments
        // `-maps-soak <cycles>`: arm once, then drive from the gate.
        if soakCyclesRemaining == 0, !didDebugOpenPin,
           let index = arguments.firstIndex(of: "-maps-soak"), index + 1 < arguments.count,
           let cycles = Int(arguments[index + 1]), cycles > 0 {
            didDebugOpenPin = true
            soakCyclesRemaining = cycles
            print("[soak] armed for \(cycles) cycles")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.advanceSoakIfNeeded()
            }
            return
        }
        // `-maps-open-post <id>`: open THAT post, not whichever one happens to
        // be first.
        //
        // ⚠️ `-maps-open-first-pin` picks by kind and then by MapKit's
        // annotation order, which is undefined — so two runs open two different
        // posts, and a transition A/B across two builds compares two different
        // flights. Three such comparisons proved nothing before this existed.
        if let index = arguments.firstIndex(of: "-maps-open-post"),
           index + 1 < arguments.count {
            let wanted = arguments[index + 1]
            guard !didDebugOpenPin,
                  views.contains(where: { ($0.annotation as? MapAnnotation)?.pin.postID.rawValue == wanted })
            else { return }
            didDebugOpenPin = true
            debugSelectMarker("-maps-open-post \(wanted)") { annotations in
                annotations.compactMap { $0 as? MapAnnotation }
                    .first { $0.pin.postID.rawValue == wanted }
            }
            return
        }
        // `-maps-open-place-id <placeID>` ("country:kenya", "city:barcelona"):
        // taps the marker that IS that place, cluster or band single alike —
        // the place-page route of one named city or country, where the
        // cluster openers pick by size and never reach a one-post country.
        // Pair with `-maps-set-region` to frame the band it shows at.
        if let wanted = Self.debugArgumentValue("-maps-open-place-id") {
            guard !didDebugOpenPin,
                  views.contains(where: {
                      $0.annotation.flatMap(Self.hierarchyPlace(of:))?.id == wanted
                  })
            else { return }
            didDebugOpenPin = true
            debugSelectMarker("-maps-open-place-id \(wanted)", { annotations in
                annotations.first { Self.hierarchyPlace(of: $0)?.id == wanted }
            }, then: { tapped in
                print("[maps] place tap → \(wanted) posts=\(Self.postIDs(of: tapped).count)"
                    + " cluster=\(tapped is MapComputedCluster)")
            })
            return
        }
        let wantsText = arguments.contains("-maps-open-first-text-pin")
        guard !didDebugOpenPin,
              wantsText || arguments.contains("-maps-open-first-pin") else { return }
        let preferred: MapPin.Kind = wantsText ? .text : .video
        // The same pick at arm time and at fire time: by kind, then any pin
        // (media only). At fire time the post armed on is preferred, so a
        // re-cluster that kept it does not swap the subject under the run.
        let pick: @MainActor ([MapAnnotation]) -> MapAnnotation? = { annotations in
            annotations.first(where: { $0.pin.kind == preferred })
                ?? (wantsText ? nil : annotations.first)
        }
        guard let armed = pick(views.compactMap { $0.annotation as? MapAnnotation }) else { return }
        didDebugOpenPin = true
        let armedID = armed.pin.postID
        debugSelectMarker(wantsText ? "-maps-open-first-text-pin" : "-maps-open-first-pin") { annotations in
            let pins = annotations.compactMap { $0 as? MapAnnotation }
            return pins.first { $0.pin.postID == armedID } ?? pick(pins)
        }
    }

    /// Taps the marker `resolve` picks from the map's CURRENT annotations,
    /// once there is one the map could open.
    ///
    /// ⚠️ RE-RESOLVED AT FIRE TIME, NEVER CAPTURED. The openers used to keep
    /// the annotation `didAdd` handed them and select it a second later. A
    /// query response landing in that second re-clusters the map, the
    /// captured object is no longer in `mapView.annotations`, the select is a
    /// no-op — and the one-shot latch (`didDebugOpenPin`) forbids a retry, so
    /// the run opened nothing and said nothing. This picks again from what is
    /// on the map when it fires (the soak's own rule, `advanceSoakIfNeeded`),
    /// waits for the pick to have a view and the gate to be open, and prints
    /// a GAVE UP line if that never happens.
    ///
    /// The 1 s before the first look is pacing, not a readiness guess: the
    /// marker's pop-in lands before it is tapped, so the flight leaves from a
    /// settled marker rather than one still scaling up.
    private func debugSelectMarker(
        _ label: String,
        _ resolve: @escaping @MainActor ([any MKAnnotation]) -> (any MKAnnotation)?,
        then willSelect: (@MainActor (any MKAnnotation) -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Picked among the markers that have a VIEW — what the old
            // `didAdd` batch was, and what a flight can leave from. Resolved
            // in the check and again in the action: the action runs in the
            // same turn the check passed, so both see the same map.
            let shown: @MainActor (MKMapView) -> [any MKAnnotation] = { mapView in
                mapView.annotations.filter { mapView.view(for: $0) != nil }
            }
            QAWait.until(label, timeout: 20, { [weak self] in
                guard let self else { return true }
                guard openGate.canOpen, view.window != nil else { return false }
                return resolve(shown(mapView)) != nil
            }) { [weak self] in
                guard let self, let target = resolve(shown(mapView)) else { return }
                // `-maps-open-delay <ms>`: the map rests that long before the
                // tap — the idle preroll's window, measurable (#654).
                if let delay = Self.debugArgumentValue("-maps-open-delay").flatMap(Double.init), delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { [weak self] in
                        guard let self, let target = resolve(shown(mapView)) else { return }
                        willSelect?(target)
                        mapView.selectAnnotation(target, animated: true)
                    }
                    return
                }
                willSelect?(target)
                // `-maps-touch-lead <ms>`: a finger rests on the marker that
                // long before the tap — the touch-down warm, measurable (#646).
                if let lead = Self.debugArgumentValue("-maps-touch-lead").flatMap(Double.init),
                   let pin = target as? MapAnnotation {
                    beginPlaybackWarm(for: pin)
                    DispatchQueue.main.asyncAfter(deadline: .now() + lead / 1000) { [weak self] in
                        self?.mapView.selectAnnotation(target, animated: true)
                    }
                    return
                }
                mapView.selectAnnotation(target, animated: true)
            }
        }
    }

    /// `-maps-open-first-cluster`: taps the biggest CLUSTER on screen and
    /// prints what it hands the feed. `-maps-open-first-text-cluster` picks the
    /// biggest cluster wearing the TEXT face instead — the case that answers
    /// "does tapping a text marker open more than one post".
    ///
    /// Clusters exist at the opening zoom now that the mock seeds venues
    /// (`MockGeoDiscoveryService.venueAssignments`); `-maps-wide-region` still
    /// makes the big ones, since a pinch cannot be injected in the sim.
    ///
    /// It prints, because "the whole group opens" is invisible to a screenshot:
    /// the feed's first page looks the same whether it was handed one post or
    /// nine, and the difference only shows up when a finger swipes. The line is
    /// the corpus the tap actually passed on.
    private func debugOpenFirstClusterIfRequested(among views: [MKAnnotationView]) {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsText = arguments.contains("-maps-open-first-text-cluster")
        // `-maps-open-first-media-cluster`: the biggest MEDIA-faced cluster —
        // the hero-presented kind, which is also what the semantic-cluster
        // gallery flow rides (places seed by default in mock mode).
        let wantsMedia = arguments.contains("-maps-open-first-media-cluster")
        guard !didDebugOpenPin,
              wantsText || wantsMedia || arguments.contains("-maps-open-first-cluster")
        else { return }
        // `-maps-open-place` only has an answer on a HIERARCHY marker: a city or
        // a country is a place before it is a photograph, and only those carry a
        // place page beneath their feed. Asking for the biggest cluster of any
        // kind picked a proximity one, whose `placePage` is nil — and the flag
        // then did nothing at all, silently.
        // `-maps-open-hierarchy-cluster` asks for the same marker WITHOUT the
        // direct push, so a run can take the real route: tap a city, get the
        // feed, and dismiss vertically onto the place page beneath. That
        // dismissal is the one landing this page has that nothing else
        // exercises — and a vertical drag on a TEXT post opens its comments
        // instead, which is why the media filter matters here too.
        let wantsPlace = arguments.contains("-maps-open-place")
            || arguments.contains("-maps-open-hierarchy-cluster")
        // The same pick at arm time (this batch) and at fire time (the whole
        // map, see `debugSelectMarker`).
        let pick: @MainActor ([MapComputedCluster]) -> MapComputedCluster? = { candidates in
            candidates
                .filter {
                    $0.memberIDs.count > 1
                        && (!wantsText || $0.representative.isText)
                        && (!wantsMedia || !$0.representative.isText)
                        && (!wantsPlace || $0.isHierarchyMarker)
                }
                .max(by: { $0.memberIDs.count < $1.memberIDs.count })
        }
        guard let cluster = pick(views.compactMap { $0.annotation as? MapComputedCluster })
        else {
            if wantsPlace {
                print("[maps] -maps-open-place found NO hierarchy marker on screen"
                    + " — pass -maps-mock-semantic-clusters, and a region wide"
                    + " enough for a city or country to form")
            }
            return
        }
        didDebugOpenPin = true
        // The marker armed on is preferred while it is still on the map
        // (clusters keep their identity through representative churn); a
        // re-cluster that retired it gets the same pick over what is there.
        // The line is printed at FIRE time, from the cluster actually tapped,
        // so it stays "the corpus the tap passed on" even after a re-cluster.
        debugSelectMarker("-maps-open-first-cluster", { annotations in
            let clusters = annotations.compactMap { $0 as? MapComputedCluster }
            return clusters.first { $0 === cluster } ?? pick(clusters)
        }, then: { tapped in
            guard let cluster = tapped as? MapComputedCluster else { return }
            let ids = Self.postIDs(of: cluster)
            let kind = cluster.representative.isText ? "text" : "media"
            print("[maps] cluster tap → representative=\(cluster.representative.postID.rawValue) "
                + "(\(kind), \(MapMarkerPresentation(face: Self.face(of: cluster)))) "
                + "opening \(ids.count) posts: \(ids.map(\.rawValue).joined(separator: ","))")
        })
    }
    #endif

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        #if DEBUG
        MapChurnCounters.viewFor += 1
        #endif
        if let flag = annotation as? CountryFlagAnnotation {
            return countryLayer.view(for: flag, in: mapView)
        }
        if let cluster = annotation as? MapComputedCluster {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MapClusterAnnotationView.reuseIdentifier,
                for: annotation
            ) as? MapClusterAnnotationView
            view?.configure(
                with: cluster, dress: dress(for: cluster), imagePipeline: imagePipeline,
                iconCatalog: iconCatalog, previewCatalog: previewCatalog
            )
            // Instant tap — bypasses MapKit's ~0.3s selection delay.
            view?.onSelect = { [weak self, weak view] in
                self?.noteInstantTap(on: cluster)
                self?.openAnnotation(cluster, thumbnail: view?.heroImage)
            }
            view?.onDressed = { [weak self, weak view] in
                guard let self, let view else { return }
                popChoreographer.release(view)
            }
            // Back from a flight: reclaim the place a flag disc took while
            // the marker was hidden (see `MapAnnotationView.onReappear`).
            view?.onReappear = { [weak self] view in self?.countryLayer.giveWay(to: view.frame) }
            return view
        }
        guard let pinAnnotation = annotation as? MapAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: MapAnnotationView.reuseIdentifier,
            for: annotation
        ) as? MapAnnotationView
        view?.configure(
            with: pinAnnotation.pin, dress: dress(for: pinAnnotation), imagePipeline: imagePipeline,
            iconCatalog: iconCatalog, previewCatalog: previewCatalog
        )
        view?.onSelect = { [weak self, weak view] in
            self?.noteInstantTap(on: pinAnnotation)
            self?.openAnnotation(pinAnnotation, thumbnail: view?.heroImage)
        }
        view?.onTouchDown = { [weak self] in self?.beginPlaybackWarm(for: pinAnnotation) }
        view?.onTouchEnd = { [weak self] cancelled in self?.touchEnded(on: pinAnnotation, cancelled: cancelled) }
        view?.onDressed = { [weak self, weak view] in
            guard let self, let view else { return }
            popChoreographer.release(view)
            // Its preview sheet is on now: a candidate for the preroll (#654).
            scheduleIdlePreroll()
        }
        view?.onReappear = { [weak self] view in self?.countryLayer.giveWay(to: view.frame) }
        return view
    }


    /// Opens a tapped marker's post(s) with the hero transition — a single pin
    /// opens its post, a cluster opens all its members (their ids are already
    /// held locally, no extra round-trip). The re-entrancy guard makes this
    /// safe to call from both the instant tap recognizer and MapKit's own
    /// `didSelect` (the fallback): whichever lands first wins, the other is a
    /// no-op while the flight is alive.
    // MARK: - Touch-down warm (#646)

    /// A finger landed on a lone marker: start its post's page player
    /// now, at the clip time its sheet shows plus the decode, so the page that
    /// opens on touch-up joins a running player instead of starting one.
    ///
    /// ⚠️ INTENT, NOT PROXIMITY. No player is started for a marker nobody
    /// touches, and this one belongs to the post's page, not to the marker
    /// (`GeoDiscoveryRepository.previewVideoURL`'s rule stands).
    /// Whether a marker tap only closes the open offer and opens nothing
    /// (#686). Pure, for tests.
    static func markerTapClosesOffer(offerOpen: Bool) -> Bool { offerOpen }

    /// What a marker tap does while an offer is up (#760): another locked
    /// country's teaser moves the offer straight to that country; its own
    /// teaser leaves it be; any other marker closes it (#686).
    enum TapUnderOffer: Equatable { case switchTo(String), keep, close }

    static func tapUnderOffer(teaserCountry: String?, offeredCountry: String?) -> TapUnderOffer {
        guard let teaserCountry else { return .close }
        return teaserCountry == offeredCountry ? .keep : .switchTo(teaserCountry)
    }

    private func noteInstantTap(on annotation: any MKAnnotation) {
        instantTap = (ObjectIdentifier(annotation as AnyObject), CACurrentMediaTime())
    }

    /// Whether `didSelect` for `annotation` is the echo of an instant tap
    /// already handled. ⚠️ (#760) The echo used to reach `openAnnotation`
    /// with the offer the tap had just opened, and CLOSE it: the map zoomed
    /// in and straight back out.
    private func isEchoOfInstantTap(_ annotation: any MKAnnotation) -> Bool {
        guard let instantTap, instantTap.annotation == ObjectIdentifier(annotation as AnyObject) else { return false }
        return Self.isSelectionEcho(tappedAt: instantTap.at, now: CACurrentMediaTime())
    }

    /// MapKit selects ~0.3 s after the touch; a second deliberate tap on the
    /// same marker comes later than this. Pure, for tests.
    static func isSelectionEcho(tappedAt: CFTimeInterval, now: CFTimeInterval) -> Bool {
        now - tappedAt < 1.0
    }

    /// The locked country `annotation` is a teaser for, if it is one.
    private func lockedTeaserCountry(of annotation: any MKAnnotation) -> String? {
        guard let pin = (annotation as? MapComputedCluster)?.representative ?? (annotation as? MapAnnotation)?.pin,
              case .offer(let code) = Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: pin))
        else { return nil }
        return code
    }

    private func beginPlaybackWarm(for annotation: MapAnnotation) {
        // ⚠️ NOT `pin.kind == .video`: production classifies every media pin
        // `.photo` (`GeoDiscoveryRepository.kind(for:)`), sheet-wearing ones
        // included. Whether there is a clip to warm is the POST's answer, and
        // the feed gives it (`FlightPlaybackWarm.warmableClip`).
        // No warm under an open offer: the tap will only close it (#686).
        guard offerSheet == nil, openGate.canOpen, playbackWarm?.postID != annotation.pin.postID else { return }
        endPlaybackWarm(opened: false)
        let time = warmMediaTime(for: annotation)
        // The marker the map prerolled: its player is already decoded and
        // paused — it plays on from the moment the marker shows now (#654).
        if promoteIdlePreroll(for: annotation.pin.postID, at: time) { return }
        // ONE player: a touch elsewhere spends the preroll's.
        endIdlePreroll()
        guard let warm = warmPlayback(annotation.pin.postID, time) else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] touch-down warm: nothing to warm for \(annotation.pin.postID.rawValue)")
            }
            #endif
            return
        }
        playbackWarm = (annotation.pin.postID, warm)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f touch-down warm %@ at %@", CACurrentMediaTime(),
                         annotation.pin.postID.rawValue, time.map { String(format: "%.2fs", $0) } ?? "start"))
        }
        #endif
    }

    /// The touch is over. A cancelled one (the map took it) lets go now; one
    /// that ended gives the tap its turn to open the post first.
    private func touchEnded(on annotation: MapAnnotation, cancelled: Bool) {
        guard let warm = playbackWarm, warm.postID == annotation.pin.postID else { return }
        guard !cancelled else { return endPlaybackWarm(opened: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmOpenWindow) { [weak self] in
            guard let self, let current = playbackWarm, current.warm === warm.warm else { return }
            endPlaybackWarm(opened: false)
        }
    }

    private func endPlaybackWarm(opened: Bool) {
        guard let warm = playbackWarm else { return }
        playbackWarm = nil
        warm.warm.end(opened: opened)
    }

    /// The clip time a warm for this marker should play from: the frame its
    /// sheet shows, plus the player's start-up.
    private func warmMediaTime(for annotation: MapAnnotation) -> TimeInterval? {
        guard case .sheet(let sheet)? = mapView.wornPreview(for: annotation)?.art,
              let frame = mapView.wornPreviewFrame(for: annotation) else { return nil }
        return MapPinZoomSource.flightMediaTime(sheet: sheet, displayedFrame: frame,
                                                lead: MapPinZoomSource.warmMediaLead)
    }

    // MARK: - Idle preroll (#654)

    /// The map came to rest: in `idlePrerollDelay`, preroll the player of the
    /// marker nearest the centre. A pan starting first cancels it.
    private func scheduleIdlePreroll() {
        idlePrerollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateIdlePreroll() }
        idlePrerollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollDelay, execute: work)
    }

    /// ⚠️ ONE PLAYER, AND IT IS THE PAGE'S. The owner's call (2026-10-07):
    /// the marker nearest the centre gets its post's page player decoded to
    /// its first frame and paused, so a tap of any length flies live video
    /// from take-off. Nothing plays behind a marker
    /// (`GeoDiscoveryRepository.previewVideoURL`'s rule stands), and a paused
    /// player decodes nothing at rest.
    private func updateIdlePreroll() {
        guard !idlePrerollRested else { return }
        guard view.window != nil, activeTransition == nil, playbackWarm == nil, !isRegionTransitioning,
              offerSheet == nil,
              UIApplication.shared.applicationState == .active else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll: not now (window=\(view.window != nil) transition=\(activeTransition != nil) "
                      + "warm=\(playbackWarm != nil) moving=\(isRegionTransitioning) "
                      + "active=\(UIApplication.shared.applicationState == .active))")
            }
            #endif
            return endIdlePreroll()
        }
        let visible = mapView.visibleMapRect
        let candidates: [(id: PostID, point: MKMapPoint, annotation: MapAnnotation)] = mapView.annotations
            .compactMap { $0 as? MapAnnotation }
            .compactMap { annotation in
                let point = MKMapPoint(annotation.coordinate)
                guard visible.contains(point), mapView.view(for: annotation) != nil,
                      case .sheet? = mapView.wornPreview(for: annotation)?.art,
                      Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: annotation.pin)) == .open
                else { return nil }
                return (annotation.pin.postID, point, annotation)
            }
        let center = MKMapPoint(mapView.centerCoordinate)
        guard let chosen = Self.prerollCandidate(center: center, pins: candidates.map { ($0.id, $0.point) }),
              let annotation = candidates.first(where: { $0.id == chosen })?.annotation else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll: no sheet-wearing marker in view")
            }
            #endif
            return endIdlePreroll()
        }
        guard idlePreroll?.postID != chosen else { return }
        endIdlePreroll()
        guard let warm = prerollPlayback(chosen, warmMediaTime(for: annotation)) else {
            guard idlePrerollRetries < Self.idlePrerollRetryLimit else { return }
            idlePrerollRetries += 1
            let retry = DispatchWorkItem { [weak self] in self?.updateIdlePreroll() }
            idlePrerollWork = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollRetryDelay, execute: retry)
            return
        }
        idlePreroll = (chosen, warm)
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, idlePreroll?.warm === warm else { return }
            endIdlePreroll()
            idlePrerollRested = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll \(chosen.rawValue) let go: the map rested \(Int(Self.idlePrerollLifetime)) s")
            }
            #endif
        }
        idlePrerollExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollLifetime, execute: expiry)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] idle preroll \(chosen.rawValue) of \(candidates.count) candidate(s)")
        }
        #endif
    }

    /// Hands the prerolled player to a touch or an open of its marker:
    /// playing on from `time`. False when the preroll is another marker's.
    private func promoteIdlePreroll(for postID: PostID, at time: TimeInterval?) -> Bool {
        guard let preroll = idlePreroll, preroll.postID == postID else { return false }
        idlePreroll = nil
        idlePrerollExpiry?.cancel()
        idlePrerollExpiry = nil
        preroll.warm.resume(at: time)
        playbackWarm = preroll
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] preroll promoted \(postID.rawValue) at \(time.map { String(format: "%.2fs", $0) } ?? "-")")
        }
        #endif
        return true
    }

    private func endIdlePreroll() {
        idlePrerollWork?.cancel()
        idlePrerollWork = nil
        idlePrerollExpiry?.cancel()
        idlePrerollExpiry = nil
        guard let preroll = idlePreroll else { return }
        idlePreroll = nil
        preroll.warm.end(opened: false)
    }

    /// The marker a preroll goes to: the one nearest the centre. Pure, for tests.
    static func prerollCandidate(center: MKMapPoint, pins: [(id: PostID, point: MKMapPoint)]) -> PostID? {
        pins.min { center.distance(to: $0.point) < center.distance(to: $1.point) }?.id
    }

    private func openAnnotation(_ annotation: any MKAnnotation, thumbnail: UIImage?) {
        // ⚠️ AN OPEN OFFER SWALLOWS THE TAP (#686), as a tap on the map does:
        // tapping away is "no thanks". Here, ahead of everything, so the
        // instant tap, MapKit's `didSelect`, VoiceOver and the DEBUG hooks all
        // meet it. A sheet already on its way down still swallows it — a fast
        // second tap must not open a post during the descent.
        if Self.markerTapClosesOffer(offerOpen: offerSheet != nil) {
            switch Self.tapUnderOffer(
                teaserCountry: lockedTeaserCountry(of: annotation), offeredCountry: offerSheet?.country.code
            ) {
            case .switchTo(let code):
                if let country = CountryAtlas.shared.country(code: code) { offer(country) }
            case .keep:
                break
            case .close:
                closeOffer(returning: true)
            }
            return
        }
        guard openGate.canOpen else { return }
        let postIDs = Self.postIDs(of: annotation)
        guard !postIDs.isEmpty else { return }
        // A locked country's marker is a teaser, not a door: it offers the
        // country — what the old locked badge did — and opens nothing.
        if let pin = (annotation as? MapComputedCluster)?.representative ?? (annotation as? MapAnnotation)?.pin,
           case .offer(let code) = Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: pin)) {
            if let country = CountryAtlas.shared.country(code: code) { offer(country) }
            return
        }
        let face = Self.face(of: annotation)
        #if DEBUG
        // Which face a tapped marker wears decides its TRANSITION
        // (`MapMarkerPresentation`: media flies, everything else reveals), and
        // a reveal growing from a disc looks like a vertical capsule halfway
        // through. Without this line, "the present animation is wrong" and
        // "this marker is not the face you think" are indistinguishable from
        // outside.
        print("[maps] tap face=\(face) presentation=\(MapMarkerPresentation(face: face)) "
              + "posts=\(postIDs.count) first=\(postIDs.first?.rawValue ?? "-")")
        #endif
        switch MapMarkerPresentation(face: face, reducesMotion: HeroMotionPolicy.prefersNativePush) {
        case .reveal where navigationController != nil:
            // The disc IS the window. Same seam as the plain push below — the
            // feed owns the pushed screen's gestures either way — with an
            // origin that says where the marker is, what shape and colour it
            // is, and what to draw in the window at each end.
            guard openGate.openBegan(.reveal) else { return }
            // A HIERARCHY marker always offers its place page, whatever face
            // it wears (a city or country is a place before it is a
            // photograph): the same builder the hero's Case B uses, handed
            // through the seam so the vertical dismissal lands on it. Same
            // criterion as the hero path — `isHierarchyMarker` — so the two
            // presentations answer "is this marker a city or a country?"
            // alike, and an ordinary proximity cluster (leaf-shared or not)
            // gets the plain feed on both. A band's group of one is its
            // place's marker too (`hierarchyPlace(of:)`).
            let hierarchyPlace = Self.hierarchyPlace(of: annotation)
            let placePage: ((UIViewController) -> UIViewController)? = hierarchyPlace.map { place in
                let mapReturn = makeMapReturnSource(for: annotation)
                let markerClose = makeMarkerClose(for: annotation)
                let country = countryCode(of: annotation)
                return { [makeClusterGallery] feed in
                    makeClusterGallery(postIDs, place, country, feed, mapReturn, markerClose)
                }
            }
            #if DEBUG
            // `-maps-open-place`: pushes the place page ON ITS OWN.
            //
            // ⚠️ THIS SCREEN HAD NO SCRIPTED ROUTE AT ALL. It is inserted under
            // the cluster feed and uncovered by a vertical dismissal — a gesture
            // no harness can inject, and the nearest arguments all land
            // somewhere else (`-snap-auto-dismiss` pops past it to the map, the
            // vertical grab opens the comments). So its layout could only ever
            // be judged by hand, and a change to it could only be verified by
            // asking someone to go and look.
            //
            // Pushed directly here it is the same controller with the same
            // content; what it does NOT exercise is the dismissal that normally
            // uncovers it, which keeps its own arguments.
            if ProcessInfo.processInfo.arguments.contains("-maps-open-place"),
               let placePage {
                navigationController?.pushViewController(placePage(UIViewController()), animated: true)
                return
            }
            #endif
            revealSnapFeed(
                postIDs,
                self,
                MapPinRevealSource.origin(
                    mapView: mapView,
                    annotation: annotation,
                    face: face,
                    dress: dress(for: annotation),
                    // Exactly what the hero does to the same marker
                    // (`MapPinZoomSource.setZoomSourceHidden`), for the same
                    // reason: while the window is elsewhere the disc must not
                    // still be sitting on the map.
                    concealMarker: { [weak mapView] concealed in
                        mapView?.view(for: annotation)?.isHidden = concealed
                    },
                    depthView: { [weak self] in self?.view }
                ),
                placePage
            )
        case .plainPush where navigationController != nil:
            // Nothing to fly (see `MapMarkerPresentation`): the platform's own
            // slide, through the feed's shared plain-push seam so this screen
            // gets the same swipe-back it gets from every other surface.
            //
            // The map's own chrome is left alone on purpose: the filter bars
            // live in this view and slide out WITH it, where the flight has to
            // hide them because the map stays visible under the card. The tab
            // bar is hidden and restored by the seam, and previews stop and
            // resume through the ordinary appearance callbacks — all of which
            // are keyed on `activeTransition == nil`, which is exactly what
            // this path is.
            guard openGate.openBegan(.plainPush) else { return }
            pushPlainSnapFeed(postIDs, self)
        case .plainPush, .hero, .reveal:
            // No stack to push onto: the window has nowhere to open, so the
            // feed is presented instead — the same concession the plain push
            // already made.
            presentSnapFeed(postIDs: postIDs, from: annotation, thumbnail: thumbnail)
        }
    }

    /// Whether MapKit's selection of `annotation` opens it: never a country's
    /// flag disc, whose own recognizer took the tap (#760).
    static func mapSelectionOpens(_ annotation: any MKAnnotation) -> Bool {
        !(annotation is CountryFlagAnnotation)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // Deselect immediately so the pin can be tapped again after dismissal.
        // The instant-tap recognizer normally fires first; this is the fallback
        // (and clears MapKit's own selection either way).
        guard let annotation = view.annotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)
        // ⚠️ A COUNTRY'S FLAG DISC HAS TAKEN ITS TAP ALREADY (#760): its own
        // recognizer offered the country; MapKit's selection, landing a beat
        // later, read as a tap under the open offer and CLOSED it — the zoom
        // in and straight back out.
        guard Self.mapSelectionOpens(annotation), !isEchoOfInstantTap(annotation) else { return }

        let thumbnail = (view as? MapAnnotationView)?.heroImage
            ?? (view as? MapClusterAnnotationView)?.heroImage
        openAnnotation(annotation, thumbnail: thumbnail)
    }

    /// Everything the tapped marker stands for, in the order the feed should
    /// page through it: one post for a lone pin, the WHOLE group for a cluster
    /// with its representative first.
    ///
    /// The same answer whatever the posts are. A cluster's members are already
    /// held client-side (`MapClusterEngine` folded them), so a text post, a
    /// photo and a video that happen to sit on the same corner all travel
    /// together into one swipeable feed — the presentation differs (see
    /// `MapMarkerPresentation`), never the corpus.
    ///
    /// Pure and static so the passthrough can be tested without a live
    /// `MKMapView`: dropping members here would be invisible on screen — the
    /// feed would simply end early — which is exactly the kind of silent
    /// truncation a test has to pin.
    static func postIDs(of annotation: any MKAnnotation) -> [PostID] {
        switch annotation {
        case let pin as MapAnnotation: [pin.pin.postID]
        case let cluster as MapComputedCluster: cluster.memberIDs
        default: []
        }
    }

    /// The MARKER's window, asked for at close time.
    ///
    /// Identical to the arguments the text-pin route already passes, so the two
    /// routes' windows are the same window — a marker opened as a hero and a
    /// marker opened as a reveal close the same way. The extra `dismissalDidEnd`
    /// is the close-out the hero's own `onSourceReturned` performs and a card
    /// close never reaches; the concealment is paid back by the animator.
    private func markerRevealOrigin(for annotation: any MKAnnotation) -> TextRevealOrigin {
        MapPinRevealSource.origin(
            mapView: mapView,
            annotation: annotation,
            face: Self.face(of: annotation),
            dress: dress(for: annotation),
            concealMarker: { [weak mapView] concealed in
                mapView?.view(for: annotation)?.isHidden = concealed
            },
            depthView: { [weak self] in self?.view },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                // ⚠️ REPORTED WHATEVER THE OUTCOME. This is the reveal route's
                // ONLY terminal signal, and the gate needs the cancelled case
                // as much as the committed one.
                openGate.dismissalBegan()
                openGate.dismissalEnded(committed: committed)
                guard committed else { return }
                // A BACKSTOP — the close's commit has normally shown the dock.
                // A card close finished the flight's pop: the session's
                // close-out, the gate already settled above.
                activeSession?.close(.abandoned)
            }
        )
    }

    /// Which screen a card close is aiming at.
    ///
    /// ⚠️ THE POP'S DESTINATION DECIDES, not the post. A vertical grab lands on
    /// the place page and closes onto its Activity row; everything else — the
    /// chevron, a horizontal grab, and both axes when there is no place page at all —
    /// lands on the MAP, so it closes onto the marker whatever post the viewer
    /// paged to. Aiming a card at a screen the pop is not going to is how a
    /// close ends up with no animation at all.
    enum MapCardCloseTarget: Equatable { case marker, placeCard }

    static func closeTarget(axis: ZoomDismissAxis, hasLanding: Bool) -> MapCardCloseTarget {
        // Down onto the place page; right and up (the end of the list,
        // #761) onto the marker.
        axis.landsBeneath && hasLanding ? .placeCard : .marker
    }

    /// Where a place page goes when a vertical dismissal commits: beneath the
    /// feed it is landing from.
    ///
    /// Pure, and separate from the navigation call for the same reason
    /// `postIDs(of:)` is: the rule needs no live `MKMapView`, and a wrong
    /// answer here is invisible on screen until someone presses back.
    /// Nil means "nothing to do" — already inserted, or no feed to insert under.
    static func stack(
        _ current: [UIViewController], inserting landing: UIViewController,
        beneath feed: UIViewController
    ) -> [UIViewController]? {
        guard !current.contains(landing),
              let index = current.firstIndex(of: feed) else { return nil }
        var next = current
        next.insert(landing, at: index)
        return next
    }

    /// …and back out again when that dismissal is abandoned.
    static func stack(
        _ current: [UIViewController], removing landing: UIViewController
    ) -> [UIViewController]? {
        guard current.contains(landing) else { return nil }
        return current.filter { $0 !== landing }
    }

    /// The face the tapped marker is wearing, so the flight card takes off as
    /// its twin — a symbol pin must not fly as an empty square.
    private static func face(of annotation: any MKAnnotation) -> PinCardView.Face {
        let pin = (annotation as? MapAnnotation)?.pin
            ?? (annotation as? MapComputedCluster)?.representative
        return pin.map(PinCardView.Face.of) ?? .media
    }

    private func presentSnapFeed(postIDs: [PostID], from annotation: any MKAnnotation, thumbnail: UIImage?) {
        // The page about to open joins the player its touch-down started
        // (#646); any other post's warm has nothing to hand over. One with a
        // picture already FLIES: the card carries it from its first frame.
        // An open with no touch-down (VoiceOver, a programmatic select) still
        // takes the marker's preroll (#654); any other post's goes.
        if playbackWarm == nil, let pin = annotation as? MapAnnotation {
            _ = promoteIdlePreroll(for: pin.pin.postID, at: warmMediaTime(for: pin))
        }
        endIdlePreroll()
        let warm = playbackWarm.flatMap { postIDs.first == $0.postID ? $0.warm : nil }
        let warmFlies = warm?.hasPicture ?? false
        endPlaybackWarm(opened: warm != nil)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] open: warm=\(warm == nil ? "none" : (warmFlies ? "flies" : "no picture yet"))")
        }
        #endif
        let feedVC = makeSnapFeed(postIDs)
        guard let nav = navigationController,
              let destination = feedVC as? any ZoomTransitionDestination else {
            // ⚠️ THE DEFENSIVE BRANCH TAKES THE LOCK TOO. It set neither flag,
            // so two taps could `present` twice — and presenting over a
            // presentation raises rather than degrades.
            guard openGate.openBegan(.modalFallback) else { return }
            // Defensive: without the hero seam (or a stack), show it plainly.
            if let nav = navigationController {
                feedVC.hidesBottomBarWhenPushed = true
                nav.pushViewController(feedVC, animated: true)
            } else {
                present(feedVC, animated: true)
            }
            return
        }
        // A live-previewing pin flies live: its pooled player is mirrored onto
        // the flight card's own render surface (same player → same frame), so
        // the flight never freezes the preview mid-loop.
        let tappedID = (annotation as? MapAnnotation)?.pin.postID
        let coordinator = videoCoordinator
        let source = MapPinZoomSource(
            mapView: mapView,
            annotation: annotation,
            thumbnail: thumbnail,
            face: Self.face(of: annotation),
            // The marker's flag border and badge ride the flight, so the card
            // is the tapped marker's twin down to its furniture — neutral for
            // anything that isn't the active band's own marker.
            dress: dress(for: annotation),

            // A touch-down warm with a picture is the page's own player, live
            // (#646): the card flies it from take-off — no sheet, no fade —
            // and the page, told so, joins it rather than starting its own.
            mirrorLive: warmFlies ? warm.map { warm in { renderView in warm.mirror(onto: renderView) } }
                : tappedID.map { id in
                { renderView in coordinator.mirrorLivePreview(of: id, to: renderView) }
            },
            // Asked while this transition is being constructed — before the
            // freeze three dozen lines below, which is what makes the answer
            // hold for the whole flight.
            isLivePreviewing: warmFlies ? { true } : tappedID.map { id in
                { coordinator.isLivePreviewing(id) }
            },
            // Asked at DISMISSAL staging, so it reports where the viewer
            // actually stopped rather than where they started. The card lands
            // on this marker either way; only its departure face adapts.
            departureCover: { [weak self, weak feedVC] in
                self?.returnCover(to: annotation, leaving: feedVC) ?? .none
            },
            awaitDepartureCover: { [weak self, weak feedVC] report in
                self?.awaitReturnCover(to: annotation, leaving: feedVC, then: report)
            }
        )
        // A *push*, not a modal: the feed joins this tab's stack, so the one
        // navigation bar cross-fades the map's items into the feed's back item
        // + author capsule natively — no second bar to pop in over the first.
        // The transition object is the stack's delegate for the feed's
        // lifetime.
        guard openGate.openBegan(.hero) else { return }
        let session = HeroPushSession(source: source, destination: destination, on: nav)
        let transition = session.controller
        activeSession = session

        // CASE B (cluster-gallery milestone): a HIERARCHY marker — the active
        // band's own city or country cluster — carries a place page beneath
        // its feed. The page joins the stack invisibly in the same
        // transaction as the feed (UIKit animates a stack whose last element
        // is new exactly like a push, and never even loads the mid
        // controller's view), and the VERTICAL grab closes the active post
        // onto the page's Activity row instead of back to the pin — as the
        // card close beside this flight (`attachCardCloseAlongsideFlight`),
        // for EVERY post: the page refuses a hero (`zoomLandingAcceptsHero`),
        // so the vertical flight driver below stays armed only to decline.
        // ORDINARY clusters
        // — proximity groups, even ones whose members happen to share a leaf
        // place — and local single pins skip all of this: only a city or a
        // country has a place page (product call, 2026-08-31). A band's group
        // of ONE is a city or a country, and gets it (`hierarchyPlace(of:)`).
        var gallery: UIViewController?
        if let place = Self.hierarchyPlace(of: annotation) {
            let built = makeClusterGallery(
                postIDs, place, countryCode(of: annotation), feedVC, makeMapReturnSource(for: annotation),
                makeMarkerClose(for: annotation)
            )
            gallery = built
            if let gallerySource = built as? any ZoomTransitionSource {
                transition.setDismissSource(gallerySource, for: built)
                // ⚠️ NOT UPWARD (#761): the end of the list closes to the map,
                // through the marker driver below.
                transition.attachInteractiveDismissal(
                    to: feedVC.view, axes: [.vertical], armsUpward: false, towards: gallerySource
                ) { [built, weak nav, weak feedVC] in
                    // ⚠️ THE PAGE JOINS THE STACK HERE, at the last moment
                    // before the pop that lands on it — the mirror of the
                    // reveal route's own splice. `built` is captured STRONGLY:
                    // the dismiss target holds it weakly, so until this runs
                    // this closure chain is the page's only owner.
                    //
                    // A plain stack transaction with nothing transitioning,
                    // which is the one condition under which it is reliable.
                    if let nav, let feedVC,
                       let plan = Self.stack(
                           nav.viewControllers, inserting: built, beneath: feedVC
                       ) {
                        nav.setViewControllers(plan, animated: false)
                    }
                    // Nothing about the dock here: this pop lands on the place
                    // page, and the feed brings the bar back through UIKit once
                    // the release commits. The filter bars are invisible under
                    // the gallery either way.
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-grab-log") {
                        print("[caseb] splice+pop delegate=\(nav?.delegate.map { "\(type(of: $0))" } ?? "nil")"
                              + " stack=\(nav?.viewControllers.map { "\(type(of: $0))" } ?? [])")
                    }
                    #endif
                    nav?.popViewController(animated: true)
                }
            }
            // Its landing is the session's `.toIntermediate` ending (below).
        }

        // ONE close-out per ending (`HeroPushSession.Ending`). The session has
        // already ended its leases on the stack's delegate slot; a place page
        // that leased it on top keeps it.
        //
        // ⚠️ `.reversed` is the flight caught mid-air and thrown back, which
        // once had no handler here at all: the latch stayed set and every
        // marker tap for the rest of the session did nothing.
        session.onClose = { [weak self, source] ending in
            guard let self else { return }
            self.activeSession = nil
            self.barsStack.alpha = 1
            switch ending {
            case .toIntermediate:
                // The gallery is the screen now, an ordinary one; the map's
                // chrome settles silently beneath it (invisible until the
                // gallery pops, when `viewWillAppear` resumes previews). The
                // present flight hid the tapped marker, and nothing on the
                // gallery path would ever restore it.
                self.openGate.dismissedToIntermediate()
                source.setZoomSourceHidden(false)
                return
            case .reversed:
                self.openGate.presentationCancelled()
                // The card close armed beside the flight serves a feed that
                // never showed; released a turn later, as the closing callbacks
                // of these objects may still be unwinding.
                let abandonedClose = self.cardClose
                self.cardClose = nil
                DispatchQueue.main.async { withExtendedLifetime(abandonedClose) {} }
            case .returned:
                self.openGate.dismissalBegan()
                self.openGate.dismissalEnded(committed: true)
            case .abandoned:
                break // whoever ended it settled the gate
            }
            self.tabBarController?.showTabBarNativelyNextTurn()
            self.videoCoordinator.setSurfaceVisible(true)
            self.idlePrerollRested = false
            self.refreshVideoPlayback()
            self.scheduleIdlePreroll()
            // The flight froze the bars' inset (`syncBarsPosition` stands down
            // while one is up); the screen is at rest again.
            self.syncBarsPosition()
        }

        var didLand = false
        transition.onDestinationShown = { [weak self, weak transition] in
            // Landed (fires again if a detail above the feed pops back — the
            // flight-scoped work must run once): release the donor player.
            guard !didLand else { return }
            didLand = true
            self?.openGate.destinationShown()
            self?.videoCoordinator.stopAll()

            #if DEBUG
            // `[delay]`, for the reason its two siblings grew one: a run that
            // PAGES the feed first cannot be scripted against a hard-coded
            // 1.5s, and the vertical dismissal onto a place page is only
            // interesting once the viewer has moved off the post the cluster
            // opened on.
            if let position = ProcessInfo.processInfo.arguments
                .firstIndex(of: "-maps-demo-grab") {
                let arguments = ProcessInfo.processInfo.arguments
                let delay = position + 1 < arguments.count
                    ? (Double(arguments[position + 1]) ?? 1.5) : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    transition?.debugScriptedGrab()
                }
            }
            #endif
        }
        // ⚠️ THE BAR IS NOT THE FLIGHT'S, and nothing here writes its alpha.
        // UIKit shows it once the close is committed (`viewWillAppear`'s
        // policy, and the feed's own close); this is the backstop. See
        // `TabBarRevealPolicy`.
        transition.onDismissalCancelled = { [weak self, gallery, weak nav, weak feedVC] in
            // The feed is STAYING, so the gate does not reopen — it goes back to
            // `.open`, which is what `committed: false` means.
            self?.openGate.dismissalBegan()
            self?.openGate.dismissalEnded(committed: false)
            // The feed is staying up: the filter bars go back down behind it.
            // The dock was never raised — it waits for a COMMITTED release.
            self?.barsStack.alpha = 0
            // ⚠️ THE UNDO IS NOW A REMOVAL, and it used to be an insertion.
            //
            // With the page off the stack at rest, an abandoned VERTICAL grab
            // is a page that was spliced in and never landed on — so this takes
            // it back out, and the back button and the horizontal close keep
            // their map landing. `gallery` is captured STRONGLY on purpose:
            // between the splice and this cancel, this closure chain is the
            // only thing keeping it alive.
            //
            // Deferred one runloop turn, and that hop is load-bearing: this
            // callback fires inside `completeTransition(false)`'s own call
            // stack, and a `setViewControllers` issued there is silently
            // swallowed by UIKit's post-cancel bookkeeping — measured in-sim.
            DispatchQueue.main.async { [weak nav] in
                guard let nav, let gallery,
                      let plan = Self.stack(nav.viewControllers, removing: gallery)
                else { return }
                nav.setViewControllers(plan, animated: false)
            }
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        if let clusterGallery = gallery {
            // Case B's HORIZONTAL escape: straight back to the map.
            //
            // ⚠️ IT NO LONGER DROPS ANYTHING, because there is nothing on the
            // stack to drop — the page is spliced in by the vertical grab
            // alone. This used to reorder the stack first (a scrubbed multi-pop
            // is not an option: UIKit commits a popTo's mutation at begin and a
            // cancel does not restore it, see `InteractivePopToStackTests`), and
            // keeping a now-redundant removal would hide a regression of the
            // new invariant rather than expose it. What is left is the
            // ordinary, fully cancellable single pop the pin grab has always
            // been, landing on the map so the default (pin) source flies the
            // card home. Axes stay disjoint with the gallery driver above:
            // exactly one of the two ever claims a drag.
            _ = clusterGallery
            // Right, and up past the end of the list (#761): both to the map.
            transition.attachInteractiveDismissal(to: feedVC.view, axes: [.horizontal, .upward]) {
                [weak nav] in
                // The bottom chrome comes back from `viewWillAppear`, which
                // this pop runs — see the pin grab below.
                nav?.popViewController(animated: true)
            }
        } else {
            // Case A (single pin / generic cluster): both axes fly home to
            // the pin.
            transition.attachInteractiveDismissal(to: feedVC.view) { [weak nav] in
                // ⚠️ NOTHING ABOUT THE DOCK AT GRAB-BEGIN any more. It used to
                // put the bar's state back here at alpha 0 and show it at the
                // landing. A grab is a question until it is released: the pop
                // below runs this screen's `viewWillAppear`, which restores the
                // filter bars and hands the dock to `TabBarRevealPolicy` —
                // UIKit shows it when the release commits.
                nav?.popViewController(animated: true)
            }
        }
        // Map is covered by the feed → stop its previews, except the tapped
        // pin's, which the flight card is still rendering. Set *before* the
        // push so the map's viewWillDisappear sweep is a no-op that can't
        // touch the donor.
        videoCoordinator.setSurfaceVisible(false, keeping: tappedID)
        // Tab bar managed by hand, NOT hidesBottomBarWhenPushed: that flag's
        // bottom-bar choreography doesn't scrub with a custom interactive pop
        // (the bar snaps in at pop-begin and flashes over the feed when a grab
        // cancels). By hand — through UIKit's API, on UIKit's animation — it
        // leaves with the lift-off, stays hidden through cancelled grabs,
        // and comes back once a close is committed. Constraint: a
        // programmatic cross-tab route while the feed is pushed would find the
        // bar hidden — today no such route fires from inside the feed.
        tabBarController?.hideTabBarNatively()
        setFilterBar(hidden: true)
        session.takeDelegateSlot()
        // ⚠️ NOT pre-paying the destination's layout here, and the empty space
        // is deliberate.
        //
        // For You calls `zoomPrepareForPresentation` before its own push, and
        // the same call was added here for parity. It is the wrong trade on
        // this screen: the map builds a FRESH feed on every tap
        // (`makeSnapFeed`), so the layout it pre-pays is a cold one, and it
        // runs synchronously — plus a `CATransaction.flush` — between the
        // finger coming up and the flight starting. Reported as a long pause
        // between tapping a marker and the animation beginning, which is worse
        // than the frame pacing it was buying: a stall the viewer is waiting
        // through beats one they are watching an animation through.
        //
        // The seam is left in place (`ZoomTransitionDestination`), because the
        // measurement that would justify calling it — a cold feed laid out off
        // the tap's critical path — is the thing to take before trying again.
        // ⚠️ AN ORDINARY PUSH, WHATEVER CASE THIS IS — and the place page is
        // NOT in it.
        //
        // It used to join the stack in the same transaction as the feed, on the
        // reasoning that the gallery is never SEEN. True, and beside the point:
        // a stack is not only what is drawn, it is what BACK means. With the
        // page sitting under the feed, the chevron's single pop landed on a
        // place page the viewer had never asked for and had no way to predict
        // — filmed twice, from a country marker and from a city one.
        //
        // The reveal route reached this conclusion first and states it in its
        // own words (`FeedFeatureBuilder.pushWithoutFlight`): the page is
        // INSERTED for a committed vertical dismissal and taken out again if
        // that dismissal is abandoned, "so the back button and the horizontal
        // close keep their map landing". Two routes, one rule, and only one of
        // them had it.
        nav.pushViewController(feedVC, animated: true)
        // ⚠️ UNCONDITIONALLY, INCLUDING CASE A. A single pin had no slide
        // driver at all, so its chevron fell through to UIKit's native pop —
        // the hero declines a `.card` close outright, and nothing else was
        // listening. `arbitratesWithHeroGrab` keeps the two grabs disjoint and
        // the `.hero` forward happens before any geometry is read, so a media
        // post's close is still the flight.
        attachCardCloseAlongsideFlight(
            feed: feedVC, gallery: gallery,
            markerOrigin: markerRevealOrigin(for: annotation), on: nav
        )
    }

    /// A dismissal for the posts this flight cannot carry.
    ///
    /// ⚠️ THE FEED IS A PAGER AND THE PRESENTATION WAS CHOSEN AT THE TAP. A
    /// media-faced marker opens with a hero; swipe to a TEXT post and there is
    /// no media left for that hero to fly. Both zoom grabs then refuse —
    /// `ZoomDismissInteractionController` gates on `zoomDismissalKind != .card`
    /// BEFORE it looks at the axis, so the horizontal one refuses too — and
    /// the native edge pop is already disclaimed. Measured: on that page the
    /// drag did nothing at all, on either axis, and the back chevron was the
    /// only way out.
    ///
    /// For You hit this first and answered it with exactly this driver
    /// (`attachCardCloseAlongsideFlight`); Case B never received the
    /// equivalent. `arbitratesWithHeroGrab` is what divides the work: each
    /// side refuses the other's kind, so exactly one claims any grab.
    private func attachCardCloseAlongsideFlight(
        feed: UIViewController, gallery: UIViewController?,
        markerOrigin: TextRevealOrigin, on nav: UINavigationController
    ) {
        // Optional now: the MARKER landing needs no place page, so the driver
        // must exist even when there is none to land on.
        let landing = gallery as? any CardCloseLanding
        let slide = InteractiveSlideDismissal()
        cardClose = slide
        // It holds the stack's slot on the flight's behalf.
        activeSession?.registerForwarder(slide)
        #if DEBUG
        print("[card-close] map armed placePage=\(landing != nil)")
        #endif
        // ⚠️ FIRST, because arming resets the driver — every setter below
        // (`fallbackSlideAxis` among them) has to land after it.
        armCardClose(slide, feed: feed, landing: landing, markerOrigin: markerOrigin)
        // ⚠️ DOWNWARD ONTO A PLACE PAGE, EVERY POST IS THIS DRIVER'S — media
        // included. After the arming above, which resets it.
        //
        // The page's landing is its ACTIVITY row, with the post the viewer is
        // on moved to the top (`PlaceProfileViewController.cardCloseGeometry`):
        // the close a TEXT marker's feed has always had, and the one filmed as
        // right (Paris). A media marker's feed used to hand a photograph's
        // downward close to the hero instead, which flew it onto a DISCOVER
        // tile — the tab chosen by the kind of post the marker wore (Lyon).
        // The page now refuses a flight (`zoomLandingAcceptsHero`), and this
        // asks that same answer, so the vertical hero grab and this driver
        // cannot both decline — or both claim — one drag. Rightward, and with
        // no page at all, the hero keeps every photograph it had.
        let gallerySource = gallery as? any ZoomTransitionSource
        slide.heroClaimsAxis = { [weak gallerySource] axis in
            !axis.landsBeneath || gallerySource?.zoomLandingAcceptsHero != false
        }
        // ⚠️ THE DEFAULT AXES, deliberately restored. Restricting the window
        // to `[.vertical]` made a horizontal grab a percent-driven SLIDE, and
        // the chevron a plain one — which is the fallback that was filmed. Both
        // now close as a window onto the marker; `fallbackSlideAxis` stays as
        // the floor for the case where no geometry could be staged at all.
        slide.fallbackSlideAxis = .horizontal
        // The bottom chrome is NOT the closing window's: the filter bars come
        // back from `viewWillAppear` and the dock through UIKit once the close
        // is committed (the feed's own close, and `viewWillAppear`'s policy),
        // with the marker origin's `dismissalDidEnd` as the landing's
        // backstop — exactly as the hero's own return does.
        slide.onWillBeginPop = { [weak nav, weak feed, gallery] axis in
            guard axis.landsBeneath, let gallery, let nav, let feed,
                  let plan = Self.stack(
                      nav.viewControllers, inserting: gallery, beneath: feed
                  )
            else { return }
            nav.setViewControllers(plan, animated: false)
            // ⚠️ AND OUT AGAIN FOR AN ABANDONED SWIPE — the removal the hero's
            // own vertical grab has in `onDismissalCancelled`, which this
            // driver now needs for every post rather than only text ones:
            // left spliced, the back button that follows lands on a place page
            // the viewer never asked for. Both hops are load-bearing, for the
            // reasons `FeedFeatureBuilder.pushWithoutFlight` measured: the
            // coordinator exists only once the pop has begun (next turn), and
            // a `setViewControllers` inside `completeTransition(false)`'s call
            // stack is silently swallowed.
            DispatchQueue.main.async { [weak nav, weak feed] in
                guard let coordinator = feed?.transitionCoordinator else { return }
                coordinator.animate(alongsideTransition: nil) { context in
                    guard context.isCancelled else { return }
                    DispatchQueue.main.async { [weak nav, weak feed] in
                        guard let nav, let feed, nav.topViewController === feed,
                              let plan = Self.stack(nav.viewControllers, removing: gallery)
                        else { return }
                        nav.setViewControllers(plan, animated: false)
                    }
                }
            }
        }
        // The backstop: whatever animated the close, no tile stays hidden. The
        // staging above conceals one, and only the reveal's own completion
        // pays that back — a pop finished by anything else would leave a hole
        // in the mosaic for good.
        slide.onFeedPopped = { [weak self, weak landing, weak nav, gallery] _ in
            landing?.clearLandingConcealment()
            // Idempotent, and only where there is a page: a card close that was
            // armed and then abandoned leaves it spliced in, and the back
            // button must still find the map. Case A never had one.
            if let gallery, let nav,
               let plan = Self.stack(nav.viewControllers, removing: gallery),
               nav.topViewController !== gallery {
                nav.setViewControllers(plan, animated: false)
            }
            self?.cardClose = nil
        }
        // AFTER the push, so the flight controller is what `install` captures
        // and a `.hero` pop forwards straight back to it.
        slide.install(on: nav)
        debugScriptCardCloseIfRequested(slide)
    }

    /// The map's two landings, armed through the SHARED helper
    /// (`armAsCardCloseAlongsideFlight`) — the close For You, a profile and
    /// the place page's own tiles make.
    ///
    /// What the helper brings is the shared rules: both axes, arbitrated
    /// against the hero grab, the reset, and a staging asked ONLY for a close
    /// that carries a card. What stays here is only the landing: the marker's
    /// window, or the place page's card.
    ///
    /// ⚠️ RESTAGED ON EVERY ATTEMPT (`restagesOnEveryAttempt`), not once.
    /// The helper's latch assumes one landing per presentation; this screen
    /// has two, chosen by the AXIS. Latched, a vertical grab abandoned
    /// half-way would leave the place card's geometry armed for the chevron
    /// that follows, and the window would shrink onto a tile that is not on
    /// screen. So each landing keeps its own rule inside the staging:
    ///
    /// * the MARKER is rebuilt at every ask — a pure build whose rect and
    ///   stand-in are resolved at ask time (`MapPinRevealSource.origin`), so a
    ///   recycled or moved marker view is found again on the next attempt;
    /// * the PLACE CARD is staged once and remembered, because its staging
    ///   ADOPTS a tile (a move that undoes itself if repeated) — and handed
    ///   back on a later vertical attempt, even after a marker attempt
    ///   replaced it in between.
    private func armCardClose(
        _ slide: InteractiveSlideDismissal, feed: UIViewController,
        landing: (any CardCloseLanding)?, markerOrigin: TextRevealOrigin
    ) {
        var placeCardGeometry: RevealGeometry?
        // ⚠️ `slide` WEAKLY: the driver owns this closure and the closure
        // writes back through the driver, so a strong capture is a retain
        // cycle — every card close ever staged would keep its driver alive
        // for the life of the process, one per opened post, and invisible to
        // every census, because what leaks is a DRIVER and nothing counts
        // those. `cardClose = nil` cannot help: the cycle holds the object
        // whether or not this controller still points at it.
        slide.armAsCardCloseAlongsideFlight(
            on: feed, restagesOnEveryAttempt: true
        ) { [weak self, weak landing, weak slide] feed, axis in
            guard let self, let slide else { return false }
            switch Self.closeTarget(axis: axis, hasLanding: landing != nil) {
            case .marker:
                slide.revealGeometry = self.makeRevealGeometry(feed, markerOrigin, nil)
            case .placeCard:
                if placeCardGeometry == nil {
                    placeCardGeometry = landing?.cardCloseGeometry(dismissing: feed)
                }
                // Nil (no card to aim at yet) leaves the plain slide, and the
                // next attempt asks again.
                slide.revealGeometry = placeCardGeometry
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-grab-log") {
                print("[card-close] stage axis=\(axis)"
                      + " geometry=\(slide.revealGeometry != nil)")
            }
            #endif
            return slide.revealGeometry != nil
        }
    }

    /// `-text-swipe-demo`: drives the armed close from a script.
    private func debugScriptCardCloseIfRequested(_ slide: InteractiveSlideDismissal) {
        #if DEBUG
        // `-text-swipe-demo <peak>` (+ `-zoom-demo-grab-vertical` for the
        // axis): the same script the reveal path honours, on the driver that
        // is otherwise unreachable — this grab only exists for a post the
        // viewer has PAGED to, and the simulator injects neither the paging
        // nor the drag. Pair with `-snap-start-index N` to settle on a text
        // page first.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-text-swipe-demo"),
           position + 1 < arguments.count,
           let peak = Double(arguments[position + 1]) {
            let axis: ZoomDismissAxis = arguments.contains("-zoom-demo-grab-vertical")
                ? .vertical : .horizontal
            Task { @MainActor [weak slide] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let driven = await slide?.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                print("[card-close] peak=\(peak) axis=\(axis) driven=\(driven ?? false)")
                // `-text-swipe-demo-again <peak>`: a SECOND attempt, 2s after
                // the first — the cancel-then-close-again route. A first peak
                // under the release threshold springs back; this is the close
                // that follows it on the same driver.
                guard let again = arguments.firstIndex(of: "-text-swipe-demo-again"),
                      again + 1 < arguments.count,
                      let secondPeak = Double(arguments[again + 1]) else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let drivenAgain = await slide?.debugPerformSwipe(
                    peakProgress: CGFloat(secondPeak), axis: axis
                )
                print("[card-close] again peak=\(secondPeak) axis=\(axis) driven=\(drivenAgain ?? false)")
            }
        }
        #endif
    }
}

#if DEBUG
extension MapsViewController {
    /// The animated-icon instrument, over the real map — `-map-icon-hud`.
    ///
    /// It replaces the standalone bench screen, and the swap is the point: a
    /// synthetic lattice could not tell you what MapKit, clustering, tile
    /// loading and the app's own working set cost around the feature. Only the
    /// shipping screen can.
    /// `-maps-nav-sweep`: pan and zoom the map on a fixed schedule, forever.
    ///
    /// The static field is the EASY case. Every earlier measurement on this
    /// feature said the same thing — animation is nearly free and navigation is
    /// what costs, because a pan re-runs clustering, re-reconciles annotations,
    /// and re-attaches artwork to recycled views. Reporting "144 markers at
    /// 16.67 ms" while the map sat still would be reporting the wrong number.
    ///
    /// Scripted rather than driven by injected gestures: CGEvent swipes land on
    /// whichever window is frontmost and vanish silently when one overlaps, so
    /// a flaky driver would show up as a performance result.
    /// `-maps-nav-drag`: step the camera in many small NON-animated increments,
    /// the way a finger does.
    ///
    /// `-maps-nav-sweep` uses `setRegion(animated: true)`, which fires
    /// `regionDidChangeAnimated` exactly ONCE per gesture — so it measured a
    /// world in which reconcile bursts cannot happen, and reported no duplicate
    /// reconciles because the workload could not produce one. A real pan fires
    /// the delegate on every step. Whether coalescing is worth anything is a
    /// question only this driver can answer.
    fileprivate func installNavigationDrag() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-nav-drag") else { return }
        // Around `-maps-set-region`'s framing when one is given: panning a
        // continent of country markers is not the workload panning Paris is.
        let home = Self.debugSetRegion ?? Self.defaultRegion
        var step = 0
        // 60 Hz stepping: one region change per display frame, which is the
        // upper bound of what a finger can generate.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A slow lissajous over the seeded region: never repeats a frame,
            // never leaves the corpus, and keeps the span fixed so this measures
            // PAN only — zoom changes the marker population and would confound
            // the reconcile count with realisation work.
            // ⚠️ BURSTS, NOT A PERPETUAL PAN. A finger moves and then stops;
            // this driver did not, and `scheduleQuery`'s cancel-and-reschedule
            // debounce (by design: do not query while the camera is moving)
            // therefore never fired, so the map held ZERO markers and every
            // performance column looked excellent. Worse, the effect appeared
            // only once the reconcile throttle had made the settles cheap
            // enough to sustain 60 Hz from launch — the optimisation was fast
            // enough to starve the app's own query. 1.0s of motion, 0.5s still.
            let cycle = Double(step) / 60.0
            if cycle.truncatingRemainder(dividingBy: 1.5) >= 1.0 { step += 1; return }
            let t = Double(step) / 60.0
            step += 1
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: home.center.latitude + 0.22 * home.span.latitudeDelta * sin(t * 0.9),
                    longitude: home.center.longitude + 0.22 * home.span.longitudeDelta * sin(t * 1.4)
                ),
                span: home.span
            )
            self.mapView.setRegion(region, animated: false)
        }
    }

    /// `-maps-zoom-sweep`: zooms the camera from a city out to the widest
    /// view MapKit allows and back in, one animated step every 2.5s, each
    /// step a settle — the path a pinch takes, filmable in the sim where a
    /// pinch cannot be injected. Every settle runs the clustering, the query
    /// and the country badges at that distance.
    ///
    /// 40 000 km is past the standard map's ~26 300 km clamp on purpose: the
    /// step asks for more than MapKit gives, as a finger pinching out keeps
    /// doing. At the widest view the camera also crosses to the Pacific and
    /// back — a viewport across the antimeridian (`MapViewport.make`).
    fileprivate func installZoomSweep() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-zoom-sweep") else { return }
        // `.stay` keeps the camera where it is; `.home` is where it was at
        // the first step (read then: this runs before the opening region).
        enum Centre { case stay, pacific, home }
        let steps: [(distance: CLLocationDistance, centre: Centre)] = [
            (300_000, .stay), (3_000_000, .stay), (14_000_000, .stay), (25_000_000, .stay),
            (40_000_000, .stay), (40_000_000, .pacific), (40_000_000, .home),
            (10_000_000, .stay), (3_000_000, .stay), (300_000, .stay),
        ]
        var step = 0
        var home: CLLocationCoordinate2D?
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            guard let self, step < steps.count else { timer.invalidate(); return }
            let camera = self.mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
            if home == nil { home = camera.centerCoordinate }
            camera.centerCoordinateDistance = steps[step].distance
            switch steps[step].centre {
            case .stay: break
            case .pacific: camera.centerCoordinate = CLLocationCoordinate2D(latitude: -17, longitude: 179)
            case .home: if let home { camera.centerCoordinate = home }
            }
            print(String(
                format: "[maps-camera] sweep step %d -> %.0f at %.2f,%.2f", step, steps[step].distance,
                camera.centerCoordinate.latitude, camera.centerCoordinate.longitude
            ))
            step += 1
            self.mapView.setCamera(camera, animated: true)
        }
    }

    fileprivate func installNavigationSweep() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-nav-sweep") else { return }
        let home = Self.defaultRegion
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A six-phase cycle: four pans around the seeded region, then a zoom
            // in and back out. Zoom is included because it changes the marker
            // POPULATION, which is the expensive half — a pure pan only moves
            // views that already exist.
            let dLat = home.span.latitudeDelta, dLon = home.span.longitudeDelta
            let offsets: [(Double, Double, Double)] = [
                (0.30, 0, 1), (0, 0.30, 1), (-0.30, 0, 1),
                (0, -0.30, 1), (0, 0, 0.45), (0, 0, 1)
            ]
            let (oLat, oLon, zoom) = offsets[step % offsets.count]
            step += 1
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: home.center.latitude + oLat * dLat,
                    longitude: home.center.longitude + oLon * dLon
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: dLat * zoom, longitudeDelta: dLon * zoom
                )
            )
            self.mapView.setRegion(region, animated: true)
        }
    }

    fileprivate func installIconDebugHUD() {
        // `-map-icon-policy full|reduced|still` pins the motion state from
        // launch. Read even without the HUD: an A/B that depends on tapping a
        // control is an A/B whose two arms were run by hand, and the arm you
        // tapped second is the one whose viewport had already drifted.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-map-icon-policy"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let policy = AnimatedIconView.MotionPolicy(
               rawValue: ProcessInfo.processInfo.arguments[index + 1]
           ) {
            AnimatedIconView.forcedPolicy = policy
        }
        guard ProcessInfo.processInfo.arguments.contains("-map-icon-hud") else { return }
        let hud = MapIconDebugHUD(
            mapView: mapView, catalog: iconCatalog as? AnimatedIconCatalog, previews: previewCatalog, pool: videoPool
        )
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.onPolicyChange = { [weak self] in
            guard let self else { return }
            for annotation in self.mapView.annotations {
                (self.mapView.view(for: annotation) as? MapAnnotationView)?.redressIcon()
                (self.mapView.view(for: annotation) as? MapClusterAnnotationView)?.redressIcon()
            }
        }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
        iconDebugHUD = hud
        hud.start()
    }
}
#endif

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

/// Holds notification tokens and removes them when the owning VC is released.
/// `@unchecked Sendable` so `deinit` may run off the main actor; the tokens are
/// only mutated on the main actor and `removeObserver` is thread-safe.
private final class MapNotificationBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

#if DEBUG
/// Weak-target beat for `-maps-trace-chrome` — see `installChromeTrace`.
private final class MapsChromeTraceProxy {
    private weak var target: MapsViewController?
    init(target: MapsViewController) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { return link.invalidate() }
        target.sampleChrome()
    }
}
#endif

extension MapsViewController: MapCountryShopHosting {}

#if DEBUG
extension MapsViewController: ArrivalInvariantReporting {
    /// Back on the map, no flight is held and no marker is still concealed.
    public func arrivalFacts() -> [(name: String, holds: Bool)] {
        let hidden = mapView.annotations.compactMap { mapView.view(for: $0) }.filter(\.isHidden).count
        return [
            ("maps.activeTransition", activeTransition == nil),
            ("maps.hiddenMarkers=\(hidden)", hidden == 0),
        ]
    }
}
#endif

extension MapsViewController: MapViewerRefreshing {
    /// Signed in or out: the dock and the people rows were someone else's.
    func viewerDidChange() {
        // A guest who signed up while locked: unlocked at once (#564).
        updateGuestLock(animated: true)
        catalogueCache.removeAll()
        peopleCache.removeAll()
        loadFavorites()
        prefetchPeople()
    }
}
