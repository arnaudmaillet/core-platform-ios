import CoreContracts
import CoreModels
import CoreNetworkingMocks
import MapKit
import Testing
@testable import Maps

/// **EVERY CITY AND COUNTRY MARKER OPENS AS PARIS DOES.**
///
/// A hierarchy marker's feed carries its place page, and a vertical dismissal
/// lands on that page rather than on the map. Both presentations used to ask
/// `annotation as? MapComputedCluster` for it, so a city or country with ONE
/// post in view — a band's group of one, drawn as a lone `MapAnnotation` in its
/// place's dress — opened as a plain pin and dismissed onto the map. The mock
/// world's ninety-four one-post countries (#368) are exactly that shape at
/// every framing, which is how it was found: Kenya closed onto the map, Paris
/// onto its page.
///
/// These build the markers the way the map does — the geo mock's tile served
/// through the real repository, decorated with the mock places, laid out by
/// the engine, turned into annotations by `makeAnnotation(for:)` — and ask the
/// one question both routes ask (`hierarchyPlace(of:)`), plus where a vertical
/// dismissal then aims (`closeTarget`).
@MainActor
struct MarkerPlaceRouteTests {
    /// The measured band framings (see `MapSemanticClusterTests`).
    private let localDiagonal = 35.7
    private let cityDiagonal = 228.6
    private let countryDiagonal = 2884.3

