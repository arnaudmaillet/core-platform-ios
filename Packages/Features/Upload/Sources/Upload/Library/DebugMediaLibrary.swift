#if DEBUG
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

        let videos = items.filter(\.isVideo).count
        let favorites = max(total / 5, 1)
        let screenshots = max(total / 8, 1)
        let albums = [
            MediaLibraryAlbum(id: "recents", title: "Recents", count: total),
            MediaLibraryAlbum(id: "videos", title: "Videos", count: videos),
            MediaLibraryAlbum(id: "favorites", title: "Favorites", count: favorites),
            MediaLibraryAlbum(id: "screenshots", title: "Screenshots", count: screenshots)
        ]
        albumList = albums.filter { $0.count > 0 }
    }

    var access: MediaLibraryAccess { .granted }

    func requestAccess() async -> MediaLibraryAccess { .granted }

    func albums() async -> [MediaLibraryAlbum] { albumList }

    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] {
        switch album {
        case "videos":
            return items.filter(\.isVideo)
        case "favorites":
            return Array(items.prefix(max(items.count / 5, 1)))
        case "screenshots":
            return Array(items.suffix(max(items.count / 8, 1)))
        default:
            return items
        }
    }

    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
        let index = Int(item.dropFirst("debug-".count)) ?? 0
        // A hue per index, spun by the golden angle so that neighbouring tiles
        // never land on the same colour.
        let spun = CGFloat(index) * 0.618_034
        let hue = spun.truncatingRemainder(dividingBy: 1)
        let fill = UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let number = String(index + 1) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size.height * 0.32, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85)
        ]

        return UIGraphicsImageRenderer(size: size).image { context in
            fill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let measured = number.size(withAttributes: attributes)
            let origin = CGPoint(
                x: (size.width - measured.width) / 2,
                y: (size.height - measured.height) / 2
            )
            number.draw(at: origin, withAttributes: attributes)
        }
    }
}
#endif
