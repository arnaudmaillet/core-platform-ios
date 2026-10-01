import Foundation

/// The mock world beyond France: posts published in other countries, city by
/// city, and which of those countries the mock account owns.
///
/// The European seed (`MockGeoDiscoveryService.hierarchyAnchors`) re-anchors
/// a third of the corpus across a handful of European cities, but it cannot
/// make a WORLD: there are only so many corpus posts to move, and every one
/// moved leaves Paris thinner. These are posts of their own — appended at the
/// TAIL of `MockSocialDataset.posts` (never the head: like counts and the
/// venue walk read array positions, see `mock-bff-coverage-gaps`), each
/// carrying its own coordinate and its own like count, so every city has a
/// clear most-trending post and every country a clear face.
///
/// Three groups, and the split is the point:
/// - **unlocked by default** — the countries the mock account owns "as if it
///   had bought them" (`unlockedCountryCodes`), seeded into the account's
///   `CountryUnlockStore` ONCE by the shell;
/// - **locked WITH posts** — Mexico and South Korea, so the locked-country
///   design has a country whose standing comes from real posts to sell;
/// - everything else stays locked with no posts, as before.
///
/// Media reuses the corpus's bundled clips and photographs (`syntheticVideo`,
/// `photo` slots) — nothing new is bundled.
///
/// ⚠️ MOCK PARITY: every city's `placeID` and center must match a city circle
/// in the Maps feature's `MapMockPlaces` (and its country a country place),
/// and every post must stand inside its country's border in `CountryAtlas`.
/// `MockWorldSeedParityTests` (Maps) pins both, post by post.
public enum MockWorldSeed {
    public enum Kind: Sendable, Equatable {
        case video
        case photo
        /// Text-only. `iconFace` gives its map marker a baked animated icon
        /// (the emote/GIF face) instead of its author's avatar.
        case text(iconFace: Bool)
    }

    public struct Post: Sendable {
        public let kind: Kind
        public let caption: String
        /// Seeded like count — the city's trending post is the largest.
        public let likes: Int64
        /// Index into the dataset's authors (`prof-N`).
        public let author: Int
    }

    public struct City: Sendable {
        /// The map place this city's posts roll up into ("city:new-york").
        public let placeID: String
        public let name: String
        public let latitude: Double
        public let longitude: Double
        public let posts: [Post]
    }

    public struct Country: Sendable {
        /// ISO 3166-1 alpha-2, as `CountryAtlas` keys it.
        public let code: String
        /// The map place a country marker stands for ("country:us").
        public let placeID: String
        public let name: String
        /// Whether the mock account owns it from the first launch.
        public let unlockedByDefault: Bool
        public let cities: [City]
    }

    /// The id namespace of the world's posts (`post-world-00`…). Kept out of
    /// the geo mock's venue walk — they stand where they were published.
    public static let postIDPrefix = "post-world-"

    // MARK: - The countries

