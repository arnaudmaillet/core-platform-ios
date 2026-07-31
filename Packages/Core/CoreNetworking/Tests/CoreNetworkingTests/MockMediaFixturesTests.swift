import Foundation
import Testing
@testable import CoreNetworkingMocks

/// Covers the fixture catalog and the two-catalog seeding rule. Deliberately
/// makes **no network calls**: reachability of the fixture URLs was verified
/// out-of-band (see `MockMediaFixtures`' doc comment), and a test that hit the
/// live CDNs would make the suite flaky and offline-hostile — the exact
/// property the synthetic default exists to protect.
struct MockMediaFixturesTests {

    // MARK: - Classification

    @Test func recognisesVideoAcrossBothCatalogs() {
        #expect(MockMediaFixtures.isVideoURL("mock://video/12?w=1080&h=1920"))
        #expect(MockMediaFixtures.isVideoURL(MockMediaFixtures.appleBipBop16x9.url))
        #expect(MockMediaFixtures.isVideoURL(MockMediaFixtures.bigBuckBunny720.url))
        // The preview loop carries a query marker; extension detection must
        // read the path, not the whole string.
        #expect(MockMediaFixtures.isVideoURL(MockMediaFixtures.mapPreviewLoop.url))
    }

    @Test func doesNotMistakeImagesForVideo() {
        #expect(!MockMediaFixtures.isVideoURL("mock://media/3?w=1080&h=1080"))
        #expect(!MockMediaFixtures.isVideoURL(MockMediaFixtures.imageURL(index: 0, width: 100, height: 100)))
    }

