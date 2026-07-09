import CoreModels
import DesignSystem
import MapKit
import MediaCore
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

    init(viewModel: MapsViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Maps"
        configureMapView()
        bindViewModel()
        mapView.setRegion(Self.defaultRegion, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick the first query; coalesces with any region-settle callback.
        scheduleQuery()
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
    }
}

// MARK: - MKMapViewDelegate

extension MapsViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        scheduleQuery()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation is MKClusterAnnotation {
            return mapView.dequeueReusableAnnotationView(
                withIdentifier: MapClusterAnnotationView.reuseIdentifier,
                for: annotation
            )
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
        // Step B: launch the hero/zoom transition into the vertical snap feed —
        // a single pin opens its post; a cluster opens the group's posts. For
        // now, just clear the selection so the map stays interactive.
        mapView.deselectAnnotation(view.annotation, animated: false)
    }
}
