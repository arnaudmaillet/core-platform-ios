import Foundation
import UIKit

/// Baked sheets kept on disk across launches, for a producer that bakes them
/// itself: the mock's animated avatars, cut from a clip's frames (#1841).
/// Sheets the server sends are pictures the picture cache already keeps.
///
/// One file per key, written atomically: the sheet as a JPEG plus its
/// geometry. A sheet is stored without a gutter (`gutterPX` 0), as the
/// square-sheet bake makes it. A file that cannot be read is a miss.
public struct AnimatedIconSheetDiskStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A store in the app's Caches, under `name`.
    public static func caches(named name: String) -> AnimatedIconSheetDiskStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AnimatedIconSheetDiskStore(directory: caches.appendingPathComponent(name, isDirectory: true))
    }

    /// The sheet stored under `key`, or nil.
    public func sheet(forKey key: String) -> AnimatedIconSheet? {
        guard let data = try? Data(contentsOf: url(forKey: key)),
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
              stored.frameCount > 0, stored.columns > 0,
              let image = UIImage(data: stored.picture, scale: 1)
        else { return nil }
        return AnimatedIconSheet(
            sheet: image, frameCount: stored.frameCount, columns: stored.columns,
            frameDuration: stored.frameDuration, startTime: stored.startTime
        )
    }

    /// Keeps `sheet` under `key`, replacing what was there. Best effort: a
    /// write that fails leaves the next launch to bake again.
    public func store(_ sheet: AnimatedIconSheet, forKey key: String) {
        guard let picture = sheet.sheet.jpegData(compressionQuality: 0.9) else { return }
        let stored = Stored(
            picture: picture, frameCount: sheet.frameCount, columns: sheet.columns,
            frameDuration: sheet.frameDuration, startTime: sheet.startTime
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(forKey: key), options: .atomic)
    }

    private func url(forKey key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe)).appendingPathExtension("sheet")
    }

    private struct Stored: Codable {
        let picture: Data
        let frameCount: Int
        let columns: Int
        let frameDuration: Double
        let startTime: Double?
    }
}
