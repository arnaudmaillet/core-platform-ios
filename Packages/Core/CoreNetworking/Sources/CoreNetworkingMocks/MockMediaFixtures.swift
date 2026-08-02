import Foundation

/// Real, public media assets for mock mode — the **opt-in** counterpart to the
/// synthesized `mock://` seeds.
///
/// The default mock dataset stays entirely offline (`MockSocialDataset` seeds
/// `mock://` URLs that `PlaceholderImageFetcher` / `PlaceholderVideoFetcher`
/// render locally), because the unit suite, previews, and CI all run against
/// `MockBackend()` and must not depend on the network. These fixtures are
/// selected explicitly via `MockSocialDataset.MediaCatalog.realAssets`
/// (launch argument `-rich-media`) when you want to exercise the pipeline
/// against real encodes: ABR ladders, HLS manifests, progressive MP4 range
/// requests, and true photographic decode cost.
///
/// **Every URL here was verified reachable on 2026-07-30** (HTTP 206 to a range
/// request, correct `Content-Type`), and every declared `width`/`height` was
/// read off the asset with `ffprobe` rather than assumed — the client
/// pre-layouts from these numbers, so a wrong one shows up as a crop.
///
/// Two known-dead sources are recorded in `deadSources` so nobody re-adds them.
public enum MockMediaFixtures {
    /// A video fixture and the dimensions the contract should declare for it.
    public struct Video: Sendable, Equatable {
        public let url: String
        public let width: Int
        public let height: Int
        /// False for the synthesized `mock://` entries that fill the aspect
        /// ratios no public asset covers (see `videos`).
        public let isRemote: Bool

        public init(url: String, width: Int, height: Int, isRemote: Bool = true) {
            self.url = url
            self.width = width
            self.height = height
            self.isRemote = isRemote
        }
    }

    // MARK: - HLS

    /// Apple's official BipBop test stream. **The reference fixture for
    /// `preferredPeakBitRate` work**: a genuine 5-rung ladder whose bottom rung
    /// is small enough to be a real grid-cell cap and whose top rung is 1080p,
    /// so capping and un-capping on one `AVPlayerItem` is observable.
    ///
    ///   416x234  @  264 kbps   ← grid-cell cap target
    ///   640x360  @  578 kbps
    ///   960x540  @  916 kbps
    ///  1280x720  @ 1030 kbps
    ///  1920x1080 @ 1924 kbps   ← what a hero-zoomed cell should climb to
    ///
    /// Declared dimensions are the top rung's; ABR picks the rung at runtime.
    public static let appleBipBop16x9 = Video(
        url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
        width: 1920, height: 1080
    )

    /// Apple's Advanced fMP4 example — fragmented MP4 segments rather than TS,
    /// which is the segment format `dev/PHASE3_VIDEO_BACKEND.md` §2 recommends
    /// our own transcode worker emit. Worth keeping distinct from BipBop so the
    /// player is exercised against both segment containers.
    public static let appleAdvancedFMP4 = Video(
        url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
        width: 1920, height: 1080
    )

    /// Unified Streaming's Tears of Steel. A second, independent CDN and a
    /// noticeably wider ladder floor (224x100 @ 493 kbps), useful for checking
    /// that our cap logic doesn't assume Apple's rung spacing. 21:9-ish, so it
    /// also lands an unusual aspect in the grid.
    public static let tearsOfSteel = Video(
        url: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8",
        width: 1680, height: 750
    )

    public static let hlsStreams: [Video] = [appleBipBop16x9, appleAdvancedFMP4, tearsOfSteel]

    // MARK: - Progressive MP4

    /// 1280x720, 10 s, ~1 MB. Short and small enough to loop cleanly — the
    /// closest public analog to the full-quality end of a post video.
    public static let bigBuckBunny720 = Video(
        url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4",
        width: 1280, height: 720
    )

    /// 854x480, 52 s. Long enough that a hero transition's playhead continuity
    /// is obvious — if the item is swapped, the restart to 0:00 is unmissable.
    public static let sintelTrailer = Video(
        url: "https://media.w3.org/2010/05/sintel/trailer.mp4",
        width: 854, height: 480
    )

    /// 853x480, ~10 min. The long-running fixture: leave a cell playing, zoom
    /// in and out, and confirm `currentTime` kept advancing across both legs.
    public static let longRunning = Video(
        url: "https://media.w3.org/2010/05/bunny/movie.mp4",
        width: 853, height: 480
    )

    /// 320x176, 10 s, tiny. Stands in for the `MEDIA_RENDITION_KIND_PREVIEW_LOOP`
    /// rendition proposed in `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md`:
    /// the cheap looping clip a **map pin** plays. Nothing else should use it.
    ///
    /// The `mock-kind=video` query item is a marker, not a server parameter —
    /// it lets `GeoDiscoveryRepository.mediaKind(for:)` keep recognising a
    /// video pin by URL shape under `-maps-force-video` now that the URL is no
    /// longer `mock://video/…`. The origin ignores it (verified 206).
    public static let mapPreviewLoop = Video(
        url: "https://www.w3schools.com/html/mov_bbb.mp4?mock-kind=video",
        width: 320, height: 176
    )

    // MARK: - Composed video catalog

