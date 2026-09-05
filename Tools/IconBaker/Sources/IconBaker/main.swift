import CoreGraphics
import Foundation

/// # IconBaker
///
/// Turns designer-authored Lottie into what the map client actually wants, at
/// publish time, taking the cheap path whenever the artwork allows it:
///
///     IconBaker Stickers/*.lottie --out build/icons
///
/// Two outputs, and which one a file gets is decided by the file, not by a flag:
///
/// - **still + track** when the composition is one affinely-animated layer.
///   One picture and three curves; the client animates it with Core Animation
///   for free. **9.0 MB for 128 distinct icons.**
/// - **sprite sheet** otherwise. Correct, and 24x more expensive:
///   **216.8 MB for the same 128.**
///
/// Both numbers are measured, on the map's real worst case — 128 markers on the
/// saturated 64pt lattice. See `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`.
///
/// The tool never guesses. A file that cannot be reduced is sheeted and SAID to
/// be sheeted, with the properties that forced it named, because a track that
/// does not reproduce its artwork is a defect nothing downstream can detect.
@MainActor
struct IconBaker {

    struct Options {
        var inputs: [URL] = []
        var output = URL(fileURLWithPath: "build/icons")
        var cellPixels = 136
        var maxFrames = 24
        /// Keys are not frames.
        ///
        /// ⚠️ The 24 above is the SHEET's cap and it exists because a frame is
        /// 72 KiB of texture. A track's sample is three floats — about 12 bytes
        /// — so applying the same cap to a track buys nothing and costs
        /// smoothness. It did exactly that: a two-second loop came out as 24
        /// keys, an 83 ms step, and icons visibly stepping at 12 fps on a
        /// screen asking for 30. The cap was right, applied to the wrong thing.
        var maxKeys = 240
        /// Off-ladder track rate, for experiments the contract does not allow.
        ///
        /// ⚠️ `frame_ms` is a `uint32` and the ladder is {33, 50, 66, 83, 100},
        /// so the contract CANNOT express 60 fps: 1/60 s is 16.67 ms and no
        /// integer rounds to it. 16 ms is 62.5 fps and 17 ms is 58.8 fps, and a
        /// stepped animation whose step is not the refresh interval beats
        /// against the display instead of landing on it. Setting this writes a
        /// fractional `stepMS` alongside `frameMS`, which is deliberately a
        /// SEPARATE field: the manifest stays contract-shaped, and anything
        /// reading the fractional one knows it is off-contract.
        var trackFPS: Double?
        var heic = true
        var plate: CGColor?
        var plateHex: String?
        var manifest = "catalog.json"
        var fit: Rasteriser.Fit = .inscribe
        var shape: AtlasWriter.Shape = .disc
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() throws -> String {
                index += 1
                guard index < arguments.count else { throw BakeError("\(argument) needs a value") }
                return arguments[index]
            }
            switch argument {
            case "--out": options.output = URL(fileURLWithPath: try next())
            case "--cell": options.cellPixels = Int(try next()) ?? 136
            case "--max-frames": options.maxFrames = Int(try next()) ?? 24
            case "--max-keys": options.maxKeys = Int(try next()) ?? 240
            case "--fps": options.trackFPS = Double(try next())
            case "--manifest": options.manifest = try next()
            case "--png": options.heic = false
            case "--fill": options.fit = .fill
            case "--square": options.shape = .square; options.fit = .fill
            case "--plate":
                let hex = try next()
                options.plate = try colour(from: hex)
                options.plateHex = hex.hasPrefix("#") ? hex : "#" + hex
            default: options.inputs.append(URL(fileURLWithPath: argument))
            }
            index += 1
        }
        return options
    }

    static func colour(from hex: String) throws -> CGColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            throw BakeError("--plate wants #RRGGBB, got \(hex)")
        }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }

    // MARK: - Baking one icon

    struct Entry: Encodable {
        let id: String
        let kind: String            // "still" | "sheet"
        let asset: String
        let frameCount: Int
        let frameMS: Int
        let cellPX: Int
        let columns: Int?
        let scale: [Double]?
        let rotation: [Double]?
        let opacity: [Double]?
        let bytes: Int
        let note: String
        /// Fractional step in milliseconds. Present only when `--fps` forced a
        /// rate the integer ladder cannot express; the client prefers it.
        let stepMS: Double?
        /// Set on `still` entries only. The plate is a COLOUR here rather than
        /// pixels, deliberately: the still is the thing the client transforms,
        /// so a plate baked into it would spin and pulse along with the mark.
        /// On a `sheet` the whole cell is the frame, so the plate belongs in it.
        let plate: String?
    }

    /// Containers the client can already decode, and that this tool packs to
    /// sheets rather than passing through. See `RasterDocument` for why the
    /// pass-through is not an option on the marker field.
    static let rasterExtensions: Set<String> = ["gif", "apng", "webp", "heics", "png"]
    /// Video containers. These bake to a SHEET — never passed through, because a
    /// marker that plays an MP4 needs a decode session and the whole reason to
    /// bake one is to need none.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func bake(_ url: URL, options: Options) async throws -> Entry {
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            return try await bakeVideo(url, options: options)
        }
        if rasterExtensions.contains(url.pathExtension.lowercased()) {
            return try bakeRaster(url, options: options)
        }
        let document = try LottieDocument.load(url)
        let profile = document.survey()

        // Frame count and step: honour the source's own duration, snapped to the
        // contract's ladder, capped at `maxFrames`.
        let sourceMS = document.sourceFrameCount / max(1, document.sourceFrameRate) * 1000
        var frameCount = min(options.maxFrames, max(2, Int((sourceMS / 33).rounded())))
        var frameMS = AtlasWriter.snapToLadder(sourceMS / Double(frameCount))

        // A TRACK is sampled at the contract's fastest rung and only coarsened
        // if the key budget bites — where a sheet is capped first and coarsened
        // by construction. Same ladder, opposite priority, because the two are
        // limited by different things.
        func trackSampling() -> (keys: Int, stepMS: Int) {
            if let fps = options.trackFPS, fps > 0 {
                let exact = 1000 / fps
                return (min(options.maxKeys, max(2, Int((sourceMS / exact).rounded()))),
                        Int(exact.rounded()))
            }
            for rung in AtlasWriter.ladderMS {
                let keys = max(2, Int((sourceMS / Double(rung)).rounded()))
                if keys <= options.maxKeys { return (keys, rung) }
            }
            let rung = AtlasWriter.ladderMS.last ?? 100
            return (min(options.maxKeys, max(2, Int((sourceMS / Double(rung)).rounded()))), rung)
        }

        try FileManager.default.createDirectory(
            at: options.output, withIntermediateDirectories: true
        )

        // The cheap path.
        if document.isSingleLayerAffine {
            // Kept, because the sheet fallback below needs them back: a track's
            // key count can legitimately exceed `maxFrames`, and handing that to
            // `bakeSheet` would ask for a 61-cell grid the contract forbids.
            let sheetFrameCount = frameCount, sheetFrameMS = frameMS
            let sampling = trackSampling()
            frameCount = sampling.keys
            frameMS = sampling.stepMS
            switch TransformTrack.extract(from: document, samples: frameCount) {
            case .success(let track):
                // Rasterised from the NEUTRALISED composition, not from this
                // one: the track carries absolute values, so a still rendered at
                // the layer's frame-zero pose would have that pose applied
                // twice. See `neutralisingLayerTransform()`.
                let rasteriser = try Rasteriser(
                    document: try document.neutralisingLayerTransform(),
                    side: options.cellPixels, fit: options.fit
                )
                guard let still = rasteriser.image(atProgress: 0, side: options.cellPixels),
                      let canvas = AtlasWriter.canvas(
                          width: options.cellPixels, height: options.cellPixels
                      )
                else { throw BakeError("\(document.name): rasteriser produced nothing") }
                // `plate: nil` — see `Entry.plate`. The mark is clipped to the
                // disc so it cannot escape when the track scales it up, but the
                // background stays transparent for the client's own plate layer.
                AtlasWriter.drawCell(
                    still, into: canvas, at: .zero,
                    cellPixels: options.cellPixels, plate: nil, shape: options.shape
                )
                guard let flattened = canvas.makeImage() else {
                    throw BakeError("\(document.name): cannot flatten still")
                }
                let asset = "\(document.name).\(options.heic ? "heic" : "png")"
                let file = options.output.appendingPathComponent(asset)
                try AtlasWriter.write(flattened, to: file, heic: options.heic)
                return Entry(
                    id: document.name, kind: "still", asset: asset,
                    frameCount: frameCount, frameMS: frameMS, cellPX: options.cellPixels,
                    columns: nil,
                    scale: track.scale, rotation: track.rotation, opacity: track.opacity,
                    bytes: size(of: file),
                    note: "\(profile.affine) affine properties, 1 animated layer",
                    stepMS: options.trackFPS.map { 1000 / $0 },
                    plate: options.plateHex
                )
            case .failure(let refusal):
                // Affine but not reducible by THIS tool. Sheeted, and said so —
                // silently sheeting it would hide a fixable authoring problem.
                frameCount = sheetFrameCount
                frameMS = sheetFrameMS
                return try bakeSheet(
                    document, options: options,
                    frameCount: &frameCount, frameMS: &frameMS,
                    note: "affine but sheeted: \(refusal)"
                )
            }
        }

        let reasons = profile.raster.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.value)x \($0.key)" }.joined(separator: ", ")
        let why = profile.isAffine
            ? "affine but \(profile.animatedLayers) animated layers"
            : "\(profile.rasterCount) raster properties (\(reasons))"
        return try bakeSheet(
            document, options: options,
            frameCount: &frameCount, frameMS: &frameMS, note: why
        )
    }

    /// A video clip into a preview sheet.
    ///
    /// The frame count is the memory lever and the only one: at a 170px cell
    /// (56pt media face at @3x plus the gutter) each frame is 112.9 KiB
    /// resident, so 24 frames is 2.65 MB per clip and 19 markers is 50.4 MB.
    /// Nothing about the source changes that — a longer clip is sampled, not
    /// packed.
    static func bakeVideo(_ url: URL, options: Options) async throws -> Entry {
        let document = try await VideoDocument.load(url)
        let stepMS = options.trackFPS.map { 1000 / $0 } ?? 83.0
        let frameCount = options.maxFrames
        let window = Double(frameCount) * stepMS / 1000
        // Start a little in: the first second of a clip is often a fade or a
        // title card, and a marker preview that opens on black reads as broken.
        let start = min(1.0, max(0, document.duration - window))

        let frames = try await document.frames(
            count: frameCount, start: start, window: window, side: options.cellPixels
        )
        guard !frames.isEmpty else { throw BakeError("\(document.name): no frames") }

        let columns = 4
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let cell = options.cellPixels
        guard let canvas = AtlasWriter.canvas(width: cell * columns, height: cell * rows) else {
            throw BakeError("\(document.name): cannot allocate sheet")
        }
        for (index, frame) in frames.enumerated() {
            AtlasWriter.drawCell(
                frame, into: canvas,
                at: AtlasWriter.origin(frame: index, columns: columns, rows: rows, cellPixels: cell),
                cellPixels: cell, plate: options.plate, shape: options.shape
            )
        }
        guard let sheet = canvas.makeImage() else {
            throw BakeError("\(document.name): cannot flatten sheet")
        }
        let empty = AtlasWriter.emptyCells(
            in: sheet, frameCount: frameCount, columns: columns, cellPixels: cell
        )
        guard empty.isEmpty else {
            throw BakeError("\(document.name): cells \(empty) are transparent")
        }
        let asset = "\(document.name).\(options.heic ? "heic" : "png")"
        let file = options.output.appendingPathComponent(asset)
        try AtlasWriter.write(sheet, to: file, heic: options.heic)
        return Entry(
            id: document.name, kind: "sheet", asset: asset,
            frameCount: frameCount, frameMS: Int(stepMS.rounded()), cellPX: cell,
            columns: columns, scale: nil, rotation: nil, opacity: nil,
            bytes: size(of: file),
            note: String(
                format: "video: %.1fs source, sampled %d frames from %.1fs over %.1fs",
                document.duration, frameCount, start, window
            ),
            stepMS: options.trackFPS.map { 1000 / $0 }, plate: nil
        )
    }

    /// A GIF (or APNG, or animated WebP) onto the catalogue's clock.
    ///
    /// Nothing here tries to decompose: a container is per-pixel animation and
    /// there is no affine track that reproduces it. What it CAN be given is the
    /// same step as everything else, which is the difference between a mixed
    /// catalogue that composites on one grid and one that fragments into as many
    /// grids as it has source files.
    static func bakeRaster(_ url: URL, options: Options) throws -> Entry {
        let document = try RasterDocument.load(url)
        let loopMS = max(1, document.loopSeconds * 1000)

        // A HARMONIC step: an integer multiple of the catalogue's base.
        //
        // The naive choice is the base step itself, and it is wrong in a way
        // that is obvious once you look at the assets rather than the numbers.
        // Real GIF loops in this repo run from 0.18 s to 56 s; forcing the 56 s
        // one onto 24 cells at 33 ms plays it in 0.79 s — SEVENTY TIMES too
        // fast, a strobe rather than an animation. The `TIME-COMPRESSED` flag
        // said so and I nearly shipped it anyway.
        //
        // The alternative usually reached for — let slow assets keep their own
        // step — fragments the clock, and the whole battery argument for a
        // quantised tick is that every icon changes on ONE grid.
        //
        // Neither is necessary. If every step is k x base for integer k, every
        // change instant still lands on the base grid: the composite rate stays
        // bounded by 30 Hz and a slow icon simply changes on fewer of those
        // ticks. Duration is preserved exactly, the cap is respected, and the
        // grid is intact. Pick the smallest k that fits the frame budget.
        let base = options.trackFPS.map { 1000 / $0 }
            ?? Double(AtlasWriter.ladderMS.first ?? 33)
        let multiple = max(1, Int(ceil(loopMS / (base * Double(options.maxFrames)))))
        let stepMS = base * Double(multiple)
        let frameCount = max(2, min(options.maxFrames, Int((loopMS / stepMS).rounded())))
        let compressed = false

        let columns = 4
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let cell = options.cellPixels
        guard let canvas = AtlasWriter.canvas(width: cell * columns, height: cell * rows) else {
            throw BakeError("\(document.name): cannot allocate sheet")
        }
        // Sampled across the SOURCE's whole loop, so a capped frame count
        // compresses time evenly instead of truncating the animation.
        for frame in 0..<frameCount {
            let t = document.loopSeconds * Double(frame) / Double(frameCount)
            AtlasWriter.drawCell(
                document.frame(at: t), into: canvas,
                at: AtlasWriter.origin(
                    frame: frame, columns: columns, rows: rows, cellPixels: cell
                ),
                cellPixels: cell, plate: options.plate, shape: options.shape
            )
        }
        guard let sheet = canvas.makeImage() else {
            throw BakeError("\(document.name): cannot flatten sheet")
        }
        let empty = AtlasWriter.emptyCells(
            in: sheet, frameCount: frameCount, columns: columns, cellPixels: cell
        )
        guard empty.isEmpty else {
            throw BakeError("\(document.name): cells \(empty) are transparent — "
                            + "the grid does not match what the client reads")
        }
        let asset = "\(document.name).\(options.heic ? "heic" : "png")"
        let file = options.output.appendingPathComponent(asset)
        try AtlasWriter.write(sheet, to: file, heic: options.heic)

        let steps = Set(document.durations.map { ($0 * 1000).rounded() }).count
        return Entry(
            id: document.name, kind: "sheet", asset: asset,
            frameCount: frameCount, frameMS: Int(stepMS.rounded()), cellPX: cell,
            columns: columns, scale: nil, rotation: nil, opacity: nil,
            bytes: size(of: file),
            note: "raster: \(document.frameCount) src frames, \(steps) src step(s), "
                + String(format: "%.2fs loop", document.loopSeconds)
                + (multiple > 1 ? ", step = \(multiple)x base (on-grid)" : ", step = base")
                + (compressed ? " — TIME-COMPRESSED" : ""),
            stepMS: stepMS, plate: nil
        )
    }

    static func bakeSheet(
        _ document: LottieDocument, options: Options,
        frameCount: inout Int, frameMS: inout Int, note: String
    ) throws -> Entry {
        let columns = 4
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let cell = options.cellPixels
        guard let canvas = AtlasWriter.canvas(width: cell * columns, height: cell * rows) else {
            throw BakeError("\(document.name): cannot allocate sheet")
        }
        let rasteriser = try Rasteriser(document: document, side: cell, fit: options.fit)
        for frame in 0..<frameCount {
            let image = rasteriser.image(
                atProgress: Double(frame) / Double(frameCount), side: cell
            )
            AtlasWriter.drawCell(
                image, into: canvas,
                at: AtlasWriter.origin(
                    frame: frame, columns: columns, rows: rows, cellPixels: cell
                ),
                cellPixels: cell, plate: options.plate, shape: options.shape
            )
        }
        guard let sheet = canvas.makeImage() else {
            throw BakeError("\(document.name): cannot flatten sheet")
        }
        let empty = AtlasWriter.emptyCells(
            in: sheet, frameCount: frameCount, columns: columns, cellPixels: cell
        )
        guard empty.isEmpty else {
            throw BakeError("\(document.name): cells \(empty) are transparent — "
                            + "the grid does not match what the client reads")
        }
        let asset = "\(document.name).\(options.heic ? "heic" : "png")"
        let file = options.output.appendingPathComponent(asset)
        try AtlasWriter.write(sheet, to: file, heic: options.heic)
        return Entry(
            id: document.name, kind: "sheet", asset: asset,
            frameCount: frameCount, frameMS: frameMS, cellPX: cell, columns: columns,
            scale: nil, rotation: nil, opacity: nil,
            bytes: size(of: file), note: note, stepMS: nil, plate: nil
        )
    }

    static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
    }

    // MARK: - Entry point

    static func run() async {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            guard !options.inputs.isEmpty else {
                print("usage: IconBaker <file.lottie|file.json>… --out <dir> "
                      + "[--cell 136] [--max-frames 24] [--max-keys 240] [--fps N] "
                      + "[--png] [--fill] [--square] [--plate #RRGGBB] [--manifest name.json]")
                exit(2)
            }
            var entries: [Entry] = []
            for input in options.inputs {
                do {
                    let entry = try await bake(input, options: options)
                    entries.append(entry)
                    let cost = entry.kind == "still"
                        ? "9.0 MB @128"
                        : String(format: "%.1f MB @128",
                                 Double(entry.frameCount) * Double(entry.cellPX * entry.cellPX * 4)
                                    * 128 / 1024 / 1024)
                    print(String(
                        format: "%-16s %-6s %2d frames @%3dms  %6.1f KB wire  %-11s  %@",
                        (entry.id as NSString).utf8String!,
                        (entry.kind as NSString).utf8String!,
                        entry.frameCount, entry.frameMS, Double(entry.bytes) / 1024,
                        (cost as NSString).utf8String!,
                        entry.note
                    ))
                } catch {
                    print("\(input.lastPathComponent): \(error)")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(
                to: options.output.appendingPathComponent(options.manifest)
            )
            let stills = entries.count { $0.kind == "still" }
            print("\n\(stills)/\(entries.count) decomposed → \(options.output.path)/\(options.manifest)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}

await IconBaker.run()
