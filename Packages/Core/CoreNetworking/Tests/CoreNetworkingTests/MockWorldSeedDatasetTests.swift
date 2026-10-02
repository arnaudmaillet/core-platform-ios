import CoreNetworkingMocks
import Foundation
import Testing

/// The world seed joins the corpus without moving it: appended at the tail,
/// dated older than everything, authored by authors who already have
/// galleries, carrying its own like counts and coordinates.
struct MockWorldSeedDatasetTests {
    private let plain = MockSocialDataset()
    private let world = MockSocialDataset(seedsWorld: true)

    private var worldPosts: [MockSocialDataset.PostRecord] {
        world.posts.filter { $0.postID.hasPrefix(MockWorldSeed.postIDPrefix) }
    }

    /// The corpus's head is untouched — the counter store's like formula and
    /// the venue walk read array positions, so an insertion would move them.
    @Test func theWorldIsAppendedAndTheCorpusDoesNotMove() {
        #expect(plain.posts.allSatisfy { !$0.postID.hasPrefix(MockWorldSeed.postIDPrefix) },
                "off by default: tests keep their calibrated corpus")
        #expect(world.posts.prefix(plain.posts.count).map(\.postID) == plain.posts.map(\.postID))
        #expect(worldPosts.map(\.postID) == MockWorldSeed.placements.map(\.postID))
        #expect(world.posts.suffix(worldPosts.count).map(\.postID) == worldPosts.map(\.postID))

