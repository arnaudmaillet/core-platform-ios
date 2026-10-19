import CacheKit
import UIKit

/// Where an animated avatar's sheet comes from: the sheet baked for the
/// sheet avatar at `avatarURL`, at `rung`, or nil when there is none (#1358,
/// #1444). The mock answers today; the backend's sheet rendition
/// (core-platform-backend#945, #948) answers once it ships.
public protocol AnimatedAvatarResolving: Sendable {
    func sheet(for avatarURL: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet?
}

/// The app's animated avatars (#1358, #1444): the sheets themselves (decoded
/// once, kept by bytes) and each sheet's still — its LAST frame, the picture
/// every animated avatar rests on (the owner, 2026-10-18).
///
/// ⚠️ **AN ANIMATED AVATAR HAS NO PHOTO** (the owner, 2026-10-19, #1444):
/// its only media is its sprite sheet. Its URL says so (`isSheet`: the
/// `#avatar-sheet` fragment), so nothing ever fetches it as a photo — the
/// image pipeline answers it with the sheet's last frame (`cachedStill`,
/// `still`), at the rung the drawn size asks for, once the sheet is fully
/// decoded, and the avatar shows its initials until then.
///
/// Resolution is asynchronous and cached: the first ask for a sheet starts
/// it, and every view waiting on it is told.
@MainActor
public final class AnimatedAvatars {
    /// Nonisolated: the image pipeline, which serves a sheet avatar's still,
    /// takes it from any thread.
    public nonisolated static let shared = AnimatedAvatars()

    /// The fragment that marks a sheet avatar's URL. Mirrored by the mock
    /// (`MockSocialDataset.sheetAvatarFragment`); the app checks the two agree.
    public nonisolated static let sheetFragment = "avatar-sheet"

    /// Whether `url` is a sheet avatar's — never a photo.
    public nonisolated static func isSheet(_ url: URL?) -> Bool {
        url?.fragment == sheetFragment
    }

    /// A sheet's cell size (core-platform-backend#948: 128 and 256 px).
    public enum Rung: Int, Sendable, CaseIterable {
        case px128 = 128
        case px256 = 256

        /// The smallest rung that covers `pixels` on a side, else the
        /// largest: the profile header's ~300 px avatar takes 256, slightly
        /// upscaled at @3x (accepted, 2026-10-19).
        public init(pixels: CGFloat) {
            self = Self.allCases.first { CGFloat($0.rawValue) >= pixels } ?? .px256
        }

        /// The rung for a picture decoded at `bucket`.
        public init(bucket: ImageBucket) {
            self.init(pixels: CGFloat(bucket.pixels ?? Rung.px256.rawValue))
        }
    }

    struct Key: Hashable, Sendable {
        let url: URL
        let rung: Rung
    }

    /// Set once at launch by the app. Nil: no avatar animates.
    public var resolver: (any AnimatedAvatarResolving)?

    /// The decoded sheets and their stills, by avatar and rung — on
    /// CacheKit, budgeted by bytes like the map's previews
    /// (`AnimatedIconCatalog`). 1.5 MB a face at the 128 px rung. Read from
    /// any thread (`cachedStill`): the cache is its own lock.
    private nonisolated let arts: MemoryCache<Key, Art>
    /// Sheets known to be missing.
    private var missing: Set<Key> = []
    private var inflight: [Key: Task<Void, Never>] = [:]
    private var waiting: [Key: [(AnimatedIconSheet?) -> Void]] = [:]

    /// A face's sheet and its still, cut once.
    struct Art: Sendable {
        let sheet: AnimatedIconSheet
        let still: UIImage?
    }

    nonisolated init(registry: UIAssetCaches? = .shared) {
        arts = UIAssetCaches.memoryCache(
            "UIAssets.avatarSheets", budget: .fixed(bytes: 32 * CacheBytes.mebibyte), priorityClass: .standard
        )
        registry?.adopt(arts)
    }

    /// The sheet for `url` at `rung` if it is known now.
    public func cachedSheet(for url: URL, rung: Rung) -> AnimatedIconSheet? {
        arts.value(for: Key(url: url, rung: rung))?.sheet
    }

