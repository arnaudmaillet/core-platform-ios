#if DEBUG
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// # The animated-icon instrument
///
/// Everything in this folder is a MEASURING DEVICE, not the feature. It exists
/// to answer one question before any product code is written: what does the
/// worst case actually cost?
///
/// The worst case is not a guess. `MapClusterEngine` guarantees no two markers
/// are within `clusterCellPoints` (64pt) of each other, so the viewport is a
/// packed lattice: 8 x 16 = 128 markers on a 440x956pt screen, 7 x 12 = 84 on
/// an iPhone SE 3. The lattice SATURATES — in any populated city the count is
/// the maximum, not an outlier — so "worst case" and "Tuesday" are the same
/// number. This screen draws exactly that.
///
/// ## What it concluded
///
/// The sprite sheet below was the starting proposal and it is now the FALLBACK.
/// The recommendation is `IconStill` — one picture plus three curves, played by
/// Core Animation itself — because the sheet turned out to be a cache of a
/// transform the compositor applies anyway. Measured here, 128 distinct icons
/// on the saturated lattice: **9.0 MB against 216.8 MB, same picture**. See
/// `IconMotionTrack`.
///
/// The sheet is still needed, and not as a courtesy: artwork whose PIXELS
/// change cannot be decomposed, and `.realGIF` on this screen is exactly that
/// case.
///
/// When the design is settled, `IconAtlas` / `IconStill` / `IconAtlasStore` /
/// `IconPlayback` move to `MediaCore` as real types. They are here, under
/// `#if DEBUG`, so the experiment costs the shipping app nothing.
///
/// See `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md` for the contract this
/// prototypes.

// MARK: - Atlas

