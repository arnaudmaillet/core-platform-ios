#if DEBUG
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Baking

/// Renders sprite sheets on device.
///
/// In production this is the BACKEND's job (or CI's) — the client should never
/// see a vector. It is here because the instrument must be self-contained: no
/// downloaded assets, no committed binaries, and every parameter (frame count,
/// cell size, fps) adjustable from the on-screen controls, which is the whole
/// point of an instrument.
///
/// The icons are SF Symbols because they are real, on-device, recognisable at
/// 44pt, and cost nothing to acquire. A designer-authored sheet would differ in
/// artwork and in nothing else that this screen measures.
nonisolated enum IconAtlasBaker {

    /// The instrument's catalogue. Chosen to read at 44pt over map tiles and to
    /// be told apart at a glance when 128 of them are on screen at once.
    static let catalogue: [(symbol: String, tint: UIColor, motion: Motion)] = [
        ("flame.fill", .systemOrange, .pulse),
        ("bolt.fill", .systemYellow, .flicker),
        ("heart.fill", .systemPink, .heartbeat),
        ("star.fill", .systemYellow, .spin),
        ("music.note", .systemPurple, .bob),
        ("camera.fill", .systemTeal, .pulse),
        ("fork.knife", .systemBrown, .bob),
        ("figure.run", .systemGreen, .bob),
        ("cloud.rain.fill", .systemBlue, .bob),
        ("gamecontroller.fill", .systemIndigo, .flicker),
        ("cart.fill", .systemMint, .pulse),
        ("pawprint.fill", .systemBrown, .heartbeat),
        ("leaf.fill", .systemGreen, .spin),
        ("cup.and.saucer.fill", .systemBrown, .pulse),
        ("airplane", .systemCyan, .spin),
        ("gift.fill", .systemRed, .heartbeat)
    ]

    enum Motion {
        case spin, pulse, heartbeat, flicker, bob

        /// Scale and rotation at normalised time `t` in [0, 1).
        func pose(at t: Double) -> (scale: Double, rotation: Double, alpha: Double) {
            switch self {
            case .spin:
                return (1, t * 2 * .pi, 1)
            case .pulse:
                return (0.82 + 0.18 * (0.5 + 0.5 * sin(t * 2 * .pi)), 0, 1)
            case .heartbeat:
                // Two quick beats then rest — a sine would read as breathing.
                let beat = max(0, sin(t * 4 * .pi)) * (t < 0.5 ? 1 : 0.55)
                return (0.85 + 0.2 * beat, 0, 1)
            case .flicker:
                return (0.9 + 0.1 * abs(sin(t * 3 * .pi)), 0, 0.55 + 0.45 * abs(sin(t * 3 * .pi)))
            case .bob:
                return (1, sin(t * 2 * .pi) * 0.22, 1)
            }
        }
    }

    /// Bakes one icon to PNG data.
    ///
    /// Returns DATA, not an image, on purpose: the store then decodes it through
    /// the same `CGImageSourceCreateThumbnailAtIndex` call `ImagePipeline` uses,
    /// so the instrument exercises the real decode path end to end rather than
    /// handing itself a convenient in-memory bitmap.
    ///
    /// The circle is baked into the ALPHA. That is not decoration — it is the
    /// single most valuable thing the backend can do for this feature. A round
    /// asset means the marker needs no mask, and a mask on a layer whose
    /// contents change every frame costs an offscreen render pass per marker per
    /// frame. At 128 markers that is the largest cost in the whole design, and
    /// pre-baking the circle deletes it. The `maskOnCard` toggle on this screen
    /// puts the wasteful version back so the difference is measurable.
    nonisolated static func bake(
        index: Int,
        frameCount: Int,
        columns: Int,
        cellPixels: Int,
        gutterPixels: Int = 2
    ) -> Data? {
        let entry = catalogue[index % catalogue.count]
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let sheetSize = CGSize(width: cellPixels * columns, height: cellPixels * rows)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1              // the sheet is authored in PIXELS
        format.opaque = false
        format.preferredRange = .standard

        let art = cellPixels - gutterPixels * 2
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: CGFloat(art) * 0.52, weight: .semibold)
        guard let glyph = UIImage(systemName: entry.symbol, withConfiguration: symbolConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }

        let image = UIGraphicsImageRenderer(size: sheetSize, format: format).image { ctx in
            let cg = ctx.cgContext
            for frame in 0..<frameCount {
                let t = Double(frame) / Double(frameCount)
                let pose = entry.motion.pose(at: t)

                // The cell's ART box — the gutter stays fully transparent.
                //
                // The gutter is not padding. The same sheet is minified to ~66px
                // for a chat emote and ~88px on a @2x device; without a
                // transparent margin, bilinear sampling pulls the NEIGHBOURING
                // frame into this one's rim. It is a silent, ugly defect that
                // only shows on small screens, which is exactly the class of bug
                // this feature is prone to.
                let origin = CGPoint(
                    x: CGFloat((frame % columns) * cellPixels + gutterPixels),
                    y: CGFloat((frame / columns) * cellPixels + gutterPixels)
                )
                let box = CGRect(origin: origin, size: CGSize(width: art, height: art))

                cg.saveGState()

                // The disc: baked circular alpha, so the marker needs no mask.
                cg.addEllipse(in: box)
                cg.clip()
                // One flat disc in the icon's own tint. Flat on purpose: an
                // instrument must let a real rendering defect stand out, and a
                // decorative band inside the art reads exactly like one.
                entry.tint.setFill()
                cg.fill(box)

                // The glyph, posed.
                //
                // ⚠️ The alpha goes through `draw(in:blendMode:alpha:)`, NOT
                // through `cg.setAlpha`. `UIImage.draw(in:)` does not honour the
                // context's global alpha — it draws at full strength — so the
                // `.flicker` motion's entire opacity channel was silently
                // missing from every sheet this baker has ever produced. The
                // icons still animated (they scale too), nothing errored, and no
                // performance number moved, which is exactly why it survived:
                // it was found by diffing the sheet against the decomposed path
                // pixel by pixel, and only after the diff image showed the
                // disagreement filling the glyph's INTERIOR rather than tracing
                // its outline.
                cg.translateBy(x: box.midX, y: box.midY)
                cg.rotate(by: pose.rotation)
                cg.scaleBy(x: pose.scale, y: pose.scale)
                glyph.draw(in: CGRect(
                    x: -glyph.size.width / 2, y: -glyph.size.height / 2,
                    width: glyph.size.width, height: glyph.size.height
                ), blendMode: .normal, alpha: CGFloat(pose.alpha))

                cg.restoreGState()
            }
        }
        return image.pngData()
    }

    /// The same artwork as INDIVIDUAL frames, for encoding into a real animated
    /// container.
    ///
    /// Note these are drawn WITHOUT the circular clip: when the source is a
    /// container, the disc is applied at bake time by `DiscMask`, which is what
    /// rescues a GIF's binary edge. Baking the circle in here too would just
    /// throw that away before ImageIO ever saw it.
    nonisolated static func frames(index: Int, frameCount: Int, side: Int) -> [CGImage] {
        let entry = catalogue[index % catalogue.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.52, weight: .semibold)
        guard let glyph = UIImage(systemName: entry.symbol, withConfiguration: symbolConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return [] }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return (0..<frameCount).compactMap { frame in
            let pose = entry.motion.pose(at: Double(frame) / Double(frameCount))
            return renderer.image { ctx in
                let cg = ctx.cgContext
                cg.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
                cg.rotate(by: pose.rotation)
                cg.scaleBy(x: pose.scale, y: pose.scale)
                // Same `setAlpha` trap as `bake` above — and this one also fed
                // the GIF and APNG paths, so their alpha channel was missing
                // too.
                glyph.draw(in: CGRect(
                    x: -glyph.size.width / 2, y: -glyph.size.height / 2,
                    width: glyph.size.width, height: glyph.size.height
                ), blendMode: .normal, alpha: CGFloat(pose.alpha))
            }.cgImage
        }
    }

    /// The motion descriptor for an icon — the whole of what the decomposed
    /// path needs beyond one picture.
    ///
    /// In production this is a handful of bytes on the wire next to the still
    /// (or, equivalently, a transform-only Lottie the CI baker reduces to it).
    /// It is the artwork property that makes `IconStill` possible, so it is
    /// exposed here rather than buried in `catalogue`.
    nonisolated static func motion(index: Int) -> Motion { catalogue[index % catalogue.count].motion }

    /// Bakes the ONE still a decomposed icon needs: the glyph, alone, at rest.
    ///
    /// Note what is NOT in it — the plate. The plate is a colour the layer tree
    /// draws for free, so the only texture this icon owns is the mark itself.
    ///
    /// Identity pose, deliberately: the track carries ABSOLUTE scale, rotation
    /// and alpha, so baking `pose(at: 0)` into the picture would apply the first
    /// keyframe twice and leave `.pulse` permanently 9% small.
    ///
    /// The canvas is the FULL cell, gutter included, because that is what
    /// `contentsRect` selects on the sheet path. Cropping to the art box here
    /// would make the decomposed glyph 3% larger than the sheet's and the two
    /// paths would no longer be comparable — a difference small enough to look
    /// like nothing and big enough to be a rendering defect.
    nonisolated static func bakeStill(index: Int, cellPixels: Int, gutterPixels: Int = 2) -> Data? {
        let entry = catalogue[index % catalogue.count]
        let art = cellPixels - gutterPixels * 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: CGFloat(art) * 0.52, weight: .semibold)
        guard let glyph = UIImage(systemName: entry.symbol, withConfiguration: symbolConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }

        let side = CGFloat(cellPixels)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            glyph.draw(in: CGRect(
                x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2,
                width: glyph.size.width, height: glyph.size.height
            ))
        }.pngData()
    }

    /// The real GIFs bundled in `App/Resources/BenchIcons`, discovered at runtime.
    ///
    /// Deliberately NOT a hardcoded list: the point of these files is that they
    /// are ordinary assets off Wikimedia Commons rather than artwork tailored to
    /// the instrument, and adding another one should cost a drag into the folder.
    ///
    /// What they exposed that the synthetic set could not — every one of these is
    /// a property the bake pipeline has to survive, and none of them existed in a
    /// uniform 12-frame loop:
    ///   • frame counts from 2 to 28
    ///   • per-frame delays that VARY inside one file (0.2s, 1.2s and 2.5s in the
    ///     same GIF) — the whole reason `FrameTimeline` resampling exists
    ///   • loops from 0.18s to 56s, so the 24-frame cap compresses time hard
    ///   • sources SMALLER than the 132px target (11x10), which must be magnified
    static let bundledGIFNames: [String] = {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "gif", subdirectory: nil) else {
            return []
        }
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    /// The plate colour a container's frames are composited onto.
    nonisolated static func plate(index: Int) -> UIColor { catalogue[index % catalogue.count].tint }

    /// Encodes frames into a REAL animated container, so the bench ingests one
    /// through the same ImageIO path production would — GIF's 1-bit alpha and
    /// 256-colour palette included, rather than simulated.
    nonisolated static func encodeContainer(
        _ frames: [CGImage],
        as kind: ContainerKind,
        delay: Double
    ) -> Data? {
        guard !frames.isEmpty else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, kind.uti as CFString, frames.count, nil
        ) else { return nil }

        CGImageDestinationSetProperties(destination, [
            kind.containerKey: [kind.loopKey: 0]
        ] as CFDictionary)

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [
                kind.containerKey: [kind.delayKey: delay]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    enum ContainerKind: String, CaseIterable {
        case gif, apng

        var uti: String {
            switch self {
            case .gif: UTType.gif.identifier
            case .apng: UTType.png.identifier
            }
        }
        var containerKey: CFString {
            switch self {
            case .gif: kCGImagePropertyGIFDictionary
            case .apng: kCGImagePropertyPNGDictionary
            }
        }
        var delayKey: CFString {
            switch self {
            case .gif: kCGImagePropertyGIFUnclampedDelayTime
            case .apng: kCGImagePropertyAPNGUnclampedDelayTime
            }
        }
        var loopKey: CFString {
            switch self {
            case .gif: kCGImagePropertyGIFLoopCount
            case .apng: kCGImagePropertyAPNGLoopCount
            }
        }
    }
}
#endif
