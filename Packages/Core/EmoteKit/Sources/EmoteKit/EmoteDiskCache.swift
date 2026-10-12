import CacheKit
import ImageIO
import MediaCore
import UIKit
import UniformTypeIdentifiers

/// EmoteKit's share of the UI assets disk namespace (`UIAssetCaches.disk`,
/// #971), for the settings that measure and clear rebuildable caches (#409).
/// Every sheet in it is baked again on demand.
public enum EmoteCache {
    /// Bytes the UI assets disk namespace holds (emote sheets today). Opens
    /// the namespace if needed: call it off the main thread.
    public static func diskBytes() -> Int64 {
        Int64(UIAssetCaches.disk?.usage.bytes ?? 0)
    }

    /// Removes every baked sheet from the disk, through the namespace, so its
    /// index stays true. An explicit clear: the one way, short of a nearly
    /// full disk, that UI assets leave the disk.
    public static func removeAll() {
        UIAssetCaches.disk?.removeAll()
    }
}

/// Baked sheets kept on disk across launches, so an emote is rasterised once
/// per install and size rather than once per launch.
///
/// One entry per sheet in the UI assets namespace (`UIAssetCaches`): the cut
/// (`Metadata`) and the PNG in one file (`EmoteSheetFile`), so the two can
/// never be evicted apart. Everything here runs OFF the main actor: callers
/// hop to it with `Task.detached`.
///
/// ⚠️ **VERSIONED BY KEY.** Changing how a sheet is baked (rate, gutter,
/// caps) must bump `version`, or a device keeps playing sheets cut by the old
/// rules against the new metadata. Old keys are never read again and leave
/// with the namespace's 30-day idle expiry.
struct EmoteDiskCache: Sendable {
    static let version = 1
    /// The store, opened on first use. A closure so that the shared engine,
    /// made on the main actor, never opens the store (index read and
    /// reconciliation) there: the first disk read, on a detached task, does.
    private let openStore: @Sendable () -> DiskStore?
    /// Whether `openStore` would answer without opening anything — what the
    /// main actor may ask (`containsIfOpen`).
    private let isOpen: @Sendable () -> Bool

    /// - Parameter isOpen: whether the store is open already. Always, for a
    ///   store a test made and holds.
    init(store: @escaping @Sendable () -> DiskStore?, isOpen: @escaping @Sendable () -> Bool = { true }) {
        self.openStore = store
        self.isOpen = isOpen
    }

    /// The app's UI assets namespace. Nil never in practice; the optional is
    /// the engine's seam for "no disk".
    static func standard() -> EmoteDiskCache? {
        EmoteDiskCache(
            store: {
                _ = removeLegacyFolderOnce
                return UIAssetCaches.disk
            },
            // Open by anyone: the app's start-up warm-up opens it before the
            // first emote asks (#898).
            isOpen: { UIAssetCaches.isDiskOpen }
        )
    }

    /// Before #971 the sheets lived in `Caches/EmoteKit` as PNG + JSON pairs
    /// no index knew about. Removed once per launch, on the first disk use.
    private static let removeLegacyFolderOnce: Void = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("EmoteKit", isDirectory: true))
    }()

    struct Metadata: Codable, Equatable {
        let frameCount: Int
        let columns: Int
        let frameDuration: Double
        let gutter: Int
    }

    /// A file-system-safe name for one sheet.
    static func fileStem(emoteID: String, side: Int, still: Bool) -> String {
        let safe = emoteID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return "\(String(safe))@\(side)\(still ? "-still" : "")"
    }

    /// The namespace key of one sheet.
    static func key(stem: String) -> String {
        "emote/v\(version)/\(stem)"
    }

    func load(stem: String) -> AnimatedIconArt? {
        guard let data = openStore()?.data(for: Self.key(stem: stem)) else { return nil }
        return EmoteSheetFile.art(from: data)
    }

    func store(_ sheet: AnimatedIconSheet, gutter: Int, stem: String) {
        guard let disk = openStore(), let data = EmoteSheetFile.data(for: sheet, gutter: gutter) else { return }
        // A full disk costs a re-bake next launch, nothing more.
        _ = try? disk.write(data, for: Self.key(stem: stem), tier: .recent)
    }

    /// Whether the sheet is on disk, without counting as a use.
    func contains(stem: String) -> Bool {
        openStore()?.contains(Self.key(stem: stem)) ?? false
    }

    /// `contains`, answered only from an index already open: false while the
    /// store is not, since opening it reads the index and reconciles it with
    /// the files — never on the main thread. A lock and a lookup.
    func containsIfOpen(stem: String) -> Bool {
        isOpen() && contains(stem: stem)
    }

    /// Opens the store. Off the main thread.
    func open() {
        _ = openStore()
    }

    func removeAll() {
        openStore()?.removeAll()
    }
}

/// One baked sheet as bytes: a 4-byte big-endian length, the JSON `Metadata`,
/// then the PNG. The disk cache writes it and the bundled seed set
/// (`EmoteSeeds`) ships it, so a seed reads exactly as a disk hit does.
enum EmoteSheetFile {
    static func data(for sheet: AnimatedIconSheet, gutter: Int) -> Data? {
        guard let image = sheet.sheet.cgImage else { return nil }
        let meta = EmoteDiskCache.Metadata(
            frameCount: sheet.frameCount, columns: sheet.columns,
            frameDuration: sheet.frameDuration, gutter: gutter
        )
        guard let metaData = try? JSONEncoder().encode(meta) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        var length = UInt32(metaData.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(metaData)
        data.append(png as Data)
        return data
    }

    static func metadata(in data: Data) -> (meta: EmoteDiskCache.Metadata, png: Data)? {
        guard data.count > 4 else { return nil }
        let start = data.startIndex
        let length = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        let metaEnd = start + 4 + length
        guard length > 0, metaEnd < data.endIndex,
              let meta = try? JSONDecoder().decode(EmoteDiskCache.Metadata.self, from: data[(start + 4)..<metaEnd])
        else { return nil }
        return (meta, data[metaEnd...])
    }

    static func art(from data: Data) -> AnimatedIconArt? {
        guard let (meta, png) = metadata(in: data), let image = decoded(png) else { return nil }
        return .sheet(AnimatedIconSheet(
            sheet: UIImage(cgImage: image), frameCount: meta.frameCount, columns: meta.columns,
            frameDuration: meta.frameDuration, gutterPX: meta.gutter
        ))
    }

    /// The PNG decoded NOW, into a bitmap Core Animation can upload as is.
    ///
    /// ⚠️ A `UIImage(data:)` handed to a layer decodes lazily — on the main
    /// thread, at the first commit that shows it. Drawing it here moves that
    /// decode onto the caller's (background) thread.
    static func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