/// One animated icon, baked: every frame in a single still image, plus the
/// geometry needed to walk them.
///
/// A sprite sheet rather than a GIF/APNG/Lottie for three reasons, all of which
/// this screen is built to demonstrate rather than assert:
///
/// 1. It is a STILL image, so it decodes through the app's existing image path
///    with no new decoder. (`ImagePipeline.decodeDownsampled` handed a GIF
///    returns frame zero with no error — an "animated icons" release would ship
///    silently static and pass every existing test.)
/// 2. One sheet is ONE texture. Every marker wearing this icon points at the
///    same `CGImage`; the animation is a rect sliding over it. That is what
///    makes 128 concurrent icons a memory non-event — and the
///    `.distinctPerInstance` toggle on this screen exists to show what happens
///    when it is not true.
/// 3. Playback is a `CAKeyframeAnimation` on `contentsRect`, which the render
///    server runs on its own. The app's main thread never wakes per frame.
nonisolated struct IconAtlas {
    /// The sheet. Held as `UIImage` rather than `CGImage` because `UIImage` is
    /// `Sendable` and this crosses an async boundary on the way out of the store.
    let sheet: UIImage
    let frameCount: Int
    let columns: Int
    /// Side of one cell in PIXELS, gutter included.
    let cellPixels: Int
    /// Seconds per frame. >= 1/15 by contract: see `IconPlayback` on why a
    /// 60fps icon is a battery decision, not a smoothness one.
    let frameDuration: CFTimeInterval

    /// The `contentsRect` for each frame, in UNIT coordinates.
    ///
    /// Unit coordinates are load-bearing, not incidental: `applyFace` resizes a
    /// marker between 56pt and 44pt on configure, and the real
    /// `PinCardView` is the same component for pin, cluster AND flying card, at
    /// sizes from 44pt to full screen. A unit rect survives every one of those
    /// without recomputation.
    let frameRects: [CGRect]

    var loopDuration: CFTimeInterval { frameDuration * CFTimeInterval(frameCount) }

    /// What this atlas costs resident, for the store's byte-budgeted cache.
    var byteCost: Int {
        guard let cg = sheet.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    init(sheet: UIImage, frameCount: Int, columns: Int, cellPixels: Int, frameDuration: CFTimeInterval) {
        self.sheet = sheet
        self.frameCount = frameCount
        self.columns = columns
        self.cellPixels = cellPixels
        self.frameDuration = frameDuration

        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let w = 1.0 / Double(columns)
        let h = 1.0 / Double(rows)
        self.frameRects = (0..<frameCount).map { i in
            CGRect(x: Double(i % columns) * w, y: Double(i / columns) * h, width: w, height: h)
        }
    }
}

// MARK: - Store

/// Byte-budgeted, request-coalescing, asynchronous atlas cache.
///
/// Asynchronous because that is what the real thing is: an `icon_id` on a pin
/// resolves to a sheet on a CDN. A marker therefore appears BEFORE its icon
/// exists, every time, and what it shows in that gap is a product decision the
/// instrument must be able to show you. `simulatedLatency` makes the gap
/// visible and adjustable rather than a 40ms accident on a fast network.
///
/// Two departures from `ImagePipeline`, both deliberate and both worth carrying
/// into the real implementation:
///
/// - **`totalCostLimit`, not `countLimit`.** `ImagePipeline` sets only
///   `countLimit = 300`. A sheet is ~870 KB; 300 of them is 260 MB, which the
///   count limit would never evict.
/// - **Decoded at FULL size.** `ImagePipeline.decodeDownsampled` passes a
///   `kCGImageSourceThumbnailMaxPixelSize`, which is right for a photograph and
///   catastrophic for a sprite sheet: downsample a 544x408 grid to 256px and
///   every frame boundary lands mid-pixel. The max size here is the sheet's own
///   larger dimension, which returns it untouched.
@MainActor
final class IconAtlasStore {

    /// Wraps `IconArt` for `NSCache`, which is an Objective-C class and cannot
    /// hold an enum.
    private final class Box {
        let art: IconArt
        init(_ art: IconArt) { self.art = art }
    }

    private let cache = NSCache<NSNumber, Box>()
    private var inflight: [Int: Task<IconArt, Error>] = [:]

    /// Stands in for the network. 0 means "already on disk".
    var simulatedLatency: TimeInterval = 0.35

    /// How long one turn of the motion takes, in seconds.
    ///
    /// This — not the frame count — is the authored property. A "pulse" is a
    /// one-second pulse whether you sample it 12 times or 30.
    var loopSeconds: CFTimeInterval = 1.0

    /// The contract's cap (`frame_count <= 24`), and the reason it exists: at a
    /// 136px cell a frame is 72 KiB, so 24 frames is 1.7 MiB resident per icon
    /// and the 48 MB cache holds ~28 distinct ones.
    ///
    /// On the SHEET path this is the memory lever and nothing else moves that
    /// number. On the `.still` path it moves nothing at all — the samples are
    /// keyframes of a curve, so the cap becomes a fidelity knob and 60 fps costs
    /// exactly what 12 fps costs. That difference is the whole argument for
    /// Ask C in the backend document.
    var maxFrames = 24

    /// Frames actually baked — DERIVED, never set.
    ///
    /// ⚠️ This was a fixed 12, and that was a real defect: raising fps then kept
    /// the same twelve images and merely shortened `frameDuration`, so the
    /// motion ran FASTER instead of smoother, and no extra samples were ever
    /// produced. Every fps measurement taken against that build compared twelve
    /// images played fast with twelve played slow — which is precisely why the
    /// memory cost of a high frame rate stayed invisible.
    var frameCount: Int { min(maxFrames, max(1, Int((loopSeconds * framesPerSecond).rounded()))) }

    /// True when the cap bit, so the loop plays faster than authored.
    var isTimeCompressed: Bool { Int((loopSeconds * framesPerSecond).rounded()) > maxFrames }

    var columns = 4
    var cellPixels = 136
    /// Authored rate. 30 is the recommendation — what Telegram actually presents
    /// for dense small elements — and the map may halve it at PLAYBACK for the
    /// stationary-battery case, which costs no memory because the whole sheet
    /// stays resident either way.
    var framesPerSecond: Double = 30

    /// Set false to force a distinct `CGImage` per marker — the control case for
    /// the shared-texture claim. Watch the memory readout, not the frame rate.
    var sharesTexture = true

    /// What arrives on the wire.
    ///
    /// `.still` is the RECOMMENDATION and the default: one picture plus a
    /// three-channel motion descriptor, played by Core Animation itself. It is
    /// the only rung on this ladder whose memory does not scale with frame
    /// count, and it costs 1/24th of the next one down. See `IconMotionTrack`.
    ///
    /// `.sheet` is the fallback for artwork whose motion is NOT affine: the
    /// server packed the grid, so the client does one still decode. `.gif` and
    /// `.apng` are the rung below that — an animated container the client
    /// unpacks itself, through ImageIO, with no dependency.
    ///
    /// Everything from `.sheet` down produces the same atlas and the same
    /// playback; only the bake differs, which is the entire point of baking.
    /// `.still` is the one that changes the SHAPE of the answer, which is why it
    /// is a wire format rather than a client-side toggle: in production the
    /// client renders what arrived, and a mode that could disagree with the
    /// asset is a mode that will.
    var wireFormat: WireFormat = .still

    /// `still` / `sheet` / `gif` / `apng` package the instrument's own synthetic
    /// artwork. `realGIF` uses the GIFs actually bundled in
    /// `Resources/BenchIcons` — downloaded from Wikimedia Commons, freely
    /// licensed, and chosen for how UNLIKE the synthetic set they are.
    /// See `IconAtlasBaker.bundledGIFNames`.
    ///
    /// ⚠️ `realGIF` is deliberately NOT decomposable. Those files are per-pixel
    /// animation; there is no affine track that reproduces them. Selecting it
    /// gives sheets no matter what, and the report counts them as fallbacks
    /// rather than averaging two designs into one number.
    ///
    /// What the container rungs cost on the saturated lattice, 128 distinct
    /// (17 Pro Max simulator) — and note it is the PEAK that indicts them, not
    /// the resident figure, which merely reflects the cache evicting:
    ///
    ///     still     9.0 MB projected    90.8 MB peak   1 clock   30 fps
    ///     sheet   216.8 MB projected   117.2 MB peak   1 clock   30 fps
    ///     realGIF 145.4 MB projected  *427.6 MB peak*  3 clocks  10 fps
    ///     gif     216.8 MB projected  *546.4 MB peak*  1 clock   30 fps
    ///
    /// The peak is 128 concurrent ImageIO decodes holding full-size frame
    /// buffers, and a pan IS first sighting. The `3 clocks` is worse than it
    /// looks: real files carry per-frame delays that vary INSIDE one file, so
    /// the markers stop changing on a common grid and the composite-rate
    /// argument for a quantised tick goes with it.
    ///
    /// `baked` is the only one that is not synthesised at all: it reads what
    /// `Tools/IconBaker` actually produced from Lottie — 16 stills with sampled
    /// tracks and 4 sheets, in one bundle folder with a manifest. It is the
    /// closest this instrument gets to the shipping shape, and the only setting
    /// where a MIXED field appears, which is the realistic production case:
    /// some artwork reduces and some does not, and the report says which.
    enum WireFormat: String, CaseIterable { case still, sheet, gif, apng, realGIF, baked }

    init(memoryBudgetMB: Int = 48) {
        cache.totalCostLimit = memoryBudgetMB * 1024 * 1024
    }

    // MARK: - The baked catalogue

    /// One entry of `Tools/IconBaker`'s manifest.
    ///
    /// Decoded, not hand-parsed, and deliberately mirroring the tool's `Entry`
    /// field for field: the manifest is a contract between a build step and a
    /// client, and the day the two drift is the day icons animate wrongly with
    /// nothing logging an error.
    nonisolated struct BakedEntry: Decodable {
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
        /// Fractional step, present only when the baker was forced off the
        /// contract's integer ladder — the only way to express 60 fps, since
        /// 1/60 s is 16.67 ms and `frame_ms` is a `uint32`.
        let stepMS: Double?
        let plate: String?
    }

    nonisolated static let bakedCatalog: [BakedEntry] = {
        guard let url = Bundle.main.url(forResource: "benchbaked", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BakedEntry].self, from: data)
        else { return [] }
        return entries
    }()

    /// Builds art from a manifest entry — the production path, end to end.
    private nonisolated static func loadBaked(id: Int) throws -> IconArt {
        let catalogue = bakedCatalog
        guard !catalogue.isEmpty else { throw URLError(.fileDoesNotExist) }
        let entry = catalogue[((id % catalogue.count) + catalogue.count) % catalogue.count]
        guard let url = Bundle.main.url(
            forResource: (entry.asset as NSString).deletingPathExtension,
            withExtension: (entry.asset as NSString).pathExtension
        ), let data = try? Data(contentsOf: url) else { throw URLError(.fileDoesNotExist) }

        // ⚠️ `UIImage(data:)`, NOT `decodeFullSize`. Same bytes, same files: the
        // app's own `ImagePipeline` call —
        // `CGImageSourceCreateThumbnailAtIndex` with
        // `kCGImageSourceShouldCacheImmediately` — never returns on HEIC in the
        // iOS 26 simulator. Not an error, not a crash: 128 markers sat on their
        // fallback glyph indefinitely while CPU idled at 7%. The identical
        // assets encoded as PNG went through that same call in 0.13 s.
        // Unverified on device; see the note in the backend document.
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        let step = CFTimeInterval(entry.stepMS ?? Double(entry.frameMS)) / 1000

        if entry.kind == "still", let scale = entry.scale,
           let rotation = entry.rotation, let opacity = entry.opacity {
            return .decomposed(IconStill(
                glyph: image,
                plate: entry.plate.flatMap(UIColor.init(hex:)) ?? .systemGray,
                motion: .sampled(scale: scale, rotation: rotation, opacity: opacity),
                frameCount: entry.frameCount,
                frameDuration: step,
                // The baker insets the disc by a 2px gutter in a `cellPX` cell,
                // so the client's plate has to use the SAME fraction or the
                // colour peeks out from behind the mark's own clipped rim.
                plateInsetFraction: 2 / Double(entry.cellPX)
            ))
        }
        return .sheet(IconAtlas(
            sheet: image, frameCount: entry.frameCount, columns: entry.columns ?? 4,
            cellPixels: entry.cellPX, frameDuration: step
        ))
    }

    func cached(_ id: Int) -> IconArt? { cache.object(forKey: NSNumber(value: id))?.art }

    /// What the RESIDENT atlases actually look like, as opposed to what the
    /// config asked for.
    ///
    /// The two diverge the moment real assets are involved, and the divergence
    /// is the point: a synthetic pack is one frame count and one step by
    /// construction, while a folder of real GIFs carries a different frame count
    /// and a different step in every file. `distinctSteps > 1` means the shared
    /// clock is BROKEN — icons no longer change on a common grid, and the
    /// composite-rate argument for a quantised tick evaporates.
    func residentProfile(
        ids: Range<Int>
    ) -> (frames: [Int], distinctSteps: Int, decomposed: Int, harmonic: Bool) {
        let resident = ids.compactMap { cached($0) }
        // ⚠️ The harmonic test runs on the UNROUNDED steps. Rounding first
        // destroys exactly the property being tested: a 30 fps base is
        // 33.3333 ms, its 21st multiple is 700, and 700 / 33 is 21.2 — so a
        // catalogue that IS on one grid reports as fragmented, which is the
        // verdict that would have sent the whole mixed-format design back.
        // The display set stays rounded; only the arithmetic does not.
        let exact = Set(resident.map { $0.frameDuration * 1000 })
        let shown = Set(exact.map { $0.rounded() })
        return (
            resident.map(\.frameCount).sorted(), shown.count,
            resident.count { $0.isDecomposed },
            Self.areHarmonic(exact)
        )
    }

    /// Are all these steps integer multiples of the smallest?
    ///
    /// This is the distinction that decides whether a MIXED catalogue is
    /// affordable, and counting distinct steps cannot make it. A field with
    /// steps of 33, 67, 700 and 2333 ms looks like four clocks and is one: every
    /// change instant lands on the same 30 Hz grid, so the composite rate stays
    /// bounded and a slow icon simply changes on fewer ticks. A field with steps
    /// of 33 and 50 ms also looks like two and IS two — their instants
    /// interleave, the screen composites at their least common multiple, and the
    /// battery argument for a quantised tick is gone.
    ///
    /// Same `distinctSteps` count, opposite verdicts. The tolerance is half a
    /// millisecond of accumulated drift, which is what a manifest carrying a
    /// rounded integer next to a fractional one can legitimately produce.
    nonisolated static func areHarmonic(_ steps: Set<Double>) -> Bool {
        guard let base = steps.min(), base > 0 else { return true }
        return steps.allSatisfy { abs($0 / base - ($0 / base).rounded()) * base <= 0.5 }
    }

    func purge() {
        cache.removeAllObjects()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
    }

    /// Resolves an icon id to its atlas, coalescing concurrent callers.
    ///
    /// The coalescing is the difference between a decode storm and a decode. On
    /// a saturated lattice 128 markers realize at once; if they each start their
    /// own load for the twenty distinct icons among them, that is 128 bakes
    /// instead of 20.
    func art(for id: Int) async throws -> IconArt {
        // The control case for the whole memory argument: no cache AND no
        // coalescing, so each caller really does get its own `CGImage`.
        //
        // Coalescing alone silently defeats this — 128 markers asking for 16
        // icons still merge into 16 bakes and 16 textures, so the "distinct"
        // run reads identical to the shared one and appears to refute the very
        // thing it was built to demonstrate. A control that quietly measures
        // the treatment is worse than no control.
        guard sharesTexture else { return try await bake(id).value }

        if let hit = cached(id) { return hit }
        if let running = inflight[id] { return try await running.value }

        let task = bake(id)
        inflight[id] = task
        defer { inflight[id] = nil }

        let art = try await task.value
        cache.setObject(Box(art), forKey: NSNumber(value: id), cost: art.byteCost)
        return art
    }

    private func bake(_ id: Int) -> Task<IconArt, Error> {
        let frames = frameCount
        return Task { [frames, columns, cellPixels, framesPerSecond, simulatedLatency, wireFormat] in
            if simulatedLatency > 0 {
                try await Task.sleep(for: .seconds(simulatedLatency))
            }
            // Bake and decode OFF the main actor: this is the CPU work the real
            // implementation does on a URLSession callback queue.
            return try await Task.detached(priority: .utility) { () -> IconArt in
                switch wireFormat {
                case .still:
                    return .decomposed(try Self.bakeStill(
                        id: id, frameCount: frames, cellPixels: cellPixels,
                        step: 1.0 / framesPerSecond
                    ))
                case .sheet:
                    guard let png = IconAtlasBaker.bake(
                        index: id, frameCount: frames, columns: columns, cellPixels: cellPixels
                    ) else { throw URLError(.cannotDecodeContentData) }
                    return .sheet(IconAtlas(
                        sheet: try Self.decodeFullSize(png),
                        frameCount: frames, columns: columns, cellPixels: cellPixels,
                        frameDuration: 1.0 / framesPerSecond
                    ))
                case .gif, .apng:
                    return .sheet(try Self.bakeFromContainer(
                        id: id, kind: wireFormat == .gif ? .gif : .apng,
                        maxFrames: frames, columns: columns, cellPixels: cellPixels,
                        authoredStep: 1.0 / framesPerSecond
                    ))
                case .realGIF:
                    return .sheet(try Self.bakeFromBundledGIF(
                        id: id, maxFrames: frames, columns: columns, cellPixels: cellPixels
                    ))
                case .baked:
                    // No bake at all: the work happened at publish time, which
                    // is the entire point. The client decodes one image.
                    return try Self.loadBaked(id: id)
                }
            }.value
        }
    }

    /// The decomposed path: one picture in, one picture out.
    ///
    /// Note how little happens here compared with every other bake below — no
    /// grid, no geometry, no canvas, no per-frame compositing loop. That absence
    /// IS the result: the 24 cells the other paths spend their time building are
    /// a recording of a transform the compositor applies anyway.
    ///
    /// The PNG round-trip is kept deliberately. It is the same
    /// `CGImageSourceCreateThumbnailAtIndex` decode the app already ships, so
    /// the decomposed path is measured through the real decoder rather than
    /// handed a convenient in-memory bitmap the other paths never get.
    private nonisolated static func bakeStill(
        id: Int, frameCount: Int, cellPixels: Int, step: CFTimeInterval
    ) throws -> IconStill {
        let gutter = 2
        guard let png = IconAtlasBaker.bakeStill(index: id, cellPixels: cellPixels, gutterPixels: gutter) else {
            throw URLError(.cannotDecodeContentData)
        }
        return IconStill(
            glyph: try decodeFullSize(png),
            plate: IconAtlasBaker.plate(index: id),
            motion: .procedural(IconAtlasBaker.motion(index: id)),
            frameCount: frameCount,
            frameDuration: step,
            plateInsetFraction: Double(gutter) / Double(cellPixels)
        )
    }

    /// The production path, end to end: an animated container arrives, ImageIO
    /// walks its frames at full size, each is composited into a cell of one
    /// shared buffer, and the result is a still atlas indistinguishable from a
    /// server-baked one.
    ///
    /// The container is synthesised here rather than downloaded, so the bench
    /// stays self-contained — but it is a REAL GIF or APNG, written and read by
    /// ImageIO, so the format's actual properties (GIF's single Transparent
    /// Color Index and 256-colour palette) are exercised rather than assumed.
    private nonisolated static func bakeFromContainer(
        id: Int,
        kind: IconAtlasBaker.ContainerKind,
        maxFrames: Int,
        columns: Int,
        cellPixels: Int,
        authoredStep: CFTimeInterval
    ) throws -> IconAtlas {
        let gutter = 2
        let art = cellPixels - gutter * 2
        let sourceFrames = IconAtlasBaker.frames(index: id, frameCount: maxFrames, side: art)
        guard let data = IconAtlasBaker.encodeContainer(sourceFrames, as: kind, delay: authoredStep),
              let source = RasterFrameSource(
                  data: data, maxFrames: maxFrames, plate: IconAtlasBaker.plate(index: id)
              )
        else { throw URLError(.cannotDecodeContentData) }

        let geometry = AtlasGeometry(
            frameCount: source.timeline.frameCount,
            columns: columns, cellPixels: cellPixels, gutterPixels: gutter
        )
        let canvas = AtlasCanvas(geometry: geometry)
        for index in 0..<geometry.frameCount {
            canvas.withCell(index) { source.render(frame: index, into: $0) }
        }
        guard let sheet = canvas.finish() else { throw URLError(.cannotDecodeContentData) }

        return IconAtlas(
            sheet: UIImage(cgImage: sheet),
            frameCount: geometry.frameCount,
            columns: columns,
            cellPixels: cellPixels,
            // The SOURCE's step, resampled onto the ladder — not the config's.
            // A container carries its own timing and the atlas must honour it.
            frameDuration: source.timeline.step
        )
    }

    /// The honest production path: real container bytes in, atlas out.
    ///
    /// No encode step and no synthetic artwork — the file's own frame count and
    /// its own per-frame delays drive `FrameTimeline`, which is the code path
    /// the synthetic set could never exercise because it always produced a
    /// uniform-delay loop.
    private nonisolated static func bakeFromBundledGIF(
        id: Int, maxFrames: Int, columns: Int, cellPixels: Int
    ) throws -> IconAtlas {
        let names = IconAtlasBaker.bundledGIFNames
        guard !names.isEmpty,
              let url = Bundle.main.url(forResource: names[id % names.count], withExtension: "gif"),
              let data = try? Data(contentsOf: url)
        else { throw URLError(.fileDoesNotExist) }

        let gutter = 2
        guard let source = RasterFrameSource(
            data: data, maxFrames: maxFrames, plate: IconAtlasBaker.plate(index: id)
        ) else { throw URLError(.cannotDecodeContentData) }

        let geometry = AtlasGeometry(
            frameCount: source.timeline.frameCount,
            columns: columns, cellPixels: cellPixels, gutterPixels: gutter
        )
        let canvas = AtlasCanvas(geometry: geometry)
        for index in 0..<geometry.frameCount {
            canvas.withCell(index) { source.render(frame: index, into: $0) }
        }
        guard let sheet = canvas.finish() else { throw URLError(.cannotDecodeContentData) }
        return IconAtlas(
            sheet: UIImage(cgImage: sheet), frameCount: geometry.frameCount,
            columns: columns, cellPixels: cellPixels, frameDuration: source.timeline.step
        )
    }

    /// `ImagePipeline.decodeDownsampled`, with the downsampling removed.
    ///
    /// Same `CGImageSourceCreateThumbnailAtIndex` call the app already ships, so
    /// this screen measures the real decode — but `maxPixelSize` is the sheet's
    /// own dimension, because a downsampled grid is a broken grid.
    private nonisolated static func decodeFullSize(_ data: Data) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 4096

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif
