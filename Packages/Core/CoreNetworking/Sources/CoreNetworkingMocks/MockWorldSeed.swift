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
/// Two tiers of countries:
/// - **featured** (`featuredCountries`) — twelve countries with several
///   posts across one or two cities each, so cities and countries cluster;
/// - **one post** (`onePostCountries`) — ninety-four more, ONE post each in
///   one city, so the world and continent framings carry a country marker
///   wherever the map has room for one (product ask, 2 October 2026: "at
///   least 100 countries with a post, at most one post each" — the data must
///   not explode).
///
/// And three lock states, and the split is the point:
/// - **unlocked by default** — the countries the mock account owns "as if it
///   had bought them" (`unlockedCountryCodes`), seeded into the account's
///   `CountryUnlockStore` ONCE per code by the shell — ten featured ones and
///   eighteen one-post ones, a few on every continent, so every framing
///   shows open markers beside locked ones and the open-beats-locked
///   collision rule always has something to arbitrate;
/// - **locked WITH posts** — Mexico, South Korea and most one-post
///   countries, so the locked-country design shows across the whole map,
///   each with a standing that comes from a real post;
/// - everything else stays locked with no posts, and wears the empty disc.
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

    /// Every seeded country, featured first: the placement walk numbers
    /// posts in this order, so the featured posts keep their ids
    /// (`post-world-00`…`50`) and the one-post countries follow.
    public static let countries: [Country] = featuredCountries + onePostCountries

    /// The countries with several posts, city by city.
    public static let featuredCountries: [Country] = [
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

    /// The countries with ONE post, in one city — near the capital or the
    /// best-known city, at a point well inside the country's border in
    /// `CountryAtlas` (≥ 0.12° from any coast or frontier, so a simplified
    /// outline can't put it at sea or next door: Lisbon, Stockholm,
    /// Copenhagen and Reykjavik all fell off their coasts, hence Évora,
    /// Uppsala, Herning and Thingvellir). Every like count is distinct,
    /// from each other and from the featured posts, so wherever two
    /// country markers collide the stronger one is decided by likes, never
    /// by an id tie-break; 18 of the 94 are unlocked by default.
    public static let onePostCountries: [Country] = [
        // Europe
        solo("PT", "Portugal", unlocked: true, in: "Évora", 38.5714, -7.9135,
             Post(kind: .photo, caption: "Roman temple at dusk, storks on every chimney.", likes: 1_265, author: 1)),
        solo("NL", "Netherlands", unlocked: true, in: "Amsterdam", 52.3676, 4.9041,
             Post(kind: .video, caption: "Canal bikes at rush hour, a ballet nobody rehearsed. 🚲", likes: 1_845, author: 4)),
        solo("BE", "Belgium", in: "Brussels", 50.8503, 4.3517,
             Post(kind: .text(iconFace: false), caption: "Ranked the fries stands of the Grand-Place. Science.", likes: 415, author: 7)),
        solo("CH", "Switzerland", unlocked: true, in: "Zurich", 47.3769, 8.5417,
             Post(kind: .photo, caption: "Lake swim before work, the Alps watching. 🏔️", likes: 985, author: 2)),
        solo("AT", "Austria", in: "Vienna", 48.2082, 16.3738,
             Post(kind: .video, caption: "A string quartet in the U-Bahn, nobody blinked. 🎻", likes: 1_135, author: 5)),
        solo("PL", "Poland", in: "Warsaw", 52.2297, 21.0122,
             Post(kind: .text(iconFace: true), caption: "Pierogi count: lost track at twelve. :lol:", likes: 645, author: 0)),
        solo("CZ", "Czechia", in: "Prague", 50.0755, 14.4378,
             Post(kind: .photo, caption: "Charles Bridge at 6am, statues and fog only.", likes: 1_515, author: 3)),
        solo("HU", "Hungary", in: "Budapest", 47.4979, 19.0402,
             Post(kind: .video, caption: "Széchenyi baths steaming in the snow ♨️", likes: 875, author: 6)),
        solo("GR", "Greece", unlocked: true, in: "Larissa", 39.6390, 22.4191,
             Post(kind: .photo, caption: "Meteora monasteries on their pillars, a short drive away.", likes: 545, author: 1)),
        solo("SE", "Sweden", unlocked: true, in: "Uppsala", 59.8586, 17.6389,
             Post(kind: .text(iconFace: false), caption: "Fika is a meeting. Meetings are fika. Productive day.", likes: 235, author: 4)),
        solo("NO", "Norway", in: "Oslo", 59.9139, 10.7522,
             Post(kind: .photo, caption: "Walked on the opera house roof, straight into the fjord light.", likes: 1_095, author: 7)),
        solo("DK", "Denmark", in: "Herning", 56.1393, 8.9738,
             Post(kind: .text(iconFace: true), caption: "Wind so strong my bike went home without me. :weather:", likes: 165, author: 2)),
        solo("FI", "Finland", in: "Tampere", 61.4978, 23.7610,
             Post(kind: .video, caption: "Sauna, lake, sauna, lake. Repeat until enlightened. 🧖", likes: 705, author: 5)),
        solo("IE", "Ireland", in: "Athlone", 53.4239, -7.9407,
             Post(kind: .photo, caption: "Oldest pub in Ireland, allegedly. The pint agrees.", likes: 335, author: 0)),
        solo("IS", "Iceland", in: "Thingvellir", 64.2559, -21.1299,
             Post(kind: .video, caption: "Standing between two continental plates. Small, very small.", likes: 1_385, author: 3)),
        solo("HR", "Croatia", in: "Zagreb", 45.8150, 15.9819,
             Post(kind: .text(iconFace: false), caption: "Museum of Broken Relationships: cried twice, recommend.", likes: 185, author: 6)),
        solo("RO", "Romania", in: "Bucharest", 44.4268, 26.1025,
             Post(kind: .photo, caption: "The Palace of Parliament does not fit in any frame.", likes: 458, author: 1)),
        solo("BG", "Bulgaria", in: "Sofia", 42.6977, 23.3219,
             Post(kind: .text(iconFace: true), caption: "Banitsa for breakfast, banitsa for lunch. :blush:", likes: 275, author: 4)),
        solo("RS", "Serbia", in: "Belgrade", 44.7866, 20.4489,
             Post(kind: .video, caption: "Sunset where the Sava meets the Danube 🌅", likes: 615, author: 7)),
        solo("UA", "Ukraine", in: "Kyiv", 50.4501, 30.5234,
             Post(kind: .photo, caption: "Golden domes after the rain.", likes: 1_045, author: 2)),
        solo("EE", "Estonia", in: "Tartu", 58.3780, 26.7290,
             Post(kind: .text(iconFace: false), caption: "University town, every café is a library.", likes: 125, author: 5)),
        solo("LT", "Lithuania", in: "Vilnius", 54.6872, 25.2797,
             Post(kind: .photo, caption: "Užupis declared itself a republic. I got a passport stamp.", likes: 395, author: 0)),
        // Asia
        solo("CN", "China", in: "Beijing", 39.9042, 116.4074,
             Post(kind: .video, caption: "Hutong morning, bikes and steam from every doorway.", likes: 1_965, author: 3)),
        solo("IN", "India", unlocked: true, in: "New Delhi", 28.6139, 77.2090,
             Post(kind: .photo, caption: "Chandni Chowk spice market, every colour and smell at once 🌶️", likes: 1_795, author: 6)),
        solo("ID", "Indonesia", unlocked: true, in: "Bandung", -6.9175, 107.6191,
             Post(kind: .video, caption: "Tea terraces above the clouds 🍵", likes: 945, author: 1)),
        solo("PH", "Philippines", in: "Baguio", 16.4023, 120.5960,
             Post(kind: .photo, caption: "Strawberry farm, pine air, jacket weather in the tropics.", likes: 485, author: 4)),
        solo("VN", "Vietnam", unlocked: true, in: "Hanoi", 21.0278, 105.8342,
             Post(kind: .text(iconFace: true), caption: "Crossed the street with confidence. Traffic parted. Legend. :lmao:", likes: 1_225, author: 7)),
        solo("TH", "Thailand", unlocked: true, in: "Bangkok", 13.7563, 100.5018,
             Post(kind: .video, caption: "Long-tail boat through the khlongs at golden hour 🛶", likes: 1_665, author: 2)),
        solo("TR", "Turkey", in: "Ankara", 39.9334, 32.8597,
             Post(kind: .photo, caption: "Simit and tea on the citadel walls.", likes: 585, author: 5)),
        solo("IR", "Iran", in: "Tehran", 35.6892, 51.3890,
             Post(kind: .photo, caption: "Tochal at sunrise, the whole city below the snow line.", likes: 825, author: 0)),
        solo("SA", "Saudi Arabia", in: "Riyadh", 24.7136, 46.6753,
             Post(kind: .video, caption: "Edge of the World cliffs, wind and nothing else.", likes: 355, author: 3)),
        solo("AE", "United Arab Emirates", unlocked: true, in: "Liwa Oasis", 23.1333, 53.7833,
             Post(kind: .video, caption: "Dunes taller than buildings, sunset on every ridge 🏜️", likes: 1_165, author: 6)),
        solo("IL", "Israel", in: "Beersheba", 31.2518, 34.7913,
             Post(kind: .text(iconFace: false), caption: "Desert sunrise from the old city, coffee with cardamom.", likes: 145, author: 1)),
        solo("JO", "Jordan", in: "Amman", 31.9454, 35.9284,
             Post(kind: .photo, caption: "Citadel view, the whole city in sandstone.", likes: 735, author: 4)),
        solo("NP", "Nepal", in: "Kathmandu", 27.7172, 85.3240,
             Post(kind: .video, caption: "Prayer flags snapping over Swayambhunath 🏔️", likes: 1_105, author: 7)),
        solo("LK", "Sri Lanka", in: "Kandy", 7.2906, 80.6337,
             Post(kind: .text(iconFace: true), caption: "The train to Ella left without me. Tea instead. :blush:", likes: 505, author: 2)),
        solo("MY", "Malaysia", in: "Kuala Lumpur", 3.1390, 101.6869,
             Post(kind: .photo, caption: "Batu Caves steps, 272 of them, every one painted.", likes: 895, author: 5)),
        solo("KH", "Cambodia", in: "Phnom Penh", 11.5564, 104.9282,
             Post(kind: .text(iconFace: false), caption: "Riverside sunset, a thousand scooters, one quiet bench.", likes: 215, author: 0)),
        solo("MN", "Mongolia", in: "Ulaanbaatar", 47.8864, 106.9057,
             Post(kind: .video, caption: "Steppe horses at full gallop 🐎", likes: 445, author: 3)),
        solo("KZ", "Kazakhstan", in: "Almaty", 43.2220, 76.8512,
             Post(kind: .photo, caption: "Big Almaty Lake, turquoise like it was edited.", likes: 375, author: 6)),
        solo("UZ", "Uzbekistan", in: "Samarkand", 39.6542, 66.9597,
             Post(kind: .photo, caption: "Registan tiles at noon, blue on blue on blue.", likes: 1_315, author: 1)),
        solo("PK", "Pakistan", in: "Islamabad", 33.6844, 73.0479,
             Post(kind: .text(iconFace: false), caption: "Margalla hills hike, monkeys stole a samosa.", likes: 265, author: 4)),
        solo("BD", "Bangladesh", in: "Dhaka", 23.8103, 90.4125,
             Post(kind: .video, caption: "Rickshaw art, every one a gallery on wheels.", likes: 315, author: 7)),
        solo("TW", "Taiwan", in: "Taipei", 25.0330, 121.5654,
             Post(kind: .text(iconFace: true), caption: "Night market plan: one of everything. Status: ongoing. :lol:", likes: 1_155, author: 2)),
        solo("GE", "Georgia", in: "Tbilisi", 41.7151, 44.8271,
             Post(kind: .photo, caption: "Sulfur baths and painted balconies.", likes: 565, author: 5)),
        solo("LA", "Laos", in: "Luang Prabang", 19.8856, 102.1347,
             Post(kind: .video, caption: "Alms giving at dawn, saffron robes in a line.", likes: 655, author: 0)),
        solo("MM", "Myanmar", in: "Mandalay", 21.9588, 96.0891,
             Post(kind: .photo, caption: "U Bein bridge at sunset, a thousand teak posts.", likes: 245, author: 3)),
        solo("IQ", "Iraq", in: "Baghdad", 33.3152, 44.3661,
             Post(kind: .text(iconFace: false), caption: "Mutanabbi Street on a Friday, books everywhere.", likes: 105, author: 6)),
        solo("OM", "Oman", in: "Nizwa", 22.9333, 57.5333,
             Post(kind: .photo, caption: "Friday goat market at the fort.", likes: 425, author: 1)),
        solo("AM", "Armenia", in: "Yerevan", 40.1792, 44.4991,
             Post(kind: .text(iconFace: true), caption: "Ararat in the window, every window. :blush:", likes: 285, author: 4)),
        solo("AZ", "Azerbaijan", in: "Ganja", 40.6828, 46.3606,
             Post(kind: .text(iconFace: false), caption: "Bottle house: built from 48,000 bottles. Counted none.", likes: 95, author: 7)),
        // Africa
        solo("EG", "Egypt", unlocked: true, in: "Cairo", 30.0444, 31.2357,
             Post(kind: .video, caption: "Felucca on the Nile as the call to prayer rolls in 🌅", likes: 1_935, author: 2)),
        solo("NG", "Nigeria", in: "Abuja", 9.0765, 7.3986,
             Post(kind: .photo, caption: "Zuma Rock, bigger than the photos say.", likes: 665, author: 5)),
        solo("KE", "Kenya", unlocked: true, in: "Nairobi", -1.2864, 36.8172,
             Post(kind: .video, caption: "Giraffes against the skyline in Nairobi National Park 🦒", likes: 1_485, author: 0)),
        solo("ET", "Ethiopia", in: "Addis Ababa", 9.0300, 38.7400,
             Post(kind: .text(iconFace: true), caption: "Coffee ceremony round three. Sleep is cancelled. :lol:", likes: 535, author: 3)),
        solo("ZA", "South Africa", unlocked: true, in: "Johannesburg", -26.2041, 28.0473,
             Post(kind: .photo, caption: "Maboneng murals, a new one every corner.", likes: 1_085, author: 6)),
        solo("TZ", "Tanzania", in: "Arusha", -3.3869, 36.6830,
             Post(kind: .video, caption: "Kilimanjaro came out of the clouds for ten minutes.", likes: 1_245, author: 1)),
        solo("GH", "Ghana", in: "Kumasi", 6.6885, -1.6244,
             Post(kind: .photo, caption: "Kejetia market from above, a sea of umbrellas.", likes: 365, author: 4)),
        solo("SN", "Senegal", in: "Thiès", 14.7910, -16.9359,
             Post(kind: .text(iconFace: false), caption: "Tapestry workshop, the looms never stop.", likes: 135, author: 7)),
        solo("DZ", "Algeria", in: "Constantine", 36.3650, 6.6147,
             Post(kind: .photo, caption: "Bridges strung across the gorge, city of bridges indeed.", likes: 475, author: 2)),
        solo("TN", "Tunisia", in: "Kairouan", 35.6781, 10.0963,
             Post(kind: .text(iconFace: true), caption: "Makroudh tasting: nine shops, nine winners. :blush:", likes: 225, author: 5)),
        solo("UG", "Uganda", in: "Kampala", 0.3476, 32.5825,
             Post(kind: .video, caption: "Boda-boda ride through the evening rush.", likes: 305, author: 0)),
        solo("RW", "Rwanda", in: "Kigali", -1.9441, 30.0619,
             Post(kind: .photo, caption: "Thousand hills, all of them green.", likes: 515, author: 3)),
        solo("CI", "Ivory Coast", in: "Yamoussoukro", 6.8276, -5.2893,
             Post(kind: .video, caption: "The basilica dome against a storm sky.", likes: 405, author: 6)),
        solo("CM", "Cameroon", in: "Yaoundé", 3.8480, 11.5021,
             Post(kind: .text(iconFace: false), caption: "Ndolé recipe acquired. Family secret, do not ask.", likes: 175, author: 1)),
        solo("AO", "Angola", in: "Huambo", -12.7761, 15.7392,
             Post(kind: .photo, caption: "Highland mornings, red earth and mist.", likes: 155, author: 4)),
        solo("MG", "Madagascar", in: "Antananarivo", -18.8792, 47.5079,
             Post(kind: .video, caption: "Lemur on the guide's shoulder, posing like a pro 🐒", likes: 1_025, author: 7)),
        solo("NA", "Namibia", in: "Windhoek", -22.5609, 17.0658,
             Post(kind: .photo, caption: "Night sky outside the city, the Milky Way to the ground ✨", likes: 1_295, author: 2)),
        solo("BW", "Botswana", in: "Maun", -19.9953, 23.4181,
             Post(kind: .video, caption: "Mokoro through the Okavango, hippos keeping an eye.", likes: 1_455, author: 5)),
        solo("ZM", "Zambia", in: "Lusaka", -15.3875, 28.3228,
             Post(kind: .text(iconFace: false), caption: "Nshima lesson: technique is everything, I have none.", likes: 115, author: 0)),
        solo("ZW", "Zimbabwe", in: "Harare", -17.8252, 31.0335,
             Post(kind: .photo, caption: "Jacarandas in bloom, purple streets for a week 💜", likes: 255, author: 3)),
        solo("MZ", "Mozambique", in: "Nampula", -15.1165, 39.2666,
             Post(kind: .text(iconFace: true), caption: "Matapa for dinner, recipe in my head forever. :blush:", likes: 195, author: 6)),
        solo("ML", "Mali", in: "Bamako", 12.6392, -8.0029,
             Post(kind: .video, caption: "Kora music at a rooftop gig 🎶", likes: 345, author: 1)),
        solo("SD", "Sudan", in: "Khartoum", 15.5007, 32.5599,
             Post(kind: .photo, caption: "Where the Blue Nile meets the White, two colours side by side.", likes: 208, author: 4)),
        solo("CD", "DR Congo", in: "Kisangani", 0.5153, 25.1910,
             Post(kind: .video, caption: "Wagenia fishermen at the falls, baskets in the rapids.", likes: 295, author: 7)),
        solo("LY", "Libya", in: "Sabha", 27.0377, 14.4283,
             Post(kind: .photo, caption: "Ubari dunes and a lake in the middle of them.", likes: 85, author: 2)),
        // Americas
        solo("AR", "Argentina", unlocked: true, in: "Córdoba", -31.4201, -64.1888,
             Post(kind: .photo, caption: "Sierras road trip, asado at every stop 🔥", likes: 1_195, author: 5)),
        solo("CL", "Chile", unlocked: true, in: "Santiago", -33.4489, -70.6693,
             Post(kind: .video, caption: "Andes over the city after the rain, snow to the edge.", likes: 1_375, author: 0)),
        solo("PE", "Peru", unlocked: true, in: "Cusco", -13.5320, -71.9675,
             Post(kind: .photo, caption: "Rainbow mountain at 5,000 m, breathless twice 🌈", likes: 1_895, author: 3)),
        solo("CO", "Colombia", unlocked: true, in: "Bogotá", 4.7110, -74.0721,
             Post(kind: .text(iconFace: true), caption: "Ajiaco at altitude: hug in a bowl. :blush:", likes: 1_015, author: 6)),
        solo("VE", "Venezuela", in: "Caracas", 10.4806, -66.9036,
             Post(kind: .photo, caption: "Ávila cable car into the clouds.", likes: 525, author: 1)),
        solo("EC", "Ecuador", in: "Quito", -0.1807, -78.4678,
             Post(kind: .video, caption: "Standing on the equator line, one foot per hemisphere.", likes: 685, author: 4)),
        solo("BO", "Bolivia", in: "La Paz", -16.4897, -68.1193,
             Post(kind: .video, caption: "Teleférico over La Paz, the city poured into a bowl.", likes: 1_175, author: 7)),
        solo("PY", "Paraguay", in: "Coronel Oviedo", -25.4167, -56.4500,
             Post(kind: .text(iconFace: false), caption: "Tereré in 34 degrees, the only correct choice.", likes: 75, author: 2)),
        solo("UY", "Uruguay", in: "Tacuarembó", -31.7333, -55.9833,
             Post(kind: .photo, caption: "Gaucho festival, horses and guitars all night.", likes: 142, author: 5)),
        solo("CU", "Cuba", in: "Santa Clara", 22.4069, -79.9647,
             Post(kind: .video, caption: "Vintage cars on the square, every one a different blue.", likes: 785, author: 0)),
        solo("DO", "Dominican Republic", in: "Santiago de los Caballeros", 19.4517, -70.6970,
             Post(kind: .text(iconFace: true), caption: "Merengue lesson one: hips do not lie, mine do. :lmao:", likes: 325, author: 3)),
        solo("GT", "Guatemala", in: "Guatemala City", 14.6349, -90.5069,
             Post(kind: .photo, caption: "Volcán de Fuego puffing over the valley 🌋", likes: 595, author: 6)),
        solo("CR", "Costa Rica", in: "San José", 9.9281, -84.0907,
             Post(kind: .video, caption: "Sloth crossing, traffic waited. Pura vida 🦥", likes: 1_065, author: 1)),
        solo("HN", "Honduras", in: "Tegucigalpa", 14.0723, -87.1921,
             Post(kind: .text(iconFace: false), caption: "Baleadas at midnight, the only rule.", likes: 65, author: 4)),
        solo("NI", "Nicaragua", in: "Managua", 12.1150, -86.2362,
             Post(kind: .photo, caption: "Masaya volcano glowing after dark.", likes: 238, author: 7)),
        // Oceania
        solo("NZ", "New Zealand", unlocked: true, in: "Hamilton", -37.7870, 175.2793,
             Post(kind: .video, caption: "Hobbiton round doors, every garden perfect 🌿", likes: 1_575, author: 2)),
        solo("PG", "Papua New Guinea", in: "Mount Hagen", -5.8580, 144.2310,
             Post(kind: .photo, caption: "Highland sing-sing, feathers and face paint.", likes: 715, author: 5)),
        solo("FJ", "Fiji", in: "Nadarivatu", -17.5667, 177.9667,
             Post(kind: .text(iconFace: true), caption: "Kava ceremony: tongue numb, heart full. :blush:", likes: 385, author: 0))
    ]

    /// A country with ONE post, published in `city`. Place ids are the
    /// names' slugs (`placeID(_:_:)`), as `MapMockPlaces` derives them.
    private static func solo(
        _ code: String, _ name: String, unlocked: Bool = false,
        in city: String, _ latitude: Double, _ longitude: Double, _ post: Post
    ) -> Country {
        Country(
            code: code, placeID: placeID("country", name), name: name, unlockedByDefault: unlocked,
            cities: [City(
                placeID: placeID("city", city), name: city,
                latitude: latitude, longitude: longitude, posts: [post]
            )]
        )
    }

    /// "city:santiago-de-los-caballeros" from ("city", "Santiago de los
    /// Caballeros"): lowercased, accents folded, words joined by dashes.
    public static func placeID(_ kind: String, _ name: String) -> String {
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !($0.isLetter || $0.isNumber) }
        return kind + ":" + words.joined(separator: "-")
    }

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
