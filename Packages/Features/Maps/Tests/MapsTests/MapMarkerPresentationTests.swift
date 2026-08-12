import CoreModels
import Foundation
import Testing
@testable import Maps

/// WHICH PRESENTATION A TAPPED MARKER GETS.
///
/// The rule is one line, and it is worth a test because it is the only thing
/// standing between a text post and a hero flight about nothing — a card
/// carrying a symbol the destination will never show. The view controller that
/// applies it needs a live `MKMapView` to exist (see `MapAnnotationPopTests`),
/// so the decision lives in a pure type and this asserts it there.
struct MapMarkerPresentationTests {
    @Test("A text marker is pushed, not flown — there is no cover to fly")
    func aTextMarkerIsPushedPlainly() {
        #expect(MapMarkerPresentation(face: .text) == .plainPush)
    }

    /// The control. Without it, "always push" would pass the test above and
    /// silently delete the map's hero transition.
    @Test("A media marker still flies")
    func aMediaMarkerStillFlies() {
        #expect(MapMarkerPresentation(face: .media) == .hero)
    }

    /// The face is the whole input, so the rule is exhaustive by construction:
    /// every marker on the map wears one of the two, and each maps to exactly
    /// one presentation.
    @Test("Every face resolves, and the two do not collide")
    func theRuleIsTotal() {
        #expect(MapMarkerPresentation(face: .text) != MapMarkerPresentation(face: .media))
    }

    /// A cluster's presentation follows its REPRESENTATIVE's face, and the
    /// representative is kind-neutral — so a MIXED group goes either way,
    /// decided by which post leads it, not by whether a photo is present.
    /// Asserted through the engine rather than by restating its rule, since
    /// that coupling is the thing that would break.
    @Test("A mixed cluster is pushed or flown by whichever post leads it")
    func aClusterFollowsItsRepresentative() {
        let coincident = (lat: 48.8566, lng: 2.3522)
        func pin(_ id: String, _ kind: MapPin.Kind) -> MapPin {
            MapPin(
                postID: PostID(id),
                latitude: coincident.lat,
                longitude: coincident.lng,
                thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"),
                kind: kind
            )
        }
        func presentation(of pins: [MapPin]) -> MapMarkerPresentation {
            let items = MapClusterEngine.cluster(pins, zoomScale: 1, cellPoints: 64)
            let representative = items[0].representative
            return MapMarkerPresentation(face: representative.isText ? .text : .media)
        }

        // Mixed, text first → pushed. This is the case the media preference
        // made unreachable: any photo in the group used to force a flight.
        #expect(presentation(of: [pin("p-1", .text), pin("p-2", .photo)]) == .plainPush)
        // Mixed, media first → flown.
        #expect(presentation(of: [pin("p-1", .photo), pin("p-2", .text)]) == .hero)
        #expect(presentation(of: [pin("p-1", .text), pin("p-2", .text)]) == .plainPush)
        #expect(presentation(of: [pin("p-1", .photo), pin("p-2", .video)]) == .hero)
    }
}
