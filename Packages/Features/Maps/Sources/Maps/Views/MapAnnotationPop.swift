import CoreModels
import MapKit
import UIKit

/// The pin pop curve: annotation views scale-and-fade IN as they land and OUT
/// as they leave, staggered across the batch so a page of results arrives as a
/// ripple rather than a slab appearing at once.
///
/// Pure values, so the timing is assertable without a live `MKMapView` —
/// instantiating one in a unit test contacts MapKit's services and is exactly
/// the kind of render-server work the CI doctrine keeps out of test targets.
enum MapAnnotationPop {
    /// Deliberately longer than the bars' `mapBarMorph`: a pin travels a
    /// scale AND an opacity, over a much shorter distance, and a snappier
    /// curve reads as a flicker at pin size.
    static let duration: TimeInterval = 0.32
    /// Just under-damped — a trace of settle so a landing pin feels placed
    /// rather than switched on. (The bars' opacity springs use zero bounce;
    /// this one is carrying a transform, where a small overshoot is the
    /// point.)
    static let dampingRatio: CGFloat = 0.75
    /// Where a pin starts (and returns to): half size, so it grows into
    /// place without ever reading as a different marker.
    static let collapsedScale: CGFloat = 0.5

    /// Per-pin stagger and its ceiling. Unbounded, a hundred-pin page would
    /// take two seconds to finish arriving and the last pins would land after
    /// the viewer had already started panning; the cap turns the tail into a
    /// dense ripple instead of a queue.
    static let staggerStep: TimeInterval = 0.02
    static let staggerCap: TimeInterval = 0.25

    static var collapsedTransform: CGAffineTransform {
        CGAffineTransform(scaleX: collapsedScale, y: collapsedScale)
    }

    /// The delay for the pin at `index` in its batch.
    static func stagger(for index: Int) -> TimeInterval {
        min(Double(max(0, index)) * staggerStep, staggerCap)
    }

    static func makeAnimator() -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UISpringTimingParameters(dampingRatio: dampingRatio)
        )
    }
}

/// Runs the pop choreography and owns its in-flight animators.
///
/// `UIViewPropertyAnimator` HERE and nowhere else in this feature. The filter
/// bars deliberately stay on the block-based `mapBarFade`/`mapBarMorph`
/// system, because their animations are discrete and their collection views
/// need the ambient animation context that `UIView.animate` establishes and an
/// animator does not. Pins are the opposite case: a filter change can retire a
/// marker that is still popping in, or bring one back that is halfway out, and
/// `stopAnimation(_:)` is what lets a running curve be abandoned at its
/// current pose instead of snapping to an end state nobody asked for.
///
/// The hard part is not the curve, it is the window a pop-OUT opens. Between
/// "start fading" and "actually remove", the marker is still on the map while
/// already gone from the caller's `annotations` index — so a re-add for the
/// same post would mint a SECOND marker on top of the first. `reclaim(_:)`
/// closes that window: a departing pin is handed back rather than duplicated.
@MainActor
final class MapAnnotationPopChoreographer {
    private unowned let mapView: MKMapView

    /// In-flight arrivals, keyed by the view they drive. Views are recycled,
    /// so the key is identity — a reused view starting a new pop-in is what
    /// retires the stale animator still pointing at it.
    private var arrivals: [ObjectIdentifier: UIViewPropertyAnimator] = [:]

    /// In-flight departures, keyed by the caller's stable identity (encoding
    /// single-vs-cluster so a pin and the cluster it collapses into never share
    /// a slot). These markers are STILL ON THE MAP and no longer in the caller's
    /// index; this is the only record of them.
    private var departures: [String: Departure] = [:]

    private struct Departure {
        let annotation: any MKAnnotation
        let animator: UIViewPropertyAnimator
    }

    init(mapView: MKMapView) {
        self.mapView = mapView
    }

    // MARK: - Arrival

