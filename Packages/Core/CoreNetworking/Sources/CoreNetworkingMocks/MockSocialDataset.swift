import Foundation

/// Deterministic fixture data shared by the timeline/post/profile mocks:
/// 8 authors and 120 posts with varied caption lengths and media shapes, so
/// the feed exercises real layout diversity without any randomness between
/// runs.
public struct MockSocialDataset: Sendable {
    public struct Author: Sendable {
        public let profileID: String
        public let handle: String
        public let displayName: String
        public let avatarURL: String
        /// Empty = no bio, so the profile header's collapsed-bio path is covered.
        public let bio: String
        /// Empty = no website link row.
        public let websiteURL: String
    }

    public struct PostRecord: Sendable {
        public let postID: String
        public let authorProfileID: String
        public let caption: String
        /// (url, width, height); nil for text-only posts.
        public let media: (url: String, width: Int, height: Int)?
        public let publishedAtMS: Int64
        /// Non-empty = this post is a repost of `parentID` (post.v1 lineage:
        /// a repost is the author's own post referencing its source).
        public let parentID: String
    }

    /// The profile owned by the mock login account (MockAuthService.accountID).
    public static let viewerProfileID = "prof-demo-viewer"

    public let authors: [Author]
    public let posts: [PostRecord]

    /// The viewer's social graph, shared by the social-graph and geo-discovery
    /// mocks so the map's "Friends"/"Following" filters and the following list
    /// agree on one truth. The viewer follows the first four authors; the
    /// first two follow back (mutual = the implicit "friend" state, per
    /// social_graph.v1's `RelationStatus` doc).
    public let followedProfileIDs: Set<String>
    public let mutualProfileIDs: Set<String>
    /// Who follows the viewer: the mutuals (they follow back, by definition)
    /// plus one unrequited follower (prof-4) — so a client deriving friends
    /// as following ∩ followers lands exactly on `mutualProfileIDs`, and the
    /// follower list isn't a trivial copy of either set.
    public let followerProfileIDs: Set<String>
    /// Who each author follows, keyed by profile id. The viewer's own entry is
    /// `followedProfileIDs`; the rest exist so a client deriving
    /// friend-of-friend suggestions has a real second hop to walk. Author `i`
    /// follows `i+1`, `i+3`, and `i+5` (mod 8, skipping itself): coprime
    /// strides with 8, so every author is reachable, no author follows
    /// everyone, and the followed-by counts differ enough to rank.
    public let followingByProfileID: [String: Set<String>]
    /// Posts the viewer saved as places ("Pinned Places" on the map). No wire
    /// contract exists for pinning yet — a hand-curated set, as befits a
    /// user-curated feature: four land inside the map's default Paris
    /// viewport (indices 19/48/63/91 under the geo mock's coprime scatter, so
    /// the filter visibly selects at launch), two outside it (4/24, so
    /// panning still changes the field). Mix of image and video posts.
    public let pinnedPostIDs: Set<String>
    /// postID → place-category token for every pinned post (the map's Places
    /// sub-filters: cafes/restaurants/parks/nightlife). Each category has one
    /// post inside the default viewport (19/48/63/91) so every sub-filter
    /// visibly selects at launch; the out-of-viewport pins (4/24) give cafes
    /// and restaurants a second hit when panning.
    public let pinnedPlaceCategories: [String: String]

