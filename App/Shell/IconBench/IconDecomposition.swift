#if DEBUG
import UIKit

// MARK: - Motion as animation, not as pixels

/// The lever that beats every other one in this instrument by an order of
/// magnitude — and it is not a rendering technique, it is an observation about
/// the artwork.
///
/// Every motion in the catalogue is a rigid still under an AFFINE transform:
/// `IconAtlasBaker.Motion.pose(at:)` returns `(scale, rotation, alpha)` and
/// nothing else. The sprite sheet spends 24 full-colour cells recording the
/// result of applying those three numbers to ONE picture. Core Animation can
/// apply the same three numbers itself, on the render server, for free.
///
/// So the sheet is a cache of a computation the compositor was going to do
/// anyway. Deleting it costs nothing and returns 24x the memory:
///
///     136px cell, RGBA8       =  72.25 KiB
///     sheet, 24 frames        =   1.69 MiB per icon
///     decomposed, 1 still     =  72.25 KiB per icon
///     128 distinct icons      = 216.6 MB   ->   9.0 MB
///
/// **This is why the Metal question resolved the way it did.** The best Metal
/// shape measured 79-91 MB against Core Animation's 217, and paid for it with
/// 128 blocking `nextDrawable` calls per tick. This gets 9 MB on the path that
/// already costs the app zero CPU per frame.
///
/// ## The second, less obvious win
///
/// On a sheet, SMOOTHNESS COSTS MEMORY: 60fps means 60 cells. Decomposed, the
/// samples are keyframes of a curve, so smoothness costs nothing in bytes —
/// `.continuous` sampling interpolates between them and the price moves entirely
/// onto composite rate, which is a battery decision the product can take per
/// surface. That is a qualitatively different trade-off, and it is the answer to
/// "can we have 60fps icons": yes, and for free in memory.
///
/// ## What it does NOT cover, and why the instrument says so out loud
///
/// A track is only valid when the motion really IS affine. A GIF of a face
/// blinking is not — its pixels change. `IconArt` therefore carries the two
/// shapes as distinct CASES rather than as a flag, and an asset that cannot be
/// decomposed is baked to a sheet and counted as such in the report. A
/// decomposition mode that silently sheeted half the field would report the
/// average of two designs and call it one — the same class of defect as a
/// control arm that quietly measures the treatment.
nonisolated struct IconMotionTrack {

    /// Samples over the CLOSED interval [0, 1] — `frameCount + 1` of them.
    ///
    /// The closing sample exists for `.continuous`: without it, linear
    /// interpolation runs from the last keyframe back to the first, and `.spin`
    /// unwinds a whole turn BACKWARDS at every loop boundary. `.stepped` drops
    /// it again, because `CAKeyframeAnimation` in `.discrete` mode divides the
    /// duration by `values.count` and an extra value would stretch the loop.
    let scales: [Double]
    let rotations: [Double]
    let alphas: [Double]
    let step: CFTimeInterval

    var frameCount: Int { max(1, scales.count - 1) }
    var loopDuration: CFTimeInterval { step * CFTimeInterval(frameCount) }

    /// Only the channels that actually move get an animation.
    ///
    /// Not a micro-optimisation: `.spin` moves one channel, `.pulse` one,
    /// `.flicker` two. Installing three animations per marker unconditionally
    /// would put 384 animations on the render server where 154 will do — and
    /// would make the decomposed path look more expensive than the sheet's
    /// single `contentsRect` animation for no reason at all.
    var movesScale: Bool { varies(scales) }
    var movesRotation: Bool { varies(rotations) }
    var movesAlpha: Bool { varies(alphas) }
    var activeChannels: Int { (movesScale ? 1 : 0) + (movesRotation ? 1 : 0) + (movesAlpha ? 1 : 0) }

    private func varies(_ channel: [Double]) -> Bool {
        guard let first = channel.first else { return false }
        return channel.contains { abs($0 - first) > 0.0005 }
    }

    /// Builds one marker's phased samples.
    ///
    /// Phase is applied by SAMPLING FROM A ROTATED GRID, which is the exact
    /// analogue of the sheet's rotated `values` array: marker *k* starts on
    /// frame *k % n* and every marker still changes on one shared clock. The
    /// two paths therefore phase identically, which is what makes the A/B on
    /// this screen a comparison of representations rather than of two different
    /// animations.
    init(motion: IconAtlasBaker.Motion, frameCount n: Int, step: CFTimeInterval, phase: Int) {
        let count = max(1, n)
        let offset = ((phase % count) + count) % count
        self.step = step

        var scales: [Double] = [], rotations: [Double] = [], alphas: [Double] = []
        scales.reserveCapacity(count + 1)
        rotations.reserveCapacity(count + 1)
        alphas.reserveCapacity(count + 1)
        for i in 0...count {
            let pose = motion.pose(at: Double((offset + i) % count) / Double(count))
            scales.append(pose.scale)
            rotations.append(pose.rotation)
            alphas.append(pose.alpha)
        }

        // UNWRAP the rotation channel.
        //
        // `pose(at:)` returns `.spin` as t * 2pi, so the sampled sequence jumps
        // from ~2pi back to 0 exactly once per loop — at the phase boundary,
        // wherever that lands. Left alone, `.stepped` would show one backwards
        // snap per turn and `.continuous` would spend a whole keyframe interval
        // spinning the wrong way at 23x speed. Taking every step along its SHORT
        // arc and accumulating turns the sequence back into the monotone ramp
        // the artwork describes, for any phase, without special-casing `.spin`.
        for i in 1...count {
            var delta = rotations[i] - rotations[i - 1]
            if delta < -Double.pi { delta += 2 * .pi }
            if delta > Double.pi { delta -= 2 * .pi }
            rotations[i] = rotations[i - 1] + delta
        }

        self.scales = scales
        self.rotations = rotations
        self.alphas = alphas
    }

    /// The same track, from samples a BAKER produced rather than from a
    /// procedural motion.
    ///
    /// This is the production shape: `IconBaker` walks a Lottie's layer
    /// transform, evaluates After Effects' bezier easing at N even instants and
    /// ships three arrays. The client never sees a curve, only its samples —
    /// which is why the phasing here has to be identical to the procedural
    /// path's, right down to the rotation unwrap. Two ways of building the same
    /// value that phase differently would show up as one icon in the field
    /// marching out of step with its neighbours, and be blamed on the asset.
    init(sampled scale: [Double], rotation: [Double], opacity: [Double],
         step: CFTimeInterval, phase: Int) {
        // The wire carries `n + 1` samples over the closed interval; the last is
        // the loop's closing value and is regenerated after rotation.
        let count = max(1, min(scale.count, min(rotation.count, opacity.count)) - 1)
        let offset = ((phase % count) + count) % count
        self.step = step

        func phased(_ channel: [Double]) -> [Double] {
            let base = Array(channel.prefix(count))
            guard !base.isEmpty else { return [0, 0] }
            var rotated = (0..<count).map { base[(offset + $0) % count] }
            rotated.append(rotated[0])
            return rotated
        }
        self.scales = phased(scale)
        self.alphas = phased(opacity)
        self.rotations = Self.unwrapped(phased(rotation))
    }

    /// Takes every step along its SHORT arc and accumulates, so a full-turn spin
    /// stays a monotone ramp whatever phase it starts on.
    private static func unwrapped(_ channel: [Double]) -> [Double] {
        guard channel.count > 1 else { return channel }
        var result = channel
        for i in 1..<result.count {
            var delta = result[i] - result[i - 1]
            if delta < -Double.pi { delta += 2 * .pi }
            if delta > Double.pi { delta -= 2 * .pi }
            result[i] = result[i - 1] + delta
        }
        return result
    }
}