    /// The still an animated avatar rests on — its sheet's last frame — if
    /// the sheet is decoded. From any thread: what the image pipeline serves
    /// a sheet avatar's URL from.
    public nonisolated func cachedStill(for url: URL, rung: Rung) -> UIImage? {
        arts.value(for: Key(url: url, rung: rung))?.still
    }

    /// The still, once the sheet is resolved and decoded; nil when there is
    /// no sheet. Never a photo: a sheet avatar has none.
    public nonisolated func still(for url: URL, rung: Rung) async -> UIImage? {
        if let known = cachedStill(for: url, rung: rung) { return known }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                self.sheet(for: url, rung: rung) { _ in continuation.resume() }
            }
        }
        return cachedStill(for: url, rung: rung)
    }

    /// Resolves `url`'s sheet at `rung`, calling `completion` on the main
    /// actor with it (or nil) — at once when it is already known.
    public func sheet(for url: URL, rung: Rung, completion: @escaping (AnimatedIconSheet?) -> Void) {
        let key = Key(url: url, rung: rung)
        if let known = cachedSheet(for: url, rung: rung) { return completion(known) }
        if missing.contains(key) { return completion(nil) }
        guard let resolver, Self.isSheet(url) else { return completion(nil) }
        waiting[key, default: []].append(completion)
        guard inflight[key] == nil else { return }
        inflight[key] = Task { [weak self] in
            let sheet = await resolver.sheet(for: url, rung: rung)
            guard let self else { return }
            inflight[key] = nil
            if let sheet {
                _ = arts.insert(Art(sheet: sheet, still: Self.lastFrame(of: sheet)), for: key, cost: sheet.byteCost)
            } else {
                missing.insert(key)
            }
            let callbacks = waiting.removeValue(forKey: key) ?? []
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
    ///
    /// ⚠️ BAKED AS A SEAMLESS LOOP THAT ENDS ON `face` (#1424,
    /// core-platform-backend#948): the last frame IS the face — the still
    /// every animated avatar rests on — and the clip cross-fades out of it
    /// over the first `blendFrames` and back into it over the last ones. So
    /// rest → frame 0 … last → rest has no cut, and the avatar's photo and
    /// its still are one picture. Without a face, the tail fades into the
    /// clip's first frame instead.
    public nonisolated static func bakeSquareSheet(
        from source: AnimatedIconSheet, cellPX: Int = 128, endingOn face: UIImage? = nil, blendFrames: Int = 6
    ) -> AnimatedIconSheet? {
        guard let image = source.sheet.cgImage else { return nil }
        let columns = 4
        let count = source.frameCount
        let rows = Int(ceil(Double(count) / Double(columns)))
        let size = CGSize(width: columns * cellPX, height: rows * cellPX)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cells: [CGImage?] = source.frameRects.map { unit in
            let frame = CGRect(x: unit.minX * width, y: unit.minY * height,
                               width: unit.width * width, height: unit.height * height)
            let side = min(frame.width, frame.height)
            return image.cropping(to: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side).integral)
        }
        let anchor: UIImage? = face.flatMap(squareCrop) ?? cells.first.flatMap { $0 }.map { UIImage(cgImage: $0) }
        let blend = max(0, min(blendFrames, (count - 1) / 2))
        let baked = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (index, cell) in cells.enumerated() {
                let target = CGRect(x: (index % columns) * cellPX, y: (index / columns) * cellPX,
                                    width: cellPX, height: cellPX)
                if let cell { UIImage(cgImage: cell).draw(in: target) }
                let weight = anchorWeight(index: index, count: count, blend: blend)
                if weight > 0, let anchor { anchor.draw(in: target, blendMode: .normal, alpha: weight) }
            }
        }
        return AnimatedIconSheet(
            sheet: baked, frameCount: count, columns: columns, frameDuration: source.frameDuration
        )
    }

    /// How much of the face frame `index` shows: all of it on the last frame,
    /// fading out over the head and back in over the tail, none between.
    nonisolated static func anchorWeight(index: Int, count: Int, blend: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        let fromEnd = count - 1 - index
        if fromEnd <= blend { return 1 - CGFloat(fromEnd) / CGFloat(blend + 1) }
        if index < blend { return 1 - CGFloat(index + 1) / CGFloat(blend + 1) }
        return 0
    }

    /// The centre square of `image`, as an avatar is cut.
    private nonisolated static func squareCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let side = min(cg.width, cg.height)
        let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        return cg.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

}
