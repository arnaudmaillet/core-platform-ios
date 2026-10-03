import ImageIO
import MediaCore
import UIKit
import UniformTypeIdentifiers

/// Baked sheets kept in Caches across launches, so an emote is rasterised once
/// per install and size rather than once per launch.
///
/// A PNG per sheet plus a few bytes of JSON saying how to cut it. Everything
/// here runs OFF the main actor: callers hop to it with `Task.detached`.
///
/// ⚠️ **VERSIONED BY FOLDER.** Changing how a sheet is baked (rate, gutter,
/// caps) must bump `version`, or a device keeps playing sheets cut by the old
/// rules against the new metadata.
/// The root of EmoteKit's on-disk sheet cache (`Caches/EmoteKit`), for the
/// settings that measure and clear rebuildable caches (#409). Every sheet in
/// it is baked again on demand.
public enum EmoteCache {
    public static var directory: URL? {
        EmoteDiskCache.standard()?.directory.deletingLastPathComponent()
    }
}

struct EmoteDiskCache: Sendable {
    static let version = 1
    let directory: URL

    /// `Caches/EmoteKit/v<version>`. Nil only if the system has no Caches
    /// directory, in which case every sheet is simply baked again.
    static func standard() -> EmoteDiskCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return EmoteDiskCache(directory: caches.appendingPathComponent("EmoteKit/v\(version)", isDirectory: true))
    }

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

    func load(stem: String) -> AnimatedIconArt? {
        let png = directory.appendingPathComponent(stem + ".png")
        let json = directory.appendingPathComponent(stem + ".json")
        guard let metaData = try? Data(contentsOf: json),
              let meta = try? JSONDecoder().decode(Metadata.self, from: metaData),
              let data = try? Data(contentsOf: png),
              let image = Self.decoded(data)
        else { return nil }
        return .sheet(AnimatedIconSheet(
            sheet: UIImage(cgImage: image), frameCount: meta.frameCount, columns: meta.columns,
            frameDuration: meta.frameDuration, gutterPX: meta.gutter
        ))
    }

    func store(_ sheet: AnimatedIconSheet, gutter: Int, stem: String) {
        guard let image = sheet.sheet.cgImage else { return }
        let meta = Metadata(frameCount: sheet.frameCount, columns: sheet.columns,
                            frameDuration: sheet.frameDuration, gutter: gutter)
        guard let metaData = try? JSONEncoder().encode(meta) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The PNG first and the metadata last: a crash between the two
            // leaves a PNG with no metadata, which `load` treats as a miss.
            try (data as Data).write(to: directory.appendingPathComponent(stem + ".png"), options: .atomic)
            try metaData.write(to: directory.appendingPathComponent(stem + ".json"), options: .atomic)
        } catch {
            // A full disk costs a re-bake next launch, nothing more.
        }
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

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
