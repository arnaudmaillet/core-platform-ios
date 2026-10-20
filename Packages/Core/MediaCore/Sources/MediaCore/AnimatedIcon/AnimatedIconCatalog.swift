import CacheKit
import ImageIO
import UIKit

/// Resolves an icon id to playable art, from a baked catalogue.
///
/// The catalogue is what `Tools/IconBaker` emits: a manifest plus one asset per
/// icon. Production will fetch these from a CDN keyed by
/// `AnimatedIcon.sheet_url` / `still_url`; today the mock reads a bundled copy,
/// and this type is the seam that will not change when the URL arrives — only
/// `loadAsset` will.
///
/// Resident icons live in the device cache's UI assets class (#971,
/// `UIAssetCaches`): kept through a memory warning and the background, after
/// feed media has gone, and dropped only on a CRITICAL warning.
@MainActor
public final class AnimatedIconCatalog: NSObject, AnimatedIconProviding {

    /// One manifest entry. Mirrors `IconBaker`'s output field for field: this is
    /// a contract between a build step and a client, and the day the two drift
    /// is the day icons animate wrongly with nothing logging an error.
    struct Entry: Decodable {
        let id: String
        let kind: String              // "still" | "sheet"
        let asset: String
        let frameCount: Int
        let frameMS: Int
        let cellPX: Int
        let columns: Int?
        /// The transparent margin inside each cell, in sheet pixels. Absent on
        /// manifests written before the baker declared it — hence optional, and
        /// hence a sheet that does not say keeps the old whole-cell sampling.
        let gutterPX: Int?
        let scale: [Double]?
        let rotation: [Double]?
        let opacity: [Double]?
        /// Fractional step, present only when the baker was pushed off the
        /// contract's integer ladder — the only way to express 60 fps, since
        /// 1/60 s is 16.67 ms and `frame_ms` is a `uint32`.
        let stepMS: Double?
        /// A video sheet's frame zero, as a time in its clip (ms) — absent on
        /// icons and on manifests baked before #539.
        let startMS: Int?
    }

    private let bundle: Bundle
    private let entries: [String: Entry]
    /// Stable order, so a caller that wants "some icon" gets the same one twice.
    public let ids: [String]
    /// Resident art, in the UI assets class.
    let cache: MemoryCache<String, AnimatedIconArt>
    private var inflight: [String: Task<AnimatedIconArt, Error>] = [:]
    /// Ids ever resolved to the cheap path: `residentDecomposed` asks the
    /// cache which of them are still there.
    private var decomposedIDs: Set<String> = []

    /// What is resident right now, and what it costs — read off the cache's
    /// own accounting, so the figure follows evictions and trims down as well
    /// as up. A resident total that only ever grows is the kind of readout
    /// that makes a memory problem look like a memory success.
    public var residentBytes: Int { cache.usage.bytes }
    public var residentCount: Int { cache.usage.count }
    /// How many of the resident icons took the cheap path.
    public var residentDecomposed: Int { decomposedIDs.filter(cache.contains).count }

