import CoreModels
import Foundation
import MapKit
import Testing
@testable import Maps

/// `MapClusterEngine` — the client-side clustering that replaces MapKit's own
/// (which degrades across pan+zoom). The contract these pin down: everything is
/// represented exactly once, and no two markers can overlap on screen.
struct MapClusterEngineTests {
    /// The production collision size (pin side + margin) and a zoom scale where
    /// one screen point is one map point, so `cellPoints` reads as map-point
    /// spacing directly.
    private static let cell = 64.0
    private static let unitScale = 1.0

    private static func pin(
        _ id: String, lat: Double, lng: Double, kind: MapPin.Kind = .photo
    ) -> MapPin {
        MapPin(
            postID: PostID(id),
            latitude: lat,
            longitude: lng,
            thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"),
            kind: kind
        )
    }

    /// Screen-space gap between two markers' centers, along whichever axis they
    /// are closest — the quantity that must clear the marker side for squares
    /// not to overlap.
    private static func axisGap(_ a: MapClusterEngine.Item, _ b: MapClusterEngine.Item, scale: Double) -> Double {
        let pa = MKMapPoint(CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude))
        let pb = MKMapPoint(CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude))
        return max(abs(pa.x - pb.x), abs(pa.y - pb.y)) * scale
    }

    @Test func everyPinIsRepresentedExactlyOnce() {
        let pins = (0..<50).map { Self.pin("p\($0)", lat: 48.85 + Double($0) * 0.001, lng: 2.35) }
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)

        let members = items.flatMap(\.memberIDs)
        #expect(Set(members) == Set(pins.map(\.postID)))
        #expect(members.count == pins.count) // no duplicates, no drops
    }

    @Test func coincidentPinsCollapseToOneCluster() {
        let pins = (0..<8).map { Self.pin("p\($0)", lat: 48.8566, lng: 2.3522) }
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)

        #expect(items.count == 1)
        #expect(items[0].isCluster)
        #expect(items[0].memberIDs.count == 8)
    }

    @Test func farApartPinsStaySingles() {
        // Three pins a whole degree apart — nowhere near colliding at any sane
        // zoom.
        let pins = [
            Self.pin("a", lat: 48.0, lng: 2.0),
            Self.pin("b", lat: 49.0, lng: 3.0),
            Self.pin("c", lat: 50.0, lng: 4.0)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)

        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isCluster })
    }

    @Test func aSingleKeepsItsExactCoordinate() {
        let lone = Self.pin("solo", lat: 48.87, lng: 2.30)
        let far = Self.pin("far", lat: 40.0, lng: 2.30)
        let items = MapClusterEngine.cluster([lone, far], zoomScale: Self.unitScale, cellPoints: Self.cell)

        let soloItem = try? #require(items.first { $0.memberIDs == [PostID("solo")] })
        #expect(soloItem?.latitude == lone.latitude)
        #expect(soloItem?.longitude == lone.longitude)
    }

    /// The core guarantee, and the one MapKit could not hold: after clustering,
    /// no two markers overlap — including the diagonal case a Euclidean merge
    /// would miss. A dense random field at a mid zoom is the stress case.
    @Test func noTwoMarkersOverlapOnAnyAxis() {
        // A deterministic pseudo-random scatter (no `Math.random` in tests).
        var pins: [MapPin] = []
        for index in 0..<200 {
            let lat = 48.8566 + Double((index * 73) % 100 - 50) * 0.002
            let lng = 2.3522 + Double((index * 137) % 100 - 50) * 0.002
            pins.append(Self.pin("p\(index)", lat: lat, lng: lng))
        }
        for scale in [4.0, 12.0, 40.0] {
            let items = MapClusterEngine.cluster(pins, zoomScale: scale, cellPoints: Self.cell)
            for i in items.indices {
                for j in items.indices where j > i {
                    // Squares of side ~56pt: any pair must clear the side on at
                    // least one axis. `cell` is 64, so a clean gap is expected.
                    #expect(
                        Self.axisGap(items[i], items[j], scale: scale) >= MapAnnotationView.side,
                        "overlap at scale \(scale) between \(items[i].memberIDs) and \(items[j].memberIDs)"
                    )
                }
            }
            // And nothing was lost in the merge.
            #expect(Set(items.flatMap(\.memberIDs)).count == pins.count)
        }
    }

    @Test func aClusterSitsAtItsMembersCentroid() {
        let pins = [
            Self.pin("a", lat: 48.80, lng: 2.30),
            Self.pin("b", lat: 48.80, lng: 2.3002),
            Self.pin("c", lat: 48.8004, lng: 2.30)
        ]
        // Tight enough to be one cluster at a low zoom.
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: 1e9)
        #expect(items.count == 1)
        let expectedLat = (48.80 + 48.80 + 48.8004) / 3
        let expectedLng = (2.30 + 2.3002 + 2.30) / 3
        #expect(abs(items[0].latitude - expectedLat) < 1e-9)
        #expect(abs(items[0].longitude - expectedLng) < 1e-9)
    }

    @Test func theRepresentativeIsTheLowestMemberID() {
        let pins = [
            Self.pin("p-9", lat: 48.8566, lng: 2.3522),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522),
            Self.pin("p-7", lat: 48.8566, lng: 2.3522)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        #expect(items.count == 1)
        // Stable key = representative id, so the marker survives small changes.
        #expect(items[0].representative.postID == PostID("p-3"))
        #expect(items[0].key == PostID("p-3"))
    }

    /// KIND DOES NOT BUY THE FACE. A mixed group is represented by its lowest
    /// id whichever kind that is — here a text post, ahead of two media
    /// members. The rule this replaced preferred media, which made the symbol
    /// face unreachable for any group containing a single photograph.
    @Test func aMixedClusterIsRepresentedByItsLowestIDWhateverKind() {
        let pins = [
            Self.pin("p-1", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-2", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522, kind: .photo),
            Self.pin("p-4", lat: 48.8566, lng: 2.3522, kind: .video)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        #expect(items.count == 1)
        #expect(items[0].representative.postID == PostID("p-1"))
        #expect(items[0].representative.isText, "a media member outranked a lower-id text one")
        // Membership is untouched — every post is still in.
        #expect(items[0].memberIDs.count == 4)
    }

    /// And symmetrically: a media post with the lowest id keeps the face, so
    /// the rule is neutral rather than reversed.
    @Test func aMixedClusterWearsMediaWhenMediaHasTheLowestID() {
        let pins = [
            Self.pin("p-1", lat: 48.8566, lng: 2.3522, kind: .photo),
            Self.pin("p-2", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522, kind: .text)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        #expect(items[0].representative.postID == PostID("p-1"))
        #expect(!items[0].representative.isText)
    }

    /// An all-text group has no media member to prefer, and still has to pick
    /// deterministically.
    @Test func anAllTextClusterFallsBackToTheLowestMemberID() {
        let pins = [
            Self.pin("p-9", lat: 48.8566, lng: 2.3522, kind: .text),
            Self.pin("p-3", lat: 48.8566, lng: 2.3522, kind: .text)
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: Self.unitScale, cellPoints: Self.cell)
        #expect(items.count == 1)
        #expect(items[0].representative.postID == PostID("p-3"))
        #expect(items[0].representative.isText)
    }

    /// A lone text pin is its own representative — the preference must not
    /// leak into the single-pin path.
    @Test func aLoneTextPinRepresentsItself() {
        let items = MapClusterEngine.cluster(
            [Self.pin("solo", lat: 48.87, lng: 2.30, kind: .text)],
            zoomScale: Self.unitScale,
            cellPoints: Self.cell
        )
        #expect(items.count == 1)
        #expect(!items[0].isCluster)
        #expect(items[0].representative.isText)
    }

    @Test func aDegenerateZoomScaleFallsBackToSingles() {
        let pins = [Self.pin("a", lat: 48.85, lng: 2.35), Self.pin("b", lat: 48.85, lng: 2.35)]
        // Before first layout the map has a zero-width rect → scale 0.
        let items = MapClusterEngine.cluster(pins, zoomScale: 0, cellPoints: Self.cell)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.isCluster })
    }
}
