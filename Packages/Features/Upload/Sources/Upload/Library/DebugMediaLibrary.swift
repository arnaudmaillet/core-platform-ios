#if DEBUG
// `PlaceholderVideoFetcher` — the feed's mock video source, reused here so a
// picked debug video is a real clip rather than a promise of one.
import MediaPlayback
import UIKit

/// A library made of nothing, for a simulator whose own is six stock images
/// deep and a screenshot that needs twenty.
///
/// This follows the house pattern for anything device-dependent: fake the
/// INPUT and keep the real screen. `-mock-compose-demo` does exactly this for
/// the publish pipeline, drawing a gradient rather than opening a camera.
///
/// Each tile carries its own number, so the order a selection ended up in is
/// legible in a still picture.
final class DebugMediaLibrary: MediaLibraryReading {
    private let items: [MediaLibraryItem]
    private let albumList: [MediaLibraryAlbum]
    /// What each album actually holds, built once — see the note in `init`.
    private let contents: [String: [MediaLibraryItem]]

    /// How long a synthesised clip runs, and how big its long edge is.
    private let clipSeconds: Double
    private let clipLongEdge: Int

    /// First frames of the synthetic clips, kept so a grid scroll does not
    /// re-open an `AVAssetImageGenerator` per cell per pass.
    private var videoPosters: [String: UIImage] = [:]

    /// Every fourth item is a video, so the "Videos" pill has a count and the
    /// grid has durations to stamp.
    ///
    /// ⚠️ SPELLED OUT RATHER THAN CHAINED. This was a `map` with a ternary over
    /// two implicit enum members and an interpolated id inside it, and the
    /// compiler gave up type-checking it — the error names a time limit, not a
    /// mistake, and the fix is always to give the pieces names.
    /// ⚠️ **`clip` IS A TEST SEAM, AND CI IS WHY IT EXISTS.** The defaults are
    /// what a simulator should show: two and a half seconds at a real size, so a
    /// picked clip behaves like a picked clip. A CI runner is another matter —
    /// the video suite really synthesises H.264 and really runs an
    /// `AVAssetExportSession`, nine package lanes share one machine, and every
    /// suite here is `@MainActor`, so wall-clock time is not work time. The
    /// first run of these tests took 105-137 seconds EACH there against six
    /// locally, and timed out mid-publish. Shrinking the fixture is the half of
    /// the fix that lowers the cost rather than just waiting longer for it.
    init(count: Int, clipSeconds: Double = 2.5, clipLongEdge: Int = 960) {
        self.clipSeconds = clipSeconds
        self.clipLongEdge = clipLongEdge
        let total = max(count, 1)
        var items: [MediaLibraryItem] = []
        items.reserveCapacity(total)
        for index in 0..<total {
            let kind: MediaLibraryItem.Kind
            if index % 4 == 3 {
                // ⚠️ **THE LENGTH OF THE CLIP THIS ITEM ACTUALLY VENDS —
                // WHICHEVER KIND IT IS.** The grid stamps this in the tile's
                // corner, and the trim handles are laid out against it.
                //
                // It used to be `7 + (index % 53)`: a pleasing spread of made-up
                // numbers over synthetic clips that all run `clipSeconds`. That
                // was merely untidy while nothing read it, and became a defect
                // the moment trim arrived — a strip built against a declared ten
                // seconds, cutting a file that is two and a half, resolves to a
                // range outside the clip. The same class of lie as a coloured
                // square standing in for a video: it looks right, and the one
                // thing a stand-in must not do is disagree with what it stands
                // for. Less varied, and true.
                let seconds = Self.realClip(forIndex: index).map { Double($0.seconds) }
                    ?? clipSeconds
                kind = .video(duration: seconds)
            } else {
                kind = .photo
            }
            items.append(MediaLibraryItem(id: "debug-\(index)", kind: kind))
        }
        self.items = items

        // ⚠️ **DIFFERENT FOLDERS, NOT THE SAME ONE WEARING FOUR NAMES.** These
        // were all slices of the same run — `prefix(total/5)`, `suffix(total/8)`
        // — so paging between albums showed the same tiles in the same order and
        // proved nothing about the pager, the per-album load, or the counts. The
        // ranges below are disjoint where it matters, so an album visibly IS a
        // different set of pictures.
        var contents: [String: [MediaLibraryItem]] = [:]
        contents["recents"] = items
        contents["videos"] = items.filter(\.isVideo)
        // Every fifth, scattered through the run rather than taken off the front.
        contents["favorites"] = items.enumerated()
            .filter { $0.offset % 5 == 0 }
            .map(\.element)
        contents["screenshots"] = Array(items.suffix(max(total / 8, 1)))
        contents["trip"] = Array(items.dropFirst(3).prefix(7))
        contents["family"] = Array(items.dropFirst(12).prefix(6))
        // The even indices are the 3:4 portraits the fixture renders — a folder
        // whose shape is uniform, which is what makes a 9:16 thumbnail frame
        // show fit-vs-fill clearly.
        contents["portraits"] = items.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
        self.contents = contents

        let albums = [
            MediaLibraryAlbum(id: "recents", title: "Recents", count: contents["recents"]?.count ?? 0),
            MediaLibraryAlbum(id: "videos", title: "Videos", count: contents["videos"]?.count ?? 0),
            MediaLibraryAlbum(id: "favorites", title: "Favorites", count: contents["favorites"]?.count ?? 0),
            MediaLibraryAlbum(id: "trip", title: "Paris 2026", count: contents["trip"]?.count ?? 0),
            MediaLibraryAlbum(id: "family", title: "Family", count: contents["family"]?.count ?? 0),
            MediaLibraryAlbum(id: "portraits", title: "Portraits", count: contents["portraits"]?.count ?? 0),
            MediaLibraryAlbum(id: "screenshots", title: "Screenshots", count: contents["screenshots"]?.count ?? 0)
        ]
        albumList = albums.filter { $0.count > 0 }
    }