        let plainCounts = MockCounterStore(dataset: plain)
        let worldCounts = MockCounterStore(dataset: world)
        #expect(plain.posts.allSatisfy { worldCounts.likeCount(for: $0.postID) == plainCounts.likeCount(for: $0.postID) })
    }

    /// The timeline is served in ARRAY order, so the world must also be the
    /// oldest — newest-first holds end to end.
    @Test func theWorldIsTheTimelinesOldestTail() {
        let stamps = world.posts.map(\.publishedAtMS)
        let oldestCorpus = plain.posts.map(\.publishedAtMS).min() ?? 0
        #expect(worldPosts.allSatisfy { $0.publishedAtMS < oldestCorpus })
        let tail = Array(stamps.suffix(worldPosts.count))
        #expect(tail == tail.sorted(by: >), "newest first within the world too")
    }

    /// Existing authors only (their profiles and galleries already exist),
    /// every kind present, every media post a bundled asset.
    @Test func worldPostsAreOrdinaryPosts() {
        let roster = Set(world.authors.prefix(8).map(\.profileID))
        #expect(worldPosts.allSatisfy { roster.contains($0.authorProfileID) })
        #expect(worldPosts.contains { $0.media == nil })
        #expect(worldPosts.contains { $0.media.map { MockMediaFixtures.isVideoURL($0.url) } == true })
        #expect(worldPosts.contains { $0.media.map { !MockMediaFixtures.isVideoURL($0.url) } == true })
        #expect(worldPosts.compactMap(\.media).allSatisfy { $0.url.hasPrefix("mock://") })
        #expect(worldPosts.allSatisfy { $0.location != nil && $0.seededLikes != nil })
    }

    /// Each featured city's trending post leads it clearly — no tie at the
    /// top — and the geo mock puts every world post where the seed says.
    @Test func everyCityHasOneTrendingPostAndItsPlace() {
        for city in MockWorldSeed.featuredCountries.flatMap(\.cities) {
            let likes = city.posts.map(\.likes).sorted(by: >)
            #expect(likes.count >= 2 && likes[0] > likes[1], "\(city.name) has no clear trending post")
        }
        let placed = Dictionary(
            uniqueKeysWithValues: MockGeoDiscoveryService(dataset: world).placements().map { ($0.postID, $0) }
        )
        for placement in MockWorldSeed.placements {
            #expect(placed[placement.postID]?.latitude == placement.latitude)
            #expect(placed[placement.postID]?.longitude == placement.longitude)
        }
    }

    /// Some text posts wear an animated icon on the map (the emote/GIF
    /// face), others their author — exactly as the seed says.
    @Test func iconFacesAreTheSeedsChoice() {
        let icons = world.animatedIconIDsByPostID(catalogue: ["a", "b", "c"])
        for placement in MockWorldSeed.placements {
            if case .text(let iconFace) = placement.post.kind {
                #expect((icons[placement.postID] != nil) == iconFace, "\(placement.postID)")
            } else {
                #expect(icons[placement.postID] == nil)
            }
        }
    }

    // MARK: - A hundred countries

    /// The twelve featured countries exactly as #348 seeded them — same
    /// order, same post counts, same ids, same unlocks — whatever was added
    /// after them.
    @Test func theFeaturedSeedIsUnchanged() {
        let featured = MockWorldSeed.featuredCountries
        #expect(featured.map(\.code) == ["ES", "IT", "GB", "DE", "US", "JP", "BR", "MA", "AU", "CA", "MX", "KR"])
        #expect(featured.map { $0.cities.flatMap(\.posts).count } == [7, 6, 4, 3, 7, 6, 3, 3, 3, 3, 3, 3])
        #expect(Set(featured.filter(\.unlockedByDefault).map(\.code))
                == ["ES", "IT", "GB", "DE", "US", "JP", "BR", "MA", "AU", "CA"])
        let featuredCodes = Set(featured.map(\.code))
        let featuredIDs = MockWorldSeed.placements.filter { featuredCodes.contains($0.countryCode) }.map(\.postID)
        #expect(featuredIDs == (0..<49).map { String(format: "post-world-%02d", $0) })
    }

    /// Over a hundred countries carry posts, each code once; every addition
    /// carries exactly ONE post, in one city, and the dataset holds exactly
    /// the seeded posts per country.
    @Test func overAHundredCountriesHavePostsAndEachAdditionExactlyOne() {
        let codes = MockWorldSeed.countries.map(\.code)
        #expect(codes.count >= 100)
        #expect(Set(codes).count == codes.count, "a country seeded twice")
        #expect(!codes.contains("FR"), "home is the corpus's, not the seed's")
        for country in MockWorldSeed.onePostCountries {
            #expect(country.cities.count == 1 && country.cities[0].posts.count == 1, "\(country.name)")
        }
        let placeIDs = MockWorldSeed.countries.flatMap { [$0.placeID] + $0.cities.map(\.placeID) }
        #expect(Set(placeIDs).count == placeIDs.count, "two places share an id")
        #expect(MockWorldSeed.placeID("city", "Santiago de los Caballeros") == "city:santiago-de-los-caballeros")
        #expect(MockWorldSeed.placeID("city", "Bogotá") == "city:bogota")

        let countryOf = Dictionary(uniqueKeysWithValues: MockWorldSeed.placements.map { ($0.postID, $0.countryCode) })
        var perCountry: [String: Int] = [:]
        for post in worldPosts { perCountry[countryOf[post.postID] ?? "?", default: 0] += 1 }
        for country in MockWorldSeed.countries {
            #expect(perCountry[country.code] == country.cities.flatMap(\.posts).count, "\(country.name)")
        }
        #expect(perCountry["?"] == nil)
    }

    /// The additions vary their kinds like the featured posts do, and every
    /// one of their like counts is its own — so where two country markers
    /// collide, likes decide which shows, never an id tie-break.
    @Test func theAdditionsVaryTheirKindsAndNeverTieOnLikes() {
        let posts = MockWorldSeed.onePostCountries.flatMap { $0.cities.flatMap(\.posts) }
        #expect(posts.contains { $0.kind == .video })
        #expect(posts.contains { $0.kind == .photo })
        #expect(posts.contains { $0.kind == .text(iconFace: true) })
        #expect(posts.contains { $0.kind == .text(iconFace: false) })
        let likes = posts.map(\.likes)
        #expect(Set(likes).count == likes.count)
        let featuredLikes = Set(MockWorldSeed.featuredCountries.flatMap { $0.cities.flatMap(\.posts) }.map(\.likes))
        #expect(featuredLikes.isDisjoint(with: likes))
        #expect(Set(posts.map(\.author)) == Set(0..<8), "authors prof-0…7, all of them")
    }

    /// A few additions are owned from the first launch, most stay locked;
    /// the featured unlocks are untouched, so the seed only GROWS
    /// (`CountryUnlockStore.seedUnlocks` grants an existing install the new
    /// codes only, once).
    @Test func mostAdditionsStayLockedAndTheUnlocksOnlyGrow() {
        let added = MockWorldSeed.onePostCountries
        let unlocked = Set(added.filter(\.unlockedByDefault).map(\.code))
        #expect(unlocked.count == 18)
        #expect(added.count - unlocked.count > 3 * unlocked.count, "most additions are locked")
        let featuredUnlocks: Set<String> = ["ES", "IT", "GB", "DE", "US", "JP", "BR", "MA", "AU", "CA"]
        #expect(MockWorldSeed.unlockedCountryCodes == featuredUnlocks.union(unlocked))
        #expect(MockWorldSeed.lockedCountryCodes.isSuperset(of: ["MX", "KR"]))
    }
}