    /// The video assignment used by `MediaCatalog.realAssets`, in order.
    ///
    /// **9:16 where it can be.** The synthetic entries are all vertical, which
    /// is the shape a Reels/TikTok-style backend would actually serve. The real
    /// encodes CANNOT follow: they are fixed public files and every one is
    /// landscape, so restating them as 9:16 would mis-drive pre-layout and crop
    /// the subject — the exact defect `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md`
    /// is about. They stay landscape and earn their place by being the only
    /// fixtures with a real ABR ladder.
    ///
    /// **Mixed by design.** No stable public source vends portrait or square
    /// test video — every candidate checked was landscape, and the two most
    /// commonly cited buckets are now dead (see `deadSources`). Rather than
    /// declare a portrait `width`/`height` for a landscape encode (which would
    /// mis-drive pre-layout and crop the subject — exactly the bug
    /// `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` is about), the portrait and
    /// square slots keep the synthesized `mock://video/…` clips, which
    /// `PlaceholderVideoFetcher` renders at whatever aspect the `w`/`h` query
    /// asks for.
    ///
    /// **Every entry that can autoplay is a real encode** (#83).
    ///
    /// This list used to interleave synthesized `mock://video/vertical-*`
    /// clips to cover portrait, and that made `-rich-media` unable to do the
    /// one job it exists for. `PostGridMosaic.arrangedForMotion` places
    /// portrait media in portrait bricks, so the synthetic entries landed in
    /// exactly the tall tiles a hero flight departs from — and those clips
    /// decode to black through `AVPlayerItemVideoOutput` (luma=16 against an
    /// asset whose every frame is a solid hue; see `VideoFrameRenderer`). Every
    /// visual check of the flight was therefore judging a black source and
    /// could not distinguish a working renderer from a broken one.
    ///
    /// The square entry stays: `autoplaysInGrid` excludes square media, so it
    /// never plays, never renders, and remains the negative case for the
    /// "square media never autoplays" rule.
    ///
    /// **The trade, stated plainly.** Portrait video coverage leaves this
    /// catalog, because every stable public encode is landscape and declaring
    /// one as 9:16 would mis-drive pre-layout and crop the subject — the exact
    /// defect `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md` is about. Aspect coverage
    /// now belongs to the DEFAULT synthetic catalog, which renders any `w`/`h`
    /// asked of it and is what the unit suite and previews run against anyway.
    /// So the two catalogs each do one job: synthetic covers shape, real covers
    /// streaming, ABR and decode.
    ///
    /// Entries are distinct on purpose — see the note on `attachSurface` about
    /// URL-keyed lookup when two tiles play the same asset.
    public static let videos: [Video] = [
        appleBipBop16x9,
        bigBuckBunny720,
        tearsOfSteel,
        sintelTrailer,
        appleAdvancedFMP4,
        longRunning,
        Video(url: "mock://video/square-1?w=1080&h=1080", width: 1080, height: 1080, isRemote: false)
    ]

    // MARK: - Images

    /// Picsum ids verified to resolve. Picsum serves a real photograph at an
    /// exact requested size, so unlike the video catalog the image fixtures
    /// cover every aspect ratio honestly — the returned pixels really are the
    /// dimensions we declare.
    static let picsumIDs = [1015, 1025, 1039, 1043, 1050, 237, 433, 866, 1074, 1084]

    /// A real photograph at exactly `width`×`height`. Deterministic: the same
    /// `index` always yields the same photo, so runs stay comparable.
    public static func imageURL(index: Int, width: Int, height: Int) -> String {
        let id = picsumIDs[abs(index) % picsumIDs.count]
        return "https://picsum.photos/id/\(id)/\(width)/\(height)"
    }

    /// A real portrait photo for an author avatar.
    public static func avatarURL(index: Int) -> String {
        imageURL(index: index, width: 128, height: 128)
    }

    // MARK: - Classification

    /// Whether a seeded media URL denotes video, across both catalogs. The
    /// synthetic catalog encodes it in the host (`mock://video/…`); the real
    /// catalog has to be recognised by extension, since a CDN URL carries no
    /// such marker.
    public static func isVideoURL(_ url: String) -> Bool {
        if url.contains("mock://video/") { return true }
        let path = URLComponents(string: url)?.path.lowercased() ?? url.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
    }

    /// The MIME type a mock attachment should declare for `url`.
    ///
    /// HLS manifests get `application/vnd.apple.mpegurl` — deliberately not a
    /// `video/*` type, so the client's real routing rule
    /// (`MediaCore.MediaKind`) is exercised rather than side-stepped.
    public static func mimeType(for url: String) -> String {
        let path = URLComponents(string: url)?.path.lowercased() ?? url.lowercased()
        if path.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if isVideoURL(url) { return "video/mp4" }
        return url.hasPrefix("mock://") ? "image/png" : "image/jpeg"
    }

    // MARK: - Provenance

    /// Sources that look right in search results but do **not** work — checked
    /// 2026-07-30. Recorded so they don't get re-added.
    ///
    /// - `commondatastorage.googleapis.com/gtv-videos-bucket/…` → **403**.
    ///   The single most widely cited sample-video bucket on the web; it is no
    ///   longer publicly readable. `storage.googleapis.com/gtv-videos-bucket/…`
    ///   is 403 too.
    /// - `download.blender.org/peach/bigbuckbunny_movies/…` → **404**.
    public static let deadSources = [
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
        "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
        "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
    ]
}
