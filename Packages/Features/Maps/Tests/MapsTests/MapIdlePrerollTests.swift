import CoreModels
import MapKit
import Testing
@testable import Maps

/// The one page player the map prerolls while it rests (#654).
///
/// Asserted through the static rules: this target never instantiates an
/// `MKMapView` (see `MapAnnotationPopTests`).
@MainActor
struct MapIdlePrerollTests {
    @Test("The preroll goes to the marker nearest the centre")
    func theNearestMarkerWins() {
        let center = MKMapPoint(x: 1000, y: 1000)
        let pins: [(id: PostID, point: MKMapPoint)] = [
            (PostID("far"), MKMapPoint(x: 1600, y: 1000)),
            (PostID("near"), MKMapPoint(x: 1000, y: 1150)),
            (PostID("middle"), MKMapPoint(x: 800, y: 1300))
        ]
        #expect(MapsViewController.prerollCandidate(center: center, pins: pins) == PostID("near"))
    }

    @Test("No candidate, no preroll")
    func nothingInView() {
        #expect(MapsViewController.prerollCandidate(center: MKMapPoint(x: 0, y: 0), pins: []) == nil)
    }

    @Test("A preroll waits a beat of rest, and gives up after a while of it")
    func itsTiming() {
        #expect(MapsViewController.idlePrerollDelay > 0 && MapsViewController.idlePrerollDelay <= 1)
        #expect(MapsViewController.idlePrerollLifetime >= 10)
    }
}