    /// The pins the map is served around `centers`, decorated with places.
    private func pins(around centers: [(lat: Double, lng: Double)]) async throws -> [MapPin] {
        let backend = MockBackend(seedsMapHierarchy: true)
        let client = backend.makeRPCClient()
        let repository = GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client)
        )
        var pins: [String: MapPin] = [:]
        for center in centers {
            let result = try await repository.queryTile(.make(
                centerLat: center.lat, centerLng: center.lng, latitudeSpan: 0.4, longitudeSpan: 0.4
            ))
            for pin in MapMockPlaces.decorate(result.pins) { pins[pin.postID.rawValue] = pin }
        }
        return pins.values.sorted { $0.postID.rawValue < $1.postID.rawValue }
    }

    /// The markers the map draws over `centers` at a band.
    private func markers(
        around centers: [(lat: Double, lng: Double)], diagonalKm: Double
    ) async throws -> [any MKAnnotation] {
        MapClusterEngine.cluster(
            try await pins(around: centers),
            zoomScale: 1, cellPoints: 64, viewportDiagonalKm: diagonalKm
        ).map(MapsViewController.makeAnnotation(for:))
    }

    /// The marker that speaks for `placeID`, if the map draws one.
    private func marker(
        _ placeID: String, around centers: [(lat: Double, lng: Double)], diagonalKm: Double
    ) async throws -> (any MKAnnotation)? {
        try await markers(around: centers, diagonalKm: diagonalKm)
            .first { MapsViewController.hierarchyPlace(of: $0)?.id == placeID }
    }

    /// The route a hierarchy marker takes: it carries a place page, and a
    /// vertical dismissal aims at that page's card — never at the marker.
    private func expectPlaceRoute(_ annotation: (any MKAnnotation)?, _ placeID: String) {
        guard let annotation else {
            Issue.record("\(placeID) has no marker of its own")
            return
        }
        let place = MapsViewController.hierarchyPlace(of: annotation)
        #expect(place?.id == placeID)
        #expect(
            MapsViewController.closeTarget(axis: .vertical, hasLanding: place != nil) == .placeCard,
            "\(placeID): a vertical dismissal must land on the place page"
        )
    }

    // MARK: - The reference

    /// Paris and France, the original place clusters: the route every other
    /// city and country must match.
    @Test func parisAndFranceOpenOntoTheirPlacePage() async throws {
        let paris = [(lat: 48.83, lng: 2.33)]
        expectPlaceRoute(try await marker("city:paris", around: paris, diagonalKm: cityDiagonal), "city:paris")
        expectPlaceRoute(
            try await marker("country:france", around: paris, diagonalKm: countryDiagonal), "country:france"
        )
    }

    // MARK: - The mock world

    /// Every world country at the country band — the featured ones (Spain)
    /// as clusters, the one-post ones (Kenya) as lone markers — takes Paris's
    /// route.
    @Test func everyWorldCountryOpensOntoItsPlacePage() async throws {
        for country in MockWorldSeed.countries {
            let centers = country.cities.map { (lat: $0.latitude, lng: $0.longitude) }
            expectPlaceRoute(
                try await marker(country.placeID, around: centers, diagonalKm: countryDiagonal),
                country.placeID
            )
        }
    }

    /// …and every world city at the city band (Barcelona, Nairobi).
    @Test func everyWorldCityOpensOntoItsPlacePage() async throws {
        for city in MockWorldSeed.countries.flatMap(\.cities) {
            expectPlaceRoute(
                try await marker(
                    city.placeID, around: [(lat: city.latitude, lng: city.longitude)], diagonalKm: cityDiagonal
                ),
                city.placeID
            )
        }
    }

    /// The case that was broken, named: a one-post country is a LONE marker —
    /// one post, no cluster — and still its country's, at both bands.
    @Test func aOnePostCountryIsAPlaceMarkerNotAPlainPin() async throws {
        let kenya = try #require(MockWorldSeed.onePostCountries.first { $0.code == "KE" })
        let nairobi = kenya.cities[0]
        let centers = [(lat: nairobi.latitude, lng: nairobi.longitude)]
        for (placeID, diagonal) in [(kenya.placeID, countryDiagonal), (nairobi.placeID, cityDiagonal)] {
            let annotation = try #require(try await marker(placeID, around: centers, diagonalKm: diagonal))
            #expect(annotation is MapAnnotation, "\(placeID): a band's group of one is drawn as a lone pin")
            #expect(MapsViewController.postIDs(of: annotation).count == 1)
            expectPlaceRoute(annotation, placeID)
        }
    }

    // MARK: - What keeps the map landing

    /// Below the bands a lone pin is ordinary local content: no place page,
    /// and both axes close onto the marker.
    @Test func aLocalPinKeepsItsMapLanding() async throws {
        let local = try await markers(around: [(lat: 48.83, lng: 2.33)], diagonalKm: localDiagonal)
        let lone = local.compactMap { $0 as? MapAnnotation }
        #expect(!lone.isEmpty, "the Paris scatter has lone pins at the local band")
        for pin in lone {
            #expect(MapsViewController.hierarchyPlace(of: pin) == nil)
            #expect(MapsViewController.closeTarget(axis: .vertical, hasLanding: false) == .marker)
        }
    }

    /// A reused lone marker follows its item: a band's group of one that
    /// dissolves into local content stops routing to a place page.
    @Test func aReusedLonePinFollowsItsBand() {
        let kenya = MapPlace(id: "country:kenya", name: "Kenya", kind: .country)
        let pin = MapPin(postID: PostID("p"), latitude: -1.28, longitude: 36.82, thumbnailURL: nil, kind: .video)
        let annotation = MapAnnotation(pin: pin, hierarchyPlace: kenya)
        #expect(MapsViewController.hierarchyPlace(of: annotation) == kenya)
        #expect(MapsViewController.dressKind(of: annotation) == .country)
        annotation.hierarchyPlace = nil
        #expect(MapsViewController.hierarchyPlace(of: annotation) == nil)
        #expect(MapsViewController.dressKind(of: annotation) == nil)
    }

    /// A locked one-post country's marker is still a teaser: the tap offers
    /// the country before any route is considered.
    @Test func aLockedOnePostCountryStillOffersItsUnlock() async throws {
        let locked = try #require(MockWorldSeed.onePostCountries.first { !$0.unlockedByDefault })
        let city = locked.cities[0]
        let annotation = try #require(try await marker(
            locked.placeID, around: [(lat: city.latitude, lng: city.longitude)], diagonalKm: countryDiagonal
        ))
        let dress = MapMarkerDress.resolve(
            kind: MapsViewController.dressKind(of: annotation), countryCode: locked.code, isLocked: true
        )
        #expect(MapsViewController.markerTap(for: dress, countryCode: locked.code) == .offer(countryCode: locked.code))
    }
}
