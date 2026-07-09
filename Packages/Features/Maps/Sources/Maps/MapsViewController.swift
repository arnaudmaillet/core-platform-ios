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
    private let imagePipeline: ImagePipeline
    /// Builds the snap feed a pin/cluster tap expands into (reuses the Feed
    /// feature via `FeedFeatureBuilding.makeSnapFeedViewController`).
    private let makeSnapFeed: ([PostID]) -> UIViewController
    /// Retains the transitioning delegate for the life of a presentation.
    private var activeTransition: MapsZoomTransition?
    /// Chooses which ≤3 visible video pins autoplay.
    private let videoCoordinator: MapVideoPlaybackCoordinator
    private let appObservers = MapNotificationBag()
    #if DEBUG
    private var didDebugOpenPin = false
    #endif

    private let mapView = MKMapView()
    /// id → live marker, so a diff can target the exact annotation to remove or
    /// refresh without rebuilding the set.
    private var annotations: [PostID: MapAnnotation] = [:]

    /// Debounce so a continuous pan fires one query on settle, not per frame.
    private var pendingQuery: DispatchWorkItem?
    private static let settleDelay: TimeInterval = 0.25

    /// A sensible default until location permission / deep-linking lands: central
    /// Paris at neighbourhood zoom (also where the mock dataset seeds its pins).
    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        span: MKCoordinateSpan(latitudeDelta: 0.09, longitudeDelta: 0.09)
    )

    init(
        viewModel: MapsViewModel,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController,
        makeSnapFeed: @escaping ([PostID]) -> UIViewController
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.videoCoordinator = MapVideoPlaybackCoordinator(pool: videoPlayback)
        self.makeSnapFeed = makeSnapFeed
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
        mapView.setRegion(Self.defaultRegion, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick the first query; coalesces with any region-settle callback.
        scheduleQuery()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Tab became frontmost (or returned from the feed): resume previews.
        videoCoordinator.setSurfaceVisible(true)
        refreshVideoPlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tab hidden: stop previews.
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
    }

    private func bindViewModel() {
        viewModel.onDiff = { [weak self] diff in self?.apply(diff) }
        // `onTileCount` is a "zoom in for more" hint hook; wired to UI later.
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
}

// MARK: - MKMapViewDelegate

extension MapsViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        scheduleQuery()
        // Panning without new pins still changes which are visible/central.
        refreshVideoPlayback()
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Annotation views now exist → a pin that should autoplay can be bound.
        refreshVideoPlayback()
        #if DEBUG
        debugOpenFirstPinIfRequested(among: views)
        #endif
    }

    #if DEBUG
    /// `-maps-open-first-pin`: taps a pin shortly after it appears so the hero
    /// transition into the snap feed can be driven/screenshotted in the sim.
    private func debugOpenFirstPinIfRequested(among views: [MKAnnotationView]) {
        guard !didDebugOpenPin,
              ProcessInfo.processInfo.arguments.contains("-maps-open-first-pin"),
              let annotation = views.compactMap({ $0.annotation as? MapAnnotation }).first else { return }
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
            thumbnail = nil
        default:
            return
        }
        guard !postIDs.isEmpty else { return }

        presentSnapFeed(postIDs: postIDs, from: annotation, thumbnail: thumbnail)
    }

    private func presentSnapFeed(postIDs: [PostID], from annotation: any MKAnnotation, thumbnail: UIImage?) {
        let feedVC = makeSnapFeed(postIDs)
        guard let destination = feedVC as? any ZoomTransitionDestination else {
            // Defensive: without the hero seam, fall back to a plain present.
            present(feedVC, animated: true)
            return
        }
        let source = MapPinZoomSource(mapView: mapView, annotation: annotation, thumbnail: thumbnail)
        let transition = MapsZoomTransition(source: source, destination: destination)
        activeTransition = transition
        feedVC.modalPresentationStyle = .overFullScreen
        feedVC.transitioningDelegate = transition

        // Force the feed view to load so the grab-to-dismiss gesture can attach.
        // On completion (only fires if the grab actually dismisses — a cancelled
        // grab leaves the feed up), resume the map's previews. An over-full-
        // screen present doesn't call the map's viewWillAppear, so we resume here.
        transition.attachInteractiveDismissal(to: feedVC.view) { [weak self, weak feedVC] in
            feedVC?.dismiss(animated: true) { self?.handleFeedDismissed() }
        }
        source.hideSourcePin()
        // Map is covered by the feed → stop its previews.
        videoCoordinator.setSurfaceVisible(false)
        present(feedVC, animated: true)
    }

    private func handleFeedDismissed() {
        activeTransition = nil
        videoCoordinator.setSurfaceVisible(true)
        refreshVideoPlayback()
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
