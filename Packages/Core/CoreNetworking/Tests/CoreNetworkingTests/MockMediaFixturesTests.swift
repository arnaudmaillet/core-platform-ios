import Foundation
import Testing
@testable import CoreNetworkingMocks

/// Covers the media rules and the two-catalog seeding. Deliberately makes **no
/// network calls**: a test that hit a live CDN would make the suite flaky and
/// offline-hostile — the exact property the synthetic default exists to
/// protect.
///
/// Video in BOTH catalogs is the corpus's own bundled clips (`MockClipCatalog`);
/// the public films and HLS ladders `-rich-media` used to seed are gone, and
/// these tests pin that they stay gone.
struct MockMediaFixturesTests {

    private var clips: MockClipCatalog { .shared }

    /// Every media URL a post carries: its head and a collection's pages.
    private func allMedia(of post: MockSocialDataset.PostRecord) -> [(url: String, width: Int, height: Int)] {
        (post.media.map { [$0] } ?? []) + post.extraMedia
    }

    // MARK: - Classification

    @Test func recognisesVideoAcrossBothCatalogs() throws {
        #expect(MockMediaFixtures.isVideoURL("mock://video/12?w=1080&h=1920"))
        let clip = try #require(clips.media(forSlot: 0), "the bundle carries no clips")
        #expect(MockMediaFixtures.isVideoURL(clip.url))
        #expect(MockMediaFixtures.isVideoURL("https://example.com/streams/master.m3u8"))
        #expect(MockMediaFixtures.isVideoURL("https://example.com/clips/intro.mp4"))
        // A query item (the map's kind stamp, say) must not hide the
        // extension: detection reads the path, not the whole string.
        #expect(MockMediaFixtures.isVideoURL("https://example.com/clips/intro.mp4?mock-kind=video"))
    }

    @Test func doesNotMistakeImagesForVideo() throws {
        #expect(!MockMediaFixtures.isVideoURL("mock://media/3?w=1080&h=1080"))
        #expect(!MockMediaFixtures.isVideoURL(MockMediaFixtures.imageURL(index: 0, width: 100, height: 100)))
        let photo = try #require(MockPhotoCatalog.shared.photo(forSlot: 0), "the bundle carries no photos")
        #expect(!MockMediaFixtures.isVideoURL(photo.media.url))
    }

