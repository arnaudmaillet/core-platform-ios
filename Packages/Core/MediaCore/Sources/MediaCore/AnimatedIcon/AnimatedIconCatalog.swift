import ImageIO
import UIKit

/// Resolves an icon id to playable art, from a baked catalogue.
///
/// The catalogue is what `Tools/IconBaker` emits: a manifest plus one asset per
/// icon. Production will fetch these from a CDN keyed by
/// `AnimatedIcon.sheet_url` / `still_url`; today the mock reads a bundled copy,
/// and this type is the seam that will not change when the URL arrives — only
/// `loadAsset` will.
@MainActor
public final class AnimatedIconCatalog: NSObject {

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
        let scale: [Double]?
        let rotation: [Double]?
        let opacity: [Double]?
        /// Fractional step, present only when the baker was pushed off the
        /// contract's integer ladder — the only way to express 60 fps, since
        /// 1/60 s is 16.67 ms and `frame_ms` is a `uint32`.
        let stepMS: Double?
    }

    private final class Box {
        let art: AnimatedIconArt
        init(_ art: AnimatedIconArt) { self.art = art }
    }

    private let bundle: Bundle
    private let entries: [String: Entry]
    /// Stable order, so a caller that wants "some icon" gets the same one twice.
    public let ids: [String]
    private let cache = NSCache<NSString, Box>()
    private var inflight: [String: Task<AnimatedIconArt, Error>] = [:]

    /// What is resident right now, and what it costs.
    ///
    /// Tracked here because `NSCache` will not say: it exposes no count, no
    /// contents and no total. Eviction is observed through
    /// `NSCacheDelegate` rather than inferred, so the figure follows the cache
    /// down as well as up — a resident total that only ever grows is the kind
    /// of readout that makes a memory problem look like a memory success.
    public private(set) var residentBytes = 0
    public private(set) var residentCount = 0
    /// How many of the resident icons took the cheap path.
    public private(set) var residentDecomposed = 0

    /// ⚠️ A BYTE budget, not a count.
    ///
    /// `ImagePipeline` caps by `countLimit`, which is right for photographs and
    /// wrong here: a sheet is up to 1.7 MB, so 300 of them is 500 MB and a count
    /// limit would never evict.
    public init(bundle: Bundle = .main, manifest: String, memoryBudgetMB: Int = 24) {
        self.bundle = bundle
        cache.totalCostLimit = memoryBudgetMB * 1024 * 1024
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
        cache.delegate = self
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func cached(_ id: String) -> AnimatedIconArt? {
        cache.object(forKey: id as NSString)?.art
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
        cache.setObject(Box(art), forKey: id as NSString, cost: art.byteCost)
        residentBytes += art.byteCost
        residentCount += 1
        if art.isDecomposed { residentDecomposed += 1 }
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

    private nonisolated static func load(
        _ entry: Entry, from bundle: Bundle
    ) async throws -> AnimatedIconArt {
        try await Task.detached(priority: .utility) {
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
                  let image = UIImage(data: data)
            else { throw URLError(.cannotDecodeContentData) }

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
                columns: entry.columns ?? 4, frameDuration: step
            ))
        }.value
    }
}

extension AnimatedIconCatalog: NSCacheDelegate {
    /// ⚠️ Called on whatever thread evicted, which is why the accounting hops
    /// back to the main actor rather than mutating from here. `NSCache` also
    /// evicts on memory PRESSURE, not only over budget, so this is the only
    /// place the resident figure can learn it went down.
    public nonisolated func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let box = obj as? Box else { return }
        let cost = box.art.byteCost
        let decomposed = box.art.isDecomposed
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.residentBytes = max(0, self.residentBytes - cost)
            self.residentCount = max(0, self.residentCount - 1)
            if decomposed { self.residentDecomposed = max(0, self.residentDecomposed - 1) }
        }
    }
}
