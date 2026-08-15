import CoreModels
import CoreNavigation
import DesignSystem
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import UIKit

/// The Maps tab surface: a full-bleed `MKMapView` that re-queries lightweight
/// pins whenever the user settles a pan/zoom, and applies the result as a
/// minimal identity diff so untouched markers never flicker.
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
    /// Runaway guard: clustering already bounds the visible set to a handful, but
    /// cap the sweep in case it runs during a pre-cluster frame.
    private static let prewarmCap = 16
    /// Retains the transitioning delegate for the life of a presentation.
    private var activeTransition: ZoomTransitionController?
    /// True from the moment a plain push is fired until the map is back on
    /// screen. It does for that path exactly what `activeTransition` does for
    /// the flight: the instant-tap recognizer and MapKit's own `didSelect` can
    /// both fire for ONE tap, and without a guard the second one pushes a
    /// second copy of the feed.
    private var isPlainFeedPushed = false
    /// Chooses which ≤3 visible video pins autoplay.
    private let videoCoordinator: MapVideoPlaybackCoordinator
    /// Runs the pins' staggered pop-in/pop-out and owns the in-flight
    /// animators — including the marker-reclaim that keeps a fast filter
    /// flip-flop from doubling a pin (see `MapAnnotationPopChoreographer`).
    private lazy var popChoreographer = MapAnnotationPopChoreographer(mapView: mapView)
    private let appObservers = MapNotificationBag()
    #if DEBUG
    private var didDebugOpenPin = false
    #endif

    private let mapView = MKMapView()
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
        videoPlayback: VideoPlaybackController,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController,
        pushPlainSnapFeed: @escaping ([PostID], UIViewController) -> Void,
        prewarm: @escaping ([PostID]) async -> Void,
        openProfile: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
        openConversation: @escaping (ProfileID) -> Void
    ) {
        self.viewModel = viewModel
        self.favoritesRepository = favoritesRepository
        self.pinService = pinService
        self.imagePipeline = imagePipeline
        self.videoCoordinator = MapVideoPlaybackCoordinator(pool: videoPlayback)
        self.makeSnapFeed = makeSnapFeed
        self.pushPlainSnapFeed = pushPlainSnapFeed
        self.prewarm = prewarm
        self.openProfile = openProfile
        self.openConversation = openConversation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No title, deliberately: the map is the tab's whole surface and
        // names itself; the header band belongs to its controls — the
        // compose "+", the wallet badge, the bell. (The tab bar still says
        // "Maps"; that label lives on `UITab`, not here.)
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
        // the sim, where pinch gestures can't be injected.
        if ProcessInfo.processInfo.arguments.contains("-maps-wide-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta *= 6
            region.span.longitudeDelta *= 6
            mapView.setRegion(region, animated: false)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    subFilterBar.setSelectedSubFilters(subFilters)
                    viewModel.subFiltersChanged(subFilters)
                }
            }
        }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncBarsPosition()
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
    /// present, laid out, and invisible. The flight path never showed it because
    /// its return drives a layout of its own (`restoreBottomChromeForReturn`).
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick the first query; coalesces with any region-settle callback.
        scheduleQuery()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Tab became frontmost: resume previews. NOT while a hero transition
        // is alive — under a push, this fires the moment a pop *begins*, and
        // an interactive grab can cancel; the completed return resumes via
        // the transition's onSourceReturned instead.
        // The map is on its way back (or arriving for the first time), so a
        // plainly-pushed feed is behind us and the next tap must open again.
        isPlainFeedPushed = false
        guard activeTransition == nil else {
            // A hero return, though, does need its bottom chrome put back —
            // invisible, so the flight can fade it in. This is the only chance
            // the back-button pop gets; a grab already did it at grab-begin, so
            // there this is a no-op.
            restoreBottomChromeForReturn(alpha: 0)
            return
        }
        videoCoordinator.setSurfaceVisible(true)
        refreshVideoPlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tab hidden: stop previews. During a feed push this is a no-op —
        // presentSnapFeed already covered the surface (keeping the donor).
        guard activeTransition == nil else { return }
        videoCoordinator.setSurfaceVisible(false)
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
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        appObservers.add(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.videoCoordinator.setSurfaceVisible(false) }
        })
        appObservers.add(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.videoCoordinator.setSurfaceVisible(true)
                self.refreshVideoPlayback()
            }
        })
    }

    private func configureMapView() {
        mapView.delegate = self
        mapView.pointOfInterestFilter = .excludingAll
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
        barsStack.addArrangedSubview(subFilterBar)
        barsStack.addArrangedSubview(filterBar)
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
        CADisplayLink(target: self, selector: #selector(sampleChrome)).add(to: .main, forMode: .common)
    }

    @objc private func sampleChrome() {
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

    /// Brings the map's bottom chrome back as the feed leaves: the app's tab bar
    /// and the map's own filter bars.
    ///
    /// The tab bar's hidden STATE and its OPACITY are set separately, and the
    /// split is the point. The state has to be restored outside any transition —
    /// done inside one, the bar's frame returns and `isTabBarHidden` reads false
    /// while its buttons never paint, leaving a row of empty glass capsules. The
    /// opacity then belongs to the flight, which drives it 1:1 with a grab and on
    /// the dismiss spring for a tap-back, so the bar is never seen to pop in
    /// after the card has landed.
    ///
    /// The filter bars are restored to FULL opacity regardless, and that is not
    /// an oversight: they live inside this view controller's own view, so the
    /// flight's dim is already over them and the presenter's recede already
    /// carries them. Giving them an alpha ramp of their own would double the
    /// fade. Only the tab bar, which is a sibling of the navigation controller's
    /// view and therefore renders above the dim, needs driving by hand.
    private func restoreBottomChromeForReturn(alpha: CGFloat) {
        barsStack.alpha = 1
        guard let tabBarController else { return }
        tabBarController.tabBar.alpha = alpha
        guard tabBarController.isTabBarHidden else { return }
        tabBarController.setTabBarHidden(false, animated: false)
        tabBarController.view.layoutIfNeeded()
    }

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
            reconcileClusters()
        }
    }

    private func flushPendingDiffs() {
        guard layoutPending else { return }
        layoutPending = false
        reconcileClusters()
    }

    // MARK: - Querying

    private func scheduleQuery() {
        pendingQuery?.cancel()
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
        let items = MapClusterEngine.cluster(
            Array(pins.values),
            zoomScale: currentZoomScale,
            cellPoints: Double(Self.clusterCellPoints)
        )
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
                let annotation = MapAnnotation(pin: item.representative)
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
                let annotation = MapComputedCluster(item)
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
        popChoreographer.popOut(departing.map { (id: $0.key, annotation: $0.value) })

        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
        refreshVideoPlayback()
    }

    private static func singleIdentity(_ postID: PostID) -> String { "p:" + postID.rawValue }

    /// Re-points and re-faces a marker already on the map for a recomputed item.
    private func update(_ annotation: any MKAnnotation, to item: MapClusterEngine.Item) {
        if let cluster = annotation as? MapComputedCluster {
            cluster.apply(item)
            (mapView.view(for: cluster) as? MapClusterAnnotationView)?
                .configure(with: cluster, imagePipeline: imagePipeline)
        } else if let single = annotation as? MapAnnotation {
            single.update(pin: item.representative)
            (mapView.view(for: single) as? MapAnnotationView)?
                .configure(with: item.representative, imagePipeline: imagePipeline)
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

    // MARK: - Live previews

    /// Recomputes the ≤3 video pins to autoplay: the on-screen, video-capable,
    /// LONE pins (a clustered post isn't its own marker), ranked by closeness
    /// to the viewport center.
    private func refreshVideoPlayback() {
        let center = mapView.centerCoordinate
        let visibleRect = mapView.visibleMapRect
        var scored: [(distance: Double, candidate: MapVideoPlaybackCoordinator.Candidate)] = []
        for annotation in displayed.values {
            guard let single = annotation as? MapAnnotation,
                  single.pin.kind == .video,
                  let url = single.pin.previewVideoURL,
                  visibleRect.contains(MKMapPoint(single.coordinate)),
                  let view = mapView.view(for: single) as? MapAnnotationView else { continue }
            let candidate = MapVideoPlaybackCoordinator.Candidate(
                id: single.pin.postID, url: url, view: view
            )
            scored.append((Self.squaredDistance(single.coordinate, center), candidate))
        }
        let ranked = scored.sorted { $0.distance < $1.distance }.map(\.candidate)
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
    private func prewarmVisiblePosts() {
        let visible = mapView.annotations(in: mapView.visibleMapRect)
        var ids: [PostID] = []
        var seen = Set<PostID>()
        func add(_ id: PostID) { if seen.insert(id).inserted { ids.append(id) } }
        for element in visible {
            if let pin = element as? MapAnnotation {
                add(pin.pin.postID)
            } else if let cluster = element as? MapComputedCluster {
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
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // A zoom/pan started: hold annotation mutations until it settles.
        isRegionTransitioning = true
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Settled. The zoom level changed, so re-lay-out the clusters now (with
        // the settled projection), fold in anything a mid-flight diff staged,
        // then request the next page.
        isRegionTransitioning = false
        reconcileClusters()
        flushPendingDiffs()
        scheduleQuery()
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Land them: scale-and-fade in, staggered across the batch. This fires
        // for pins panning into the rendered region too, not only for a fresh
        // query — which is what makes the map feel populated rather than
        // stamped.
        popChoreographer.popIn(views)
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
        let wantsText = arguments.contains("-maps-open-first-text-pin")
        guard !didDebugOpenPin,
              wantsText || arguments.contains("-maps-open-first-pin") else { return }
        let annotations = views.compactMap { $0.annotation as? MapAnnotation }
        let preferred: MapPin.Kind = wantsText ? .text : .video
        guard let annotation = annotations.first(where: { $0.pin.kind == preferred })
            ?? (wantsText ? nil : annotations.first)
        else { return }
        didDebugOpenPin = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.mapView.selectAnnotation(annotation, animated: true)
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
        guard !didDebugOpenPin,
              wantsText || arguments.contains("-maps-open-first-cluster") else { return }
        let clusters = views.compactMap { $0.annotation as? MapComputedCluster }
            .filter { $0.memberIDs.count > 1 && (!wantsText || $0.representative.isText) }
        guard let cluster = clusters.max(by: { $0.memberIDs.count < $1.memberIDs.count })
        else { return }
        didDebugOpenPin = true
        let ids = Self.postIDs(of: cluster)
        let kind = cluster.representative.isText ? "text" : "media"
        print("[maps] cluster tap → representative=\(cluster.representative.postID.rawValue) "
            + "(\(kind), \(MapMarkerPresentation(face: Self.face(of: cluster)))) "
            + "opening \(ids.count) posts: \(ids.map(\.rawValue).joined(separator: ","))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.mapView.selectAnnotation(cluster, animated: true)
        }
    }
    #endif

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MapComputedCluster {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MapClusterAnnotationView.reuseIdentifier,
                for: annotation
            ) as? MapClusterAnnotationView
            view?.configure(with: cluster, imagePipeline: imagePipeline)
            // Instant tap — bypasses MapKit's ~0.3s selection delay.
            view?.onSelect = { [weak self, weak view] in
                self?.openAnnotation(cluster, thumbnail: view?.heroImage)
            }
            return view
        }
        guard let pinAnnotation = annotation as? MapAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: MapAnnotationView.reuseIdentifier,
            for: annotation
        ) as? MapAnnotationView
        view?.configure(with: pinAnnotation.pin, imagePipeline: imagePipeline)
        view?.onSelect = { [weak self, weak view] in
            self?.openAnnotation(pinAnnotation, thumbnail: view?.heroImage)
        }
        return view
    }

    /// Opens a tapped marker's post(s) with the hero transition — a single pin
    /// opens its post, a cluster opens all its members (their ids are already
    /// held locally, no extra round-trip). The re-entrancy guard makes this
    /// safe to call from both the instant tap recognizer and MapKit's own
    /// `didSelect` (the fallback): whichever lands first wins, the other is a
    /// no-op while the flight is alive.
    private func openAnnotation(_ annotation: any MKAnnotation, thumbnail: UIImage?) {
        guard activeTransition == nil, !isPlainFeedPushed else { return }
        let postIDs = Self.postIDs(of: annotation)
        guard !postIDs.isEmpty else { return }
        let face = Self.face(of: annotation)
        switch MapMarkerPresentation(face: face) {
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
            isPlainFeedPushed = true
            pushPlainSnapFeed(postIDs, self)
        case .plainPush, .hero:
            presentSnapFeed(postIDs: postIDs, from: annotation, thumbnail: thumbnail)
        }
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // Deselect immediately so the pin can be tapped again after dismissal.
        // The instant-tap recognizer normally fires first; this is the fallback
        // (and clears MapKit's own selection either way).
        guard let annotation = view.annotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)

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

    /// The face the tapped marker is wearing, so the flight card takes off as
    /// its twin — a symbol pin must not fly as an empty square.
    private static func face(of annotation: any MKAnnotation) -> PinCardView.Face {
        let pin = (annotation as? MapAnnotation)?.pin
            ?? (annotation as? MapComputedCluster)?.representative
        return pin?.isText == true ? .text : .media
    }

    private func presentSnapFeed(postIDs: [PostID], from annotation: any MKAnnotation, thumbnail: UIImage?) {
        let feedVC = makeSnapFeed(postIDs)
        guard let nav = navigationController,
              let destination = feedVC as? any ZoomTransitionDestination else {
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
            mirrorLive: tappedID.map { id in
                { renderView in coordinator.mirrorLivePreview(of: id, to: renderView) }
            }
        )
        // A *push*, not a modal: the feed joins this tab's stack, so the one
        // navigation bar cross-fades "Maps" into the feed's back item + author
        // capsule natively — no second bar to pop in over the first. The
        // transition object is the stack's delegate for the feed's lifetime.
        let transition = ZoomTransitionController(source: source, destination: destination)
        activeTransition = transition

        var didLand = false
        transition.onDestinationShown = { [weak self, weak transition] in
            // Landed (fires again if a detail above the feed pops back — the
            // flight-scoped work must run once): release the donor player.
            guard !didLand else { return }
            didLand = true
            self?.videoCoordinator.stopAll()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-maps-demo-grab") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    transition?.debugScriptedGrab()
                }
            }
            #endif
        }
        // The bar's opacity rides the return — 1:1 with a grab, and on the
        // flight's own spring for a tap-back — so it is revealed as the card
        // shrinks instead of appearing once it has landed. Same mechanism the
        // For You grid uses; the two surfaces must not diverge, since a viewer
        // sees the same bar return from the same feed either way.
        transition.returningSourceChrome = tabBarController?.tabBar
        transition.onSourceReturned = { [weak self, weak nav] in
            // Completed pop only — a cancelled grab reports through
            // `onDismissalCancelled`, so the transition (and future grabs)
            // survives it by construction.
            nav?.delegate = nil
            guard let self else { return }
            // Idempotent close-out: the state and the alpha are already right by
            // now (see `restoreBottomChromeForReturn`).
            self.restoreBottomChromeForReturn(alpha: 1)
            self.activeTransition = nil
            self.videoCoordinator.setSurfaceVisible(true)
            self.refreshVideoPlayback()
        }
        transition.onDismissalCancelled = { [weak self] in
            // The feed is staying up: put the bottom chrome back down behind it.
            self?.tabBarController?.setTabBarHidden(true, animated: false)
            self?.tabBarController?.tabBar.alpha = 1
            self?.barsStack.alpha = 0
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        transition.attachInteractiveDismissal(to: feedVC.view) { [weak self, weak nav] in
            // Restore the bar's hidden STATE at grab-begin, before the pop and
            // so outside any transition — the one point at which it paints
            // correctly. Invisible, so the drag can fade it in.
            self?.restoreBottomChromeForReturn(alpha: 0)
            nav?.popViewController(animated: true)
        }
        // Map is covered by the feed → stop its previews, except the tapped
        // pin's, which the flight card is still rendering. Set *before* the
        // push so the map's viewWillDisappear sweep is a no-op that can't
        // touch the donor.
        videoCoordinator.setSurfaceVisible(false, keeping: tappedID)
        // Tab bar managed by hand, NOT hidesBottomBarWhenPushed: that flag's
        // bottom-bar choreography doesn't scrub with a custom interactive pop
        // (the bar snaps in at pop-begin and flashes over the feed when a grab
        // cancels). Manually it slides away with the lift-off, stays hidden
        // through cancelled grabs, and comes back on the return with its opacity
        // driven by the flight (`restoreBottomChromeForReturn`). Constraint: a
        // programmatic cross-tab route while the feed is pushed would find the
        // bar hidden — today no such route fires from inside the feed.
        tabBarController?.setTabBarHidden(true, animated: true)
        setFilterBar(hidden: true)
        nav.delegate = transition
        nav.pushViewController(feedVC, animated: true)
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
