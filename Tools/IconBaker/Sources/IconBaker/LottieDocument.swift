import Foundation

/// A Lottie file, and the one question the pipeline needs answered about it.
///
/// Mirrors `Scripts/lottie-decomposability.py` deliberately: the script is what
/// a designer or a reviewer runs on one file, this is what the pipeline runs on
/// all of them, and if the two ever disagree the contract has two definitions of
/// "decomposable", which is worse than having none.
struct LottieDocument {

    let name: String
    let json: [String: Any]
    /// Frames per second the composition was authored at.
    let sourceFrameRate: Double
    /// Composition length in source frames.
    let sourceFrameCount: Double
    let rawJSON: Data

    // MARK: - Loading

    /// dotLottie is a ZIP around the JSON; a bare `.json` is the animation.
    ///
    /// Unzipped by shelling out rather than by adding an archive dependency: the
    /// alternative is a second package in a tool whose whole point is to keep
    /// dependencies out of the shipping app, and `unzip` is on every macOS.
    static func load(_ url: URL) throws -> LottieDocument {
        let data: Data
        if url.pathExtension.lowercased() == "lottie" {
            data = try unzipAnimation(url)
        } else {
            data = try Data(contentsOf: url)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BakeError("\(url.lastPathComponent): not a JSON object")
        }
        let inPoint = json["ip"] as? Double ?? 0
        let outPoint = json["op"] as? Double ?? 0
        return LottieDocument(
            name: url.deletingPathExtension().lastPathComponent,
            json: json,
            sourceFrameRate: json["fr"] as? Double ?? 30,
            sourceFrameCount: max(1, outPoint - inPoint),
            rawJSON: data
        )
    }

    private static func unzipAnimation(_ url: URL) throws -> Data {
        let listing = try shell("/usr/bin/unzip", ["-Z1", url.path])
        guard let entry = String(data: listing, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasSuffix(".json") && !$0.contains("manifest") })
        else { throw BakeError("\(url.lastPathComponent): no animation JSON inside") }
        return try shell("/usr/bin/unzip", ["-p", url.path, entry])
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: - Classification

    /// Lottie transform channels — everything Core Animation applies for free.
    /// A property under a layer's `ks` or a shape group's `tr` is affine
    /// wherever it appears beneath it, so the flag is INHERITED down the walk.
    struct Survey {
        var affine = 0
        var raster: [String: Int] = [:]
        var animatedLayers = 0

        var rasterCount: Int { raster.values.reduce(0, +) }
        var isAffine: Bool { raster.isEmpty }
    }

    func survey() -> Survey {
        var result = Survey()
        walk(json, inTransform: false, key: nil, into: &result)
        for layer in json["layers"] as? [[String: Any]] ?? [] {
            var perLayer = Survey()
            walk(layer, inTransform: false, key: nil, into: &perLayer)
            if perLayer.affine + perLayer.rasterCount > 0 { result.animatedLayers += 1 }
        }
        return result
    }

    private func walk(_ node: Any, inTransform: Bool, key: String?, into result: inout Survey) {
        if let dictionary = node as? [String: Any] {
            // An animatable Lottie property is `{"a": 1, "k": [keyframes…]}`.
            if dictionary["a"] as? Int == 1, dictionary["k"] is [Any] {
                if inTransform {
                    result.affine += 1
                } else {
                    let label = Self.readable[key ?? "?"] ?? (key ?? "?")
                    result.raster[label, default: 0] += 1
                }
                return
            }
            let isGroupTransform = dictionary["ty"] as? String == "tr"
            for (childKey, value) in dictionary {
                walk(value,
                     inTransform: inTransform || isGroupTransform || childKey == "ks",
                     key: childKey, into: &result)
            }
        } else if let array = node as? [Any] {
            for value in array { walk(value, inTransform: inTransform, key: key, into: &result) }
        }
    }

    static let readable: [String: String] = [
        "sh": "path morph", "c": "colour", "tm": "trim path", "w": "stroke width",
        "d": "dash", "e": "gradient end", "s": "gradient start", "g": "gradient stops",
        "ir": "inner radius", "or": "outer radius", "pt": "star points",
        "rz": "rounded corners", "cp": "repeater copies", "o": "fill opacity"
    ]

    // MARK: - The track

    /// Extracts the motion track from a SINGLE-LAYER affine composition.
    ///
    /// Single-layer on purpose, and the limit is honest rather than lazy: with
    /// N animated layers the decomposition is N stills and N tracks, and
    /// isolating one Lottie layer's artwork from the rest is a rendering problem
    /// this tool does not need to solve yet. A map icon is one mark on a disc —
    /// exactly the N = 1 case — and `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`
    /// now says so as an authoring rule. Anything else bakes a sheet, which is
    /// correct output, just not the cheap one.
    ///
    /// SAMPLED, not transcribed. Lottie keyframes carry bezier easing (`i`/`o`
    /// control points) that a uniformly-spaced `MotionTrack` cannot express, so
    /// the track is the eased curve evaluated at N even instants rather than the
    /// keyframes copied across. Copying them would produce an icon that hits the
    /// right poses at the wrong times — which looks like a subtly wrong
    /// animation and reads like nothing at all in a diff. See `TransformTrack`.
    var isSingleLayerAffine: Bool {
        let profile = survey()
        return profile.isAffine && profile.animatedLayers == 1
    }
}

extension LottieDocument {

    /// The same composition with its animated layer transform NEUTRALISED —
    /// scale 100%, rotation 0, opacity 100% — so the still is the artwork at
    /// identity.
    ///
    /// ⚠️ Without this the still is rendered at the layer's frame-zero pose, and
    /// since `MotionTrack` carries ABSOLUTE values the client applies that pose
    /// a second time: a mark authored to pulse between 0.80 and 1.10 renders
    /// between 0.64 and 0.88. Twenty percent small, in proportion, with correct
    /// motion — it looks like a design choice, and every automated check passes.
    /// Caught by baking the fixture and looking at it.
    ///
    /// Position and anchor are left alone deliberately: they are required to be
    /// static for the track to be extractable at all, so they are part of the
    /// artwork's own framing rather than part of its motion.
    func neutralisingLayerTransform() throws -> LottieDocument {
        var copy = json
        guard var layers = copy["layers"] as? [[String: Any]] else { return self }
        for index in layers.indices {
            guard var transform = layers[index]["ks"] as? [String: Any] else { continue }
            guard Self.animates(transform) else { continue }
            transform["s"] = ["a": 0, "k": [100, 100, 100]]
            transform["r"] = ["a": 0, "k": 0]
            transform["o"] = ["a": 0, "k": 100]
            layers[index]["ks"] = transform
        }
        copy["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: copy)
        return LottieDocument(
            name: name, json: copy, sourceFrameRate: sourceFrameRate,
            sourceFrameCount: sourceFrameCount, rawJSON: data
        )
    }

    static func animates(_ node: Any?) -> Bool {
        guard let dictionary = node as? [String: Any] else { return false }
        if dictionary["a"] as? Int == 1 { return true }
        return dictionary.values.contains { animates($0) }
    }
}

struct BakeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
