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
    /// no such dependency: `delaysTouchesBegan` stays false and nothing is
    /// required to fail, so it fires on touch-up with no perceptible gap. (The
    /// trade — a double-tap that lands on a marker opens it rather than zooming
    /// — is the right call for a tappable card, and matches how map cards
    /// behave elsewhere.)
    func installInstantTap(target: Any, action: Selector) {
        let tap = UITapGestureRecognizer(target: target, action: action)
        tap.delaysTouchesBegan = false
        addGestureRecognizer(tap)
    }
}
