#if DEBUG
import CoreGraphics
import ImageIO
import UIKit
import Foundation
import UniformTypeIdentifiers

/// # The bake seam
///
/// Two very different sources — an animated raster container (GIF / APNG /
/// WebP / HEICS) and, later, a vector scene — have to end up as the SAME thing:
/// one still atlas plus a fixed frame step.
///
/// The seam is `AtlasCanvas`, and the trick is that neither branch returns
/// pixels. Each writes directly into a sub-rectangle of the finished atlas.
/// That is possible because both drawing APIs take a STRIDE independently of
/// width — `CGBitmapContext(bytesPerRow:)`, and ThorVG's
/// `tvg_swcanvas_set_target(canvas, buffer, stride, w, h, cs)` — so a cell is
/// just a window onto the shared buffer. No intermediate bitmaps, no copies,
/// and the vector branch slots in without touching the raster one.

// MARK: - Geometry

nonisolated struct AtlasGeometry {
    let frameCount: Int
    let columns: Int
    let cellPixels: Int
    let gutterPixels: Int

    var rows: Int { Int(ceil(Double(frameCount) / Double(columns))) }
    var width: Int { columns * cellPixels }
    var height: Int { rows * cellPixels }
    /// The drawable side of a cell, gutter excluded.
    var artSide: Int { cellPixels - gutterPixels * 2 }

    /// Unit-space rects, one per frame — what `contentsRect` walks.
    var frameRects: [CGRect] {
        let w = 1.0 / Double(columns)
        let h = 1.0 / Double(rows)
        return (0..<frameCount).map { i in
            CGRect(x: Double(i % columns) * w, y: Double(i / columns) * h, width: w, height: h)
        }
    }
}

// MARK: - Timing

/// How a source's own timeline maps onto the fixed step a discrete
/// `CAKeyframeAnimation` requires.
///
/// This is mandatory, not a nicety: a GIF may carry a different delay on every
/// frame, and `CAKeyframeAnimation` with `calculationMode = .discrete` has ONE
/// duration for the whole loop. Ignoring that plays a 7-frame GIF whose delays
/// sum to 0.63s as though every frame were equal — visibly wrong for anything
/// with a hold.
nonisolated struct FrameTimeline {
    let frameCount: Int
    /// Seconds per output frame — the single number playback needs.
    let step: CFTimeInterval
    /// For each output cell, which SOURCE frame it shows.
    let sourceIndices: [Int]
    /// True when the source loop was longer than the frame budget allows, so it
    /// plays faster than authored. Fine for a pulse, wrong for anything with a
    /// beat — which is why it is reported rather than swallowed.
    let timeCompressed: Bool

    var loopDuration: CFTimeInterval { step * CFTimeInterval(frameCount) }

    /// The only step values permitted.
    ///
    /// Every one divides both 60 and 120 exactly. 24fps is deliberately absent:
    /// it is a native ProMotion step (120/5) but NOT a divisor of 60, so it
    /// plays 3:2 and judders on every non-ProMotion iPhone — the number film
    /// instinct reaches for and the worst of the candidates for a mixed fleet.
    static let ladder: [CFTimeInterval] = [1.0 / 30, 0.05, 1.0 / 15, 1.0 / 12, 0.10]

    /// Resamples a source's per-frame delays onto the ladder.
    ///
    /// Picks the FINEST step whose frame count still fits the budget, because
    /// frame count is the memory lever — at 136px cells a frame is 72 KiB, so
    /// 12 frames is 867 KiB resident and 24 is 1.7 MiB. The budget is bytes
    /// first and fidelity second, which is the reverse of the instinct.
    static func resampling(delays: [CFTimeInterval], maxFrames: Int) -> FrameTimeline {
        let sanitised = delays.map { $0 > 0.001 ? $0 : 1.0 / 30 }
        let loop = sanitised.reduce(0, +)
        guard loop > 0, !sanitised.isEmpty else {
            return FrameTimeline(frameCount: 1, step: 1.0 / 30, sourceIndices: [0], timeCompressed: false)
        }

        // Cumulative start time of each source frame, for the sampling below.
        var starts: [CFTimeInterval] = []
        var running: CFTimeInterval = 0
        for delay in sanitised {
            starts.append(running)
            running += delay
        }

        func sourceIndex(at time: CFTimeInterval) -> Int {
            let t = time.truncatingRemainder(dividingBy: loop)
            var index = 0
            for (i, start) in starts.enumerated() where start <= t { index = i }
            return index
        }

        for step in ladder {
            let count = Int(ceil(loop / step))
            if count <= maxFrames, count >= 1 {
                return FrameTimeline(
                    frameCount: count,
                    step: step,
                    sourceIndices: (0..<count).map { sourceIndex(at: CFTimeInterval($0) * step) },
                    timeCompressed: false
                )
            }
        }

        // Nothing on the ladder fits: spread the whole loop across the budget
        // and say so. At 12 frames the coarsest step caps a baked loop at 1.2s.
        let step = ladder.last ?? 0.10
        return FrameTimeline(
            frameCount: maxFrames,
            step: step,
            sourceIndices: (0..<maxFrames).map {
                sourceIndex(at: loop * CFTimeInterval($0) / CFTimeInterval(maxFrames))
            },
            timeCompressed: true
        )
    }
}

