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

    /// Every fourth item is a video, so the "Videos" pill has a count and the
    /// grid has durations to stamp.
    ///
    /// ⚠️ SPELLED OUT RATHER THAN CHAINED. This was a `map` with a ternary over
    /// two implicit enum members and an interpolated id inside it, and the
    /// compiler gave up type-checking it — the error names a time limit, not a
    /// mistake, and the fix is always to give the pieces names.
    init(count: Int) {
        let total = max(count, 1)
        var items: [MediaLibraryItem] = []
        items.reserveCapacity(total)
        for index in 0..<total {
            let kind: MediaLibraryItem.Kind
            if index % 4 == 3 {
                let seconds = 7 + (index % 53)
                kind = .video(duration: TimeInterval(seconds))
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
    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
        let index = Int(item.dropFirst("debug-".count)) ?? 0
        // A hue per index, spun by the golden angle so that neighbouring tiles
        // never land on the same colour.
        let spun = CGFloat(index) * 0.618_034
        let hue = spun.truncatingRemainder(dividingBy: 1)
        let fill = UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let number = String(index + 1) as NSString

        // The long edge follows what was asked for, so a full-screen request
        // still yields a full-screen-scale picture; only the SHAPE is the
        // photograph's own.
        let longEdge = max(size.width, size.height, 1)
        let rendered = index.isMultiple(of: 2)
            ? CGSize(width: longEdge * 0.75, height: longEdge)
            : CGSize(width: longEdge, height: longEdge * 0.75)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: rendered.height * 0.32, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85)
        ]

        return UIGraphicsImageRenderer(size: rendered).image { context in
            fill.setFill()
            context.fill(CGRect(origin: .zero, size: rendered))
            let measured = number.size(withAttributes: attributes)
            let origin = CGPoint(
                x: (rendered.width - measured.width) / 2,
                y: (rendered.height - measured.height) / 2
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
    /// `PlaceholderVideoFetcher` is the feed's own mock source and already
    /// synthesises exactly this — a short looping clip with a sweeping band,
    /// hue derived from the URL and cached on disk — so a picked debug video is
    /// deterministic and costs one write per id. It lives in `MediaPlayback`,
    /// which `PostComposer` already depends on for `VideoExporter`.
    ///
    /// 3:4 to match the odd-indexed thumbnails, and even on both sides because
    /// H.264 requires it — the fetcher rounds down, but asking correctly keeps
    /// the shape the grid promised.
    func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
        guard items.first(where: { $0.id == item })?.isVideo == true else { return nil }
        guard let source = URL(string: "mock://video/\(item)?w=720&h=960") else { return nil }
        return try? await PlaceholderVideoFetcher().playableURL(for: source)
    }
}
#endif
