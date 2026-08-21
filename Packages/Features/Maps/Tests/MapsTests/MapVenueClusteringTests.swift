import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Maps

/// CO-LOCATED POSTS, END TO END — mock service → wire bytes → repository →
/// clustering → what a tap would open.
///
/// The map's clustering is kind-blind (`MapUnifiedGroupingTests` proves that on
/// synthetic input); these run the SAME machinery on the corpus the simulator
/// actually shows, at the zoom the app actually opens at, because the property
/// that matters to a viewer is not "the algorithm ignores kind" but "the marker
/// I tapped opened everything that was under it".
///
/// They exist because the fixture used to have a property no real corpus has:
/// every post at its own coordinate. Measured before the venues landed — 10
/// pins, 10 markers, ZERO clusters at the opening region, and no two posts
/// sharing a coordinate anywhere. Nothing was excluding text posts; there was
/// simply nothing co-located to cluster WITH, at any zoom the app opens at.
@MainActor
struct MapVenueClusteringTests {
    /// The map's own opening region (`MapsViewController.defaultRegion`).
    private static let openingSpan = 0.09
    /// `mapView.bounds.width / visibleMapRect.size.width` for that region on a
    /// 402pt-wide screen — the projection the engine grids in.
    private static let openingZoomScale = 402.0 / (openingSpan / 360 * 268_435_456)
    /// The production collision cell: the marker footprint plus its margin.
    /// `PinCardView.Face.media.side` rather than `MapAnnotationView.side` —
    /// the same number, reachable off the main actor.
    private static let cellPoints = Double(PinCardView.Face.media.side + 8)

    private func markersAtOpeningZoom() async throws -> (pins: [MapPin], items: [MapClusterEngine.Item]) {
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
        let pins = try await repository.queryTile(.make(
            centerLat: 48.8566, centerLng: 2.3522,
            latitudeSpan: Self.openingSpan, longitudeSpan: Self.openingSpan
        )).pins
        return (pins, MapClusterEngine.cluster(
            pins, zoomScale: Self.openingZoomScale, cellPoints: Self.cellPoints
        ))
    }

    private func kinds(of item: MapClusterEngine.Item, among pins: [MapPin]) -> [MapPin.Kind] {
        let members = Set(item.memberIDs)
        return pins.filter { members.contains($0.postID) }.map(\.kind)
    }

    /// The precondition everything else rests on: the corpus contains addresses
    /// where several posts were published from one exact point.
    @Test func theFixtureCoLocatesPosts() async throws {
        let (pins, _) = try await markersAtOpeningZoom()
        var byCoordinate: [String: [MapPin]] = [:]
        for pin in pins {
            byCoordinate[String(format: "%.6f,%.6f", pin.latitude, pin.longitude), default: []].append(pin)
        }
        let shared = byCoordinate.values.filter { $0.count > 1 }
        #expect(shared.count >= 3, "no venue: every post sits at its own coordinate again")
        // And one of them is text AND media at the same address.
        #expect(shared.contains { group in
            group.contains(where: \.isText) && group.contains { !$0.isText }
        }, "no address mixes kinds, so nothing proves the grouping ignores them")
    }

    /// Clusters exist at the zoom the map OPENS at, not only when zoomed out.
    @Test func markersStandForSeveralPostsAtTheOpeningZoom() async throws {
        let (_, items) = try await markersAtOpeningZoom()
        let clusters = items.filter(\.isCluster)
        #expect(!clusters.isEmpty, "every marker was a lone pin")
    }

    /// Text and media at one address land in ONE cluster object — the grouping
    /// never separates them — and a tap opens the whole thing.
    @Test func aVenueClustersTextAndMediaIntoOneMarker() async throws {
        let (pins, items) = try await markersAtOpeningZoom()
        let mixed = items.filter { item in
            let memberKinds = kinds(of: item, among: pins)
            return memberKinds.contains(.text) && memberKinds.contains { $0 != .text }
        }
        #expect(!mixed.isEmpty, "text and media at one address were split into separate markers")
        let cluster = try #require(mixed.first)
        #expect(MapsViewController.postIDs(of: MapComputedCluster(cluster)).count == cluster.memberIDs.count)
    }

    /// THE CASE THE WHOLE THING IS ABOUT: a marker wearing the text SYMBOL that
    /// stands for a MIXED group — tapping it opens every post at that address,
    /// photographs included, through the plain push its face calls for.
    ///
    /// Unreachable under the old media-preferring rule by construction: one
    /// photo anywhere in the group took the face, so a symbol could only ever
    /// mean "all text here" and a text tap could only ever open a text feed.
    @Test func aTextFacedMixedClusterOpensBothKinds() async throws {
        let (pins, items) = try await markersAtOpeningZoom()
        // Searched, never indexed: the engine builds its markers from a
        // Dictionary's values, so their ORDER is unspecified and varies with
        // Swift's per-process hash seed. Taking `.first` here passed for two
        // runs and then picked the all-text venue instead — a test that fails
        // on a Tuesday for no reason anyone can see.
        let cluster = try #require(
            items.first { item in
                item.representative.isText && item.isCluster
                    && kinds(of: item, among: pins).contains { $0 != .text }
            },
            "no text-faced marker carries media, so a text tap can only open text"
        )

        // Everything under it travels, in the tapped order, with nothing lost.
        let opened = MapsViewController.postIDs(of: MapComputedCluster(cluster))
        #expect(opened.count > 1)
        #expect(opened == cluster.memberIDs)
        #expect(Set(opened).count == opened.count, "a member was duplicated")
        // You land on the post you tapped...
        #expect(opened.first == cluster.representative.postID)
        // ...and it opens as a window, not a flight, per that post's face.
        #expect(MapMarkerPresentation(face: .text) == .reveal)

        // The payload is genuinely mixed: the symbol face is not a promise
        // about the group's contents, only about its first post.
        let openedKinds = kinds(of: cluster, among: pins)
        #expect(openedKinds.contains(.text))
        #expect(openedKinds.contains { $0 != .text },
                "a text-faced cluster carrying no media — the mixed case is untested")
    }

    /// The control: a lone pin still opens exactly itself, whatever its kind.
    /// Without this, "always open the whole viewport" would pass everything above.
    @Test func aLonePinStillOpensOnlyItself() async throws {
        let (_, items) = try await markersAtOpeningZoom()
        let singles = items.filter { !$0.isCluster }
        #expect(!singles.isEmpty)
        for single in singles {
            #expect(MapsViewController.postIDs(of: MapAnnotation(pin: single.representative))
                == [single.representative.postID])
        }
    }
}