    public init(postCount: Int = 120) {
        // (handle, name, bio, website) — bios vary from empty to multi-line so
        // the profile header exercises every identity-row combination.
        let names: [(String, String, String, String)] = [
            ("ava.moreau", "Ava Moreau", "Street photography, mostly Lyon.\nPrints on request.", "https://www.avamoreau.example/prints/"),
            ("kenji.dev", "Kenji Tanaka", "Building small tools for small teams. Coffee first, commits later.", "https://kenji.example"),
            ("lena_klein", "Lena Klein", "", ""),
            ("marcus.holt", "Marcus Holt", "Trail runner · Amateur baker", ""),
            ("sofia.reyes", "Sofía Reyes", "Cocino, viajo, repito.", "https://sofia.example/blog"),
            ("tom.okafor", "Tom Okafor", "Bass, mostly.", ""),
            ("yuki.snow", "Yuki Shirakawa", "Snow reports and mountain film.\nSee you in Hakuba.", ""),
            ("zed.aldrin", "Zed Aldrin", "", "https://zed.example"),
            ("nina.varga", "Nina Varga", "Ceramics, badly. Improving.", ""),
            ("olu.adeyemi", "Olu Adeyemi", "Backend by day, bread by night.", "https://olu.example"),
            ("priya.raman", "Priya Raman", "Long runs and longer playlists.", ""),
            ("quentin.dubois", "Quentin Dubois", "", ""),
            ("rosa.iglesias", "Rosa Iglesias", "Archivist. Ask me about microfilm.", ""),
            ("sam.whitfield", "Sam Whitfield", "Boats, mostly small ones.", "https://sam.example"),
            ("tara.nkemelu", "Tara Nkemelu", "Illustration + risograph.", ""),
            ("umar.qadir", "Umar Qadir", "Teaching maths, learning guitar.", ""),
            ("vera.lindqvist", "Vera Lindqvist", "Cold water swimmer.\nYes, year round.", ""),
            ("wes.bramley", "Wes Bramley", "", ""),
            ("xiomara.cruz", "Xiomara Cruz", "Salsa on Tuesdays.", "https://xio.example"),
            ("yannis.papas", "Yannis Papas", "Olive groves and old engines.", ""),
            ("zara.hadid", "Zara Hadid", "Drawing buildings that won't stand up.", ""),
            ("aiko.tanabe", "Aiko Tanabe", "Tea, type, and terrible puns.", ""),
            ("bruno.costa", "Bruno Costa", "", ""),
            ("chloe.baptiste", "Chloé Baptiste", "Sound design for small films.", "https://chloe.example"),
            ("dmitri.orlov", "Dmitri Orlov", "Chess clocks and film cameras.", ""),
            ("elif.demir", "Elif Demir", "Rooftop gardener.", ""),
            ("finn.oleary", "Finn O'Leary", "Sea swimming, poorly.", ""),
            ("greta.hansen", "Greta Hansen", "Maps, always maps.", "https://greta.example"),
            ("hugo.martel", "Hugo Martel", "", ""),
            ("ines.ferreira", "Inês Ferreira", "Botanical prints.", ""),
            ("jonas.weber", "Jonas Weber", "Cycling the long way round.", ""),
            ("kaia.lindgren", "Kaia Lindgren", "Ceramicist. Kiln #3.", ""),
            ("leo.marchetti", "Leo Marchetti", "Espresso and edge cases.", ""),
            ("mira.solberg", "Mira Solberg", "Field recordings.", "https://mira.example"),
            ("noah.brandt", "Noah Brandt", "", ""),
            ("orla.kavanagh", "Orla Kavanagh", "Sea glass and short stories.", ""),
            ("pavel.novak", "Pavel Novák", "Trams, timetables, trivia.", ""),
            ("quinn.abara", "Quinn Abara", "", "https://quinn.example"),
            ("rita.moreno", "Rita Moreno", "Weaving on a very old loom.", ""),
            ("stefan.ilic", "Stefan Ilić", "Mountains before breakfast.", ""),
            ("tessa.okonkwo", "Tessa Okonkwo", "Type design, slowly.", ""),
            ("ulf.johansson", "Ulf Johansson", "", ""),
            ("valeria.rossi", "Valeria Rossi", "Pasta, patiently.", "https://valeria.example"),
            ("wren.mackay", "Wren MacKay", "Birds, bothies, bad weather.", ""),
            ("xander.pike", "Xander Pike", "Restoring one motorbike forever.", ""),
            ("yara.haddad", "Yara Haddad", "Murals and mosaics.", ""),
            ("zeke.turner", "Zeke Turner", "", ""),
            ("amara.diallo", "Amara Diallo", "Documentary sound.", "https://amara.example"),
            ("bo.lindholm", "Bo Lindholm", "Woodcut prints.", ""),
            ("celia.marsh", "Celia Marsh", "Rock pools and field notes.", ""),
            ("dara.singh", "Dara Singh", "Kites, mostly homemade.", "")
        ]
        authors = names.enumerated().map { index, name in
            Author(
                profileID: "prof-\(index)",
                handle: name.0,
                displayName: name.1,
                avatarURL: "mock://avatar/\(index)?w=128&h=128",
                bio: name.2,
                websiteURL: name.3
            )
        }

        let captionBank = [
            "Golden hour at the pier.",
            "Shipped a thing today. Small, but mine.",
            "Coffee count: unreasonable. Progress: acceptable. The refactor is finally starting to pay for itself and the test suite agrees.",
            "No caption needed.",
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to. Writing it up properly this week — the short version is that the queue was never the problem, the clock was.",
            "New city, same habits.",
            "Testing in production is fine if production is your simulator.",
            "The mountains were louder than the city this time. Three days offline and the feed can wait."
        ]
        // Aspect ratios the layout must handle: portrait, landscape, square.
        let mediaShapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080), (900, 1600)]

        var records: [PostRecord] = []
        let newestMS: Int64 = 1_780_000_000_000 // fixed epoch so ordering is stable
        for index in 0..<postCount {
            let author = authors[index % authors.count]
            var caption = captionBank[index % captionBank.count]
            // Every fourth post mentions another author by @handle — the
            // corpus behind the profile gallery's "Tagged" category (search
            // matches the handle in the caption). `+4` keeps mentioner ≠
            // mentioned (4 ≢ 0 mod 8) and, being even, is solvable against
            // the odd `index % 4 == 1` residue — every author gets mentions,
            // and (via index % 3) in all three post kinds.
            if index % 4 == 1 {
                caption += " Spotted with @\(authors[(index + 4) % authors.count].handle)."
            }
            // One of every three posts is video, one image, one text-only —
            // a mix that exercises all three snap-feed cell paths.
            let hasMedia = index % 3 != 2
            let isVideo = index % 3 == 0
            let mediaHost = isVideo ? "video" : "media"
            let shape = mediaShapes[index % mediaShapes.count]
            // Every fifth post is a repost of the previous same-slot post.
            // Per author that lands on one residue mod 40 → three reposts
            // each, cycling all three kinds (40 ≡ 1 mod 3).
            let isRepost = index % 5 == 4 && index >= 8
            records.append(PostRecord(
                postID: String(format: "post-%04d", index),
                authorProfileID: author.profileID,
                caption: caption,
                media: hasMedia ? ("mock://\(mediaHost)/\(index)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1) : nil,
                publishedAtMS: newestMS - Int64(index) * 180_000, // 3 minutes apart, newest first
                parentID: isRepost ? String(format: "post-%04d", index - 8) : ""
            ))
        }
        posts = records

        // Twelve follows, not four: the compose picker expands the viewer's
        // first eight follows into friend-of-friend candidates
        // (`SocialConnectionsRepository.connectorExpansionLimit`), so a
        // four-follow graph could never produce more than a handful of
        // suggestions — far too few to reach a second page.
        followedProfileIDs = Set(authors.prefix(12).map(\.profileID))
        mutualProfileIDs = Set(authors.prefix(2).map(\.profileID))
        // Unrequited followers are the STRONGEST suggestion tier ("follows
        // you"), and the compose picker filters out anyone already in Recent —
        // so they are drawn from the far end of the roster, clear of the
        // authors the seeded conversations use. A pool that overlapped Recent
        // collapsed to a handful of suggestions after deduplication, far too
        // few to page.
        followerProfileIDs = mutualProfileIDs.union(authors[18...].map(\.profileID))

        var followingGraph: [String: Set<String>] = [
            MockSocialDataset.viewerProfileID: followedProfileIDs
        ]
        // Local copy: reading the property inside the stride closure would
        // capture a `self` that isn't fully initialized yet.
        let roster = authors
        for (index, author) in roster.enumerated() {
            var following = Set([1, 3, 5].map { roster[(index + $0) % roster.count].profileID })
            // The authors who follow the viewer must say so here too: this
            // graph is now the single source both edge lists are answered
            // from, so `followerProfileIDs` has to be derivable by inverting
            // it — otherwise the viewer would read as having no followers.
            if followerProfileIDs.contains(author.profileID) {
                following.insert(MockSocialDataset.viewerProfileID)
            }
            followingGraph[author.profileID] = following
        }
        followingByProfileID = followingGraph

        let pinnedCategoriesByIndex = [
            19: "cafes", 48: "restaurants", 63: "parks", 91: "nightlife", // in default viewport
            4: "cafes", 24: "restaurants" // outside — panning changes the field
        ]
        var categories: [String: String] = [:]
        for (index, category) in pinnedCategoriesByIndex where index < records.count {
            categories[records[index].postID] = category
        }
        pinnedPlaceCategories = categories
        pinnedPostIDs = Set(categories.keys)
    }

    public func author(for profileID: String) -> Author? {
        authors.first { $0.profileID == profileID }
    }

    public func post(for postID: String) -> PostRecord? {
        posts.first { $0.postID == postID }
    }
}
