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
    /// it lets `GeoDiscoveryRepository.kind(for:)` keep recognising a
    /// video pin by URL shape under `-maps-force-video` now that the URL is no
    /// longer `mock://video/…`. The origin ignores it.
    ///
    /// ⚠️ WAS `www.w3schools.com/html/mov_bbb.mp4`, AND THAT HOST NOW SERVES
    /// **403** TO NON-BROWSER CLIENTS. The note here used to read "the origin
    /// ignores it (verified 206)", which was true when it was written and
    /// silently stopped being true. Nothing in the app reports it: a 403 on a
    /// video is a page that stays black for ever, and because this clip is also
    /// in the POST catalogue below, the failure showed up as an ordinary post
    /// whose media never starts — filmed and reported as "a video in the mock
    /// that does not work".
    ///
    /// A fixture URL is a dependency on somebody else's hosting policy. When
    /// one of these goes quiet, check it with a ranged GET rather than a
    /// browser: `curl -o /dev/null -w '%{http_code}' -r 0-1023 <url>`.
    public static let mapPreviewLoop = Video(
        url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4?mock-kind=video",
        width: 640, height: 360
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
    /// ⚠️ ONLY WHAT DECODES. The three HLS ladders are gone.
    ///
    /// The table used to list seven. `AVAssetImageGenerator` opens neither the
    /// HLS ladders (they will not load as assets from a build machine) nor the
    /// w3 bunny mp4, which is 249 MB and answers -11821 "cannot decode". A
    /// fixture that cannot be decoded cannot be previewed, so every post
    /// carrying one had a marker with nothing honest to show — and, before the
    /// mapping became a table, wore a preview of somebody else's film instead.
    ///
    /// What is left is two real clips that both bake, so a video post's marker
    /// previews ITS OWN footage. The variety lost is variety that never
    /// rendered.
    public static let videos: [Video] = [
        bigBuckBunny720,
        sintelTrailer,
        // ⚠️ KEPT, and it is not a decode failure. This one is a deliberate
        // placeholder — the synthetic half of the catalogue, and the only square
        // aspect in it. Two suites pin both properties. It has no frames to bake
        // from, so a post carrying it wears its cover rather than a preview,
        // which is the ladder working rather than a gap in it.
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
    /// Which BAKED preview clip this fixture's footage is, or nil when none was
    /// baked from it.
    ///
    /// ⚠️ AN EXPLICIT TABLE, not a substring match on the url. Sniffing looked
    /// like it worked because two fixtures happen to carry their clip's name;
    /// the other five silently fell through to an arbitrary sheet, so most video
    /// markers previewed footage from a different film. A table cannot do that
    /// quietly — a fixture that is not in it has no sheet, and the marker shows
    /// its cover instead, which is the honest rung of the same ladder.
    ///
    /// `Tools/IconBaker` produced these from the fixtures themselves; the ones
    /// missing here are the HLS ladders and the synthetic clip, which
    /// `AVAssetImageGenerator` would not decode from this machine.
    /// The scheme a baked clip's poster is served under. The app resolves it
    /// from its own preview catalogue; nothing fetches it over the wire.
    public static let previewPosterScheme = "mock://preview/"

    /// The scheme a clip's OWN FIRST FRAME is served under, for clips that have
    /// no baked sheet — the HLS ladders and anything else `bakedClip` does not
    /// name. The app decodes it with `AVAssetImageGenerator` and the pipeline
    /// caches the result by URL, so it runs once per clip per session.
    ///
    /// ⚠️ IT EXISTS SO THE ANSWER IS NEVER A PHOTOGRAPH OF SOMEWHERE ELSE. A
    /// pin's single URL has to be something the surface can render, and the
    /// two ways to satisfy that are a frame of the post's own clip or a stock
    /// picture of something unrelated. The second was what shipped, and it put
    /// a sky on a marker whose post was a build log.
    public static let frameZeroScheme = "mock://frame0/"

    /// ⚠️ THE SOURCE IS PERCENT-ENCODED WHOLE, which is not decoration. Left
    /// readable, a request for `mock://frame0/?src=mock://video/7` contains the
    /// literal `mock://video/`, and `isVideoURL` — a substring test — would
    /// call the still a video. Encoding removes the substring rather than
    /// teaching every reader about the exception.
    public static func frameZeroURL(for videoURL: String) -> String {
        let encoded = videoURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? videoURL
        return "\(frameZeroScheme)?src=\(encoded)"
    }

    /// The clip a frame-zero request is about, or nil if it is not one.
    public static func frameZeroSource(of url: String) -> String? {
        guard url.hasPrefix(frameZeroScheme),
              let items = URLComponents(string: url)?.queryItems
        else { return nil }
        return items.first { $0.name == "src" }?.value
    }

    /// ⚠️ THREE OF THESE URLS ARE THE SAME FILM, and saying so is what puts
    /// sprite sheets back on the map.
    ///
    /// Only two clips have baked sheets (`App/Resources/MapPreviews`), and this
    /// table used to name exactly two URLs — so five of the seven video
    /// fixtures resolved to `nil` and their markers fell back to a cover. That
    /// was invisible while every media post was a video, because some visible
    /// marker almost always held one of the two; with the corpus back on
    /// honest thirds it became "the sprite sheets are gone from the
    /// annotations", measured as `sheets=0` with two resident and none bound.
    ///
    /// `bigBuckBunny720`, `longRunning` and `mapPreviewLoop` are all Big Buck
    /// Bunny at different encodes and lengths, so a sheet baked from one IS a
    /// sample of the others' own footage — which is the rule
    /// `previewSheetIDsByPostID` insists on. Sintel is a different film and
    /// keeps its own. The HLS ladders are left out on purpose: they are there
    /// to exercise manifest handling, and a still sampled from a variant
    /// stream is not obviously the post's own frame.
    public static func bakedClip(for url: String) -> String? {
        switch url {
        case bigBuckBunny720.url, longRunning.url, mapPreviewLoop.url: "bigbuckbunny"
        case sintelTrailer.url: "sinteltrailer"
        default: nil
        }
    }

    public static func isVideoURL(_ url: String) -> Bool {
        if url.contains("mock://video/") { return true }
        // ⚠️ MEMBERSHIP FIRST, sniffing second. The table is the truth about
        // what is a video; the suffix test is a heuristic for urls that are not
        // in it. Sniffing alone dropped every fixture whose url does not end in
        // a known extension, so a THIRD of the corpus's videos read as
        // photographs on the map — measured as photo 24 / text 24 / video 12
        // where the corpus is an even 40/40/40.
        if videos.contains(where: { $0.url == url }) { return true }
        let path = URLComponents(string: url)?.path.lowercased() ?? url.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
    }

    /// The MIME type a mock attachment should declare for `url`.
    ///
    /// HLS manifests get `application/vnd.apple.mpegurl` — deliberately not a
    /// `video/*` type, so the client's real routing rule
    /// (`MediaCore.MediaKind`) is exercised rather than side-stepped.
    public static func mimeType(for url: String) -> String {
        // The two still schemes answer PICTURES, whatever they are about. Asked
        // before anything else because a frame-zero request names a clip, and
        // reading the answer off the subject rather than off the request is how
        // a still gets classified as a video.
        if url.hasPrefix(previewPosterScheme) || url.hasPrefix(frameZeroScheme) { return "image/png" }
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
