import CacheKit
import UIKit

/// Where an avatar's animation comes from: the sheet baked for the avatar at
/// `avatarURL`, or nil for a still avatar (#1358). The mock answers today;
/// the backend's sheet rendition (core-platform-backend#945) answers once it
/// ships.
public protocol AnimatedAvatarResolving: Sendable {
    func sheet(for avatarURL: URL) async -> AnimatedIconSheet?
}

/// The app's animated avatars (#1358): which avatar has a sheet, the sheets
/// themselves (decoded once, kept by bytes), and each sheet's still — its
/// LAST frame, the picture every animated avatar rests on (the owner,
/// 2026-10-18).
///
/// Resolution is asynchronous and cached: the first ask for a URL starts it,
/// and `onResolved` tells the views waiting on that URL.
@MainActor
public final class AnimatedAvatars {
    public static let shared = AnimatedAvatars()

    /// Set once at launch by the app. Nil: no avatar animates.
    public var resolver: (any AnimatedAvatarResolving)?

    /// The decoded sheets and their stills, by avatar — on CacheKit, budgeted
    /// by bytes like the map's previews (`AnimatedIconCatalog`). 1.5 MB a
    /// face at the 128 px rung; the budget holds about twenty.
    private let arts: MemoryCache<URL, Art>
    /// Avatars known to have no sheet.
    private var stills: Set<URL> = []
    private var inflight: [URL: Task<Void, Never>] = [:]
    private var waiting: [URL: [(AnimatedIconSheet?) -> Void]] = [:]

    /// A face's sheet and its still, cut once.
    struct Art: Sendable {
        let sheet: AnimatedIconSheet
        let still: UIImage?
    }

    init(registry: UIAssetCaches? = .shared) {
        arts = UIAssetCaches.memoryCache(
            "UIAssets.avatarSheets", budget: .fixed(bytes: 32 * CacheBytes.mebibyte), priorityClass: .standard
        )
        registry?.adopt(arts)
    }

    /// The sheet for `url` if it is known now; nil if it is a still or not
    /// resolved yet.
    public func cachedSheet(for url: URL) -> AnimatedIconSheet? {
        arts.value(for: url)?.sheet
    }

    /// The still an animated avatar rests on — its sheet's last frame — if
    /// `url` is known to be animated.
    public func still(for url: URL) -> UIImage? {
        arts.value(for: url)?.still
    }

    /// Resolves `url`'s sheet, calling `completion` on the main actor with it
    /// (or nil for a still) — at once when it is already known.
    public func sheet(for url: URL, completion: @escaping (AnimatedIconSheet?) -> Void) {
        if let known = cachedSheet(for: url) { return completion(known) }
        if stills.contains(url) { return completion(nil) }
        guard let resolver else { return completion(nil) }
        waiting[url, default: []].append(completion)
        guard inflight[url] == nil else { return }
        inflight[url] = Task { [weak self] in
            let sheet = await resolver.sheet(for: url)
            guard let self else { return }
            inflight[url] = nil
            if let sheet {
                _ = arts.insert(Art(sheet: sheet, still: Self.lastFrame(of: sheet)), for: url, cost: sheet.byteCost)
            } else {
                stills.insert(url)
            }
            let callbacks = waiting.removeValue(forKey: url) ?? []
            callbacks.forEach { $0(sheet) }
        }
    }

    /// A sheet's last frame, the picture every animated avatar rests on.
    nonisolated static func lastFrame(of sheet: AnimatedIconSheet) -> UIImage? {
        guard let image = sheet.sheet.cgImage, let unit = sheet.frameRects.last else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: unit.minX * width, y: unit.minY * height,
                          width: unit.width * width, height: unit.height * height).integral
        guard let cell = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cell, scale: 1, orientation: .up)
    }

    /// Cuts an avatar sheet out of a video preview sheet: each frame
    /// centre-cropped to a square and drawn at `cellPX`, four to a row — the
    /// geometry the backend is asked to bake (core-platform-backend#945).
    /// What the mock resolver makes its sheets with.
    public nonisolated static func bakeSquareSheet(
        from source: AnimatedIconSheet, cellPX: Int = 128
    ) -> AnimatedIconSheet? {
        guard let image = source.sheet.cgImage else { return nil }
        let columns = 4
        let rows = Int(ceil(Double(source.frameCount) / Double(columns)))
        let size = CGSize(width: columns * cellPX, height: rows * cellPX)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let baked = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (index, unit) in source.frameRects.enumerated() {
                let frame = CGRect(x: unit.minX * width, y: unit.minY * height,
                                   width: unit.width * width, height: unit.height * height)
                let side = min(frame.width, frame.height)
                let square = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
                guard let cell = image.cropping(to: square.integral) else { continue }
                let target = CGRect(x: (index % columns) * cellPX, y: (index / columns) * cellPX,
                                    width: cellPX, height: cellPX)
                UIImage(cgImage: cell).draw(in: target)
            }
        }
        return AnimatedIconSheet(
            sheet: baked, frameCount: source.frameCount, columns: columns, frameDuration: source.frameDuration
        )
    }

}