    public static let countries: [Country] = [
        Country(code: "ES", placeID: "country:spain", name: "Spain", unlockedByDefault: true, cities: [
            City(placeID: "city:barcelona", name: "Barcelona", latitude: 41.3874, longitude: 2.1686, posts: [
                Post(kind: .video, caption: "Sunset from the bunkers, the whole city turning gold. 🌇", likes: 2_350, author: 0),
                Post(kind: .photo, caption: "Mercat de la Boqueria before the crowds 🍓🍊", likes: 640, author: 4),
                Post(kind: .text(iconFace: true), caption: "Gaudí really said: no straight lines, ever. :lol:", likes: 310, author: 2),
                Post(kind: .photo, caption: "Barceloneta, 7am, one swimmer and a dog.", likes: 120, author: 5)
            ]),
            City(placeID: "city:madrid", name: "Madrid", latitude: 40.4200, longitude: -3.7000, posts: [
                Post(kind: .photo, caption: "Retiro on a Sunday, rowing boats everywhere 🚣", likes: 1_480, author: 3),
                Post(kind: .text(iconFace: false), caption: "Dinner at 11pm is not late here, it is early.", likes: 420, author: 4),
                Post(kind: .video, caption: "Gran Vía lights from the rooftop.", likes: 260, author: 7)
            ])
        ]),
        Country(code: "IT", placeID: "country:italy", name: "Italy", unlockedByDefault: true, cities: [
            City(placeID: "city:rome", name: "Rome", latitude: 41.8933, longitude: 12.4829, posts: [
                Post(kind: .photo, caption: "Pantheon in the rain, the oculus pouring light. ☔️", likes: 2_120, author: 1),
                Post(kind: .video, caption: "Scooters, cobblestones, espresso. Repeat.", likes: 530, author: 6),
                Post(kind: .text(iconFace: true), caption: "Third gelato of the day and zero regrets 🍨🍨🍨", likes: 380, author: 0)
            ]),
            City(placeID: "city:milan", name: "Milan", latitude: 45.4642, longitude: 9.1900, posts: [
                Post(kind: .video, caption: "Duomo rooftop at golden hour ✨", likes: 990, author: 5),
                Post(kind: .photo, caption: "Navigli canals after aperitivo.", likes: 270, author: 2),
                Post(kind: .text(iconFace: false), caption: "Design week: every courtyard is a gallery.", likes: 150, author: 3)
            ])
        ]),
        Country(code: "GB", placeID: "country:uk", name: "United Kingdom", unlockedByDefault: true, cities: [
            City(placeID: "city:london", name: "London", latitude: 51.5074, longitude: -0.1278, posts: [
                Post(kind: .video, caption: "Thames at dusk from Waterloo Bridge 🌉", likes: 2_640, author: 7),
                Post(kind: .photo, caption: "Columbia Road flower market haul 🌷", likes: 710, author: 1),
                Post(kind: .text(iconFace: true), caption: "Four seasons before lunch, as promised. :weather:", likes: 455, author: 6),
                Post(kind: .photo, caption: "Brick Lane bagel, 2am, worth it.", likes: 180, author: 3)
            ])
        ]),
        Country(code: "DE", placeID: "country:germany", name: "Germany", unlockedByDefault: true, cities: [
            City(placeID: "city:berlin", name: "Berlin", latitude: 52.5200, longitude: 13.4050, posts: [
                Post(kind: .photo, caption: "Tempelhof field, kites and endless sky 🪁", likes: 1_760, author: 2),
                Post(kind: .video, caption: "Spree boat ride past the East Side Gallery.", likes: 590, author: 0),
                Post(kind: .text(iconFace: false), caption: "Späti tour ranking coming soon. Strong opinions.", likes: 240, author: 5)
            ])
        ]),
        Country(code: "US", placeID: "country:us", name: "United States", unlockedByDefault: true, cities: [
            City(placeID: "city:new-york", name: "New York", latitude: 40.7128, longitude: -74.0060, posts: [
                Post(kind: .video, caption: "Brooklyn Bridge at sunrise, the city still asleep 🌁", likes: 3_120, author: 4),
                Post(kind: .photo, caption: "Bodega cat, appointed manager. 🐈", likes: 1_050, author: 1),
                Post(kind: .text(iconFace: true), caption: "Walked 30,000 steps and saw maybe 4 blocks. :lmao:", likes: 610, author: 7),
                Post(kind: .photo, caption: "Central Park in its orange week 🍂", likes: 330, author: 2)
            ]),
            City(placeID: "city:los-angeles", name: "Los Angeles", latitude: 34.0522, longitude: -118.2437, posts: [
                Post(kind: .photo, caption: "Griffith at golden hour, haze and all 🌄", likes: 1_890, author: 6),
                Post(kind: .video, caption: "Venice skatepark, nobody falls, somehow.", likes: 720, author: 3),
                Post(kind: .text(iconFace: false), caption: "Traffic report: yes.", likes: 205, author: 0)
            ])
        ]),
        Country(code: "JP", placeID: "country:japan", name: "Japan", unlockedByDefault: true, cities: [
            City(placeID: "city:tokyo", name: "Tokyo", latitude: 35.6762, longitude: 139.6503, posts: [
                Post(kind: .video, caption: "Shibuya crossing from above, a tide of umbrellas ☔️", likes: 2_870, author: 6),
                Post(kind: .photo, caption: "Konbini breakfast ranking, part 3 🍙", likes: 880, author: 1),
                Post(kind: .text(iconFace: true), caption: "Got lost in Shinjuku station. Found a new life there. :lol:", likes: 490, author: 5)
            ]),
            City(placeID: "city:kyoto", name: "Kyoto", latitude: 35.0116, longitude: 135.7681, posts: [
                // Kyoto's face is a TEXT post on purpose: one city in the
                // world wears an animated icon at the city band.
                Post(kind: .text(iconFace: true), caption: "Fushimi Inari at 6am: 10,000 gates and nobody else. ⛩️", likes: 1_340, author: 6),
                Post(kind: .photo, caption: "Arashiyama bamboo, wind in the canopy 🎋", likes: 760, author: 2),
                Post(kind: .video, caption: "Tea ceremony, slowest twenty minutes of my year.", likes: 310, author: 4)
            ])
        ]),
        Country(code: "BR", placeID: "country:brazil", name: "Brazil", unlockedByDefault: true, cities: [
            City(placeID: "city:rio-de-janeiro", name: "Rio de Janeiro", latitude: -22.9068, longitude: -43.1729, posts: [
                Post(kind: .video, caption: "Pão de Açúcar cable car at sunset 🚡", likes: 2_210, author: 4),
                Post(kind: .photo, caption: "Ipanema, posto 9, the whole city on one beach 🏖️", likes: 930, author: 0),
                Post(kind: .text(iconFace: true), caption: "Samba lesson #1: my feet filed a complaint. 💃", likes: 400, author: 7)
            ])
        ]),
        Country(code: "MA", placeID: "country:morocco", name: "Morocco", unlockedByDefault: true, cities: [
            City(placeID: "city:marrakech", name: "Marrakech", latitude: 31.6295, longitude: -7.9811, posts: [
                // Text-led too: Morocco's COUNTRY marker wears an icon face.
                Post(kind: .text(iconFace: true), caption: "Jemaa el-Fnaa at night: smoke, drums, a hundred stories. 🌙", likes: 1_620, author: 3),
                Post(kind: .photo, caption: "Majorelle blue, impossible to photograph badly 💙", likes: 840, author: 5),
                Post(kind: .video, caption: "Mint tea poured from a metre up.", likes: 290, author: 1)
            ])
        ]),
        Country(code: "AU", placeID: "country:australia", name: "Australia", unlockedByDefault: true, cities: [
            City(placeID: "city:sydney", name: "Sydney", latitude: -33.8688, longitude: 151.2093, posts: [
                Post(kind: .photo, caption: "Opera House from the ferry, never gets old ⛴️", likes: 2_030, author: 2),
                Post(kind: .video, caption: "Bondi to Coogee walk, waves the whole way 🌊", likes: 880, author: 7),
                Post(kind: .text(iconFace: false), caption: "A cockatoo stole my toast. Respect.", likes: 350, author: 4)
            ])
        ]),
        Country(code: "CA", placeID: "country:canada", name: "Canada", unlockedByDefault: true, cities: [
            City(placeID: "city:montreal", name: "Montreal", latitude: 45.5019, longitude: -73.5674, posts: [
                Post(kind: .video, caption: "Mount Royal lookout, first snow ❄️", likes: 1_430, author: 5),
                Post(kind: .photo, caption: "Bagel debate settled: both. 🥯", likes: 570, author: 6),
                Post(kind: .text(iconFace: true), caption: "Bonjour-hi, the official greeting. :blush:", likes: 260, author: 0)
            ])
        ]),
        // LOCKED, WITH POSTS — the locked-country design's fixtures.
        Country(code: "MX", placeID: "country:mexico", name: "Mexico", unlockedByDefault: false, cities: [
            City(placeID: "city:mexico-city", name: "Mexico City", latitude: 19.4326, longitude: -99.1332, posts: [
                Post(kind: .photo, caption: "Coyoacán market, every colour at once 🌮", likes: 1_910, author: 4),
                Post(kind: .video, caption: "Trajinera ride in Xochimilco 🎶", likes: 820, author: 1),
                Post(kind: .text(iconFace: true), caption: "Tacos al pastor count today: classified. :lol:", likes: 340, author: 3)
            ])
        ]),
        Country(code: "KR", placeID: "country:south-korea", name: "South Korea", unlockedByDefault: false, cities: [
            City(placeID: "city:seoul", name: "Seoul", latitude: 37.5665, longitude: 126.9780, posts: [
                Post(kind: .video, caption: "Han river at night, bridges lit up 🌉", likes: 2_480, author: 7),
                Post(kind: .photo, caption: "Gwangjang market, bindaetteok fresh off the griddle.", likes: 960, author: 2),
                Post(kind: .text(iconFace: false), caption: "Convenience store ramyeon by the river, peak evening.", likes: 300, author: 6)
            ])
        ])
    ]

