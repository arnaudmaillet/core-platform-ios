import CoreContracts
import CoreLocation
import CoreModels
import MapKit
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

    /// Ten featured countries owned as if bought, Mexico and South Korea
    /// locked WITH posts; of the one-post additions, a few owned, most
    /// locked — the locked-country design across the whole map.
    @Test func theSeedOwnsTenFeaturedCountriesAndLocksMostAdditions() {
        let featured = MockWorldSeed.featuredCountries
        #expect(Set(featured.filter(\.unlockedByDefault).map(\.code))
                == ["ES", "IT", "GB", "DE", "US", "JP", "BR", "MA", "AU", "CA"])
        #expect(Set(featured.filter { !$0.unlockedByDefault }.map(\.code)) == ["MX", "KR"])
        let added = MockWorldSeed.onePostCountries
        #expect(added.filter(\.unlockedByDefault).count == 18)
        #expect(added.filter { !$0.unlockedByDefault }.count == added.count - 18)
        #expect(!MockWorldSeed.unlockedCountryCodes.contains("FR"), "home is unlocked by rule, not by the seed")
        for country in featured {
            #expect(!country.cities.isEmpty && country.cities.allSatisfy { $0.posts.count >= 2 },
                    "\(country.name): a city of one post would never be a cluster")
        }
        for country in MockWorldSeed.countries {
            // The atlas knows every code — the shop and the border shading
            // key on it.
            #expect(CountryAtlas.shared.country(code: country.code) != nil, "\(country.code)")
        }
    }

    /// Every one-post country's post stands INSIDE its border — not offshore
    /// and claimed by reach, not next to a frontier a simplified outline
    /// could move — at least 0.12° (~13 km) from the outline.
    @Test func everyAdditionStandsClearlyInsideItsCountry() {
        let added = Set(MockWorldSeed.onePostCountries.map(\.code))
        let placements = MockWorldSeed.placements.filter { added.contains($0.countryCode) }
        #expect(placements.count == added.count)
        for placement in placements {
            let point = CLLocationCoordinate2D(latitude: placement.latitude, longitude: placement.longitude)
            #expect(CountryAtlas.shared.country(containing: point)?.code == placement.countryCode,
                    "\(placement.postID) is not inside \(placement.countryCode)")
            let margin = CountryAtlas.shared.country(code: placement.countryCode)?.distance(to: point, within: 1)
            #expect((margin ?? .infinity) >= 0.12, "\(placement.postID) is \(margin ?? 0)° from the border")
        }
    }

    /// The Maps catalog holds exactly the seed's one-post places — same
    /// codes, ids, names and centers (this target can't import the mocks).
    @Test func theCatalogMirrorsEveryAddition() {
        let catalog = Dictionary(uniqueKeysWithValues: MapMockPlaces.onePostPlaces.map { ($0.code, $0) })
        #expect(catalog.count == MockWorldSeed.onePostCountries.count)
        for country in MockWorldSeed.onePostCountries {
            let city = country.cities[0]
            let entry = catalog[country.code]
            #expect(entry?.country.id == country.placeID && entry?.country.name == country.name, "\(country.code)")
            #expect(entry?.country.kind == .country)
            #expect(entry?.city.id == city.placeID && entry?.city.name == city.name, "\(city.name)")
            #expect(entry?.city.kind == .city)
            #expect(entry?.center.lat == city.latitude && entry?.center.lng == city.longitude, "\(city.name)")
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

    /// Whether the mock account may open `pin` on a first launch: its
    /// country is home, or seeded unlocked.
    private func isOpenOnFirstLaunch(_ pin: MapPin) -> Bool {
        let owner = CountryAtlas.shared.country(
            owning: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        )
        return !MockWorldSeed.lockedCountryCodes.contains(owner?.code ?? "")
    }

    /// The map's framings at the country band, as a 402pt-wide screen sees
    /// them: the world, and the continents the product checks by eye.
    /// `degrees` is the framing's longitude span; the diagonal stays above
    /// the measured Europe-framed one, so the country band is up.
    static let framings: [(name: String, degrees: Double, diagonalKm: Double)] = [
        ("world", 360, 20_000), ("americas", 140, 14_000), ("asia", 110, 10_000),
        ("africa", 80, 9_000), ("europe", 45, 4_500)
    ]

    /// Every framing (the world one is the user's screenshot, 2026-10-01):
    /// every marker on screen is a COUNTRY's — never a neutral group fusing
    /// two of them — and no two overlap. A country whose marker would
    /// overlap a stronger one is hidden, and the stronger one is always the
    /// open one first, the more trending second.
    @Test(arguments: framings.map(\.name))
    func everyFramingShowsOnlyCountriesAndTheStrongerOneOfEachCollision(_ name: String) async throws {
        let framing = try #require(Self.framings.first { $0.name == name })
        let pins = try await worldPins(around: MockWorldSeed.countries.flatMap(\.cities))
        let isOpen = isOpenOnFirstLaunch
        let zoom = 402.0 / (268_435_456.0 * framing.degrees / 360)
        let cell = 64 / zoom
        var occlusion = MapClusterEngine.Occlusion()
        let shown = MapClusterEngine.cluster(
            pins, zoomScale: zoom, cellPoints: 64, viewportDiagonalKm: framing.diagonalKm,
            isOpen: isOpen, occlusion: &occlusion
        )
        #expect(!occlusion.hiddenItems.isEmpty, "the \(name) framing must collide somewhere")
        for item in shown {
            #expect(item.isHierarchyMarker && item.place?.kind == .country,
                    "\(item.place?.id ?? "a placeless group") is not a country marker")
        }
        // Every country is on the books, shown or hidden — once.
        let books = (shown + occlusion.hiddenItems).compactMap { $0.place?.id }
        #expect(Set(books) == Set(MockWorldSeed.countries.map(\.placeID)))
        #expect(books.count == Set(books).count)

        func point(_ item: MapClusterEngine.Item) -> MKMapPoint {
            MKMapPoint(CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude))
        }
        func open(_ item: MapClusterEngine.Item) -> Bool { isOpen(item.representative) }
        for hidden in occlusion.hiddenItems {
            let p = point(hidden)
            let blockers = shown.filter {
                let q = point($0)
                return max(abs(p.x - q.x), abs(p.y - q.y)) < cell
            }
            #expect(!blockers.isEmpty, "\(hidden.place?.id ?? "?") is hidden behind nothing")
            #expect(blockers.contains { blocker in
                open(blocker) != open(hidden)
                    ? open(blocker)
                    : blocker.representative.likeCount >= hidden.representative.likeCount
            }, "\(hidden.place?.id ?? "?") is hidden behind a weaker marker")
        }
        // Readable: no two shown markers overlap.
        for (index, a) in shown.enumerated() {
            for b in shown[(index + 1)...] {
                let (p, q) = (point(a), point(b))
                #expect(max(abs(p.x - q.x), abs(p.y - q.y)) >= cell,
                        "\(a.place?.id ?? "?") overlaps \(b.place?.id ?? "?")")
            }
        }
    }

    /// Which country shows where two collide is a function of the pins, not
    /// of the order they arrive in: the same framing over the same pins,
    /// shuffled, shows and hides the same markers wearing the same faces.
    @Test func collisionsAreDeterministic() async throws {
        let pins = try await worldPins(around: MockWorldSeed.countries.flatMap(\.cities))
        let zoom = 402.0 / 268_435_456.0
        func layout(_ pins: [MapPin]) -> (shown: [String], hidden: Set<String>) {
            var occlusion = MapClusterEngine.Occlusion()
            let shown = MapClusterEngine.cluster(
                pins, zoomScale: zoom, cellPoints: 64, viewportDiagonalKm: 20_000,
                isOpen: isOpenOnFirstLaunch, occlusion: &occlusion
            )
            return (shown.map { "\($0.place?.id ?? "?")=\($0.representative.postID.rawValue)" }.sorted(),
                    occlusion.hiddenKeys)
        }
        let reference = layout(pins)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            let other = layout(pins.shuffled(using: &generator))
            #expect(other.shown == reference.shown)
            #expect(other.hidden == reference.hidden)
        }
        // And the ranking never falls to the id tie-break between two
        // countries: no two seeded country faces hold the same likes.
        let faces = MockWorldSeed.countries.map { country in
            country.cities.flatMap(\.posts).map(\.likes).max() ?? 0
        }
        #expect(Set(faces).count == faces.count)
    }

    /// The world framing's ONE query brings every world post — the geo
    /// mock's per-response cap must not cut the dataset's tail, where the
    /// world sits — and each seeded country holds exactly its seeded posts:
    /// a one-post country exactly one post of any kind, corpus included.
    @Test func theWorldFramingReceivesEveryCountrysPosts() async throws {
        let backend = MockBackend(seedsMapHierarchy: true)
        let client = backend.makeRPCClient()
        let repository = GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client)
        )
        let result = try await repository.queryTile(.make(
            centerLat: 0, centerLng: 0, latitudeSpan: 170, longitudeSpan: 360
        ))
        let world = result.pins.filter { $0.postID.rawValue.hasPrefix(MockWorldSeed.postIDPrefix) }
        #expect(Set(world.map(\.postID.rawValue)) == Set(MockWorldSeed.placements.map(\.postID)))

        var perCountry: [String: (world: Int, all: Int)] = [:]
        for pin in result.pins {
            let point = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            guard let code = CountryAtlas.shared.country(owning: point)?.code else { continue }
            let isWorld = pin.postID.rawValue.hasPrefix(MockWorldSeed.postIDPrefix)
            perCountry[code, default: (0, 0)].world += isWorld ? 1 : 0
            perCountry[code, default: (0, 0)].all += 1
        }
        let withPosts = MockWorldSeed.countries.filter { (perCountry[$0.code]?.world ?? 0) > 0 }
        #expect(withPosts.count >= 100)
        for country in MockWorldSeed.featuredCountries {
            #expect(perCountry[country.code]?.world == country.cities.flatMap(\.posts).count, "\(country.name)")
        }
        for country in MockWorldSeed.onePostCountries {
            #expect(perCountry[country.code]?.all == 1, "\(country.name)")
        }
    }
}
