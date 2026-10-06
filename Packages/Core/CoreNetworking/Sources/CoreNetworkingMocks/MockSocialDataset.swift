import Foundation

/// Deterministic fixture data shared by the timeline/post/profile mocks:
/// 8 authors and 120 posts with varied caption lengths and media shapes, so
/// the feed exercises real layout diversity without any randomness between
/// runs.
public struct MockSocialDataset: Sendable {
    /// Which media URLs the seeds carry.
    ///
    /// `.synthetic` is the default and must stay so: it seeds only `mock://`
    /// URLs, served locally — the bundled files behind them or the synthesized
    /// placeholders of `PlaceholderImageFetcher`/`PlaceholderVideoFetcher` —
    /// which is what keeps the unit suite, SwiftUI previews, and CI free of any
    /// network dependency.
    ///
    /// POST MEDIA IS THE SAME IN BOTH CATALOGS: the corpus's own bundled clips
    /// (`syntheticVideo`, `MockClipCatalog`) and photo galleries (`photo`,
    /// `galleryPhoto`, `MockPhotoCatalog`). `.realAssets` swaps only the
    /// AVATARS for real photographs at exact dimensions
    /// (`MockMediaFixtures.imageURL`). Opt in with `-rich-media`.
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
        ///
        /// The FIRST piece, and it stays a scalar because most of the mock
        /// reads exactly that: the kind is routed off this URL, the map's pins
        /// take their face from it, and a collection is still one thing in a
        /// grid. `extraMedia` carries the rest.
        public let media: (url: String, width: Int, height: Int)?
        /// Pages two and up of a collection post, empty for everything else.
        ///
        /// Separate rather than folding `media` into an array: every existing
        /// reader wants the head, and an array would have made each of them say
        /// `.first` — which is the exact shape of the bug this feature exists to
        /// undo, reintroduced one layer down.
        public var extraMedia: [(url: String, width: Int, height: Int)] = []
        public let publishedAtMS: Int64
        /// Non-empty = this post is a repost of `parentID` (post.v1 lineage:
        /// a repost is the author's own post referencing its source).
        public let parentID: String
        /// A like count chosen for this post, instead of the counter store's
        /// array-index formula. Only the world seed sets it (`MockWorldSeed`):
        /// a city's trending post has to be the trending post on purpose.
        public var seededLikes: Int64?
        /// Where this post was published, when the seed says so — the geo
        /// mock otherwise derives one (a venue, or the scatter). Only the
        /// world seed sets it.
        public var location: (latitude: Double, longitude: Double)?
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
    /// Draws its media from the same catalogs as the main corpus. It once did
    /// NOT: these seeded synthesized `mock://` placeholders unconditionally,
    /// so the arrivals were the only posts still showing flat colours — and
    /// being newest-first they are the first pages the feed opens on.
    /// Reported as "some posts render as a plain solid colour with
    /// `-rich-media`".
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

    /// Whether every post that has media is a VIDEO, or the corpus runs on its
    /// honest thirds (video, image, text).
    ///
    /// Was `true` while the video path was the one under work — photographs set
    /// aside so the map and the feed exercised video everywhere a post had
    /// media. Back to `false`: a hero flight's behaviour on a PHOTOGRAPH is not
    /// deducible from its behaviour on a clip, and a corpus with no photographs
    /// cannot answer the question at all. The two differ in the one place that
    /// matters for a transition — a photo surface has no player, no first-frame
    /// gate and no aspect-fill of a 1280x720 landscape source magnified ~3.9x
    /// into a portrait card.
    ///
    /// The photo branches were deliberately left in place rather than deleted
    /// while the switch was off, so this is one edit and not an excavation. The
    /// venue quotas move with it — see `MockGeoDiscoveryService`.
    ///
    /// What it does NOT change: `hasMedia`, so text-only posts stay exactly as
    /// they were and the text/media split is untouched.
    static let mediaIsAlwaysVideo = false