    /// The countries the mock account owns from the first launch, as if
    /// bought — France, the home country, is unlocked by rule and not here.
    public static var unlockedCountryCodes: Set<String> {
        Set(countries.filter(\.unlockedByDefault).map(\.code))
    }

    /// Countries that have posts and stay locked.
    public static var lockedCountryCodes: Set<String> {
        Set(countries.filter { !$0.unlockedByDefault }.map(\.code))
    }

    // MARK: - Placement

    /// Where the `index`-th post of a city stands, relative to its center:
    /// a few kilometres apart, so the city opens into separate markers at
    /// the local band, and all well inside the 0.15° city circle
    /// `MapMockPlaces` tags them by (≤ 0.06°, and ≤ 0.07° from the center).
    static let offsets: [(lat: Double, lng: Double)] = [
        (0.012, -0.018), (-0.026, 0.022), (0.034, 0.031), (-0.041, -0.036), (0.048, -0.004)
    ]

    /// Every world post's id, author, coordinate and kind, in seed order — the
    /// one walk both the dataset and the tests read.
    public struct Placement: Sendable {
        public let postID: String
        public let countryCode: String
        public let cityPlaceID: String
        public let latitude: Double
        public let longitude: Double
        public let post: Post
    }

    public static var placements: [Placement] {
        var result: [Placement] = []
        for country in countries {
            for city in country.cities {
                for (index, post) in city.posts.enumerated() {
                    let offset = offsets[index % offsets.count]
                    result.append(Placement(
                        postID: String(format: "\(postIDPrefix)%02d", result.count),
                        countryCode: country.code,
                        cityPlaceID: city.placeID,
                        latitude: city.latitude + offset.lat,
                        longitude: city.longitude + offset.lng,
                        post: post
                    ))
                }
            }
        }
        return result
    }