    /// Pops a freshly added batch of views in, staggered in the order MapKit
    /// handed them over.
    func popIn(_ views: [MKAnnotationView]) {
        for (index, view) in views.enumerated() {
            let key = ObjectIdentifier(view)
            // This view may be a recycled one whose previous pop is still
            // running; that animator now points at the wrong pin.
            arrivals.removeValue(forKey: key)?.stopAnimation(true)

            view.alpha = 0
            view.transform = MapAnnotationPop.collapsedTransform

            let animator = MapAnnotationPop.makeAnimator()
            animator.addAnimations {
                view.alpha = 1
                view.transform = .identity
            }
            animator.addCompletion { [weak self] _ in
                self?.arrivals.removeValue(forKey: key)
            }
            arrivals[key] = animator
            animator.startAnimation(afterDelay: MapAnnotationPop.stagger(for: index))
        }
    }

    // MARK: - Departure

    /// Scale-and-fades a batch OUT — mirroring `popIn` — and retires each from
    /// the map in its animator's completion, so the removal is the LAST thing
    /// that happens and the marker never blinks out from under the animation.
    /// Each item is `(identity, annotation)`; the identity is how `reclaim`
    /// finds a marker that comes back mid-fade.
    ///
    /// A marker with no view (scrolled out of the rendered region, or never
    /// realized) has nothing to animate and is removed at once.
    func popOut(_ items: [(id: String, annotation: any MKAnnotation)]) {
        guard !items.isEmpty else { return }
        var immediate: [any MKAnnotation] = []

        for (index, item) in items.enumerated() {
            // A prior departure for this identity (a rapid leave→return→leave)
            // is superseded — stop it without finishing so its completion can't
            // remove the marker we are about to re-animate.
            departures.removeValue(forKey: item.id)?.animator.stopAnimation(true)

            guard let view = mapView.view(for: item.annotation) else {
                immediate.append(item.annotation)
                continue
            }
            // An arrival still in flight would keep animating toward alpha 1
            // underneath the departure.
            arrivals.removeValue(forKey: ObjectIdentifier(view))?.stopAnimation(true)

            let animator = MapAnnotationPop.makeAnimator()
            animator.addAnimations {
                view.alpha = 0
                view.transform = MapAnnotationPop.collapsedTransform
            }
            animator.addCompletion { [weak self] position in
                guard let self else { return }
                departures.removeValue(forKey: item.id)
                // `.end` only: a reclaimed marker stops at `.current` and must
                // stay on the map. (Reclaim stops without finishing, so this
                // block does not run for it at all — the check is the belt to
                // that braces.)
                guard position == .end else { return }
                mapView.removeAnnotation(item.annotation)
            }
            departures[item.id] = Departure(annotation: item.annotation, animator: animator)
            animator.startAnimation(afterDelay: MapAnnotationPop.stagger(for: index))
        }

        if !immediate.isEmpty { mapView.removeAnnotations(immediate) }
    }

    /// Takes a mid-departure marker back: stops the fade where it is, springs
    /// it home, and returns it so the caller re-indexes it instead of adding a
    /// duplicate. Nil when nothing with this identity is leaving.
    func reclaim(_ id: String) -> (any MKAnnotation)? {
        guard let departure = departures.removeValue(forKey: id) else { return nil }
        // Without finishing: the completion (which would remove it) never runs.
        departure.animator.stopAnimation(true)
        if let view = mapView.view(for: departure.annotation) {
            let animator = MapAnnotationPop.makeAnimator()
            animator.addAnimations {
                view.alpha = 1
                view.transform = .identity
            }
            let key = ObjectIdentifier(view)
            animator.addCompletion { [weak self] _ in self?.arrivals.removeValue(forKey: key) }
            arrivals[key] = animator
            animator.startAnimation()
        }
        return departure.annotation
    }

    /// Everything still departing, so a caller tearing the map down can retire
    /// the markers rather than leave them mid-fade with no animator to finish
    /// them. Also the answer to "did anything orphan?" — after this, both
    /// ledgers are empty by construction.
    @discardableResult
    func finishAllDepartures() -> [any MKAnnotation] {
        let pending = departures.values.map(\.annotation)
        for departure in departures.values { departure.animator.stopAnimation(true) }
        departures.removeAll()
        for animator in arrivals.values { animator.stopAnimation(true) }
        arrivals.removeAll()
        if !pending.isEmpty { mapView.removeAnnotations(pending) }
        return pending
    }
}
