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
        var heic = true
        var plate: CGColor?
        var fit: Rasteriser.Fit = .inscribe
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
            case "--png": options.heic = false
            case "--fill": options.fit = .fill
            case "--plate": options.plate = try colour(from: next())
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
    }

    static func bake(_ url: URL, options: Options) throws -> Entry {
        let document = try LottieDocument.load(url)
        let profile = document.survey()

        // Frame count and step: honour the source's own duration, snapped to the
        // contract's ladder, capped at `maxFrames`.
        let sourceMS = document.sourceFrameCount / max(1, document.sourceFrameRate) * 1000
        var frameCount = min(options.maxFrames, max(2, Int((sourceMS / 33).rounded())))
        var frameMS = AtlasWriter.snapToLadder(sourceMS / Double(frameCount))

        try FileManager.default.createDirectory(
            at: options.output, withIntermediateDirectories: true
        )

        // The cheap path.
        if document.isSingleLayerAffine {
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
                AtlasWriter.drawCell(
                    still, into: canvas, at: .zero,
                    cellPixels: options.cellPixels, plate: options.plate
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
                    note: "\(profile.affine) affine properties, 1 animated layer"
                )
            case .failure(let refusal):
                // Affine but not reducible by THIS tool. Sheeted, and said so —
                // silently sheeting it would hide a fixable authoring problem.
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
                at: CGPoint(x: (frame % columns) * cell, y: (frame / columns) * cell),
                cellPixels: cell, plate: options.plate
            )
        }
        guard let sheet = canvas.makeImage() else {
            throw BakeError("\(document.name): cannot flatten sheet")
        }
        let asset = "\(document.name).\(options.heic ? "heic" : "png")"
        let file = options.output.appendingPathComponent(asset)
        try AtlasWriter.write(sheet, to: file, heic: options.heic)
        return Entry(
            id: document.name, kind: "sheet", asset: asset,
            frameCount: frameCount, frameMS: frameMS, cellPX: cell, columns: columns,
            scale: nil, rotation: nil, opacity: nil,
            bytes: size(of: file), note: note
        )
    }

    static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
    }

    // MARK: - Entry point

    static func run() {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            guard !options.inputs.isEmpty else {
                print("usage: IconBaker <file.lottie|file.json>… --out <dir> "
                      + "[--cell 136] [--max-frames 24] [--png] [--fill] [--plate #RRGGBB]")
                exit(2)
            }
            var entries: [Entry] = []
            for input in options.inputs {
                do {
                    let entry = try bake(input, options: options)
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
                to: options.output.appendingPathComponent("catalog.json")
            )
            let stills = entries.count { $0.kind == "still" }
            print("\n\(stills)/\(entries.count) decomposed → \(options.output.path)/catalog.json")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}

IconBaker.run()
