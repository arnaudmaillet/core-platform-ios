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
        // Armed right after the recycled view's first hold, with the same
        // deadline: once it is let in, that first deadline has run too.
        let witness = MKAnnotationView(annotation: nil, reuseIdentifier: nil)

        pop.hold([view], deadline: 0.2)
        pop.hold([witness], deadline: 0.2)
        pop.release(view)
        // Far beyond any stall of a loaded host (#1041): a 5 s deadline ran out
        // on a starved runner, and that correct release read as the bug.
        pop.hold([view], deadline: 600)
        #expect(pop.isHolding(view), "guard: held again for its new annotation")

        // Looks, not a clock: until the old deadline has had its turn.
        for _ in 0..<6_000 where pop.isHolding(witness) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!pop.isHolding(witness), "guard: the first hold's deadline never ran")
        await Task.yield()

        #expect(pop.isHolding(view), "the previous hold's deadline let the recycled view in")
    }

    @Test func aHoldIsStillReleasedByItsOwnDeadline() async throws {
        // Held for the whole test: the choreographer keeps its map `unowned`.
        let mapView = MKMapView()
        let pop = MapAnnotationPopChoreographer(mapView: mapView)
        defer { withExtendedLifetime(mapView) {} }
        let view = MKAnnotationView(annotation: nil, reuseIdentifier: nil)

        pop.hold([view], deadline: 0.2)
        // Until the deadline has run, however late a loaded host delivers it
        // (a fixed 450 ms was this suite's own flake on CI).
        for _ in 0..<100 where pop.isHolding(view) {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(!pop.isHolding(view), "a picture that never came must not leave a hole")
    }
}