// MARK: - Canvas

/// One cell of the atlas, as a window onto the shared buffer.
nonisolated struct CellWindow {
    let base: UnsafeMutableRawPointer
    /// Bytes per row of the WHOLE atlas — this is what confines the cell.
    let rowBytes: Int
    let side: Int

    /// A context that physically cannot address another cell: its origin is
    /// this cell's first pixel and its height stops at this cell's last row.
    ///
    /// ⚠️ NO CTM FLIP, deliberately. A bitmap context plus `CGContext.draw` plus
    /// `makeImage()` already round-trips a top-oriented `CGImage` correctly —
    /// the upside-down images everyone remembers come from UIKit PRE-flipping
    /// its own contexts, not from Core Graphics. Adding a flip here inverts an
    /// orientation that was already right, and the bug hides: the disc is
    /// symmetric and so are half the glyphs, so it only shows on asymmetric art
    /// (a music note, a camera) — which is exactly how it survived a first look.
    func makeContext() -> CGContext? {
        CGContext(
            data: base,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

/// The atlas under construction. One allocation; every frame writes into it.
nonisolated final class AtlasCanvas {
    let geometry: AtlasGeometry
    private var buffer: UnsafeMutableRawPointer?
    private let rowBytes: Int

    init(geometry: AtlasGeometry) {
        self.geometry = geometry
        self.rowBytes = geometry.width * 4
        // calloc, not malloc: the gutters and any unused trailing cells are
        // already fully transparent and nothing has to clear them. The gutter
        // is what stops bilinear minification pulling a neighbouring frame into
        // this one's rim when the same sheet is drawn small.
        self.buffer = calloc(geometry.height, rowBytes)
    }

    deinit { free(buffer) }

    /// Hands `body` a window onto cell `index`, gutter excluded.
    func withCell<T>(_ index: Int, _ body: (CellWindow) -> T) -> T? {
        guard let buffer, index < geometry.frameCount else { return nil }
        let column = index % geometry.columns
        let row = index / geometry.columns
        let originY = row * geometry.cellPixels + geometry.gutterPixels
        let originX = column * geometry.cellPixels + geometry.gutterPixels
        let offset = originY * rowBytes + originX * 4
        return body(CellWindow(base: buffer + offset, rowBytes: rowBytes, side: geometry.artSide))
    }

    /// Transfers the buffer to a `CGImage`. The canvas is spent afterwards.
    func finish() -> CGImage? {
        guard let buffer else { return nil }
        let context = CGContext(
            data: buffer,
            width: geometry.width, height: geometry.height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return context?.makeImage()
    }
}

// MARK: - The disc

/// The marker's silhouette, drawn by US and applied to every cell.
///
/// This is what makes a GIF usable on this surface at all. Measured on a real
/// round-trip: a source with 55 alpha levels and 404 partial-alpha pixels comes
/// back from GIF with **2 levels and 0 partial pixels** — GIF89a carries a
/// single Transparent Color Index, so its edge is binary by format. Applying
/// our own antialiased disc restores 42 levels and 296 partial pixels, because
/// the only edge the viewer sees at 44pt is then ours, not the file's.
///
/// `.destinationIn` against a precomputed antialiased disc, NOT `addEllipse` +
/// `clip()` — a clip path is hard-edged, which would put the jaggies straight
/// back.
nonisolated enum DiscMask {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [Int: CGImage] = [:]

    /// Locked, because bakes run concurrently and this is shared. Cheap to hold:
    /// the disc is computed once per size for the life of the process.
    static func disc(side: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[side] { return hit }
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: {
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1
                f.opaque = false
                return f
            }()
        )
        let image = renderer.image { ctx in
            ctx.cgContext.setShouldAntialias(true)
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        cache[side] = image.cgImage
        return image.cgImage
    }

    /// Paints the opaque plate a raster frame is composited onto, then returns.
    ///
    /// The plate matters as much as the disc: binary alpha then only ever keys
    /// against a known solid colour, never against live map tiles, so the
    /// classic GIF matte fringe — art authored over white, keyed onto a park —
    /// is structurally impossible here.
    static func fillPlate(_ context: CGContext, side: Int, colour: UIColor) {
        context.setFillColor(colour.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }

    static func apply(to context: CGContext, side: Int) {
        guard let disc = disc(side: side) else { return }
        context.setBlendMode(.destinationIn)
        context.draw(disc, in: CGRect(x: 0, y: 0, width: side, height: side))
        context.setBlendMode(.normal)
    }
}

// MARK: - Sources

/// A thing that can render frame N into a cell.
///
/// Deliberately NOT `Sendable`: a source holds a decoder (a `CGImageSource`, or
/// later a ThorVG animation handle) and is confined to the one task that opened
/// it. Opening once per bake rather than once per frame is load-bearing for the
/// vector branch, where parse is the super-linear cost and render is linear.
nonisolated protocol IconFrameSource: AnyObject {
    var timeline: FrameTimeline { get }
    func render(frame index: Int, into window: CellWindow)
}

/// GIF / APNG / animated WebP / HEICS, through ImageIO. No dependency.
nonisolated final class RasterFrameSource: IconFrameSource {
    /// ⚠️ RETAINED. `CGImageSourceCreateWithData` holds this buffer rather than
    /// copying it, and with `kCGImageSourceShouldCache: false` below every frame
    /// read goes back to it — so letting the `Data` die makes
    /// `CGImageSourceCreateImageAtIndex` return fully transparent frames, some
    /// of the time. From outside it reads as icons blinking; the same bug in the
    /// publish-time baker put 3 of 5 cells at alpha 0 in one sheet and none in
    /// another, with no relation to the artwork.
    private let data: Data
    private let source: CGImageSource
    private let plate: UIColor
    let timeline: FrameTimeline

    /// Reads the UNCLAMPED delay, per container.
    ///
    /// ⚠️ The clamped key is a trap with teeth: measured, HEICS reports
    /// clamped 0.100 against unclamped 0.033, so reading the wrong one plays a
    /// 30fps icon at 10fps and nothing errors.
    private static func delay(from properties: [CFString: Any]) -> CFTimeInterval? {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (container, unclamped, clamped) in containers {
            guard let dictionary = properties[container] as? [CFString: Any] else { continue }
            if let value = dictionary[unclamped] as? Double, value > 0 { return value }
            if let value = dictionary[clamped] as? Double, value > 0 { return value }
        }
        return nil
    }

    init?(data: Data, maxFrames: Int, plate: UIColor) {
        // ShouldCache false: frames are drawn once into the atlas and never
        // wanted again, so caching them is pure resident cost.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        self.data = data
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var delays: [CFTimeInterval] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            delays.append(Self.delay(from: properties) ?? 1.0 / 30)
        }

        self.source = source
        self.plate = plate
        self.timeline = FrameTimeline.resampling(delays: delays, maxFrames: maxFrames)
    }

    func render(frame index: Int, into window: CellWindow) {
        guard let context = window.makeContext() else { return }
        let sourceIndex = timeline.sourceIndices[min(index, timeline.sourceIndices.count - 1)]
        // FULL size, never CreateThumbnailAtIndex — that call is what silently
        // returns frame zero elsewhere in this app, and a downsampled grid is a
        // broken grid.
        guard let frame = CGImageSourceCreateImageAtIndex(source, sourceIndex, nil) else { return }
        DiscMask.fillPlate(context, side: window.side, colour: plate)
        context.draw(frame, in: Self.aspectFill(frame, in: window.side))
        DiscMask.apply(to: context, side: window.side)
    }

    /// Centre-crop to fill the square cell, matching the marker's own
    /// `scaleAspectFill`.
    ///
    /// Real assets are not square: of the GIFs bundled with this instrument the
    /// aspect ratios run from 15x15 to 221x134. Stretching them to a square
    /// would be a rendering defect the instrument invented, and it would show up
    /// as squashed artwork that reads like a decode bug.
    private static func aspectFill(_ image: CGImage, in side: Int) -> CGRect {
        let target = CGFloat(side)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: target, height: target) }
        let scale = max(target / width, target / height)
        let drawn = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: (target - drawn.width) / 2, y: (target - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )
    }
}
#endif