    /// The world's post records, dated just before `olderThanMS` and a
    /// minute apart, so they sit at the timeline's tail in the same order as
    /// the array (the mock timeline is served in array order, never sorted).
    static func records(authors: [MockSocialDataset.Author], olderThanMS: Int64) -> [MockSocialDataset.PostRecord] {
        guard !authors.isEmpty else { return [] }
        let shapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080)]
        return placements.enumerated().map { index, placement in
            let shape = shapes[index % shapes.count]
            // Slots past the ones the corpus, the viewer and the arrivals
            // draw first (they wrap over the bundled catalogs), so a world
            // post rarely repeats a neighbour's picture on one screen.
            let media: (url: String, width: Int, height: Int)? = switch placement.post.kind {
            case .video:
                MockSocialDataset.syntheticVideo(
                    slot: 60 + index, fallback: "mock://video/world-\(index)", shape: shape
                )
            case .photo:
                MockSocialDataset.photo(slot: 60 + index, fallback: "world-\(index)", shape: shape)
            case .text:
                nil
            }
            var record = MockSocialDataset.PostRecord(
                postID: placement.postID,
                authorProfileID: authors[placement.post.author % authors.count].profileID,
                caption: placement.post.caption,
                media: media,
                publishedAtMS: olderThanMS - Int64(index + 1) * 60_000,
                parentID: ""
            )
            record.seededLikes = placement.post.likes
            record.location = (placement.latitude, placement.longitude)
            return record
        }
    }

    /// Whether `postID` is a world post whose map marker wears an animated
    /// icon (`Kind.text(iconFace: true)`).
    static func wearsIconFace(_ postID: String) -> Bool {
        iconFacePostIDs.contains(postID)
    }

    private static let iconFacePostIDs: Set<String> = Set(placements.compactMap { placement in
        if case .text(iconFace: true) = placement.post.kind { return placement.postID }
        return nil
    })
}
