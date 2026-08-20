import Foundation

/// Deterministic fixture data shared by the timeline/post/profile mocks:
/// 8 authors and 120 posts with varied caption lengths and media shapes, so
/// the feed exercises real layout diversity without any randomness between
/// runs.
public struct MockSocialDataset: Sendable {
    /// Which media URLs the seeds carry.
    ///
    /// `.synthetic` is the default and must stay so: it seeds `mock://` URLs
    /// that `PlaceholderImageFetcher`/`PlaceholderVideoFetcher` render locally,
    /// which is what keeps the unit suite, SwiftUI previews, and CI free of any
    /// network dependency.
    ///
    /// `.realAssets` swaps in the verified public fixtures in
    /// `MockMediaFixtures` — real HLS ladders, progressive MP4s, and real
    /// photographs at exact dimensions — for driving the app by hand against
    /// realistic decode and streaming behaviour. Opt in with `-rich-media`.
    /// Never select it from a test.
    public enum MediaCatalog: Sendable {
        case synthetic
        case realAssets
    }

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

    /// Posts staged as having arrived since the viewer last looked, so For
    /// You's unread badge has something real to count on a cold launch.
    ///
    /// ⚠️ **Dated a few minutes into the FUTURE, and that is the mechanism.**
    /// The rest of the corpus sits on a fixed epoch so ordering is stable, which
    /// also means nothing in it is ever newer than a watermark taken from it —
    /// a badge derived honestly could only ever read zero, and the feature was
    /// unverifiable without a launch argument. A first sight baselines at the
    /// newest post the viewer COULD have seen, which is capped at the present
    /// moment (see `ForYouUnreadStore.sessionBaseline`), so a post stamped
    /// ahead of the clock is by construction an arrival. `MockChatService`
    /// stages the inbox's unread counts the same way and for the same reason.
    ///
    /// Recomputed per dataset instance rather than pinned to a constant: a
    /// fixed future date stops being the future, and the badge would quietly
    /// die some morning with nothing to point at.
    ///
    /// The captions are load-bearing. `ContentContext` is a caption keyword
    /// search, so these decide the per-mode counts the menu shows — three that
    /// read as Work, one as Focus, one as neither. `MockForYouArrivalTests`
    /// pins those numbers so a caption edit cannot quietly change them.
    ///
    /// Takes the catalog for the same reason the main corpus does, and it did
    /// NOT: these five seeded `mock://` unconditionally, so under
    /// `-rich-media` the arrivals were the only posts still showing
    /// synthesized placeholders — and a synthesized video placeholder is a
    /// flat colour. Being newest-first they are also the first pages the feed
    /// opens on, so the one group that ignored the flag was the group most
    /// likely to be looked at. Reported as "some posts render as a plain solid
    /// colour with `-rich-media`".
    /// Posts authored by the VIEWER, so their own profile is not empty.
    ///
    /// It was, and that is a hole in the fixtures rather than a product
    /// decision: every profile the mock can show has a gallery except the one
    /// the app opens by default. Two things could not be exercised because of
    /// it — a hero flight departing from the Profile TAB's root, and autoplay
    /// on the viewer's own gallery — and both looked like feature bugs.
    ///
    /// Nine posts on the same three-kind cycle the main corpus uses (video,
    /// image, text), so all three profile tabs have something: the mosaic, the
    /// timeline, and Short.
    static func viewerRecords(mediaCatalog: MediaCatalog, after count: Int) -> [PostRecord] {
        let captions = [
            "Testing in production is fine if production is your simulator.",
            "Shipping the new build tonight.",
            "Refactor landed and the office survived it.",
            "Weekend build log: the queue was never the problem, the clock was.",
            "No caption needed.",
            "Three days offline and the feed can wait.",
            "Golden hour over the harbour.",
            "Quiet morning, notes and a long walk before anything else.",
            "New city, same habits."
        ]
        let shapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080)]
        let newestMS: Int64 = 1_780_000_000_000
        return (0..<captions.count).map { index in
            let hasMedia = index % 3 != 2
            let isVideo = index % 3 == 0
            let shape = shapes[index % shapes.count]
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, mediaCatalog) {
            case (false, _):
                nil
            case (true, .synthetic):
                ("mock://\(isVideo ? "video" : "media")/me\(index)?w=\(shape.0)&h=\(shape.1)",
                 shape.0, shape.1)
            case (true, .realAssets):
                if isVideo {
                    { let fixture = MockMediaFixtures.videos[index % MockMediaFixtures.videos.count]
                      return (fixture.url, fixture.width, fixture.height) }()
                } else {
                    (MockMediaFixtures.imageURL(index: 900 + index, width: shape.0, height: shape.1),
                     shape.0, shape.1)
                }
            }
            return PostRecord(
                postID: String(format: "post-me-%02d", index),
                authorProfileID: Self.viewerProfileID,
                caption: captions[index],
                media: media,
                // Older than the seeded corpus, so the shared timeline keeps
                // the order it had and these sit at its tail rather than
                // pushing everyone else down.
                publishedAtMS: newestMS - Int64(count + index) * 180_000,
                parentID: ""
            )
        }
    }

    static func justArrivedRecords(
        authors: [Author],
        mediaCatalog: MediaCatalog
    ) -> [PostRecord] {
        // Ahead of the clock by enough that a slow launch cannot overtake it.
        let epochMS = Int64(Date().timeIntervalSince1970 * 1000) + 5 * 60_000
        // TWO OF THESE ARE LONG ON PURPOSE, and the lengths are as load-bearing
        // as the keywords: the timeline card truncates a caption at
        // `PostGridListRowCell.captionLineLimit` and offers the rest, and
        // nothing exercised that until the fixture had a caption that overran
        // it. Index 2 is the TEXT arrival — the one `-foryou-open 2` opens, so
        // the long case is also the one the hero transition is measured on —
        // and index 0 is a MEDIA arrival, because a card truncates whether or
        // not it carries a preview.
        //
        // ⚠️ Both extensions stay inside `ContentContext.work`'s vocabulary and
        // introduce no other context's. `MockForYouArrivalTests` pins three
        // work, one focus, one neither, and the search is a plain substring
        // match — so "notes", "quiet", "show", "watch", "play", "stream",
        // "level" and their kin cannot appear here by accident. The focus
        // arrival is index 3 and must keep its wording exactly.
        let captions = [
            """
            Standup moved to nine. The deadline holds. We cut the scope of the \
            settings rewrite rather than the date, which means the migration \
            ships as-is and the polish lands next week. Anyone who needs the \
            old behaviour can keep it behind the flag until the end of the month.
            """,
            "Refactor landed and the office survived it.",
            """
            Shipping the new build tonight. The changelog is longer than I \
            expected: two crashes that only reproduced on a cold launch, a \
            migration that had been silently no-oping since spring, and a \
            rewrite of the retry logic that finally makes sense. Everything is \
            behind a flag, so if the numbers look wrong in the morning we turn \
            it off and nobody has to be woken up. The summary for standup is \
            already in the doc.
            """,
            "Quiet morning, notes and a long walk before anything else.",
            "Golden hour over the harbour."
        ]
        let shapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080)]
        return captions.enumerated().map { index, caption in
            // ONE of the five is text-only (index 2), on the corpus's own
            // `index % 3 == 2` rule so the arrivals do not all land in one cell
            // path.
            let hasMedia = index % 3 != 2
            let shape = shapes[index % shapes.count]
            let isVideo = index % 2 == 1
            let host = isVideo ? "video" : "media"
            // Same branch as the main corpus, and the same reason for the
            // asymmetry inside it: a real video's declared size must come FROM
            // the fixture, because the client pre-layouts from it and a wrong
            // number shows up as a crop. Images keep `shapes` — Picsum returns
            // exactly the size asked for.
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, mediaCatalog) {
            case (false, _):
                nil
            case (true, .synthetic):
                ("mock://\(host)/new-\(index)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1)
            case (true, .realAssets):
                if isVideo {
                    { let fixture = MockMediaFixtures.videos[index % MockMediaFixtures.videos.count]
                      return (fixture.url, fixture.width, fixture.height) }()
                } else {
                    (MockMediaFixtures.imageURL(index: index, width: shape.0, height: shape.1),
                     shape.0, shape.1)
                }
            }
            return PostRecord(
                postID: String(format: "post-new-%02d", index),
                authorProfileID: authors[index % authors.count].profileID,
                caption: caption,
                media: media,
                // Newest first, a minute apart, all of them ahead of the clock.
                publishedAtMS: epochMS - Int64(index) * 60_000,
                parentID: ""
            )
        }
    }

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

    /// Which catalog this dataset was built with, so the mocks that need to
    /// vary their output by it (the geo pin projection) can ask.
    public let mediaCatalog: MediaCatalog

    public init(postCount: Int = 120, mediaCatalog: MediaCatalog = .synthetic) {
        self.mediaCatalog = mediaCatalog
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
        // `mediaCatalog` here is the initializer parameter, not the stored
        // property — reading `self` mid-init would not compile.
        func avatarURL(index: Int) -> String {
            switch mediaCatalog {
            case .synthetic: "mock://avatar/\(index)?w=128&h=128"
            case .realAssets: MockMediaFixtures.avatarURL(index: index)
            }
        }
        authors = names.enumerated().map { index, name in
            Author(
                profileID: "prof-\(index)",
                handle: name.0,
                displayName: name.1,
                avatarURL: avatarURL(index: index),
                bio: name.2,
                websiteURL: name.3
            )
        }
        relationshipsPrivateProfileIDs = Set(
            names.indices
                .filter { Self.isRelationshipsPrivate(profileIndex: $0) }
                .map { "prof-\($0)" }
        )

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
            // Under `.realAssets` a video post takes its dimensions FROM the
            // fixture rather than from `mediaShapes`: the declared size has to
            // match the real encode or pre-layout crops it. Image posts keep
            // `mediaShapes`, because Picsum returns exactly the size asked for.
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, mediaCatalog) {
            case (false, _):
                nil
            case (true, .synthetic):
                ("mock://\(mediaHost)/\(index)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1)
            case (true, .realAssets):
                if isVideo {
                    { let fixture = MockMediaFixtures.videos[(index / 3) % MockMediaFixtures.videos.count]
                      return (fixture.url, fixture.width, fixture.height) }()
                } else {
                    (MockMediaFixtures.imageURL(index: index, width: shape.0, height: shape.1), shape.0, shape.1)
                }
            }
            // Every fifth post is a repost of the previous same-slot post.
            // Per author that lands on one residue mod 40 → three reposts
            // each, cycling all three kinds (40 ≡ 1 mod 3).
            let isRepost = index % 5 == 4 && index >= 8
            records.append(PostRecord(
                postID: String(format: "post-%04d", index),
                authorProfileID: author.profileID,
                caption: caption,
                media: media,
                publishedAtMS: newestMS - Int64(index) * 180_000, // 3 minutes apart, newest first
                parentID: isRepost ? String(format: "post-%04d", index - 8) : ""
            ))
        }
        // Five posts that arrived AFTER the viewer last looked, at the head of
        // the timeline. See `justArrivedRecords`.
        posts = Self.justArrivedRecords(authors: authors, mediaCatalog: mediaCatalog)
            + records
            + Self.viewerRecords(mediaCatalog: mediaCatalog, after: postCount)

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

    // MARK: - Visibility

    /// Whether author `index` restricts its **relationship lists**.
    ///
    /// `index % 9 < 4` — a fixed 4-in-9 pattern, so a little under half the
    /// roster is restricted (23 of 48 authors, 48%) and the split is
    /// deterministic rather than sampled. The stride matters as much as the
    /// ratio: 9 is coprime with the viewer's twelve follows
    /// (`prof-0…prof-11`), so the pattern straddles that boundary instead of
    /// aligning with it, and **both** sides of the privacy rule are reachable
    /// without a launch argument:
    ///
    /// - restricted *and inside* the viewer's follow set (prof-0/1/2/3/9/10/11)
    ///   → the lists open normally, because a private profile is not private
    ///   to the people already in its graph;
    /// - restricted *and outside* it (prof-18/19/20/21/27/…) → the restricted
    ///   state renders and the client issues no edge request at all;
    /// - unrestricted (25 authors, prof-4 among them) → the ordinary path.
    ///
    /// Named for the *relationship lists* because that is the permission being
    /// modelled — matching the `follower_list_visibility` /
    /// `following_list_visibility` fields proposed in
    /// `BACKEND_RELATIONSHIP_LISTS.md`. It has to travel on `ProfileView`'s
    /// whole-profile `visibility` today only because that is the sole privacy
    /// field the contracts actually have; when the per-surface fields land,
    /// this seed moves onto them and nothing else changes. See
    /// `dev/BACKEND_GAPS.md` §13.
    public static func isRelationshipsPrivate(profileIndex: Int) -> Bool {
        profileIndex % 9 < 4
    }

    /// Every author whose relationship lists are restricted. The viewer is
    /// never in here: their own lists are always their own to see, so seeding
    /// it would model nothing.
    public let relationshipsPrivateProfileIDs: Set<String>

    public func isRelationshipsPrivate(_ profileID: String) -> Bool {
        relationshipsPrivateProfileIDs.contains(profileID)
    }

    // MARK: - Accounts

    /// One account owning several profiles, used by the profile screen's
    /// account-wide block. prof-5 and prof-6 are seeded as **aliases of one
    /// stranger** — the case the feature exists for. Everyone else gets a
    /// private account, so the ordinary single-profile path stays the default.
    public static let aliasAccountID = "acct-mock-alias"

    /// Which account owns `profileID`.
    ///
    /// prof-0 and prof-2 belong to the VIEWER's account, matching the profile
    /// switcher's seeded list — the two features have to agree or the switcher
    /// would offer profiles this map says belong to someone else.
    public func accountID(for profileID: String) -> String {
        switch profileID {
        case Self.viewerProfileID, "prof-0", "prof-2": MockAuthService.accountID
        case "prof-5", "prof-6": Self.aliasAccountID
        default: "acct-mock-" + profileID
        }
    }

    /// Every profile on `accountID`. The viewer stays FIRST on its own
    /// account — every viewer-id resolver takes `.first`.
    public func profileIDs(inAccount accountID: String) -> [String] {
        var ids: [String] = []
        if accountID == MockAuthService.accountID {
            ids.append(Self.viewerProfileID)
        }
        ids.append(contentsOf: authors.map(\.profileID).filter { self.accountID(for: $0) == accountID })
        return ids
    }

    public func post(for postID: String) -> PostRecord? {
        posts.first { $0.postID == postID }
    }
}