// MARK: - The still

/// One icon as ONE picture plus a description of how it moves.
///
/// The plate is a COLOUR, not a texture, and that is worth a sentence: a
/// `CALayer` with a `backgroundColor` and a circular `cornerRadius` costs zero
/// bytes of backing store and composites as a rounded-rect fill the GPU already
/// has a fast path for. The disc in the sheet, by contrast, is re-recorded in
/// full colour in every one of the 24 cells.
///
/// Where real artwork has a textured plate rather than a flat one, this becomes
/// TWO textures instead of one — and 2 against 24 is still the same finding.
nonisolated struct IconStill {
    /// The only texture this icon owns.
    let glyph: UIImage
    /// The plate. Free.
    let plate: UIColor
    /// Where the motion comes from. Two cases rather than a flag, so a baked
    /// asset and a synthetic one cannot be confused for one another anywhere
    /// downstream — including in the report.
    enum Source {
        /// The instrument's own catalogue.
        case procedural(IconAtlasBaker.Motion)
        /// Samples from `IconBaker`'s manifest: the real wire shape.
        case sampled(scale: [Double], rotation: [Double], opacity: [Double])
    }
    let motion: Source
    /// Sample count per loop. On this path it is a FIDELITY knob, not a memory
    /// one — the bytes do not move when it changes.
    let frameCount: Int
    let frameDuration: CFTimeInterval
    /// Fraction of the cell the plate covers, so the layer geometry reproduces
    /// the sheet's gutter exactly instead of approximately.
    let plateInsetFraction: Double

    var loopDuration: CFTimeInterval { frameDuration * CFTimeInterval(frameCount) }

    /// Texture PLUS track.
    ///
    /// ⚠️ This counted only the texture, which made the headline finding true by
    /// construction of its own metric: of course frame rate costs no memory if
    /// the thing frame rate scales is excluded from the measurement. At 120 keys
    /// the samples are 3 channels x 8 bytes x 120 = 2.9 KB per icon, ~368 KB
    /// across 128. Small — 4% of the 9 MB — but small is a result and zero is a
    /// bookkeeping error, and only one of them survives being checked.
    var byteCost: Int {
        let texture = glyph.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        guard case .sampled(let scale, let rotation, let opacity) = motion else { return texture }
        return texture
            + (scale.count + rotation.count + opacity.count) * MemoryLayout<Double>.size
    }

    var isBaked: Bool { if case .sampled = motion { return true }; return false }

    func track(phase: Int) -> IconMotionTrack {
        switch motion {
        case .procedural(let motion):
            IconMotionTrack(
                motion: motion, frameCount: frameCount, step: frameDuration, phase: phase
            )
        case .sampled(let scale, let rotation, let opacity):
            IconMotionTrack(
                sampled: scale, rotation: rotation, opacity: opacity,
                step: frameDuration, phase: phase
            )
        }
    }
}