    /// ⚠️ **`.limited` IS UNREACHABLE ON A SIMULATOR WITHOUT THIS.** The device
    /// grants the whole library, and this stand-in returned `.granted` outright,
    /// so the access notice above the grid could be written and shipped without
    /// anyone ever having seen it appear. `-upload-access limited` (or `denied`)
    /// forces the state the banner exists for.
    var access: MediaLibraryAccess {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-upload-access"),
              arguments.count > flag + 1
        else { return .granted }
        switch arguments[flag + 1] {
        case "limited": return .limited
        case "denied": return .denied
        case "undetermined": return .undetermined
        default: return .granted
        }
    }

    func requestAccess() async -> MediaLibraryAccess { access }

    /// ⚠️ **DELIBERATELY NOTHING, AND IT SAYS SO.** There is no system sheet to
    /// present against a synthetic library, and a stand-in that pretended to
    /// widen the selection would report a success the grid could never show. The
    /// notice's OTHER route — Settings — is the one worth driving on a simulator.
    func presentLimitedPicker(from host: UIViewController) {}

    func albums() async -> [MediaLibraryAlbum] { albumList }

    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] {
        contents[album] ?? items
    }

    /// ⚠️ **A STAND-IN MUST NOT BE THE SHAPE OF WHATEVER ASKED FOR IT.** This
    /// rendered at exactly `size`, so every picture matched its container's
    /// aspect exactly — and `scaleAspectFill` and `scaleAspectFit` then produce
    /// IDENTICAL pixels. The editor's fill/fit control was therefore impossible
    /// to judge by eye on any screen: both states looked full-bleed, and the
    /// only time a letterbox ever appeared was when the canvas was BROKEN and
    /// the cell disagreed with the size that had been requested.
    ///
    /// Real photographs are 3:4 or 4:3. These alternate by index, so filling
    /// crops and fitting letterboxes — in both directions, over a run of tiles.
    /// ⚠️ **A VIDEO'S TILE IS A FRAME OF THE CLIP THAT WILL BE PUBLISHED, NOT A
    /// COLOURED SQUARE WITH A DURATION STAMPED ON IT.** It was the latter, and a
    /// stand-in that only *claims* to be a video hides the two things that go
    /// wrong with real ones: a grid that shows one picture while the post
    /// carries another, and a thumbnail whose aspect disagrees with the file's.
    /// Drawn by `VideoExporter.posterImage` — the very call the publish path
    /// uses for `thumbnail_url` — on the very file `videoFile(for:)` hands over,
    /// so what the grid shows IS what the post gets. Built once per id; the
    /// clip underneath is cached on disk by the fetcher.
    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
        let index = Self.index(of: item)
        if items.first(where: { $0.id == item })?.isVideo == true {
            if let cached = videoPosters[item] { return cached }
            guard let file = await videoFile(for: item),
                  let frame = await VideoExporter().posterImage(for: file)
            else { return nil }
            let numbered = Self.numbered(index, over: frame, in: frame.size)
            videoPosters[item] = numbered
            return numbered
        }

        // A hue per index, spun by the golden angle so that neighbouring tiles
        // never land on the same colour.
        let spun = CGFloat(index) * 0.618_034
        let hue = spun.truncatingRemainder(dividingBy: 1)
        let fill = UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)

        // The long edge follows what was asked for, so a full-screen request
        // still yields a full-screen-scale picture; only the SHAPE is the
        // photograph's own.
        let longEdge = max(size.width, size.height, 1)
        let rendered = Self.isPortrait(index)
            ? CGSize(width: longEdge * 0.75, height: longEdge)
            : CGSize(width: longEdge, height: longEdge * 0.75)

        return Self.numbered(index, over: nil, in: rendered, ground: fill)
    }

    /// Whether the item at `index` is drawn 3:4 rather than 4:3.
    ///
    /// ⚠️ **ONE RULE, TWO USERS — THE TILE AND THE CLIP.** A synthetic video
    /// whose file was 3:4 while its tile was 4:3 would break the seam's aspect
    /// contract in the one place the contract exists for: the editor chooses a
    /// crop against a canvas-sized render and the publish path bakes it against
    /// another, and `MediaCrop` is fractions, so the two agree only while both
    /// wear the same proportions.
    private static func isPortrait(_ index: Int) -> Bool { index.isMultiple(of: 2) }

    private static func index(of item: MediaLibraryItem.ID) -> Int {
        Int(item.dropFirst("debug-".count)) ?? 0
    }

    /// The tile's number, over a picture or over a flat colour.
    ///
    /// The number is why these exist: it makes the ORDER a selection ended up in
    /// legible in a still screenshot. A video frame keeps it for the same reason
    /// a photograph does.
    private static func numbered(
        _ index: Int, over picture: UIImage?, in size: CGSize, ground: UIColor? = nil
    ) -> UIImage {
        let number = String(index + 1) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size.height * 0.32, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85)
        ]
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = picture?.scale ?? UITraitCollection.current.displayScale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let ground {
                ground.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            picture?.draw(in: CGRect(origin: .zero, size: size))
            let measured = number.size(withAttributes: attributes)
            let origin = CGPoint(
                x: (size.width - measured.width) / 2,
                y: (size.height - measured.height) / 2
            )
            number.draw(at: origin, withAttributes: attributes)
        }
    }

    /// ⚠️ **REAL H.264 BYTES, NOT A STAND-IN FOR THEM.** Everything downstream
    /// of here opens the file for real — `VideoExporter` runs an
    /// `AVAssetExportSession` over it, `AVAssetImageGenerator` pulls a poster out
    /// of it, and the optimistic feed entry plays it. A made-up URL, or a file
    /// with no video track, would fail in each of those and prove nothing about
    /// the path this library exists to drive.
    ///
    /// Two routes, and both end in a local file:
    ///
    /// - **A real public encode** under `-rich-media` (`realClips`), downloaded
    ///   once and cached by `PlaceholderVideoFetcher`. This is the one that
    ///   finds things a fixture cannot: it is what showed that
    ///   `VideoExporter.posterImage` sampled at exactly t=0 and therefore
    ///   published a black `thumbnail_url` for any film that fades in.
    /// - **A synthesised clip** otherwise — the feed's own mock source, a short
    ///   looping film with a sweeping band, hue derived from the URL, cached on
    ///   disk, deterministic and offline. This is the default precisely because
    ///   the unit suite, previews and CI must not touch the network.
    ///
    /// ⚠️ **THE SYNTHESISED CLIP WEARS THE SHAPE ITS TILE PROMISED**, via
    /// `isPortrait` — see the note there. Even on both sides because H.264
    /// requires it; the fetcher rounds down anyway, but asking correctly keeps
    /// the aspect exact. A real encode brings its own shape, which is why they
    /// are all landscape and all land on odd indices; see `realClips`.
    func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
        guard items.first(where: { $0.id == item })?.isVideo == true else { return nil }
        let index = Self.index(of: item)
        let fetcher = PlaceholderVideoFetcher()

        // ⚠️ **A REAL ENCODE UNDER `-rich-media`, AND ONE CHECK COVERS BOTH WAYS
        // OF NOT GETTING ONE.** `playableURL` hands an http(s) URL to the
        // fetcher's own download-once cache, which is itself gated on
        // `-rich-media` and returns the REMOTE url unchanged when it is absent
        // or when the download did not produce something plausibly a video. So
        // `isFileURL` answers "did I actually get a local file" for both the
        // not-opted-in case and the fixture-went-dark case, and the synthesised
        // clip below catches both. A remote URL must never escape from here:
        // `VideoExporter` would run an `AVAssetExportSession` over the network,
        // and `AVAssetImageGenerator` refuses remote assets outright (-11800).
        if let clip = Self.realClip(forIndex: index),
           let remote = URL(string: clip.url),
           let resolved = try? await fetcher.playableURL(for: remote),
           resolved.isFileURL {
            return resolved
        }

        let portrait = Self.isPortrait(index)
        let long = max(clipLongEdge, 16)
        let short = max(Int(Double(long) * 0.75), 16)
        let width = portrait ? short : long
        let height = portrait ? long : short
        guard let source = URL(string: "mock://video/\(item)?w=\(width)&h=\(height)") else {
            return nil
        }
        return try? await PlaceholderVideoFetcher(durationSeconds: clipSeconds)
            .playableURL(for: source)
    }

    // MARK: - Real clips

    /// A public test encode, and how long it actually runs.
    struct RealClip: Equatable {
        let url: String
        /// Read off the asset, not guessed — the grid stamps this on the tile,
        /// and a tile that says 0:10 over a 52-second film is a stand-in lying
        /// about the thing it stands in for.
        let seconds: Int
    }

    /// ⚠️ **URLS COPIED FROM `MockMediaFixtures`, NOT IMPORTED FROM IT — AND
    /// THAT IS DELIBERATE.** They live in `CoreNetworkingMocks`, a product this
    /// feature's target does not depend on and should not: SwiftPM has no
    /// per-configuration dependencies, so declaring it would link a mocks
    /// library into the Release app to serve a file that is `#if DEBUG` from top
    /// to bottom. `MockMediaFixtures` stays the canonical catalogue — it records
    /// the `ffprobe`-read dimensions, the verification dates and the
    /// `deadSources` list — and anything added here should be added there first.
    ///
    /// ⚠️ **ALL LANDSCAPE, AND THAT IS NOT AN OVERSIGHT.** `MockMediaFixtures`
    /// explains why: the commonly cited portrait buckets are dead, and declaring
    /// a portrait size for a landscape encode mis-drives pre-layout and crops
    /// the subject. It happens to fit here — every video item lands on an odd
    /// index, which `isPortrait` already draws 4:3 — but a portrait fixture
    /// added later must not be assigned to an even one.
    ///
    /// ⚠️ **NO TEN-MINUTE FIXTURE.** `MockMediaFixtures.longRunning` is right
    /// for a playhead-continuity test and wrong here: a picker stand-in that
    /// takes minutes to export teaches nothing the 52-second one does not.
    ///
    /// Verified with a ranged GET on 2026-09-15 — all 206, `video/mp4`. When one
    /// goes quiet, check it the way that file prescribes:
    /// `curl -o /dev/null -w '%{http_code}' -r 0-1023 <url>`.
    static let realClips = [
        // 1280x720, ~1 MB. `MockMediaFixtures.bigBuckBunny720`.
        RealClip(
            url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4",
            seconds: 10
        ),
        // 854x480, the long one — enough to make an export take real time.
        // `MockMediaFixtures.sintelTrailer`.
        RealClip(url: "https://media.w3.org/2010/05/sintel/trailer.mp4", seconds: 52),
        // 640x360, ~1 MB. `MockMediaFixtures.mapPreviewLoop`, without its
        // `mock-kind=video` marker — that exists to let the map's repository
        // recognise a video pin by URL shape, and nothing here reads it.
        RealClip(
            url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4",
            seconds: 10
        )
    ]

    /// Which real clip a video item gets, or nil when real clips are off.
    ///
    /// Videos sit at every fourth index, so the k-th of them is at `4k + 3`;
    /// rotating on k rather than on the index is what stops three clips from
    /// landing on one and repeating.
    static func realClip(forIndex index: Int) -> RealClip? {
        guard usesRealClips else { return nil }
        return rotatedClip(forIndex: index)
    }

    /// The rotation on its own, with no opinion about whether real clips are
    /// switched on — so which film lands where is testable without a launch
    /// argument, and therefore without the network.
    static func rotatedClip(forIndex index: Int) -> RealClip? {
        guard index % 4 == 3 else { return nil }
        return realClips[((index - 3) / 4) % realClips.count]
    }

    /// ⚠️ **THE SAME FLAG THE FIXTURES THEMSELVES OBEY.** The default mock mode
    /// is offline and deterministic — the unit suite, previews and CI all run
    /// against it and must not touch the network — and
    /// `PlaceholderVideoFetcher`'s download cache is gated on this argument
    /// already. Inventing a second flag here would let the library ask for a
    /// download the fetcher then refuses, which reads as "real videos are
    /// broken" rather than "they are off".
    static var usesRealClips: Bool {
        ProcessInfo.processInfo.arguments.contains("-rich-media")
    }
}
#endif
