import MapKit
import UIKit

extension MKAnnotationView {
    /// Wires a single-tap recognizer straight onto the marker so a tap opens it
    /// the instant the finger lifts.
    ///
    /// The default path — MapKit's own selection, surfaced via
    /// `mapView(_:didSelect:)` — carries a ~0.3s delay: its selection tap is set
    /// to require the map's double-tap-to-zoom recognizer to FAIL first, so
    /// every pin tap waits out the double-tap window before registering. That
    /// wait reads as a laggy, unresponsive marker. A recognizer of our own has
    /// no such dependency: `delaysTouchesBegan` stays false, so it fires on
    /// touch-up with no perceptible gap.
    ///
    /// It does, however, defer to the map's own pan/pinch (see
    /// `MapMarkerTapGestureDelegate`) so a DRAG that begins on a marker scrolls
    /// or zooms the map instead of opening the card. That dependency costs no
    /// delay — pan and pinch fail instantly on a stationary touch, so a true tap
    /// still fires the moment the finger lifts.
    func installInstantTap(target: Any, action: Selector) {
        let tap = UITapGestureRecognizer(target: target, action: action)
        tap.delaysTouchesBegan = false
        tap.delegate = MapMarkerTapGestureDelegate.shared
        addGestureRecognizer(tap)
    }
}

/// Makes a marker's tap require the map's pan/pinch to FAIL before it fires, so
/// a drag beginning on a marker moves the map rather than opening the card.
///
/// Delay-free by design, and this is the crux: a double-tap dependency would
/// stall every tap ~0.3s waiting out the second-tap window, but pan and pinch
/// resolve differently — on a stationary touch they never begin and fail at
/// touch-up, the same instant a tap fires. So a true tap stays instant; only a
/// touch that travels far enough to START a pan (or pinch) is suppressed, which
/// is exactly the drag we want to hand to the map.
///
/// Stateless, so one shared instance serves every marker. The recognizer's
/// `delegate` is weak; the static `shared` is what keeps it alive.
final class MapMarkerTapGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = MapMarkerTapGestureDelegate()

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer is UIPanGestureRecognizer
            || otherGestureRecognizer is UIPinchGestureRecognizer
        else { return false }
        // Only the MAP's scroll/zoom, identified by an `MKMapView` in the
        // recognizer's view chain — never some unrelated pan elsewhere on
        // screen (a marker's tap should not wait on those).
        var view = otherGestureRecognizer.view
        while let current = view {
            if current is MKMapView { return true }
            view = current.superview
        }
        return false
    }
}