    /// ⚠️ A BYTE budget, not a count.
    ///
    /// `ImagePipeline` caps by `countLimit`, which is right for photographs and
    /// wrong here: a sheet is up to 1.7 MB, so 300 of them is 500 MB and a count
    /// limit would never evict.
    ///
    /// - Parameters:
    ///   - priorityClass: `persistent` for icons, a UI asset. The map's
    ///     preview sheets are cut from posts' clips, feed media in all but
    ///     format: they pass `standard` and go with the feed under pressure.
    ///   - registry: where the cache is announced (namespace
    ///     `UIAssets.icons.<manifest>`), so the app's coordinator budgets and
    ///     trims it; nil keeps it to itself.
    public init(
        bundle: Bundle = .main, manifest: String, memoryBudgetMB: Int = 24,
        priorityClass: CachePriorityClass = .persistent, registry: UIAssetCaches? = .shared
    ) {
        self.bundle = bundle
        cache = UIAssetCaches.memoryCache(
            "UIAssets.icons.\(manifest)", budget: .fixed(bytes: memoryBudgetMB * CacheBytes.mebibyte),
            priorityClass: priorityClass
        )
        registry?.adopt(cache)
        guard let url = bundle.url(forResource: manifest, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            self.entries = [:]
            self.ids = []
            super.init()
            return
        }
        self.entries = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.ids = decoded.map(\.id)
        super.init()
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func cached(_ id: String) -> AnimatedIconArt? {
        cache.value(for: id)
    }

    /// Resolves an id, coalescing concurrent callers.
    ///
    /// The coalescing is the difference between a decode storm and a decode: on
    /// a saturated map a hundred markers realise at once, and without it they
    /// each start their own load for the same handful of icons.
    public func art(for id: String) async throws -> AnimatedIconArt {
        if let hit = cached(id) { return hit }
        if let running = inflight[id] { return try await running.value }
        guard let entry = entries[id] else { throw URLError(.fileDoesNotExist) }

        let bundle = self.bundle
        let task = Task { try await Self.load(entry, from: bundle) }
        inflight[id] = task
        defer { inflight[id] = nil }

        let art = try await task.value
        cache.insert(art, for: id, cost: art.byteCost)
        if art.isDecomposed { decomposedIDs.insert(id) }
        return art
    }

    /// Do every resident icon change on ONE grid?
    ///
    /// Counting distinct steps cannot answer this, and the distinction decides
    /// whether a mixed catalogue is affordable: steps of 33/67/700/2333 ms are
    /// four steps and one grid — every change instant lands on the 30 Hz base,
    /// so a slow icon simply changes on fewer ticks. Steps of 33 and 50 ms are
    /// two steps and two grids: their instants interleave, the screen
    /// composites at their least common multiple, and the battery argument for
    /// a quantised tick is gone.
    ///
    /// ⚠️ On the UNROUNDED steps. Rounding first destroys exactly the property
    /// being tested — a 30 fps base is 33.333 ms and its 21st multiple is 700,
    /// but 700 / 33 is 21.2.
    public var isHarmonic: Bool {
        let steps = Set(entries.values.map { Double($0.stepMS ?? Double($0.frameMS)) })
        guard let base = steps.min(), base > 0 else { return true }
        return steps.allSatisfy { abs($0 / base - ($0 / base).rounded()) * base <= 0.5 }
    }

    /// Where every asset is read and decoded: ONE serial GCD queue, never
    /// Swift's cooperative pool (#1466).
    ///
    /// ⚠️ The assets are HEIC, and the simulator's software HEVC decoder
    /// never returns when several decodes run at once (see `load`). A
    /// `UIImage(data:)` handed out undecoded only moved that decode to
    /// whoever drew it first: the animated avatar bakes and the emote
    /// mattes, seven and two `Task.detached` drawing at once, parked every
    /// thread of the cooperative pool (8 on the simulator host) in the
    /// decoder, and nothing async in the app ever ran again, XCTest's
    /// queries included. So the catalogue decodes here, one asset at a time,
    /// and hands out bitmaps. Drawing one costs no decode.
    private nonisolated static let decodeQueue = DispatchQueue(
        label: "MediaCore.AnimatedIconCatalog.decode", qos: .utility
    )

    private nonisolated static func load(
        _ entry: Entry, from bundle: Bundle
    ) async throws -> AnimatedIconArt {
        try await withCheckedThrowingContinuation { continuation in
            decodeQueue.async {
                continuation.resume(with: Result { try decode(entry, from: bundle) })
            }
        }
    }

    private nonisolated static func decode(_ entry: Entry, from bundle: Bundle) throws -> AnimatedIconArt {
        let name = (entry.asset as NSString).deletingPathExtension
        let ext = (entry.asset as NSString).pathExtension
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url),
              // ⚠️ `UIImage(data:)`, NOT `ImagePipeline.decodeDownsampled`.
              //
              // Two reasons, and the second is a live defect. Downsampling a
              // GRID is a broken grid — every frame boundary lands
              // mid-pixel. And `CGImageSourceCreateThumbnailAtIndex` with
              // `kCGImageSourceShouldCacheImmediately`, which is what that
              // helper does, NEVER RETURNS on HEIC under concurrent load in
              // the iOS 26 simulator: 128 markers sat on their fallback
              // forever, no error, 7% CPU. Same bytes through `UIImage`
              // resolved in 0.12 s.
              let encoded = UIImage(data: data)
        else { throw URLError(.cannotDecodeContentData) }
        // Decoded now, on this queue (see `decodeQueue`).
        let image = encoded.preparingForDisplay() ?? encoded

        let step = CFTimeInterval(entry.stepMS ?? Double(entry.frameMS)) / 1000
        if entry.kind == "still", let scale = entry.scale,
           let rotation = entry.rotation, let opacity = entry.opacity {
            return .decomposed(AnimatedIconStill(
                mark: image,
                track: AnimatedIconMotionTrack(
                    scales: scale, rotations: rotation, alphas: opacity, step: step
                )
            ))
        }
        return .sheet(AnimatedIconSheet(
            sheet: image, frameCount: entry.frameCount,
            columns: entry.columns ?? 4, frameDuration: step,
            gutterPX: entry.gutterPX ?? 0,
            startTime: entry.startMS.map { TimeInterval($0) / 1000 }
        ))
    }
}