    /// HLS must declare the manifest type rather than a `video/*` one, so the
    /// client's real routing rule is exercised instead of side-stepped.
    @Test func hlsDeclaresManifestMimeType() {
        #expect(MockMediaFixtures.mimeType(for: "https://example.com/streams/master.m3u8")
            == "application/vnd.apple.mpegurl")
        #expect(MockMediaFixtures.mimeType(for: "https://example.com/streams/variant.m3u8?token=1")
            == "application/vnd.apple.mpegurl")
    }

    @Test func progressiveAndImageMimeTypes() throws {
        #expect(MockMediaFixtures.mimeType(for: "https://example.com/clips/intro.mp4") == "video/mp4")
        #expect(MockMediaFixtures.mimeType(for: "mock://video/1?w=10&h=10") == "video/mp4")
        let clip = try #require(clips.media(forSlot: 0), "the bundle carries no clips")
        #expect(MockMediaFixtures.mimeType(for: clip.url) == "video/mp4")
        #expect(MockMediaFixtures.mimeType(for: "mock://media/1?w=10&h=10") == "image/png")
        #expect(MockMediaFixtures.mimeType(for: "https://picsum.photos/id/1/10/10") == "image/jpeg")
        // The bundled galleries are JPEG files.
        let photo = try #require(MockPhotoCatalog.shared.photo(forSlot: 0), "the bundle carries no photos")
        #expect(MockMediaFixtures.mimeType(for: photo.media.url) == "image/jpeg")
    }

    // MARK: - The clip catalog

    /// Declared dimensions drive pre-layout, so a zero would divide badly.
    @Test func everyClipDeclaresUsableDimensions() throws {
        try #require(!clips.clips.isEmpty, "the bundle carries no clips")
        for clip in clips.clips {
            #expect(clip.width > 0 && clip.height > 0, "bad dimensions for \(clip.id)")
        }
    }

    /// Two tiles on one URL is a hazard for the URL-keyed surface lookup in
    /// `VideoPlaybackController.attachSurface`, which resolves to the first
    /// view playing that asset.
    @Test func clipIDsAreUnique() {
        let ids = clips.clips.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The clips carry the shape coverage the public films never could: they
    /// were all landscape, so portrait video had to be synthesized.
    @Test func clipsCoverPortraitLandscapeAndSquare() {
        let aspects = clips.clips.map { Double($0.width) / Double($0.height) }
        #expect(aspects.contains { (0.95...1.05).contains($0) }, "no square clip")
        #expect(aspects.contains { $0 > 1.05 }, "no landscape clip")
        #expect(aspects.contains { $0 < 0.95 }, "no portrait clip")
    }

    // MARK: - Dataset seeding

    /// Under `.realAssets`, every video — a post's head or a collection page —
    /// is one of the bundled clips. Nothing else plays in the mock.
    @Test func everyRealAssetVideoIsABundledClip() throws {
        try #require(!clips.clips.isEmpty, "the bundle carries no clips")
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        var checked = 0
        for post in dataset.posts {
            for media in allMedia(of: post) where MockMediaFixtures.isVideoURL(media.url) {
                let url = try #require(URL(string: media.url))
                #expect(clips.clip(for: url) != nil, "\(post.postID) plays a non-clip video: \(media.url)")
                checked += 1
            }
        }
        #expect(checked > 0, "no video landed in the real-asset corpus")
    }

    /// No public media survives anywhere in either catalog: every post's media
    /// is a bundled file, never a film, a manifest or a stock photograph.
    @Test func noCatalogSeedsRemotePostMedia() {
        for dataset in [MockSocialDataset(), MockSocialDataset(mediaCatalog: .realAssets)] {
            for post in dataset.posts {
                for media in allMedia(of: post) {
                    #expect(!media.url.hasPrefix("http"), "\(post.postID) seeds remote media: \(media.url)")
                }
            }
        }
    }

    /// The two catalogs differ in their AVATARS only: every post's media is the
    /// same clip or photo at the same slot whichever is selected, pages
    /// included.
    @Test func bothCatalogsSeedTheSamePostMedia() {
        let synthetic = MockSocialDataset()
        let real = MockSocialDataset(mediaCatalog: .realAssets)
        for (lhs, rhs) in zip(synthetic.posts, real.posts) {
            #expect(allMedia(of: lhs).map(\.url) == allMedia(of: rhs).map(\.url),
                    "\(lhs.postID) carries different media per catalog")
        }
    }

    /// Every media piece is either a bundled photograph or a bundled clip, in
    /// both catalogs — no seed group may invent its own.
    ///
    /// The "just arrived" group once seeded `mock://media/new-N`
    /// unconditionally, so the newest posts — the first pages the feed opens
    /// on — kept their synthesized placeholders under the flag. Reported as
    /// "some posts render as a plain solid colour with `-rich-media`".
    @Test func everyPostDrawsItsMediaFromTheBundledCatalogs() throws {
        try #require(!clips.clips.isEmpty, "the bundle carries no clips")
        try #require(!MockPhotoCatalog.shared.photos.isEmpty, "the bundle carries no photos")
        for dataset in [MockSocialDataset(), MockSocialDataset(mediaCatalog: .realAssets)] {
            for post in dataset.posts {
                for media in allMedia(of: post) {
                    let url = URL(string: media.url)
                    let isPhoto = url.flatMap { MockPhotoCatalog.shared.photo(for: $0) } != nil
                    let isClip = url.flatMap { clips.clip(for: $0) } != nil
                    #expect(isPhoto || isClip, "\(post.postID) bypasses the catalogs: \(media.url)")
                }
            }
        }
    }

    /// The arrivals specifically, because they are the group that regressed
    /// and the one a corpus-wide sweep can hide: they are a handful of posts
    /// among 120, so a single missed branch is under 5% of the assertions above.
    @Test func theJustArrivedPostsHonourTheRealAssetCatalog() {
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        let arrivals = dataset.posts.filter { $0.postID.hasPrefix("post-new-") }
        #expect(!arrivals.isEmpty)
        for post in arrivals {
            for media in allMedia(of: post) {
                #expect(!media.url.hasPrefix("mock://media/new-"),
                        "\(post.postID) still seeds an ad-hoc placeholder")
                #expect(!media.url.hasPrefix("mock://video/new-"),
                        "\(post.postID) still seeds an ad-hoc placeholder")
                #expect(!media.url.hasPrefix("mock://video/cap-"),
                        "\(post.postID) still seeds an ad-hoc placeholder")
            }
        }
    }

    /// A gallery's clip pages are DIFFERENT clips: the pool keeps one player
    /// per asset, so two pages on one file would hide the very duplication the
    /// galleries exist to catch.
    @Test func noGalleryRepeatsAClip() {
        for catalog in [MockSocialDataset.MediaCatalog.synthetic, .realAssets] {
            let dataset = MockSocialDataset(mediaCatalog: catalog)
            for post in dataset.posts where !post.extraMedia.isEmpty {
                let videos = allMedia(of: post).map(\.url).filter(MockMediaFixtures.isVideoURL)
                #expect(Set(videos).count == videos.count, "\(post.postID) repeats a clip: \(videos)")
            }
        }
    }

    /// …and the default catalog stays entirely offline, which is what keeps
    /// CI and previews network-free.
    @Test func theSyntheticCatalogNeverReachesTheNetwork() {
        let dataset = MockSocialDataset()
        for post in dataset.posts {
            for media in allMedia(of: post) {
                #expect(media.url.hasPrefix("mock://"),
                        "\(post.postID) escapes the offline catalog: \(media.url)")
            }
        }
    }

    @Test func imageURLsAreDeterministicAndCarryRequestedSize() {
        let first = MockMediaFixtures.imageURL(index: 7, width: 1080, height: 1350)
        #expect(first == MockMediaFixtures.imageURL(index: 7, width: 1080, height: 1350))
        #expect(first.hasSuffix("/1080/1350"))
    }

    /// The load-bearing guarantee: the default dataset never reaches the
    /// network. If this fails, the whole unit suite silently becomes
    /// network-dependent.
    @Test func syntheticCatalogIsTheDefaultAndStaysOffline() {
        let dataset = MockSocialDataset()
        #expect(dataset.mediaCatalog == .synthetic)
        for post in dataset.posts {
            #expect(post.media.map { $0.url.hasPrefix("mock://") } ?? true)
        }
        for author in dataset.authors where !author.avatarURL.isEmpty {
            #expect(author.avatarURL.hasPrefix("mock://"))
        }
    }

    /// The corpus seeds every banner shape: landscape avatars (a band),
    /// portrait ones (a poster), and authors with none (no banner).
    @Test func authorsComeInEveryBannerShape() {
        let dataset = MockSocialDataset()
        let shapes = dataset.authors.indices.map { MockSocialDataset.avatarShape(index: $0) }
        #expect(shapes.contains { $0 == nil })
        #expect(shapes.contains { $0.map { $0.0 > $0.1 } == true })
        #expect(shapes.contains { $0.map { $0.0 < $0.1 } == true })
        #expect(MockSocialDataset.avatarShape(index: 0)?.0 == 1600)
        #expect(MockSocialDataset.avatarShape(index: 1)?.1 == 1600)
        #expect(MockSocialDataset.avatarShape(index: 3) == nil)
        // And the URL says the shape it was given.
        #expect(dataset.authors[0].avatarURL.hasSuffix("w=1600&h=900"))
        #expect(dataset.authors[3].avatarURL.isEmpty)
    }

    /// `-rich-media` still means real AVATARS — the one thing it swaps — and
    /// the corpus still carries both kinds of post media.
    @Test func realAssetCatalogSeedsRemoteAvatarsOverBundledMedia() {
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        #expect(dataset.mediaCatalog == .realAssets)
        #expect(dataset.authors.allSatisfy { $0.avatarURL.isEmpty || $0.avatarURL.hasPrefix("https://") })
        #expect(dataset.authors.contains { $0.avatarURL.hasPrefix("https://") })

        #expect(dataset.posts.contains { $0.media.map { MockMediaFixtures.isVideoURL($0.url) } ?? false })
        #expect(dataset.posts.contains { $0.media?.url.hasPrefix(MockPhotoCatalog.scheme) == true })
    }

    /// ⚠️ THE AVATARS ARE EXACTLY WHAT THEY WERE — the product asked for them
    /// kept while every post picture changed. Pinned URL for URL, in both
    /// catalogs, so a later media change cannot take them along by accident.
    @Test func avatarsAreUnchanged() {
        let synthetic = MockSocialDataset()
        let real = MockSocialDataset(mediaCatalog: .realAssets)
        for index in synthetic.authors.indices {
            guard let shape = MockSocialDataset.avatarShape(index: index) else {
                #expect(synthetic.authors[index].avatarURL.isEmpty)
                #expect(real.authors[index].avatarURL.isEmpty)
                continue
            }
            #expect(synthetic.authors[index].avatarURL == "mock://avatar/\(index)?w=\(shape.0)&h=\(shape.1)")
            #expect(real.authors[index].avatarURL
                == MockMediaFixtures.imageURL(index: index, width: shape.0, height: shape.1))
        }
        #expect(MockMediaFixtures.imageURL(index: 0, width: 1600, height: 900)
            == "https://picsum.photos/id/1015/1600/900")
    }

    /// A video's declared size must equal its clip's true encoded size, in the
    /// URL and in the tuple. Declaring the slot's layout shape over a real
    /// encode is precisely the content-blind crop
    /// `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` describes.
    @Test func realVideoPostsDeclareTheClipsTrueDimensions() throws {
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        var checked = 0
        for post in dataset.posts {
            for media in allMedia(of: post) {
                guard let url = URL(string: media.url), let clip = clips.clip(for: url) else { continue }
                #expect(media.width == clip.width && media.height == clip.height,
                        "declared \(media.width)x\(media.height) but \(clip.id) is \(clip.width)x\(clip.height)")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first { $0.name == "w" }?.value == String(clip.width))
                #expect(query.first { $0.name == "h" }?.value == String(clip.height))
                checked += 1
            }
        }
        #expect(checked > 0, "no clip landed in the dataset")
    }

    /// Both catalogs must keep the same post/author/text skeleton — only the
    /// avatar URLs differ — so a bug can't hide behind a different corpus.
    @Test func catalogsDifferOnlyInAvatars() {
        let synthetic = MockSocialDataset()
        let real = MockSocialDataset(mediaCatalog: .realAssets)
        #expect(synthetic.posts.count == real.posts.count)
        #expect(synthetic.posts.map(\.postID) == real.posts.map(\.postID))
        #expect(synthetic.posts.map(\.caption) == real.posts.map(\.caption))
        #expect(synthetic.posts.map(\.parentID) == real.posts.map(\.parentID))
        #expect(synthetic.pinnedPostIDs == real.pinnedPostIDs)
        // Same posts carry media in both, with the same number of pages.
        #expect(synthetic.posts.map { $0.media != nil } == real.posts.map { $0.media != nil })
        #expect(synthetic.posts.map(\.extraMedia.count) == real.posts.map(\.extraMedia.count))
    }

    // MARK: - Map pins

    /// A pin's single URL must always be something the surface can actually
    /// render: the client treats every pin as an image, so handing it a video
    /// URL paints a blank pin.
    ///
    /// ⚠️ AND IT MUST BE A FRAME OF THE POST'S OWN CLIP. This used to be
    /// satisfied by a stock photograph chosen from the LENGTH of the video's
    /// URL, which renders perfectly and is a picture of somewhere else — filmed
    /// on the map as a marker whose post was a build log flying a photograph of
    /// a sky. Renderable is necessary and was never sufficient.
    @Test func videoPinsCarryAFrameOfTheirOwnClip() throws {
        // A clip with a baked sheet answers the sheet's own cell 0.
        let clip = try #require(clips.clip(forSlot: 0), "the bundle carries no clips")
        let clipURL = try #require(clips.media(forSlot: 0)).url
        let sheeted = MockGeoDiscoveryService.pinURL(forMediaURL: clipURL, catalog: .realAssets)
        #expect(sheeted.hasPrefix("\(MockMediaFixtures.previewPosterScheme)\(clip.id)"))
        #expect(sheeted.contains(MockGeoDiscoveryService.videoKindMarker),
                "the kind stamp is the map's only signal that a pin is a video")
        #expect(MockMediaFixtures.mimeType(for: sheeted).hasPrefix("image/"))
        #expect(!MockMediaFixtures.isVideoURL(sheeted))

        // A video without one answers its own first frame, decoded from the asset.
        let unbaked = "mock://video/7?w=1080&h=1920"
        let bare = MockGeoDiscoveryService.pinURL(forMediaURL: unbaked, catalog: .realAssets)
        #expect(MockMediaFixtures.frameZeroSource(of: bare) == unbaked)
        #expect(bare.contains(MockGeoDiscoveryService.videoKindMarker))
        #expect(MockMediaFixtures.mimeType(for: bare).hasPrefix("image/"))
        #expect(!MockMediaFixtures.isVideoURL(bare),
                "the encoded source must not make a still look like a clip")
    }

    /// Every video pin of the real-asset corpus describes ITS post's clip.
    @Test func everyRealAssetVideoPinNamesItsOwnClip() throws {
        try #require(!clips.clips.isEmpty, "the bundle carries no clips")
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        for post in dataset.posts {
            guard let media = post.media, MockMediaFixtures.isVideoURL(media.url),
                  let clip = MockMediaFixtures.bakedClip(for: media.url)
            else { continue }
            let pin = MockGeoDiscoveryService.pinURL(forMediaURL: media.url, catalog: .realAssets)
            #expect(pin == "\(MockMediaFixtures.previewPosterScheme)\(clip)?\(MockGeoDiscoveryService.videoKindMarker)",
                    "\(post.postID) pins \(pin)")
        }
    }

    /// The synthetic catalog carries renderable `mock://` URLs, but a video is
    /// still a video: an image pipeline decodes nothing from one, which is the
    /// empty marker filmed on the map.
    @Test func syntheticVideoPinsAlsoCarryAFrame() throws {
        let clipURL = try #require(clips.media(forSlot: 0), "the bundle carries no clips").url
        let url = MockGeoDiscoveryService.pinURL(forMediaURL: clipURL, catalog: .synthetic)
        #expect(url.hasPrefix(MockMediaFixtures.previewPosterScheme))
        #expect(!url.contains(MockGeoDiscoveryService.videoKindMarker),
                "the synthetic catalog never stamped, and stamping would reclassify every pin")
    }

    @Test func imagePinsAreUntouched() {
        let image = MockMediaFixtures.imageURL(index: 2, width: 400, height: 400)
        #expect(MockGeoDiscoveryService.pinURL(forMediaURL: image, catalog: .realAssets) == image)
    }

    /// The synthetic catalog already carries renderable `mock://` URLs for both
    /// kinds, so a video that names no baked clip passes through untouched.
    @Test func syntheticPinsAreUntouched() {
        let video = "mock://video/6?w=1080&h=1920"
        #expect(MockGeoDiscoveryService.pinURL(forMediaURL: video, catalog: .synthetic) == video)
    }

    @Test func realCatalogIsDeterministic() {
        let first = MockSocialDataset(mediaCatalog: .realAssets)
        let second = MockSocialDataset(mediaCatalog: .realAssets)
        #expect(first.posts.compactMap { $0.media?.url } == second.posts.compactMap { $0.media?.url })
    }
}

