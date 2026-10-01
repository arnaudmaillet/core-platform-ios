import CoreContracts
import CoreLocation
import CoreModels
import CoreNetworkingMocks
import Testing
@testable import Maps

/// The mock world beyond France (`MockWorldSeed`) on the map: every post
/// stands in its own city and country — by the clustering's places AND by
/// the borders the map unlocks with — and every city and country comes out
/// of the engine as its own semantic marker, wearing its trending post.
struct MockWorldSeedTests {
    /// The measured band framings `MapSemanticClusterTests` anchors on:
    /// Île-de-France framed (city band) and Europe framed (country band).
    private let cityDiagonal = 228.6
    private let countryDiagonal = 2884.3

    private func pin(lat: Double, lng: Double) -> MapPin {
        MapPin(postID: PostID("p"), latitude: lat, longitude: lng, thumbnailURL: nil, kind: .text)
    }

    // MARK: - Who owns what

    /// Ten countries owned as if bought; Mexico and South Korea stay locked
    /// WITH posts, for the locked-country design.
    @Test func theSeedOwnsTenCountriesAndLocksTwoWithPosts() {
        #expect(MockWorldSeed.unlockedCountryCodes
                == ["ES", "IT", "GB", "DE", "US", "JP", "BR", "MA", "AU", "CA"])
        #expect(MockWorldSeed.lockedCountryCodes == ["MX", "KR"])
        #expect(!MockWorldSeed.unlockedCountryCodes.contains("FR"), "home is unlocked by rule, not by the seed")
        for country in MockWorldSeed.countries {
            #expect(!country.cities.isEmpty && country.cities.allSatisfy { $0.posts.count >= 2 },
                    "\(country.name): a city of one post would never be a cluster")
            // The atlas knows every code — the shop and the border shading
            // key on it.
            #expect(CountryAtlas.shared.country(code: country.code) != nil, "\(country.code)")
        }
    }

    // MARK: - Mock parity

    /// Every world post's coordinate carries exactly its city's ladder in
    /// `MapMockPlaces`, and lies inside its country's BORDER — which is what
    /// hides or shows it when the country is locked or unlocked.
    @Test func everyWorldPostStandsInItsCityAndCountry() {
        let countryPlace = Dictionary(uniqueKeysWithValues: MockWorldSeed.countries.map { ($0.code, $0.placeID) })
        for placement in MockWorldSeed.placements {
            let ladder = MapMockPlaces.ladder(for: pin(lat: placement.latitude, lng: placement.longitude))
            #expect(ladder.map(\.id) == [placement.cityPlaceID, countryPlace[placement.countryCode]],
                    "\(placement.postID) in \(placement.cityPlaceID)")
            let owner = CountryAtlas.shared.country(
                owning: CLLocationCoordinate2D(latitude: placement.latitude, longitude: placement.longitude)
            )
            #expect(owner?.code == placement.countryCode, "\(placement.postID) lies in \(owner?.code ?? "the sea")")
        }
    }

    /// A pin in one of the world's countries but outside its cities still
    /// rolls up into the country — by its border.
    @Test func aCountrysidePinTakesItsCountryFromTheBorder() {
        #expect(MapMockPlaces.ladder(for: pin(lat: 39.0, lng: -98.0)).map(\.id) == ["country:us"])
        #expect(MapMockPlaces.ladder(for: pin(lat: 52.0, lng: -106.0)).map(\.id) == ["country:canada"])
        #expect(MapMockPlaces.ladder(for: pin(lat: -25.0, lng: 134.0)).map(\.id) == ["country:australia"])
        #expect(MapMockPlaces.ladder(for: pin(lat: 0.0, lng: -30.0)).isEmpty, "the open sea is no country")
    }

    // MARK: - The engine

    /// The world's pins as the app sees them: served by the geo mock,
    /// likes hydrated from the counter mock, decorated with the places.
    private func worldPins(around cities: [MockWorldSeed.City]) async throws -> [MapPin] {
        let backend = MockBackend(seedsMapHierarchy: true)
        let client = backend.makeRPCClient()
        let repository = GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client)
        )
        var pins: [String: MapPin] = [:]
        for city in cities {
            let result = try await repository.queryTile(.make(
                centerLat: city.latitude, centerLng: city.longitude, latitudeSpan: 0.4, longitudeSpan: 0.4
            ))
            for pin in MapMockPlaces.decorate(result.pins) { pins[pin.postID.rawValue] = pin }
        }
        return pins.values.sorted { $0.postID.rawValue < $1.postID.rawValue }
    }

    /// The seeded posts of one city, most liked first.
    private func seeded(_ city: MockWorldSeed.City) -> [MockWorldSeed.Placement] {
        MockWorldSeed.placements
            .filter { $0.cityPlaceID == city.placeID }
            .sorted { $0.post.likes > $1.post.likes }
    }

    /// At the city band each world city is ONE marker of its own place,
    /// holding every post seeded there and wearing the city's trending post.
    @Test func everyWorldCityIsItsOwnClusterWearingItsTrendingPost() async throws {
        for country in MockWorldSeed.countries {
            for city in country.cities {
                let items = MapClusterEngine.cluster(
                    try await worldPins(around: [city]),
                    zoomScale: 1, cellPoints: 64, viewportDiagonalKm: cityDiagonal
                )
                let marker = items.first { $0.place?.id == city.placeID }
                #expect(marker?.isHierarchyMarker == true, "\(city.name) has no city marker")
                let ids = Set(marker?.memberIDs.map(\.rawValue) ?? [])
                #expect(Set(seeded(city).map(\.postID)).isSubset(of: ids), "\(city.name) lost a post")
                #expect(marker?.representative.postID.rawValue == seeded(city).first?.postID,
                        "\(city.name) wears \(marker?.representative.postID.rawValue ?? "nothing")")
            }
        }
    }

    /// At the country band each world country is ONE marker, rolling up all
    /// of its cities and wearing the most-liked post among them.
    @Test func everyWorldCountryIsItsOwnClusterWearingItsTrendingPost() async throws {
        for country in MockWorldSeed.countries {
            let items = MapClusterEngine.cluster(
                try await worldPins(around: country.cities),
                zoomScale: 1, cellPoints: 64, viewportDiagonalKm: countryDiagonal
            )
            let marker = items.first { $0.place?.id == country.placeID }
            #expect(marker?.isHierarchyMarker == true, "\(country.name) has no country marker")
            let seededIDs = country.cities.flatMap(seeded).map(\.postID)
            #expect(Set(seededIDs).isSubset(of: Set(marker?.memberIDs.map(\.rawValue) ?? [])))
            let trending = country.cities.flatMap(seeded).max { $0.post.likes < $1.post.likes }
            #expect(marker?.representative.postID.rawValue == trending?.postID,
                    "\(country.name) wears \(marker?.representative.postID.rawValue ?? "nothing")")
        }
    }
}
