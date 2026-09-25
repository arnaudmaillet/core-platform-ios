import MapKit
import Testing
import UIKit
@testable import Maps

/// A hold's deadline lets in only the hold it was armed for.
///
/// ⚠️ **It used to let in whichever hold the VIEW was under.** MapKit recycles
/// annotation views: one released and held again for another annotation, inside
/// the first hold's deadline, was popped in by that old deadline before its own
/// picture arrived.
@MainActor
struct MapAnnotationHoldTests {
    @Test func aRecycledViewIsNotReleasedByTheDeadlineOfItsPreviousHold() async throws {
        // Held for the whole test: the choreographer keeps its map `unowned`.
        let mapView = MKMapView()
        let pop = MapAnnotationPopChoreographer(mapView: mapView)
        defer { withExtendedLifetime(mapView) {} }
        let view = MKAnnotationView(annotation: nil, reuseIdentifier: nil)

        pop.hold([view], deadline: 0.2)
        pop.release(view)
        pop.hold([view], deadline: 5)
        #expect(pop.isHolding(view), "guard: held again for its new annotation")

        try await Task.sleep(for: .milliseconds(450))

        #expect(pop.isHolding(view), "the previous hold's deadline let the recycled view in")
    }

    @Test func aHoldIsStillReleasedByItsOwnDeadline() async throws {
        // Held for the whole test: the choreographer keeps its map `unowned`.
        let mapView = MKMapView()
        let pop = MapAnnotationPopChoreographer(mapView: mapView)
        defer { withExtendedLifetime(mapView) {} }
        let view = MKAnnotationView(annotation: nil, reuseIdentifier: nil)

        pop.hold([view], deadline: 0.2)
        try await Task.sleep(for: .milliseconds(450))

        #expect(!pop.isHolding(view), "a picture that never came must not leave a hole")
    }
}
