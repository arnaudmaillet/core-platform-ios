@preconcurrency import AVFoundation
import ImageIO
import UIKit

/// The camera's captures, served to the editor and the finalisation screen
/// through the same seam the photo library is.
///
/// ⚠️ **ONE PER PRESENTATION, AND THE SAME ONE ALL THE WAY TO "POST"** — the
/// rule `UploadFeatureBuilder.makeMediaUploadViewController` states for the
/// Photos library, for its reason: every screen of the flow asks the library
/// by identifier, and a library that never registered an item answers nothing.
///
/// ⚠️ **FILES, READ FROM DISK, AND NEVER THE PHOTO LIBRARY.** The captures are
/// not saved to Photos (the author decided); they live in the draft's
/// `CaptureFolder` and are read from there.
@MainActor
final class CapturedMediaLibrary: MediaLibraryReading {
    private struct Entry {
        let url: URL
        let kind: MediaLibraryItem.Kind
    }

    private var entries: [MediaLibraryItem.ID: Entry] = [:]

    /// The screens reading each file, held weakly — see `hold(_:by:)`.
    private var holders: [URL: [WeakHolder]] = [:]

    private final class WeakHolder {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    init() {}

    /// Records that `holder` reads the files behind `items` for as long as it
    /// lives — the editor a capture was handed to, and the finalisation screen
    /// after it.
    ///
    /// ⚠️ **A FILE THE CAMERA HANDED OVER OUTLIVES THE CAMERA'S OWN USE OF
    /// IT.** "Post" keeps running when the author steps back — the finalisation
    /// screen's publishing task holds that screen until it is done — and the
    /// camera, reached again, deleted the joined take (a new clip replaces
    /// it) or a one-clip take's clip (undo), which the export was still
    /// reading. The camera now asks `isHeld` before deleting, and leaves a held
    /// file for later.
    func hold(_ items: [MediaLibraryItem], by holder: AnyObject) {
        for item in items {
            guard let url = entries[item.id]?.url else { continue }
            holders[url, default: []].append(WeakHolder(holder))
        }
    }

    /// Whether a screen that was handed `url` is still alive.
    func isHeld(_ url: URL) -> Bool {
        holders[url] = holders[url]?.filter { $0.object != nil }
        return !(holders[url]?.isEmpty ?? true)
    }

    /// Internal for tests: how many live screens read `url`.
    func holderCount(of url: URL) -> Int {
        _ = isHeld(url)
        return holders[url]?.count ?? 0
    }

    /// Registers a file and returns the item that stands for it.
    func register(_ url: URL, kind: MediaLibraryItem.Kind) -> MediaLibraryItem {
        let item = MediaLibraryItem(id: "capture-\(UUID().uuidString)", kind: kind)
        entries[item.id] = Entry(url: url, kind: kind)
        return item
    }

    func url(for item: MediaLibraryItem.ID) -> URL? { entries[item]?.url }

    /// Captures need no permission of their own: they are this session's files.
    var access: MediaLibraryAccess { .granted }
    func requestAccess() async -> MediaLibraryAccess { .granted }
    func presentLimitedPicker(from host: UIViewController) {}
    func albums() async -> [MediaLibraryAlbum] { [] }
    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }

    /// ⚠️ **THE PICTURE'S OWN SHAPE, AND ALREADY UPRIGHT.** The protocol demands
    /// the photograph's proportions whatever `size` says, because a crop is
    /// fractions of it. ImageIO's thumbnail keeps the aspect and — asked with
    /// `…CreateThumbnailWithTransform` — spends the orientation flag, so a phone
    /// photograph comes back upright; a clip's frame is read with its track's
    /// transform applied for the same reason.
    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
        guard let entry = entries[item] else { return nil }
        let scale = UITraitCollection.current.displayScale
        let longest = max(size.width, size.height) * scale
        let url = entry.url
        switch entry.kind {
        case .photo:
            return await Task.detached(priority: .userInitiated) {
                Self.decodedThumbnail(at: url, longestSide: longest, scale: scale)
            }.value
        case .video:
            return await Self.frame(of: url, longestSide: longest, scale: scale)
        }
    }

    func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
        guard let entry = entries[item], entry.kind != .photo else { return nil }
        return entry.url
    }

    // MARK: - Reading the files

    nonisolated static func decodedThumbnail(at url: URL, longestSide: CGFloat, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longestSide.rounded(.up)))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// The size a photograph file is DRAWN at: its pixel size with its EXIF
    /// orientation spent.
    nonisolated static func uprightImageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // 5…8 are the quarter turns, which swap the axes.
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The size a clip is DRAWN at: its natural size through its track's
    /// preferred transform.
    nonisolated static func uprightVideoSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(turned.width), height: abs(turned.height))
    }

    nonisolated static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return 0 }
        return duration.seconds
    }

    nonisolated private static func frame(of url: URL, longestSide: CGFloat, scale: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longestSide, height: longestSide)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