    /// A video post's media, in EITHER catalog: one of the REAL clips when the
    /// bundle carries them (`MockClipCatalog` — footage with its own sound),
    /// the synthesized placeholder at `shape` otherwise.
    ///
    /// ⚠️ `-rich-media` asks here too. It used to seed public films and HLS
    /// ladders instead, and the product plays only the real clips; a video post
    /// is the same clip at the same slot whichever catalog is selected.
    ///
    /// Slots spread the corpus across the catalog: the main timeline takes
    /// 0..<40, the viewer's, the just-arrived and the collection pages take
    /// the ones after, so a clip does not show up twice on one screen. The
    /// declared size is the CLIP's, never `shape`: pre-layout trusts it, and
    /// a size the file does not have shows up as a crop.
    static func syntheticVideo(
        slot: Int, fallback: String, shape: (Int, Int)
    ) -> (url: String, width: Int, height: Int) {
        MockClipCatalog.shared.media(forSlot: slot)
            ?? ("\(fallback)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1)
    }

    /// A photo post's media, in EITHER catalog: one of the REAL photographs
    /// (`MockPhotoCatalog`), cycling through every photo of every gallery.
    ///
    /// Slots follow the clips' layout: the main timeline takes 0..<40, the
    /// viewer's 40..<50, the just-arrived 50 and up. The declared size is the
    /// PHOTO's, never `shape`: pre-layout trusts it and crops to it. `shape`
    /// only sizes the synthesized placeholder a missing bundle falls back to
    /// (`mock://photo/unbundled-<fallback>`, which no catalog photo matches,
    /// so the image fetcher paints its colour).
    static func photo(
        slot: Int, fallback: String, shape: (Int, Int)
    ) -> (url: String, width: Int, height: Int) {
        MockPhotoCatalog.shared.photo(forSlot: slot)?.media
            ?? Self.unbundledPhoto(fallback, shape: shape)
    }

    /// Page `page` of a collection whose photos all come from the gallery at
    /// `gallery` — one shoot per post. Cycles within that gallery when the
    /// collection has more photo pages than the gallery has photos.
    static func galleryPhoto(
        gallery: Int, page: Int, fallback: String, shape: (Int, Int)
    ) -> (url: String, width: Int, height: Int) {
        MockPhotoCatalog.shared.photo(inGalleryForSlot: gallery, page: page)?.media
            ?? Self.unbundledPhoto(fallback, shape: shape)
    }

    private static func unbundledPhoto(
        _ name: String, shape: (Int, Int)
    ) -> (url: String, width: Int, height: Int) {
        ("\(MockPhotoCatalog.scheme)unbundled-\(name)?w=\(shape.0)&h=\(shape.1)", shape.0, shape.1)
    }

    static func viewerRecords(mediaCatalog: MediaCatalog, after count: Int) -> [PostRecord] {
        let captions = [
            "Testing in production is fine if production is your simulator. :lmao:",
            "Shipping the new build tonight. 🚀",
            "Refactor landed and the office survived it.",
            "Weekend build log: the queue was never the problem, the clock was.",
            "No caption needed.",
            "Three days offline and the feed can wait 😌",
            "Golden hour over the harbour. 🌊✨",
            "Quiet morning, notes and a long walk before anything else.",
            "New city, same habits. ✈️"
        ]
        let shapes: [(Int, Int)] = [(1080, 1350), (1600, 900), (1080, 1080)]
        let newestMS: Int64 = 1_780_000_000_000
        return (0..<captions.count).map { index in
            let hasMedia = index % 3 != 2
            let isVideo = Self.mediaIsAlwaysVideo || index % 3 == 0
            let shape = shapes[index % shapes.count]
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, isVideo) {
            case (false, _):
                nil
            case (true, true):
                Self.syntheticVideo(slot: 40 + index, fallback: "mock://video/me\(index)", shape: shape)
            case (true, false):
                Self.photo(slot: 40 + index, fallback: "me\(index)", shape: shape)
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

    /// The id namespace of the posts that arrived after the viewer last looked.
    /// Read by the geo fixture, which keeps them out of its venues — see
    /// `MockGeoDiscoveryService.venueAssignments` for why a map fixture cares
    /// what the timeline's head is made of.
    static let arrivalIDPrefix = "post-new-"

    static func justArrivedRecords(
        authors: [Author],
        mediaCatalog: MediaCatalog
    ) -> [PostRecord] {
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
            old behaviour can keep it behind the flag until the end of the month. ☕☕
            """,
            // Arrivals 0, 1, 2, 5, 6 and 7 carry EMOTES — Unicode emoji and
            // house `:code:`s — so EmoteKit's animated caption shows in mock
            // mode. Emoji add no words, and neither `lmao` nor `lol` is in any
            // context lexicon. Arrivals 3 and 4 stay exactly as written: 3 is
            // the focus arrival and 4 is matched BY CAPTION below.
            "Refactor landed and the office survived it. 🎉 :lmao:",
            """
            Shipping the new build tonight. The changelog is longer than I \
            expected: two crashes that only reproduced on a cold launch, a \
            migration that had been silently no-oping since spring, and a \
            rewrite of the retry logic that finally makes sense. Everything is \
            behind a flag, so if the numbers look wrong in the morning we turn \
            it off and nobody has to be woken up. The summary for standup is \
            already in the doc. 🤞
            """,
            "Quiet morning, notes and a long walk before anything else.",
            "Golden hour over the harbour.",
            "Every clip from the trip, back to back 🔥😂 :lol: ❤️",
            // ⚠️ TWO TEXT ARRIVALS IN A ROW, AND THAT IS THE WHOLE POINT.
            //
            // The corpus makes every third post text-only, so two text posts
            // are NEVER adjacent in it — which meant the case that produced
            // three separate defects (a text page arriving while another text
            // page still owns the resting interface) could not be reached from
            // the seed at all. Every recording of it had to be made by opening
            // one post and paging until the order happened to cooperate.
            //
            // These two sit at the head, so a cold launch opens on a text page
            // and the very first page down is another. Vocabulary kept clear of
            // every context lexicon — see the note above the captions — so the
            // lens counts below do not move.
            "Third coffee. Still deciding whether the rewrite was a good idea. ☕🤔",
            "Wrote four paragraphs, kept one. That is a normal ratio. :lol:"
        ]
        // ⚠️ THE LEAD SCALES WITH THE COUNT, because the stamps step BACK a
        // minute each: the newest is `epochMS` and the oldest is that minus one
        // minute per arrival. A fixed five minutes was five arrivals' worth
        // exactly, so the sixth landed ON the clock and stopped being an
        // arrival at all — measured as `theArrivalsLeadTheCorpus` failing for
        // the one post that was added, not for anything it does.
        //
        // Five minutes of margin PAST the oldest, so a slow launch cannot
        // overtake the run.
        let epochMS = Int64(Date().timeIntervalSince1970 * 1000)
            + Int64(captions.count + 5) * 60_000
        // One entry PER ARRIVAL rather than a short roster cycled by modulus,
        // because with five arrivals and a `% 3` roster only two of the shapes
        // were ever reachable here: media lands on indices 0, 1, 3 and 4, which
        // is `{0, 1, 0, 1}` over three. The Following feed therefore had no
        // story-format post at all while the main corpus did — which is exactly
        // what "the feed only has landscape media" was.
        //
        // Chosen against the slot's KIND, since only indices 1 and 3 are video:
        //
        //   0  image  4:5    the portrait CAP, the shape drawn uncropped
        //   1  video  16:9   the landscape end
        //   2  —             text-only, so this entry is never read
        //   3  video  9:16   a vertical VIDEO (the placeholder's shape, below)
        //   4  image  9:16   a vertical PHOTO, in both catalogs
        //
        // ⚠️ These shapes are only the PLACEHOLDERS'. When the bundle carries
        // the real clips and photos (it does, in both catalogs) a post takes
        // its dimensions from its own file, because declaring a size the file
        // does not have is the pre-layout crop.
        let shapes: [(Int, Int)] = [
            (1080, 1350), (1600, 900), (1080, 1080), (900, 1600), (1080, 1920)
        ]
        return captions.enumerated().map { index, caption in
            // ONE of the five is text-only (index 2), on the corpus's own
            // `index % 3 == 2` rule so the arrivals do not all land in one cell
            // path.
            // ⚠️ ARRIVAL 5 IS THE OVER-CAPACITY GALLERY, and it is the first
            // card in the feed.
            //
            // The pool carries `capacity` players — six — and every limit this
            // seed exercises so far sits UNDER that number, so nothing here
            // ever showed what a gallery does when it asks for more than the
            // pool can hold. It was meant to hold seven clips — one more than
            // the budget, the smallest number that makes the retention window
            // refuse something. ⚠️ It holds THREE (see where its pages are
            // built): the list it was sized from never had seven playable
            // entries.
            //
            // Its own page is a PHOTOGRAPH, like every other collection here —
            // page one decides the post's kind, and a clip there would make
            // this a video post that happens to have pages rather than the
            // gallery under test.
            //
            // Placed LAST in this array because the New section presents these
            // in reverse (see arrival 4's note), so the highest index is the
            // card a cold launch opens on.
            let isOverCapacityGallery = index == 5
            // ⚠️ 6 AND 7 ARE TEXT, back to back — see the captions' own note.
            let isAdjacentTextPair = index >= 6
            let hasMedia = !isAdjacentTextPair && (isOverCapacityGallery || index % 3 != 2)
            let shape = isOverCapacityGallery ? (1600, 900) : shapes[index % shapes.count]
            let isVideo = !isOverCapacityGallery && index % 2 == 1
            // Same rule as the main corpus, in both catalogs: a video is a real
            // clip and a photo a real photograph, each declaring its FILE's
            // size because the client pre-layouts from it and a wrong number
            // shows up as a crop.
            //
            // ⚠️ A COLLECTION'S HEAD IS ITS GALLERY'S PAGE 0, not a photo from
            // the shared rotation: the post's own page and the pages behind it
            // are one shoot (`collectionGallery`).
            let collectionGallery: Int? = switch index {
            case 5: 2  // the over-capacity gallery: a photo head over clips
            case 4: 3  // the large gallery — the one with mixed aspects
            case 1: 4  // the small gallery: a clip head over two photos
            default: nil
            }
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, isVideo) {
            case (false, _):
                nil
            case (true, true):
                Self.syntheticVideo(slot: 44 + index, fallback: "mock://video/new-\(index)", shape: shape)
            case (true, false):
                if let collectionGallery {
                    Self.galleryPhoto(gallery: collectionGallery, page: 0,
                                      fallback: "new-\(index)", shape: shape)
                } else {
                    Self.photo(slot: 50 + index, fallback: "new-\(index)", shape: shape)
                }
            }
            // ARRIVAL 4 IS A COLLECTION — four photos behind the one the card
            // opens on.
            //
            // Index FOUR, not zero, and it is worth stating why: these five are
            // stamped newest-first (`epochMS - index * 60_000`) but the New
            // section presents them the other way round, so index 4 is the card
            // a cold launch opens on and index 0 is the one five scrolls down.
            // Measured in the simulator, not assumed — the collection was
            // seeded on index 0 first and could not be seen without scrolling.
            // It is also an IMAGE slot (`index % 2 == 1` is video), which a
            // collection has to be.
            //
            // ⚠️ MIXED: one of these pages is a VIDEO.
            //
            // `post.v1` distinguishes `carousel` from `main_video`, and nothing
            // in the contract says a carousel's pages agree about their type —
            // each attachment carries its own MIME. The seed was photos-only
            // while the card's carousel could only draw covers, and that made a
            // mixed collection unverifiable rather than unsupported: the client
            // hydrates `MediaPage.videoURL` per page already, off the same MIME
            // rule, so the only thing missing was a post that exercised it.
            //
            // Position ONE, not zero: page one decides the box's aspect and the
            // post's kind, so a video there would make this a video post that
            // happens to have pages. The interesting case is a video arriving
            // mid-scroll, inside a box a photograph chose.
            //
            // A carousel takes its box from the first page and aspect-fills the
            // rest. Every page keeps its FILE's own dimensions — the shapes
            // below are only the placeholders' when the bundle has no media —
            // because declaring a size the file does not have is how a page
            // ends up cropped against a ratio nothing in the file matches.
            let collectionShapes: [(Int, Int)] = [(1600, 900), (1080, 1080), (900, 1600)]
            // ⚠️ TWO of the three extra pages are clips, not one.
            //
            // One clip proves a gallery can hold a video; two prove the POOL
            // keeps one player per asset rather than one per gallery. The
            // difference is the whole of "no duplicates during the transitions"
            // — with a single clip, a duplicate and a correct reuse look the
            // same from outside.
            let videoPagePositions: Set<Int> = [1, 2]
            // ⚠️ THE FEED'S FIRST POST IS THE LARGE GALLERY — index 0.
            //
            // Posts are ordered newest first, so index zero is what a viewer
            // meets on launch. The limits are what want looking at, and they
            // are not reachable by scrolling past three other cards first.
            //
            // Three pages exercise the seams; they do not exercise the LIMITS.
            // A dozen does: the indicator has to stop drawing one dot per page
            // and start windowing, the retention window has to refuse most of
            // what it is offered, and a scrub across the chip has to reach pages
            // that are nowhere near the screen. None of that is observable on a
            // gallery small enough for every page to be a dot.
            //
            // Two of its pages are clips, for the same reason the small one has
            // two: with a single clip, a duplicated player and a correctly
            // reused one look identical from outside.
            // ⚠️ ELEVEN extra pages, not twelve — the post's own media is page
            // one. Counting the extras as the total is how a "twelve-page
            // gallery" quietly becomes thirteen.
            let bigShapes: [(Int, Int)] = (0..<11).map { position in
                switch position % 3 {
                case 0: (1600, 900)
                case 1: (1080, 1080)
                default: (900, 1600)
                }
            }
            let bigVideoPositions: Set<Int> = [3, 8]
            // ⚠️ A THIRD GALLERY, small — index 1.
            //
            // The indicator now expands only when the full run of dots wants
            // more room than it already has, and that rule has two outcomes.
            // Testing it needs both near the top of the feed, where a viewer
            // opening the app meets them without scrolling: twelve pages, which
            // must expand and displace the counters, and three, which must not
            // move anything at all. One of each proves the condition; either
            // alone proves only that something happens.
            let smallShapes: [(Int, Int)] = [(1080, 1080), (1600, 900)]
            // ⚠️ CHOSEN BY CAPTION, NOT BY INDEX, and the arithmetic is why.
            //
            // These are seeded oldest-index-first and the feed presents them the
            // other way round, so "index 0" is the LAST card a viewer sees —
            // the opposite of what was asked for. Rather than re-derive that
            // inversion here and have it rot the next time the ordering moves,
            // the post is named: this caption was empirically the first card in
            // the feed, and a mock may know that about itself.
            //
            // ⚠️ It is the SECOND card now — the over-capacity gallery above was
            // seeded after it and takes the top slot. The name is kept rather
            // than renamed to `isLargeGallery`, because what this flag selects
            // is still "the twelve-page one near the top", and a reader chasing
            // the ordering should find this note rather than a flag that
            // silently claims a position it no longer holds.
            let isFirstInFeed = caption == "Golden hour over the harbour."
            let extraMedia: [(url: String, width: Int, height: Int)] =
                isOverCapacityGallery
                // ⚠️ ONE CLIP PER PAGE, each on its OWN slot: the pool keeps
                // one player per ASSET, so pages sharing a file would be fewer
                // players than pages and would prove nothing about a budget.
                //
                // THREE pages, which is what this gallery has always carried in
                // practice. It was built from the public-fixture list (two
                // remote films plus the map's preview loop) while its note
                // above promised seven; those fixtures are gone and the count
                // is stated here instead of inherited from a list's length.
                //
                // Each keeps its clip's own dimensions for the reason the notes
                // above give: the client pre-layouts from the declared size,
                // and a number the file does not have shows up as a crop.
                ? (0..<3).map { position in
                    Self.syntheticVideo(slot: 46 + position, fallback: "mock://video/cap-\(position)",
                                        shape: (1600, 900))
                }
                // ⚠️ EVERY PHOTO PAGE FROM THE POST'S OWN GALLERY. A carousel
                // is one shoot; pages drawn from the shared rotation would be a
                // post made of other posts' pictures. Page N of the collection
                // is page N of the gallery (the head is page 0), cycling within
                // the gallery if the collection outgrows it — clip pages simply
                // skip their number.
                : isFirstInFeed
                ? bigShapes.enumerated().map { position, shape in
                    if bigVideoPositions.contains(position) {
                        // Distinct clips, and distinct from the small
                        // gallery's: two posts sharing a file is its own test
                        // (see `PlaybackScopeTests`) and must not be smuggled in
                        // here by accident.
                        Self.syntheticVideo(slot: 30 + position, fallback: "mock://video/new-0-\(position)",
                                            shape: shape)
                    } else {
                        Self.galleryPhoto(gallery: collectionGallery ?? index, page: position + 1,
                                          fallback: "new-0-\(position)", shape: shape)
                    }
                }
                : index == 1
                ? smallShapes.enumerated().map { position, shape in
                    // The head is a clip, so the gallery starts at page 0 here.
                    Self.galleryPhoto(gallery: collectionGallery ?? index, page: position,
                                      fallback: "new-1-\(position)", shape: shape)
                }
                : index == 4
                ? collectionShapes.enumerated().map { position, shape in
                    if videoPagePositions.contains(position) {
                        // `mock://video/…` is what `MockMediaFixtures.isVideoURL`
                        // routes on, so the attachment declares a video MIME and
                        // the client's own rule does the rest. A DIFFERENT clip
                        // per page (one slot each): two pages on one asset would
                        // hide the very duplication this exists to catch.
                        Self.syntheticVideo(slot: 36 + position, fallback: "mock://video/new-4-\(position)",
                                            shape: shape)
                    } else {
                        Self.galleryPhoto(gallery: collectionGallery ?? index, page: position + 1,
                                          fallback: "new-4-\(position)", shape: shape)
                    }
                }
                : []
            return PostRecord(
                postID: String(format: "\(arrivalIDPrefix)%02d", index),
                authorProfileID: authors[index % authors.count].profileID,
                caption: caption,
                media: media,
                extraMedia: extraMedia,
                // Newest first, a minute apart, all of them ahead of the clock.
                publishedAtMS: epochMS - Int64(index) * 60_000,
                parentID: ""
            )
        }
    }

    public let authors: [Author]
    public let posts: [PostRecord]

    /// Each post's author avatar, by post id.
    ///
    /// For the map: `RadarPin` carries no author, so a text marker has no face
    /// to wear on the wire (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`). The mock
    /// knows the authorship the wire omits — the same thing that already lets
    /// the map's Friends/Following filters work here and nowhere else — so it
    /// can answer, and the whole marker is built and testable before the field
    /// exists.
    public func authorAvatarURLsByPostID() -> [String: String] {
        let avatars = Dictionary(
            authors.map { ($0.profileID, $0.avatarURL) }, uniquingKeysWith: { first, _ in first }
        )
        return posts.reduce(into: [:]) { result, post in
            result[post.postID] = avatars[post.authorProfileID]
        }
    }

    /// Animated pin icons, keyed by post id — **TEXT-ONLY posts, and only
    /// every other one**.
    ///
    /// `RadarPin` carries no `icon_id` yet
    /// (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md` proposes field 12), so the
    /// mock answers what the wire cannot. Text-only is read from the record —
    /// `media == nil` — never re-derived: the corpus expresses that rule three
    /// different ways in three places, and a fourth formula would drift from
    /// all of them.
    ///
    /// Two deliberate properties of the seed:
    ///
    /// - **Two text posts in three get one**, so the map shows icon markers
    ///   NEXT TO avatar markers and glyph fallbacks. A field where every text
    ///   pin animates proves the renderer and hides the mixing; a field where
    ///   too few do shows nothing at all at city zoom, where a handful of
    ///   clusters stand in for a hundred posts and their representatives are
    ///   chosen by like count rather than by kind.
    /// - **Icons are chosen by the post id's NUMERIC SUFFIX, not by
    ///   `hashValue`.** ⚠️ Swift seeds its string hash per launch, so hashing
    ///   would give the same post a different icon on every run: no screenshot
    ///   diff would ever be stable and no QA recipe could pin a marker's
    ///   appearance.
    ///
    /// `catalogue` is the icon ids a face is handed out from, in order, so the
    /// caller decides which icons — and how many distinct ones — the map can
    /// show (the app hands in emote faces, never the baked catalogue's
    /// geometric placeholders: see `EmoteKit.EmoteMapIcons`).
    public func animatedIconIDsByPostID(catalogue: [String]) -> [String: String] {
        guard !catalogue.isEmpty else { return [:] }
        return posts.reduce(into: [:]) { result, post in
            guard post.media == nil else { return }
            guard let index = Self.numericSuffix(of: post.postID) else { return }
            // The world's text posts say for themselves which wear an icon
            // (`MockWorldSeed.Kind.text(iconFace:)`): their ids do not run on
            // the corpus's three-kind cycle the rule below reads.
            if post.postID.hasPrefix(MockWorldSeed.postIDPrefix) {
                if MockWorldSeed.wearsIconFace(post.postID) {
                    result[post.postID] = catalogue[index % catalogue.count]
                }
                return
            }
            // Text posts are `index % 3 == 2` in this corpus, so `index / 3`
            // numbers them 0, 1, 2 … — skipping every third leaves a visible
            // minority wearing the author's face instead.
            guard (index / 3) % 3 != 2 else { return }
            result[post.postID] = catalogue[(index / 3) % catalogue.count]
        }
    }

    /// Baked preview sheets, keyed by post id — **MEDIA posts only**, the exact
    /// complement of `animatedIconIDsByPostID`.
    ///
    /// A text post has no footage to preview and a media post has no icon, so
    /// the two decorations can never land on one marker. That disjointness is
    /// the product rule, not an implementation detail: a marker answers "what is
    /// this post" once.
    ///
    /// Every media post gets one. Unlike the icons, there is no deliberate
    /// minority left undressed — the interesting question here is what a field
    /// where EVERYTHING moves costs, and the still cover is already the fallback
    /// while a sheet loads.
    public func previewSheetIDsByPostID(catalogue: [String]) -> [String: String] {
        guard !catalogue.isEmpty else { return [:] }
        return posts.reduce(into: [:]) { result, post in
            // ⚠️ VIDEO POSTS ONLY, and the guard used to be `post.media != nil`.
            //
            // A preview sheet is a sample of the post's OWN footage. A
            // photograph has none — its marker should wear the photograph (or
            // its first frame), which is what the cover already does. Seeding
            // every post that merely HAS media gave still photos an animated
            // marker playing somebody else's clip: the annotation and the post
            // no longer described the same thing, and opening one showed a page
            // with nothing moving in it.
            guard let media = post.media,
                  MockMediaFixtures.isVideoURL(media.url),
                  let index = Self.numericSuffix(of: post.postID)
            else { return }
            // ⚠️ NIL IS AN ANSWER. A video with no baked sheet gets NONE, and
            // the marker falls back to its cover — which is the ladder. Handing
            // it an arbitrary clip was the defect a viewer reported: most of
            // the old public fixtures had no sheet of their own and every one
            // of them wore somebody else's footage.
            result[post.postID] = Self.previewSheet(for: media.url, in: catalogue, index: index)
        }
    }

    /// The sheet baked from THIS post's clip when one exists.
    ///
    /// The catalogue's ids are `<clip>-<segment>` and a clip's URL names the
    /// clip (`mock://video/clip-NN`), so every video post wears a preview of
    /// its own footage. A URL that names no baked clip (the synthesized
    /// placeholder) gets none.
    ///
    /// ⚠️ THE OPENING SEGMENT, NOT ONE PICKED BY POST INDEX.
    ///
    /// Spreading posts across a clip's segments made the map look varied and
    /// made "frame 0" a lie: a marker's cover is the cell 0 of the sheet it
    /// wears, so a post seeded with segment 7 had a cover that was the first
    /// frame of the middle of the film, while the page it opened resolved a
    /// different segment again. Filmed as a marker showing a black title card
    /// over a post whose flight animated a forest.
    ///
    /// The cost is real and deliberate: every post of the same clip now
    /// previews the same footage. The invariant is worth more than the variety,
    /// and each clip is baked with one segment anyway.
    ///
    /// `index` is kept for the signature's callers and no longer read.
    static func previewSheet(for url: String, in catalogue: [String], index: Int) -> String? {
        guard let clip = MockMediaFixtures.bakedClip(for: url) else { return nil }
        return MockMediaFixtures.openingSegment(ofClip: clip, in: catalogue)
    }

    /// The trailing digits of `post-0007`. Nil when there are none, which keeps
    /// a hand-written id out of the seed rather than mapping it to zero.
    static func numericSuffix(of id: String) -> Int? {
        let digits = id.reversed().prefix { $0.isNumber }.reversed()
        return digits.isEmpty ? nil : Int(String(digits))
    }

    /// The viewer's social graph, shared by the social-graph and geo-discovery
    /// mocks so the map's "Friends"/"Following" filters and the following list
    /// agree on one truth. The viewer follows the first twelve authors; eight
    /// of them follow back (`friendIndices` — mutual = the implicit "friend"
    /// state, per social_graph.v1's `RelationStatus` doc).
    public let followedProfileIDs: Set<String>
    public let mutualProfileIDs: Set<String>
    /// Which authors are the viewer's friends — see where `mutualProfileIDs`
    /// is seeded for why these eight.
    public static let friendIndices = [0, 1, 2, 4, 5, 8, 9, 10]
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

    /// `seedsWorld` appends the posts published beyond France
    /// (`MockWorldSeed`) at the TAIL. Off by default, so every test that
    /// builds a dataset keeps the corpus its fixtures are calibrated
    /// against; the app turns it on with the map's place seed
    /// (`MockBackend(seedsMapHierarchy:)`).
    public init(postCount: Int = 120, mediaCatalog: MediaCatalog = .synthetic, seedsWorld: Bool = false) {
        self.mediaCatalog = mediaCatalog
        // (handle, name, bio, website) — bios vary from empty to multi-line so
        // the profile header exercises every identity-row combination. Many
        // carry an emote or two, one a run, as bios do; a few carry a
        // `@handle` or a `#tag` (#524).
        let names: [(String, String, String, String)] = [
            ("ava.moreau", "Ava Moreau", "Street photography, mostly Lyon. 📸\nPrints on request.", "https://www.avamoreau.example/prints/"),
            ("kenji.dev", "Kenji Tanaka", "Building small tools for small teams. Coffee first ☕, commits later. :laptop:", "https://kenji.example"),
            ("lena_klein", "Lena Klein", "", ""),
            ("marcus.holt", "Marcus Holt", "Trail runner 🏁 · Amateur baker 🍪\nLong runs with @priya.raman. #trailrunning", ""),
            ("sofia.reyes", "Sofía Reyes", "Cocino, viajo, repito. 🌮✈️", "https://sofia.example/blog"),
            ("tom.okafor", "Tom Okafor", "Bass, mostly. 🎸", ""),
            ("yuki.snow", "Yuki Shirakawa", "Snow reports and mountain film. ❄️\nSee you in Hakuba.", ""),
            ("zed.aldrin", "Zed Aldrin", "", "https://zed.example"),
            ("nina.varga", "Nina Varga", "Ceramics, badly. Improving. 🙃", ""),
            ("olu.adeyemi", "Olu Adeyemi", "Backend by day, bread by night.", "https://olu.example"),
            ("priya.raman", "Priya Raman", "Long runs and longer playlists 🎶🔥 :lol:", ""),
            ("quentin.dubois", "Quentin Dubois", "", ""),
            ("rosa.iglesias", "Rosa Iglesias", "Archivist. Ask me about #microfilm.", ""),
            ("sam.whitfield", "Sam Whitfield", "Boats, mostly small ones. 🌊 #sailing", "https://sam.example"),
            ("tara.nkemelu", "Tara Nkemelu", "Illustration + risograph.", ""),
            ("umar.qadir", "Umar Qadir", "Teaching maths, learning guitar. :books: 🎸", ""),
            ("vera.lindqvist", "Vera Lindqvist", "Cold water swimmer. 🥶\nYes, year round.", ""),
            ("wes.bramley", "Wes Bramley", "", ""),
            ("xiomara.cruz", "Xiomara Cruz", "Salsa on Tuesdays. 💃💃💃💃💃", "https://xio.example"),
            ("yannis.papas", "Yannis Papas", "Olive groves and old engines.", ""),
            ("zara.hadid", "Zara Hadid", "Drawing buildings that won't stand up.", ""),
            ("aiko.tanabe", "Aiko Tanabe", "Tea, type, and terrible puns. :lol:", ""),
            ("bruno.costa", "Bruno Costa", "", ""),
            ("chloe.baptiste", "Chloé Baptiste", "Sound design for small films.", "https://chloe.example"),
            ("dmitri.orlov", "Dmitri Orlov", "Chess clocks and film cameras.", ""),
            ("elif.demir", "Elif Demir", "Rooftop gardener. 🌱🌷", ""),
            ("finn.oleary", "Finn O'Leary", "Sea swimming, poorly. 🐬", ""),
            ("greta.hansen", "Greta Hansen", "Maps, always maps.", "https://greta.example"),
            ("hugo.martel", "Hugo Martel", "", ""),
            ("ines.ferreira", "Inês Ferreira", "Botanical prints. 🌸", ""),
            ("jonas.weber", "Jonas Weber", "Cycling the long way round.", ""),
            ("kaia.lindgren", "Kaia Lindgren", "Ceramicist. Kiln #3.", ""),
            ("leo.marchetti", "Leo Marchetti", "Espresso and edge cases. ☕", ""),
            ("mira.solberg", "Mira Solberg", "Field recordings.", "https://mira.example"),
            ("noah.brandt", "Noah Brandt", "", ""),
            ("orla.kavanagh", "Orla Kavanagh", "Sea glass and short stories.", ""),
            ("pavel.novak", "Pavel Novák", "Trams, timetables, trivia.", ""),
            ("quinn.abara", "Quinn Abara", "", "https://quinn.example"),
            ("rita.moreno", "Rita Moreno", "Weaving on a very old loom.", ""),
            ("stefan.ilic", "Stefan Ilić", "Mountains before breakfast. 🌞", ""),
            ("tessa.okonkwo", "Tessa Okonkwo", "Type design, slowly.", ""),
            ("ulf.johansson", "Ulf Johansson", "", ""),
            ("valeria.rossi", "Valeria Rossi", "Pasta, patiently. 🤌", "https://valeria.example"),
            ("wren.mackay", "Wren MacKay", "Birds, bothies, bad weather. :weather:", ""),
            ("xander.pike", "Xander Pike", "Restoring one motorbike forever. 😩", ""),
            ("yara.haddad", "Yara Haddad", "Murals and mosaics. 🌈", ""),
            ("zeke.turner", "Zeke Turner", "", ""),
            ("amara.diallo", "Amara Diallo", "Documentary sound.", "https://amara.example"),
            ("bo.lindholm", "Bo Lindholm", "Woodcut prints.", ""),
            ("celia.marsh", "Celia Marsh", "Rock pools and field notes. 🐙", ""),
            ("dara.singh", "Dara Singh", "Kites, mostly homemade.", "")
        ]
        // `mediaCatalog` here is the initializer parameter, not the stored
        // property — reading `self` mid-init would not compile.
        //
        // ⚠️ THREE SHAPES OF AVATAR, because the profile's banner IS its
        // avatar until the contract grows a cover field, and the banner takes
        // its shape from the picture: a landscape avatar gives a band, a
        // portrait one a poster, and no avatar no banner at all. Every fourth
        // author has none; the rest alternate.
        func avatarURL(index: Int) -> String {
            guard let shape = Self.avatarShape(index: index) else { return "" }
            switch mediaCatalog {
            case .synthetic: return Self.syntheticAvatarURL(index: index)
            case .realAssets: return MockMediaFixtures.imageURL(index: index, width: shape.0, height: shape.1)
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
            "Coffee count: unreasonable ☕😂 Progress: acceptable :lol: The refactor is finally starting to pay for itself and the test suite agrees 🔥",
            "No caption needed.",
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to. Writing it up properly this week — the short version is that the queue was never the problem, the clock was.",
            "New city, same habits. ✈️",
            "Testing in production is fine if production is your simulator. :lmao:",
            "The mountains were louder than the city this time. Three days offline and the feed can wait.",
            // Entries 8 and up only lengthen the cycle, so the first eight posts
            // keep the captions they always had. About half of the bank carries
            // emotes (Noto emoji from EmoteKit's bundled subset, and house
            // `:code:`s), two of them as a run, so animated text shows up on a
            // normal scroll. ⚠️ Keep them clear of `ContentContext`'s keywords
            // ("work", "play", "show", "notes"…): a caption is a substring
            // search for the For You modes.
            "Sunday market haul 🍓🥑🍉",
            "Tried the new ramen place. Worth the queue. 🍜🔥",
            "😂😂😂😂😂😂 I can't believe that actually happened",
            "Nothing planned, which was the plan.",
            "Birthday dinner with the best people 🎂🥂🎉🥳💕",
            "Rain all week, so here's some sun from last month 🌞 :weather:",
            "First swim of the year. Never again. Until tomorrow. 🥶🥶",
            "Late train home, good book, zero signal."
        ]
        // Placeholder shapes, read only when the bundle has no clips or photos
        // (a post otherwise declares its own file's size): portrait,
        // landscape, square.
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
            let isVideo = Self.mediaIsAlwaysVideo || index % 3 == 0
            let shape = mediaShapes[index % mediaShapes.count]
            // A video post is a real clip and an image post a real photograph,
            // in BOTH catalogs, and each takes its dimensions FROM its file
            // rather than from `mediaShapes`: the declared size has to match
            // the file or pre-layout crops it.
            let media: (url: String, width: Int, height: Int)? = switch (hasMedia, isVideo) {
            case (false, _):
                nil
            case (true, true):
                Self.syntheticVideo(slot: index / 3, fallback: "mock://video/\(index)", shape: shape)
            case (true, false):
                Self.photo(slot: index / 3, fallback: "\(index)", shape: shape)
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
        let seeded = Self.justArrivedRecords(authors: authors, mediaCatalog: mediaCatalog)
            + records
            + Self.viewerRecords(mediaCatalog: mediaCatalog, after: postCount)
        // The world goes LAST: like counts and the geo mock's venue walk read
        // array positions, so anything inserted ahead would move them all.
        // Authored by the first eight authors, whose profiles already carry
        // galleries.
        posts = seedsWorld
            ? seeded + MockWorldSeed.records(
                authors: Array(authors.prefix(8)),
                olderThanMS: seeded.map(\.publishedAtMS).min() ?? newestMS
            )
            : seeded

        // Twelve follows, not four: the compose picker expands the viewer's
        // first eight follows into friend-of-friend candidates
        // (`SocialConnectionsRepository.connectorExpansionLimit`), so a
        // four-follow graph could never produce more than a handful of
        // suggestions — far too few to reach a second page.
        followedProfileIDs = Set(authors.prefix(12).map(\.profileID))
        // EIGHT friends, chosen rather than taken as a prefix (2026-09-29):
        // For You's stories row lists the viewer's friends, and two avatars
        // is not a row. Every one of them has a real avatar (indices 3, 7 and
        // 11 have none — `avatarShape`), and the mix is deliberate: 0, 1, 2,
        // 4 and 5 posted a just-arrived post (`justArrivedRecords` is authored
        // by indices 0…7), so they lead with a ring; 8, 9 and 10 did not, so
        // they sit after, bare. The four followed-but-not-friends (3, 6, 7,
        // 11) are the Following row.
        // Spelled from the index (`prof-N`, as `authors` is built above):
        // reading `authors` inside the closure would capture a `self` that is
        // not fully initialized yet.
        mutualProfileIDs = Set(Self.friendIndices.map { "prof-\($0)" })
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
    /// The shape of an author's avatar — and so of their banner — or nil for
    /// an author with no picture. Landscape on even indices, portrait on odd,
    /// none on every fourth: `prof-0` band, `prof-1` poster, `prof-3` bare.
    /// An author's avatar in the default (offline) catalogue: one of the
    /// bundled REAL photographs, with its own encoded size.
    ///
    /// ⚠️ NEVER A FLAT COLOUR. It was `mock://avatar/<n>`, which the
    /// placeholder fetcher renders as a solid colour, so three authors in four
    /// wore a plain coloured disc and a plain coloured banner (2026-09-28: "on
    /// ne devrait avoir aucun avatar de couleur unie"). An author has a real
    /// picture or none (`avatarShape` nil → initials, no banner). A stride of
    /// 7 over the catalogue spreads neighbours across shoots; the banner takes
    /// its shape from the photo, so most are posters.
    public static func syntheticAvatarURL(index: Int) -> String {
        let photos = MockPhotoCatalog.shared.photos
        guard !photos.isEmpty else { return "" }
        // The landscape AVATARS (`avatarShape` even) take the catalogue's
        // landscape photographs in turn, so the corpus keeps band banners;
        // the rest spread over every photo.
        let landscape = photos.filter { $0.width > $0.height }
        if let shape = avatarShape(index: index), shape.0 > shape.1, !landscape.isEmpty, index % 4 == 0 {
            return landscape[(index / 4) % landscape.count].media.url
        }
        return photos[(index * 7 + 3) % photos.count].media.url
    }

    /// The viewer's avatar in the default catalogue: a LANDSCAPE photograph,
    /// so the viewer's own profile wears a band.
    public static var syntheticViewerAvatarURL: String {
        let catalog = MockPhotoCatalog.shared
        let landscape = catalog.photos.first { $0.width > $0.height }
        return (landscape ?? catalog.photos.first)?.media.url ?? ""
    }

    public static func avatarShape(index: Int) -> (Int, Int)? {
        if index % 4 == 3 { return nil }
        return index % 2 == 0 ? (1600, 900) : (900, 1600)
    }

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
