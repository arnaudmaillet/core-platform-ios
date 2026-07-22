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
            ("zed.aldrin", "Zed Aldrin", "", "https://zed.example")
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

        followedProfileIDs = Set(authors.prefix(4).map(\.profileID))
        mutualProfileIDs = Set(authors.prefix(2).map(\.profileID))
        followerProfileIDs = mutualProfileIDs.union([authors[4].profileID])

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
