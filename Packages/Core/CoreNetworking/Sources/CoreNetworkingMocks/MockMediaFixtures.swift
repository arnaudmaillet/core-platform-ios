import Foundation

/// Media for the mock corpus's opt-in real-asset catalog, and the URL rules
/// both catalogs share.
///
/// The default mock dataset stays entirely offline (`MockSocialDataset` seeds
/// `mock://` URLs that `PlaceholderImageFetcher` / `PlaceholderVideoFetcher`
/// render locally), because the unit suite, previews, and CI all run against
/// `MockBackend()` and must not depend on the network. The real-asset catalog
/// is selected explicitly via `MockSocialDataset.MediaCatalog.realAssets`
/// (launch argument `-rich-media`) and swaps the synthesized AVATARS for real
/// photographs at exact dimensions (Picsum).
///
/// ⚠️ THERE ARE NO PUBLIC POST MEDIA. Posts in BOTH catalogs carry the
/// corpus's own bundled files: clips (`MockClipCatalog`,
/// `mock://video/clip-NN?w=&h=`), each with its own sound and baked map
/// preview, and photo galleries (`MockPhotoCatalog`,
/// `mock://photo/gallery-N-MM?w=&h=`). The royalty-free films, HLS ladders and
/// Picsum post photographs this file used to supply were removed on purpose.
public enum MockMediaFixtures {

    // MARK: - Avatars

    /// Picsum ids verified to resolve. Picsum serves a real photograph at an
    /// exact requested size, so an avatar can take any aspect honestly — the
    /// returned pixels really are the dimensions we declare.
    ///
    /// ⚠️ AVATARS ONLY. Post photographs come from `MockPhotoCatalog`; these
    /// stay because the product wants the avatars exactly as they are.
    static let picsumIDs = [1015, 1025, 1039, 1043, 1050, 237, 433, 866, 1074, 1084]

    /// A real photograph at exactly `width`×`height`, for an author avatar
    /// under `-rich-media`. Deterministic: the same `index` always yields the
    /// same photo, so runs stay comparable.
    public static func imageURL(index: Int, width: Int, height: Int) -> String {
        let id = picsumIDs[abs(index) % picsumIDs.count]
        return "https://picsum.photos/id/\(id)/\(width)/\(height)"
    }

    /// A real portrait photo for an author avatar.
    public static func avatarURL(index: Int) -> String {
        imageURL(index: index, width: 128, height: 128)
    }

    // MARK: - Stills of a clip

    /// The scheme a baked clip's poster is served under. The app resolves it
    /// from its own preview catalogue; nothing fetches it over the wire.
    public static let previewPosterScheme = "mock://preview/"

    /// The scheme a clip's OWN FIRST FRAME is served under, for clips that have
    /// no baked sheet — anything `bakedClip` does not name. The app decodes it
    /// with `AVAssetImageGenerator` and the pipeline caches the result by URL,
    /// so it runs once per clip per session.
    ///
    /// ⚠️ IT EXISTS SO THE ANSWER IS NEVER A PHOTOGRAPH OF SOMEWHERE ELSE. A
    /// pin's single URL has to be something the surface can render, and the
    /// two ways to satisfy that are a frame of the post's own clip or a stock
    /// picture of something unrelated. The second was what shipped, and it put
    /// a sky on a marker whose post was a build log.
    public static let frameZeroScheme = "mock://frame0/"

    /// The catalogue id of a clip's OPENING segment.
    ///
    /// ⚠️ ONE RULE, TWO CALLERS, and that is the whole point. The marker wears
    /// a sheet and its cover is that sheet's cell 0 — but the seeding picked a
    /// segment by post index while the poster resolved `ids.first(where:)`, so
    /// a marker animated one part of the film while its cover, and the page it
    /// opened, showed the first frame of ANOTHER part. Both ask here now, and
    /// "frame 0" means the same picture everywhere.
    ///
    /// Lowest numeric suffix, not `first`: the catalogue's order is whatever
    /// the bundle enumerated, and `clip-01-11` sorts before `clip-01-2` as
    /// text.
    public static func openingSegment(ofClip clip: String, in catalogue: [String]) -> String? {
        catalogue
            .filter { $0.hasPrefix("\(clip)-") }
            .min { lhs, rhs in segmentIndex(of: lhs) < segmentIndex(of: rhs) }
    }

    private static func segmentIndex(of id: String) -> Int {
        Int(id.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? .max
    }

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

    /// Which BAKED preview clip a video URL's footage is, or nil when none was
    /// baked from it.
    ///
    /// A real clip is baked under its own id (`Scripts/import-mock-clips.py`,
    /// sheets in `App/Resources/MapPreviews`), so its marker previews — and
    /// its poster — are its own footage. Anything else (a synthesized
    /// placeholder when the clips are missing from the bundle) answers nil and
    /// the marker wears its cover, which is the honest rung of the same ladder.
    /// ⚠️ NEVER a substring or a fallback pick: a marker that previews another
    /// post's footage is the defect this table replaced.
    public static func bakedClip(for url: String) -> String? {
        URL(string: url).flatMap { MockClipCatalog.shared.clip(for: $0)?.id }
    }

    // MARK: - Classification

    /// Whether a seeded media URL denotes video. The mock encodes it in the
    /// host (`mock://video/…`); anything else is recognised by extension,
    /// since a CDN URL carries no such marker. The path is read rather than
    /// the whole string so a query item (a kind stamp, a discriminator) does
    /// not hide the extension.
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
        // The two still schemes answer PICTURES, whatever they are about. Asked
        // before anything else because a frame-zero request names a clip, and
        // reading the answer off the subject rather than off the request is how
        // a still gets classified as a video.
        if url.hasPrefix(previewPosterScheme) || url.hasPrefix(frameZeroScheme) { return "image/png" }
        // The bundled galleries are JPEG files, and the attachment says so.
        if url.hasPrefix(MockPhotoCatalog.scheme) { return "image/jpeg" }
        let path = URLComponents(string: url)?.path.lowercased() ?? url.lowercased()
        if path.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if isVideoURL(url) { return "video/mp4" }
        return url.hasPrefix("mock://") ? "image/png" : "image/jpeg"
    }
}