// MARK: - What the store hands back

/// Two representations of the same icon, kept apart at the type level.
///
/// A boolean flag on one struct would let a fallback pass unnoticed; two cases
/// force every consumer to state what it is looking at, and let the report count
/// the fallbacks instead of averaging over them.
nonisolated enum IconArt {
    case sheet(IconAtlas)
    case decomposed(IconStill)

    var byteCost: Int {
        switch self {
        case .sheet(let atlas): atlas.byteCost
        case .decomposed(let still): still.byteCost
        }
    }
    var frameCount: Int {
        switch self {
        case .sheet(let atlas): atlas.frameCount
        case .decomposed(let still): still.frameCount
        }
    }
    var frameDuration: CFTimeInterval {
        switch self {
        case .sheet(let atlas): atlas.frameDuration
        case .decomposed(let still): still.frameDuration
        }
    }
    var isDecomposed: Bool {
        if case .decomposed = self { return true }
        return false
    }
}

// MARK: - Proving the two paths are the same picture

/// Renders one icon BOTH ways and measures the difference.
///
/// This exists because "the decomposition is exact" is the kind of claim that is
/// obviously true right up until a corner curve, an anchor point or a
/// premultiplication convention makes it quietly false — and the failure mode is
/// an icon that is 3% too small or a plate that is a squircle, neither of which
/// any performance number on this screen would ever show. The same reasoning
/// caught a vertical flip in the container path earlier, which was invisible
/// because the disc and half the glyphs are symmetric.
///
/// It earned its keep on the first run, and not in the direction expected: the
/// two `.flicker` icons came back at 0.92 and 3.14 MAE against 0.05-0.51 for the
/// other fourteen, and the cause was a dropped alpha channel in the SHEET baker
/// rather than anything in the decomposition. Current state, 24 frames, 136px
/// cells:
///
///     worst 0.5136 / 255 (camera.fill), peak 70, every icon under 0.52
///
/// The residual is antialiasing on the plate rim — `addEllipse` against a
/// circular `cornerRadius` — and it is exactly 0.0000 on every frame whose pose
/// is identity.
///
/// Reached with `-icon-bench-verify`.
@MainActor
enum DecompositionAudit {

