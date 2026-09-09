import MapKit
import Testing
import UIKit
@testable import Maps

/// What a recycled marker must NOT carry into the next pin.
///
/// ⚠️ MapKit's reuse pool is where a transition's leftovers become a DIFFERENT
/// post's defect. Both transitions conceal the marker they fly from — the
/// hero's `setZoomSourceHidden`, the reveal's `concealMarker` — and a flight
/// that ends any way but the happy one leaves it concealed. The view goes back
/// to the pool hidden, and the next pin to dequeue it is invisible: a hole in
/// the marker field with no error, no log, and no way to tell it from a pin
/// that was never returned by the query.
///
/// ⚠️ AND THE INVARIANT IS ALREADY KEPT — by `super`, not by this code, which
/// is precisely why it is worth pinning. Adding an explicit `isHidden = false`
/// to both overrides changed nothing: with the line commented out again the
/// tests still passed, so `MKAnnotationView.prepareForReuse` resets it. The
/// line came out; the test stayed.
///
/// What it guards is the day someone stops calling `super` (both overrides
/// begin with it today), or writes `isHidden` after it. `alpha` and `transform`
/// ARE reset by this code, with a comment giving the same reasoning, so the
/// three properties are pinned together whoever happens to own each one.
@MainActor
struct MapMarkerReuseHygieneTests {

    @Test func aRecycledPinIsNotStillConcealed() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.isHidden = true          // what a flight leaves behind
        view.alpha = 0                // and what the pop leaves behind
        view.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)

        view.prepareForReuse()

        #expect(view.isHidden == false, "the next pin to dequeue this view would be invisible")
        #expect(view.alpha == 1)
        #expect(view.transform == .identity)
    }

    @Test func aRecycledClusterIsNotStillConcealed() {
        let view = MapClusterAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.isHidden = true
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)

        view.prepareForReuse()

        #expect(view.isHidden == false, "the next cluster to dequeue this view would be invisible")
        #expect(view.alpha == 1)
        #expect(view.transform == .identity)
    }
}