    /// HLS must declare the manifest type rather than a `video/*` one, so the
    /// client's real routing rule is exercised instead of side-stepped.
    @Test func hlsDeclaresManifestMimeType() {
        #expect(MockMediaFixtures.mimeType(for: MockMediaFixtures.appleBipBop16x9.url)
            == "application/vnd.apple.mpegurl")
        #expect(MockMediaFixtures.mimeType(for: MockMediaFixtures.tearsOfSteel.url)
            == "application/vnd.apple.mpegurl")
    }

    @Test func progressiveAndImageMimeTypes() {
        #expect(MockMediaFixtures.mimeType(for: MockMediaFixtures.bigBuckBunny720.url) == "video/mp4")
        #expect(MockMediaFixtures.mimeType(for: "mock://video/1?w=10&h=10") == "video/mp4")
        #expect(MockMediaFixtures.mimeType(for: "mock://media/1?w=10&h=10") == "image/png")
        #expect(MockMediaFixtures.mimeType(for: "https://picsum.photos/id/1/10/10") == "image/jpeg")
    }

    // MARK: - Catalog composition

    /// Everything in the real-asset catalog that can AUTOPLAY must be a real
    /// encode.
    ///
    /// This is the invariant `-rich-media` exists to provide, and it was
    /// silently untrue: synthesized portrait clips landed in the tall bricks
    /// (`arrangedForMotion` puts portrait media in portrait bricks), which are
    /// exactly the tiles a hero flight departs from, and those clips decode to
    /// black through `AVPlayerItemVideoOutput`. Every visual check of the
    /// flight was judging a black source.
    ///
    /// Square is exempt because `autoplaysInGrid` excludes it — it never
    /// plays, so a synthetic entry there cannot be seen.
    @Test func everyAutoplayableRealAssetFixtureIsARealEncode() {
        for fixture in MockMediaFixtures.videos {
            let aspect = Double(fixture.width) / Double(fixture.height)
            let isSquare = (0.95...1.05).contains(aspect)
            if isSquare { continue }
            #expect(fixture.isRemote, "autoplayable fixture is synthetic: \(fixture.url)")
        }
    }

    /// Landscape and square still come from this catalog. Portrait coverage
    /// deliberately moved to the DEFAULT synthetic catalog: every stable public
    /// encode is landscape, and declaring one as 9:16 would mis-drive
    /// pre-layout and crop the subject.
    @Test func videoCatalogCoversLandscapeAndSquare() {
        let aspects = MockMediaFixtures.videos.map { Double($0.width) / Double($0.height) }
        #expect(aspects.contains { (0.95...1.05).contains($0) }, "no square video fixture")
        #expect(aspects.contains { $0 > 1.05 }, "no landscape video fixture")
    }

    /// Two posts sharing one URL is a hazard for the URL-keyed surface lookup
    /// in `VideoPlaybackController.attachSurface`, which resolves to the first
    /// view playing that asset. The dataset cycles this list, so duplicates
    /// here would put the same URL in two simultaneously visible tiles.
    @Test func videoCatalogHasNoDuplicateURLs() {
        let urls = MockMediaFixtures.videos.map(\.url)
        #expect(Set(urls).count == urls.count)
    }

    @Test func videoCatalogMixesRealAndSyntheticAssets() {
        #expect(MockMediaFixtures.videos.contains { $0.isRemote })
        #expect(MockMediaFixtures.videos.contains { !$0.isRemote })
        // Synthetic entries must stay on the scheme the placeholder fetcher
        // handles, or they would be routed to the network and 404.
        for fixture in MockMediaFixtures.videos where !fixture.isRemote {
            #expect(fixture.url.hasPrefix("mock://"))
        }
        for fixture in MockMediaFixtures.videos where fixture.isRemote {
            #expect(fixture.url.hasPrefix("https://"))
        }
    }

    /// Declared dimensions drive pre-layout, so a zero would divide badly and a
    /// swapped pair would crop the subject.
    @Test func everyFixtureDeclaresUsableDimensions() {
        for fixture in MockMediaFixtures.videos + MockMediaFixtures.hlsStreams {
            #expect(fixture.width > 0 && fixture.height > 0, "bad dimensions for \(fixture.url)")
        }
    }

    @Test func imageURLsAreDeterministicAndCarryRequestedSize() {
        let first = MockMediaFixtures.imageURL(index: 7, width: 1080, height: 1350)
        #expect(first == MockMediaFixtures.imageURL(index: 7, width: 1080, height: 1350))
        #expect(first.hasSuffix("/1080/1350"))
    }

    // MARK: - Dataset seeding

    /// The load-bearing guarantee: the default dataset never reaches the
    /// network. If this fails, the whole unit suite silently becomes
    /// network-dependent.
    @Test func syntheticCatalogIsTheDefaultAndStaysOffline() {
        let dataset = MockSocialDataset()
        #expect(dataset.mediaCatalog == .synthetic)
        for post in dataset.posts {
            #expect(post.media.map { $0.url.hasPrefix("mock://") } ?? true)
        }
        for author in dataset.authors {
            #expect(author.avatarURL.hasPrefix("mock://"))
        }
    }

    @Test func realAssetCatalogSeedsRemoteMedia() {
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        #expect(dataset.mediaCatalog == .realAssets)
        #expect(dataset.authors.allSatisfy { $0.avatarURL.hasPrefix("https://") })

        let remoteMedia = dataset.posts.compactMap(\.media).filter { $0.url.hasPrefix("https://") }
        #expect(!remoteMedia.isEmpty)
        #expect(dataset.posts.contains { $0.media.map { MockMediaFixtures.isVideoURL($0.url) } ?? false })
    }

    /// A video post's declared size must equal the fixture's true encoded size.
    /// Declaring `mediaShapes` over a real landscape encode is precisely the
    /// content-blind crop `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` describes.
    @Test func realVideoPostsDeclareTheFixturesTrueDimensions() {
        let dataset = MockSocialDataset(mediaCatalog: .realAssets)
        let byURL = Dictionary(
            MockMediaFixtures.videos.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var checked = 0
        for post in dataset.posts {
            guard let media = post.media, let fixture = byURL[media.url] else { continue }
            #expect(media.width == fixture.width && media.height == fixture.height,
                    "declared \(media.width)x\(media.height) but \(fixture.url) is \(fixture.width)x\(fixture.height)")
            checked += 1
        }
        #expect(checked > 0, "no video fixtures landed in the dataset")
    }

    /// Both catalogs must keep the same post/author/text skeleton — only the
    /// media URLs differ — so a bug can't hide behind a different corpus.
    @Test func catalogsDifferOnlyInMedia() {
        let synthetic = MockSocialDataset()
        let real = MockSocialDataset(mediaCatalog: .realAssets)
        #expect(synthetic.posts.count == real.posts.count)
        #expect(synthetic.posts.map(\.postID) == real.posts.map(\.postID))
        #expect(synthetic.posts.map(\.caption) == real.posts.map(\.caption))
        #expect(synthetic.posts.map(\.parentID) == real.posts.map(\.parentID))
        #expect(synthetic.pinnedPostIDs == real.pinnedPostIDs)
        // Same posts carry media in both.
        #expect(synthetic.posts.map { $0.media != nil } == real.posts.map { $0.media != nil })
    }

    // MARK: - Map pins

    /// A pin's single URL must always be something the surface can actually
    /// render. Without `-maps-force-video` the client treats every pin as an
    /// image, so handing it an HLS manifest or an MP4 paints a blank pin —
    /// caught in the simulator, and this is the regression guard.
    @Test func videoPinsCarryADecodableStillByDefault() throws {
        try #require(!MockGeoDiscoveryService.forcesMapVideo,
                     "run without -maps-force-video")
        let url = MockGeoDiscoveryService.pinURL(
            forMediaURL: MockMediaFixtures.appleBipBop16x9.url, catalog: .realAssets
        )
        #expect(!MockMediaFixtures.isVideoURL(url))
        #expect(MockMediaFixtures.mimeType(for: url).hasPrefix("image/"))
    }

    @Test func imagePinsAreUntouched() {
        let image = MockMediaFixtures.imageURL(index: 2, width: 400, height: 400)
        #expect(MockGeoDiscoveryService.pinURL(forMediaURL: image, catalog: .realAssets) == image)
    }

    /// The synthetic catalog already carries renderable `mock://` URLs for both
    /// kinds, so it must pass through untouched.
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