    struct Result {
        let index: Int
        let symbol: String
        /// Mean absolute per-channel difference, 0-255.
        let mae: Double
        /// Worst single channel, 0-255. A low mean with a high peak means the
        /// two agree everywhere except an edge — which is antialiasing, not a
        /// geometry error.
        let peak: Double
        /// Share of pixels differing by more than 8/255. Antialiasing lives on
        /// the rim; a geometry error covers area.
        let disagreeingFraction: Double
        /// Frames the check could not cover. See `renderHonoursOpacity`.
        let skippedFrames: Int
        let comparedFrames: Int
        /// Per-frame `(mae, scale, alpha)`.
        ///
        /// A single number cannot tell a geometry error from a colour one. A
        /// breakdown can: error that tracks `alpha` is a compositing
        /// difference, error that tracks `scale` is a resampling one, and error
        /// that is flat across the loop is neither — it is the artwork.
        let byFrame: [(mae: Double, scale: Double, alpha: Double)]
    }

    /// White at 50% over black, blended BOTH ways — the guard that says whether
    /// the two paths agree on what "half transparent" means.
    ///
    /// They DO agree (128 and 128), and the probe is kept because reaching that
    /// answer took three wrong turns worth recording. It began as a boolean
    /// "does `render(in:)` apply opacity at all", whose threshold was loose
    /// enough to accept a gamma-wrong answer as a correct one; it was then
    /// pointed at `backgroundColor` when the icons are `contents`. Both versions
    /// returned a comfortable "yes" and left a 3.14 MAE unexplained.
    ///
    /// The disagreement was never here. It was in `IconAtlasBaker.bake`, which
    /// passed its alpha through `CGContext.setAlpha` — a call `UIImage.draw(in:)`
    /// ignores — so the `.flicker` motion's opacity channel was missing from
    /// every sprite sheet the instrument had ever produced. The check found a
    /// real defect in the REFERENCE while I was busy suspecting the thing being
    /// checked.
    ///
    /// - `layerBlend`: a white sublayer at `opacity = 0.5` over a black one,
    ///   flattened by `CALayer.render(in:)`.
    /// - `contextBlend`: `CGContext.setAlpha(0.5)` then a white fill over a
    ///   black one — exactly what `IconAtlasBaker.bake` does per frame.
    ///
    /// 128 is an sRGB-space blend; ~188 is a linear-light one. If they differ,
    /// the sheet and the decomposition disagree about compositing and not about
    /// geometry — which is a colour question with a colour answer, not a reason
    /// to abandon the representation.
    static let opacityBlend: (layerBlend: Double, contextBlend: Double) = {
        let side = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)

        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        root.anchorPoint = .zero
        root.position = .zero
        root.contentsScale = 1
        let backdrop = CALayer()
        backdrop.frame = root.bounds
        backdrop.backgroundColor = UIColor.black.cgColor
        backdrop.contentsScale = 1
        root.addSublayer(backdrop)

        // `contents`, NOT `backgroundColor`, and that distinction is the whole
        // probe. The first version of this check used a background colour, got
        // a correct 128, and concluded opacity was honoured — while the real
        // comparison was still 3 MAE out. `render(in:)` applies `opacity` to a
        // layer's background but NOT to its `contents` image, and the icons are
        // contents. A probe that does not exercise the same property as the
        // thing it vouches for is a probe that vouches for nothing.
        let white = UIGraphicsImageRenderer(size: root.bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(root.bounds)
        }
        let mark = CALayer()
        mark.frame = root.bounds
        mark.contents = white.cgImage
        mark.opacity = 0.5
        mark.contentsScale = 1
        root.addSublayer(mark)
        let layerImage = renderer.image { root.render(in: $0.cgContext) }

