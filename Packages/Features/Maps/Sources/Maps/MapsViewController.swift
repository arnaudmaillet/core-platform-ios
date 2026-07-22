import CoreModels
import CoreNavigation
import DesignSystem
import MapKit
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
    /// The client-persisted pinned set behind the favorites section (nil
    /// until the viewer first curates → fall back to followed profiles).
    private let favoritesStore = MapFavoritesStore()
    /// What the favorites section currently shows — the seed material when a
    /// first pin/unpin materializes the store from the fallback.
    private var currentFavorites: [MapFavorite] = []
    /// What the sub-filter row currently shows — the full-list sheet's data.
    private var currentSubFilterOptions: [MapSubFilterOption] = []
    private let imagePipeline: ImagePipeline
    /// Builds the snap feed a pin/cluster tap expands into (reuses the Feed
    /// feature via `FeedFeatureBuilding.makeSnapFeedViewController`).
    private let makeSnapFeed: ([PostID]) -> UIViewController
    /// Warms the given posts into the shared cache so a tap opens instantly.
    private let prewarm: ([PostID]) async -> Void
    /// The current viewport's prefetch, cancelled when the map settles elsewhere.
    private var prewarmTask: Task<Void, Never>?
    /// Runaway guard: clustering already bounds the visible set to a handful, but
    /// cap the sweep in case it runs during a pre-cluster frame.
    private static let prewarmCap = 16
    /// Retains the transitioning delegate for the life of a presentation.
    private var activeTransition: MapsZoomTransition?
    /// Chooses which ≤3 visible video pins autoplay.
    private let videoCoordinator: MapVideoPlaybackCoordinator
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
    /// id → live marker, so a diff can target the exact annotation to remove or
    /// refresh without rebuilding the set.
    private var annotations: [PostID: MapAnnotation] = [:]

    /// Debounce so a continuous pan fires one query on settle, not per frame.
    private var pendingQuery: DispatchWorkItem?
    private static let settleDelay: TimeInterval = 0.25

    /// True between `regionWillChange` and `regionDidChange` — i.e. while a
    /// zoom/pan is animating. Mutating annotations during that window can corrupt
    /// MapKit's clustering pass, so diffs that arrive mid-flight are buffered.
    private var isRegionTransitioning = false
    /// Diffs deferred while a transition was in flight, applied in order on
    /// settle. Order preservation means the applied set still converges to the
    /// view model's authoritative state.
    private var pendingDiffs: [MapAnnotationDiff] = []

    /// A sensible default until location permission / deep-linking lands: central
    /// Paris at neighbourhood zoom (also where the mock dataset seeds its pins).
    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        span: MKCoordinateSpan(latitudeDelta: 0.09, longitudeDelta: 0.09)
    )

    init(
        viewModel: MapsViewModel,
        favoritesRepository: any MapFavoritesProviding,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController,
        prewarm: @escaping ([PostID]) async -> Void
    ) {
        self.viewModel = viewModel
        self.favoritesRepository = favoritesRepository
        self.imagePipeline = imagePipeline
        self.videoCoordinator = MapVideoPlaybackCoordinator(pool: videoPlayback)
        self.makeSnapFeed = makeSnapFeed
        self.prewarm = prewarm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Maps"
        configureMapView()
        bindViewModel()
        observeAppLifecycle()
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
        if let token = UserDefaults.standard.string(forKey: "maps-select-filter"),
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
        if let token = UserDefaults.standard.string(forKey: "maps-select-filter-2") {
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
        // `-maps-open-subfilter-sheet`: presents the sub-filter full-list
        // sheet ~3s in (the trailing bubble's tap). Pair with
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
        if let id = UserDefaults.standard.string(forKey: "maps-pin-favorite") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.togglePinnedFavorite(MapFavorite(profileID: ProfileID(id), title: ""))
            }
        }
        // `-maps-select-subfilter <profile:ID|place:token>`: selects a
        // refinement pill ~3s in (after the sub-filter row has loaded).
        // Pair with `-maps-select-filter friends|following|pinned`.
        if let token = UserDefaults.standard.string(forKey: "maps-select-subfilter") {
            let subFilter: MapSubFilter? = if token.hasPrefix("profile:") {
                .profile(ProfileID(String(token.dropFirst("profile:".count))))
            } else if token.hasPrefix("place:") {
                .placeCategory(String(token.dropFirst("place:".count)))
            } else {
                nil
            }
            if let subFilter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.subFilterBar.setSelectedSubFilter(subFilter)
                    self.viewModel.subFilterChanged(subFilter)
                }
            }
        }
        #endif
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
        // the transition's onMapReturned instead.
        guard activeTransition == nil else { return }
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
        configureFilterBar()
    }

    private func configureFilterBar() {
        barsStack.axis = .vertical
        barsStack.spacing = Spacing.xs
        barsStack.clipsToBounds = false
        view.addSubview(barsStack)
        barsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            barsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The safe-area bottom already sits above the floating tab bar, so
            // this rests the pills directly over it on every device class.
            barsStack.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.sm
            ),
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
        subFilterBar.onSubFilterChanged = { [weak self] subFilter in
            self?.viewModel.subFilterChanged(subFilter)
        }
        subFilterBar.onExpandTapped = { [weak self] in
            self?.presentSubFilterSheet()
        }
        subFilterBar.isPinned = { [weak self] profileID in
            self?.currentFavorites.contains { $0.profileID == profileID } ?? false
        }
        subFilterBar.onTogglePin = { [weak self] favorite in
            self?.togglePinnedFavorite(favorite)
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
            self.peopleCache[.friends] = friendsList
            self.peopleCache[.following] = followingList
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
            // 1) Instant: whatever the cache holds right now.
            let cached = peopleCache[primary] ?? []
            if !cached.isEmpty {
                showSubFilterRow(MapSubFilterOption.people(cached))
            }
            // 2) Refresh behind it (also the cold path pre-prefetch, where
            // the row appears when data lands — nothing to render sooner).
            let repository = favoritesRepository
            subFilterLoadTask = Task { [weak self] in
                let people = primary == .friends
                    ? await repository.friends()
                    : await repository.following()
                guard let self, !Task.isCancelled else { return }
                self.peopleCache[primary] = people
                guard self.filterBar.selectedFilter == primary else { return }
                // Don't churn the row (and its selection) for identical data.
                guard people != cached else { return }
                if people.isEmpty {
                    self.currentSubFilterOptions = []
                    self.setSubFilterBar(visible: false)
                } else {
                    self.showSubFilterRow(MapSubFilterOption.people(people))
                }
            }
        case .pinned:
            showSubFilterRow(MapSubFilterOption.placeCategories)
        default:
            // All / a favorite: no refinement dimension.
            currentSubFilterOptions = []
            setSubFilterBar(visible: false)
        }
    }

    /// One entry point for populating the row, choosing the right
    /// transition: hidden → set content and fade the bar in; already
    /// visible → cross-dissolve the pills in place (a hard swap while
    /// on-screen reads as a snap).
    private func showSubFilterRow(_ options: [MapSubFilterOption]) {
        currentSubFilterOptions = options
        if isSubFilterBarVisible {
            subFilterBar.transition(to: options)
        } else {
            subFilterBar.setOptions(options)
            setSubFilterBar(visible: true)
        }
    }

    /// The trailing bubble: the row's full contents as a searchable native
    /// bottom sheet; a row tap applies (or clears) that refinement.
    private func presentSubFilterSheet() {
        guard !currentSubFilterOptions.isEmpty else { return }
        let title: String? = switch filterBar.selectedFilter {
        case .friends: "Friends"
        case .following: "Following"
        case .pinned: "Places"
        default: nil
        }
        guard let title else { return }
        let sheet = MapSubFilterSheetViewController(
            title: title,
            options: currentSubFilterOptions,
            selected: subFilterBar.selectedSubFilter,
            imagePipeline: imagePipeline
        ) { [weak self] subFilter in
            guard let self else { return }
            self.subFilterBar.setSelectedSubFilter(subFilter)
            self.viewModel.subFilterChanged(subFilter)
        }
        present(sheet, animated: true)
    }

    /// Long-press pin/unpin from a person pill. The first mutation
    /// materializes the on-screen fallback into the persisted store, so what
    /// the viewer sees is what stays.
    private func togglePinnedFavorite(_ favorite: MapFavorite) {
        var pinned = favoritesStore.pinnedProfileIDs ?? currentFavorites.map(\.profileID)
        if let index = pinned.firstIndex(of: favorite.profileID) {
            pinned.remove(at: index)
        } else {
            pinned.append(favorite.profileID)
        }
        favoritesStore.setPinned(pinned)
        loadFavorites()
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
            // …then spring the finished row in, in place.
            UIView.mapBarSpring { self.subFilterBar.alpha = 1 }
        } else {
            UIView.mapBarSpring(
                { self.subFilterBar.alpha = 0 },
                completion: { _ in
                    // Collapse only after the spring settles — and only if a
                    // re-show didn't land while the fade-out was in flight.
                    guard !self.isSubFilterBarVisible else { return }
                    self.subFilterBar.isHidden = true
                }
            )
        }
    }

    /// Loads the favorites section: the persisted pinned set when curated,
    /// else the followed profiles (Phase-1 fallback). Fail-open: an empty
    /// result leaves the bar with just its primaries.
    private func loadFavorites() {
        favoritesTask?.cancel()
        let repository = favoritesRepository
        let pinnedIDs = favoritesStore.pinnedProfileIDs
        favoritesTask = Task { [weak self] in
            let favorites = if let pinnedIDs {
                await repository.profiles(for: pinnedIDs)
            } else {
                await repository.following()
            }
            guard let self, !Task.isCancelled else { return }
            self.currentFavorites = favorites
            self.filterBar.setFavorites(favorites)
        }
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

    private func bindViewModel() {
        viewModel.onDiff = { [weak self] diff in self?.handleDiff(diff) }
        // `onTileCount` is a "zoom in for more" hint hook; wired to UI later.
    }

    /// Applies a diff now, or buffers it if a region transition is animating —
    /// so `add/removeAnnotations` never lands mid-clustering-pass.
    private func handleDiff(_ diff: MapAnnotationDiff) {
        if isRegionTransitioning {
            pendingDiffs.append(diff)
        } else {
            apply(diff)
        }
    }

    private func flushPendingDiffs() {
        guard !pendingDiffs.isEmpty else { return }
        let diffs = pendingDiffs
        pendingDiffs.removeAll()
        for diff in diffs { apply(diff) }
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

    // MARK: - Diff application

    private func apply(_ diff: MapAnnotationDiff) {
        var toRemove: [MapAnnotation] = []
        for pin in diff.removed {
            if let annotation = annotations.removeValue(forKey: pin.postID) {
                toRemove.append(annotation)
            }
        }
        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

        var toAdd: [MapAnnotation] = []
        for pin in diff.added {
            let annotation = MapAnnotation(pin: pin)
            annotations[pin.postID] = annotation
            toAdd.append(annotation)
        }
        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }

        // Updated: keep the marker, refresh its model + (if on screen) its view.
        for pin in diff.updated {
            guard let annotation = annotations[pin.postID] else { continue }
            annotation.update(pin: pin)
            if let view = mapView.view(for: annotation) as? MapAnnotationView {
                view.configure(with: pin, imagePipeline: imagePipeline)
            }
        }

        refreshVideoPlayback()
    }

    // MARK: - Live previews

    /// Recomputes the ≤3 video pins to autoplay: the on-screen, video-capable,
    /// un-clustered annotations, ranked by closeness to the viewport center.
    private func refreshVideoPlayback() {
        let center = mapView.centerCoordinate
        let visibleRect = mapView.visibleMapRect
        var scored: [(distance: Double, candidate: MapVideoPlaybackCoordinator.Candidate)] = []
        for annotation in annotations.values {
            guard annotation.pin.mediaKind == .video,
                  let url = annotation.pin.previewVideoURL,
                  visibleRect.contains(MKMapPoint(annotation.coordinate)),
                  let view = mapView.view(for: annotation) as? MapAnnotationView else { continue }
            let candidate = MapVideoPlaybackCoordinator.Candidate(
                id: annotation.pin.postID, url: url, view: view
            )
            scored.append((Self.squaredDistance(annotation.coordinate, center), candidate))
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
            } else if let cluster = element as? MKClusterAnnotation,
                      let first = cluster.memberAnnotations.first as? MapAnnotation {
                add(first.pin.postID)
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
        // Settled: safe to mutate again. Apply anything that arrived mid-flight
        // before requesting the next page.
        isRegionTransitioning = false
        flushPendingDiffs()
        scheduleQuery()
        // Panning without new pins still changes which are visible/central.
        refreshVideoPlayback()
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Annotation views now exist (clustering is current) → bind autoplay and
        // warm the visible posts so a tap opens instantly.
        refreshVideoPlayback()
        prewarmVisiblePosts()
        #if DEBUG
        debugOpenFirstPinIfRequested(among: views)
        #endif
    }

    #if DEBUG
    /// `-maps-open-first-pin`: taps a pin shortly after it appears so the hero
    /// transition into the snap feed can be driven/screenshotted in the sim.
    /// Prefers a video pin when any exists (with `-maps-force-video`), so
    /// live-media flights are exercised deterministically.
    private func debugOpenFirstPinIfRequested(among views: [MKAnnotationView]) {
        guard !didDebugOpenPin,
              ProcessInfo.processInfo.arguments.contains("-maps-open-first-pin") else { return }
        let annotations = views.compactMap { $0.annotation as? MapAnnotation }
        guard let annotation = annotations.first(where: { $0.pin.mediaKind == .video }) ?? annotations.first
        else { return }
        didDebugOpenPin = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.mapView.selectAnnotation(annotation, animated: true)
        }
    }
    #endif

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MKClusterAnnotation {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MapClusterAnnotationView.reuseIdentifier,
                for: annotation
            ) as? MapClusterAnnotationView
            view?.configure(with: cluster, imagePipeline: imagePipeline)
            return view
        }
        guard let pinAnnotation = annotation as? MapAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: MapAnnotationView.reuseIdentifier,
            for: annotation
        ) as? MapAnnotationView
        view?.configure(with: pinAnnotation.pin, imagePipeline: imagePipeline)
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // Deselect immediately so the pin can be tapped again after dismissal.
        guard let annotation = view.annotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)

        // Resolve the tapped post(s): a single pin opens its post; a cluster
        // opens all its members (their ids are already held locally — no extra
        // round-trip).
        let postIDs: [PostID]
        let thumbnail: UIImage?
        switch annotation {
        case let pin as MapAnnotation:
            postIDs = [pin.pin.postID]
            thumbnail = (view as? MapAnnotationView)?.heroImage
        case let cluster as MKClusterAnnotation:
            postIDs = cluster.memberAnnotations.compactMap { ($0 as? MapAnnotation)?.pin.postID }
            // The cluster's face is the first member's cover — fly it, so the
            // frame-0 handshake holds for clusters exactly as for pins.
            thumbnail = (view as? MapClusterAnnotationView)?.heroImage
        default:
            return
        }
        guard !postIDs.isEmpty else { return }

        presentSnapFeed(postIDs: postIDs, from: annotation, thumbnail: thumbnail)
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
            mirrorLive: tappedID.map { id in
                { renderView in coordinator.mirrorLivePreview(of: id, to: renderView) }
            }
        )
        // A *push*, not a modal: the feed joins this tab's stack, so the one
        // navigation bar cross-fades "Maps" into the feed's back item + author
        // capsule natively — no second bar to pop in over the first. The
        // transition object is the stack's delegate for the feed's lifetime.
        let transition = MapsZoomTransition(source: source, destination: destination)
        activeTransition = transition

        var didLand = false
        transition.onFeedShown = { [weak self, weak transition] in
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
        transition.onMapReturned = { [weak self, weak nav] in
            // Completed pop only — a cancelled grab reports nothing, so the
            // transition (and future grabs) survives it by construction.
            nav?.delegate = nil
            guard let self else { return }
            self.tabBarController?.setTabBarHidden(false, animated: true)
            self.setFilterBar(hidden: false)
            self.activeTransition = nil
            self.videoCoordinator.setSurfaceVisible(true)
            self.refreshVideoPlayback()
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        transition.attachInteractiveDismissal(to: feedVC.view) { [weak nav] in
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
        // through cancelled grabs, and returns only on the completed pop
        // (onMapReturned above). Constraint: a programmatic cross-tab route
        // while the feed is pushed would find the bar hidden — today no such
        // route fires from inside the feed.
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