/// A marker's preview is a sample of the POST'S OWN footage.
///
/// ⚠️ The seed used to guard on `post.media != nil`, so every photograph got a
/// sprite sheet too — an animated marker playing an unrelated clip in front of a
/// post that is a still. The annotation and the post stopped describing the same
/// thing, which is the one thing a preview exists to do.
struct MapPreviewSheetSeedTests {
    private func dataset() -> MockSocialDataset {
        MockSocialDataset(postCount: 120, mediaCatalog: .realAssets)
    }

    /// The shipped manifest's shape: one opening sheet per clip, `clip-NN-0`.
    private var catalogue: [String] {
        MockClipCatalog.shared.clips.map { "\($0.id)-0" }
    }

    @Test func aSheetIsSeededExactlyWhenTheClipHasOne() throws {
        try #require(!MockClipCatalog.shared.clips.isEmpty, "the bundle carries no clips")
        let data = dataset()
        let sheets = data.previewSheetIDsByPostID(catalogue: catalogue)
        #expect(!sheets.isEmpty, "a corpus of baked clips must seed some previews")

        for post in data.posts {
            let seeded = sheets[post.postID] != nil
            guard let media = post.media, MockMediaFixtures.isVideoURL(media.url) else {
                #expect(!seeded, "\(post.postID) is not a video and must not wear a preview")
                continue
            }
            let baked = MockMediaFixtures.bakedClip(for: media.url) != nil
            #expect(seeded == baked,
                    "\(post.postID) media=\(media.url) seeded=\(seeded) baked=\(baked)")
        }
    }

    /// Every video post wears its OWN clip's opening sheet — every one, since
    /// every video in the corpus is a baked clip now.
    @Test func everyVideoPostWearsItsOwnClipsOpeningSheet() throws {
        try #require(!MockClipCatalog.shared.clips.isEmpty, "the bundle carries no clips")
        let data = dataset()
        let sheets = data.previewSheetIDsByPostID(catalogue: catalogue)
        var checked = 0
        for post in data.posts {
            guard let media = post.media, MockMediaFixtures.isVideoURL(media.url) else { continue }
            let url = try #require(URL(string: media.url))
            let clip = try #require(MockClipCatalog.shared.clip(for: url), "\(post.postID) is not a clip")
            #expect(sheets[post.postID] == "\(clip.id)-0", "\(post.postID) wears \(sheets[post.postID] ?? "nil")")
            checked += 1
        }
        #expect(checked > 0)
    }

    /// A video with no baked sheet gets NONE, and the marker falls back to its
    /// cover. Handing it an arbitrary clip is the defect this replaced.
    @Test func anUnbakedVideoGetsNoSheetAtAll() throws {
        #expect(MockSocialDataset.previewSheet(
            for: "https://example.com/streams/master.m3u8", in: catalogue, index: 0
        ) == nil)
        #expect(MockSocialDataset.previewSheet(
            for: "mock://video/square-1?w=1080&h=1080", in: catalogue, index: 0
        ) == nil)
        #expect(MockMediaFixtures.bakedClip(for: "mock://video/square-1?w=1080&h=1080") == nil)
        // A real clip whose sheet is missing from the manifest gets none either,
        // rather than a neighbour's.
        let clipURL = try #require(MockClipCatalog.shared.media(forSlot: 0), "the bundle carries no clips").url
        let clip = try #require(MockClipCatalog.shared.clip(forSlot: 0))
        let others = catalogue.filter { $0 != "\(clip.id)-0" }
        #expect(MockSocialDataset.previewSheet(for: clipURL, in: others, index: 0) == nil)
    }

    /// And it is a preview of ITS clip's OPENING segment, not of an arbitrary
    /// clip nor of whichever segment the bundle listed first.
    @Test func aSheetIsAlwaysItsOwnClipsOpening() throws {
        let first = try #require(MockClipCatalog.shared.clip(forSlot: 0), "the bundle carries no clips")
        let second = try #require(MockClipCatalog.shared.clip(forSlot: 1))
        let firstURL = try #require(MockClipCatalog.shared.media(forSlot: 0)).url
        let secondURL = try #require(MockClipCatalog.shared.media(forSlot: 1)).url
        let catalogue = ["\(first.id)-11", "\(first.id)-2", "\(first.id)-0", "\(second.id)-1", "\(second.id)-0"]

        #expect(MockSocialDataset.previewSheet(for: firstURL, in: catalogue, index: 0) == "\(first.id)-0")
        #expect(MockSocialDataset.previewSheet(for: secondURL, in: catalogue, index: 1) == "\(second.id)-0")
    }
}