        let contextImage = renderer.image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            cg.fill(root.bounds)
            cg.setAlpha(0.5)
            UIColor.white.setFill()
            cg.fill(root.bounds)
        }

        func centreRed(_ image: UIImage) -> Double {
            guard let cg = image.cgImage else { return -1 }
            let pixels = rasterise(cg, side: side)
            // `premultipliedFirst` / `byteOrder32Little` -> B G R A in memory.
            return Double(pixels[(side / 2) * side * 4 + (side / 2) * 4 + 2])
        }
        return (centreRed(layerImage), centreRed(contextImage))
    }()

    /// True when the two agree to within a rounding step — they do.
    ///
    /// Kept as a guard rather than deleted: if a future SDK changes either
    /// blend, frames whose alpha is not 1 drop OUT of the comparison and are
    /// counted as skipped, instead of quietly inflating the MAE and reading as a
    /// defect in the decomposition.
    static var opacityBlendsMatch: Bool { abs(opacityBlend.layerBlend - opacityBlend.contextBlend) <= 2 }

    static func compare(index: Int, frameCount: Int, cellPixels: Int, columns: Int) -> Result? {
        guard
            let sheetData = IconAtlasBaker.bake(
                index: index, frameCount: frameCount, columns: columns, cellPixels: cellPixels
            ),
            let sheet = UIImage(data: sheetData)?.cgImage,
            let stillData = IconAtlasBaker.bakeStill(index: index, cellPixels: cellPixels),
            let glyph = UIImage(data: stillData)?.cgImage
        else { return nil }

        let entry = IconAtlasBaker.catalogue[index % IconAtlasBaker.catalogue.count]
        let gutter = 2
        var total = 0.0
        var peak = 0.0
        var disagreeing = 0
        var samples = 0
        var compared = 0
        var skipped = 0
        var byFrame: [(mae: Double, scale: Double, alpha: Double)] = []

        for frame in 0..<frameCount {
            let origin = CGPoint(
                x: CGFloat((frame % columns) * cellPixels),
                y: CGFloat((frame / columns) * cellPixels)
            )
            guard let cell = sheet.cropping(to: CGRect(
                origin: origin, size: CGSize(width: cellPixels, height: cellPixels)
            )) else { continue }

            let pose = entry.motion.pose(at: Double(frame) / Double(frameCount))
            // Excluded, not averaged in: the offline renderer cannot reproduce
            // this frame, so including it would report a limitation of the
            // check as a defect in the thing checked.
            guard opacityBlendsMatch || pose.alpha > 0.999 else { skipped += 1; continue }
            guard let rebuilt = render(
                glyph: glyph, plate: entry.tint, pose: pose,
                cellPixels: cellPixels, gutterPixels: gutter
            ) else { continue }

            let a = rasterise(cell, side: cellPixels)
            let b = rasterise(rebuilt, side: cellPixels)
            guard a.count == b.count else { continue }
            var frameTotal = 0.0
            for i in 0..<a.count {
                let delta = abs(Double(a[i]) - Double(b[i]))
                frameTotal += delta
                peak = max(peak, delta)
                if delta > 8 { disagreeing += 1 }
            }
            total += frameTotal
            samples += a.count
            compared += 1
            byFrame.append((frameTotal / Double(a.count), pose.scale, pose.alpha))
        }

        guard samples > 0 else { return nil }
        return Result(
            index: index,
            symbol: entry.symbol,
            mae: total / Double(samples),
            peak: peak,
            disagreeingFraction: Double(disagreeing) / Double(samples),
            skippedFrames: skipped,
            comparedFrames: compared,
            byFrame: byFrame
        )
    }

    /// The decomposed marker's layer tree, posed and flattened.
    ///
    /// Deliberately the REAL layer tree rather than a CoreGraphics
    /// re-implementation of it: re-drawing the same thing a second way and
    /// finding it matches proves only that I can write the same code twice.
    private static func render(
        glyph: CGImage,
        plate: UIColor,
        pose: (scale: Double, rotation: Double, alpha: Double),
        cellPixels: Int,
        gutterPixels: Int
    ) -> CGImage? {
        let cell = CGRect(x: 0, y: 0, width: cellPixels, height: cellPixels)

        let root = CALayer()
        root.bounds = cell
        root.anchorPoint = .zero
        root.position = .zero
        root.contentsScale = 1

        let disc = CALayer()
        disc.frame = cell.insetBy(dx: CGFloat(gutterPixels), dy: CGFloat(gutterPixels))
        disc.backgroundColor = plate.cgColor
        disc.cornerRadius = disc.bounds.width / 2
        // `.circular`, NOT `.continuous`. A continuous curve at radius = half the
        // side is a superellipse, not a circle — it would read as a subtly
        // squarish plate against the sheet's `addEllipse`, and nothing else here
        // would flag it.
        disc.cornerCurve = .circular
        disc.contentsScale = 1
        root.addSublayer(disc)

        let glyphLayer = CALayer()
        glyphLayer.frame = cell
        glyphLayer.contents = glyph
        glyphLayer.contentsScale = 1
        glyphLayer.opacity = Float(pose.alpha)
        glyphLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(CGFloat(pose.scale), CGFloat(pose.scale), 1),
            CATransform3DMakeRotation(CGFloat(pose.rotation), 0, 0, 1)
        )
        root.addSublayer(glyphLayer)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: cell.size, format: format).image { context in
            root.render(in: context.cgContext)
        }.cgImage
    }

    /// Writes reference / rebuilt / amplified-difference PNGs for one frame.
    ///
    /// Because a scalar cannot say WHERE two pictures differ, and where is the
    /// whole answer: a difference spread over a glyph's interior is a
    /// compositing one, a difference confined to its outlines is resampling.
    /// Two probes and a plausible story got that backwards twice here before
    /// anyone looked at the pixels.
    static func dump(index: Int, frame: Int, frameCount: Int, cellPixels: Int, columns: Int, to directory: URL) -> String {
        guard
            let sheetData = IconAtlasBaker.bake(
                index: index, frameCount: frameCount, columns: columns, cellPixels: cellPixels
            ),
            let sheet = UIImage(data: sheetData)?.cgImage,
            let stillData = IconAtlasBaker.bakeStill(index: index, cellPixels: cellPixels),
            let glyph = UIImage(data: stillData)?.cgImage
        else { return "dump: bake failed" }

        let entry = IconAtlasBaker.catalogue[index % IconAtlasBaker.catalogue.count]
        let origin = CGPoint(
            x: CGFloat((frame % columns) * cellPixels), y: CGFloat((frame / columns) * cellPixels)
        )
        guard let cell = sheet.cropping(to: CGRect(
            origin: origin, size: CGSize(width: cellPixels, height: cellPixels)
        )) else { return "dump: crop failed" }

        let pose = entry.motion.pose(at: Double(frame) / Double(frameCount))
        guard let rebuilt = render(
            glyph: glyph, plate: entry.tint, pose: pose, cellPixels: cellPixels, gutterPixels: 2
        ) else { return "dump: render failed" }

        let a = rasterise(cell, side: cellPixels)
        let b = rasterise(rebuilt, side: cellPixels)
        var diff = [UInt8](repeating: 0, count: a.count)
        for i in stride(from: 0, to: a.count, by: 4) {
            let delta = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max() ?? 0
            let amplified = UInt8(min(255, delta * 6))
            // `premultipliedFirst` + `byteOrder32Little` lays the bytes out
            // B G R A, so alpha is the LAST one. Writing it first produced a
            // uniformly white difference image — an invalid premultiplied
            // pixel, not a picture of a defect.
            diff[i] = amplified
            diff[i + 1] = amplified
            diff[i + 2] = amplified
            diff[i + 3] = 255
        }
        var written: [String] = []
        for (name, pixels) in [("ref", a), ("new", b), ("diff", diff)] {
            var buffer = pixels
            let cg: CGImage? = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: cellPixels, height: cellPixels,
                    bitsPerComponent: 8, bytesPerRow: cellPixels * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ) else { return nil }
                return context.makeImage()
            }
            guard let cg, let data = UIImage(cgImage: cg).pngData() else { continue }
            let url = directory.appendingPathComponent("icon\(index)-f\(frame)-\(name).png")
            try? data.write(to: url)
            written.append(url.lastPathComponent)
        }
        return "dump: " + written.joined(separator: " ") + " in " + directory.path
    }

    /// Both sides through ONE pixel format, so the comparison is of pictures and
    /// not of colour spaces.
    private nonisolated static func rasterise(_ image: CGImage, side: Int) -> [UInt8] {
        let rowBytes = side * 4
        var buffer = [UInt8](repeating: 0, count: rowBytes * side)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buffer
    }
}
#endif

#if DEBUG
extension UIColor {
    /// `#RRGGBB` from the baker's manifest.
    ///
    /// `nonisolated` because the baked catalogue is decoded off the main actor,
    /// on the same detached task every other bake path uses.
    nonisolated convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }
}
#endif
