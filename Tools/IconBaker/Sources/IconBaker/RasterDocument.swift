import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An animated raster container — GIF, APNG, animated WebP or HEICS — read
/// through ImageIO.
///
/// It exists so the baker has ONE entry point for everything the pipeline might
/// be handed. A map field that mixes Lottie and GIF is not two features; it is
/// one catalogue with two source formats, and the only way that stays true is if
/// a single tool resolves both onto the same asset contract and, crucially, the
/// same clock.
///
/// ## The clock is the whole reason this is not just "decode and pack"
///
/// Real GIFs carry per-frame delays that vary INSIDE one file — 0.2 s, 1.2 s and
/// 2.5 s in the same file, in the set bundled with this repo. Pack those as-is
/// and every icon in the catalogue changes on its own grid: the client reports
/// `distinct steps > 1`, markers stop changing together, and the quantised-tick
/// argument that keeps whole-screen composites at 30 Hz instead of 60 is gone.
/// Measured cost of that on the marker field: 3 distinct clocks and a presented
/// rate of 10 fps for a field asking for 30.
///
/// So this RESAMPLES onto one step, chosen once for the catalogue.
struct RasterDocument {

    let name: String
    /// Cumulative start time of each source frame, in seconds.
    let starts: [Double]
    let durations: [Double]
    let source: CGImageSource
    /// ⚠️ RETAINED, and the whole reason this property exists.
    ///
    /// `CGImageSourceCreateWithData` does NOT copy: it holds the buffer. Let the
    /// `Data` go out of scope and the source is reading freed memory, so
    /// `CGImageSourceCreateImageAtIndex` starts returning frames that are fully
    /// transparent — INTERMITTENTLY, depending on whether that memory has been
    /// reused yet.
    ///
    /// What it looks like from the outside is icons that blink. What it looked
    /// like in the baked sheet was 3 of 5 cells at alpha 0 for one GIF, 1 of 23
    /// for another, and none at all for a third — a pattern with no relation to
    /// the artwork, which is the tell. It was reported as a rendering problem
    /// and it is a lifetime bug two lines from here.
    let data: Data
    var loopSeconds: Double { (starts.last ?? 0) + (durations.last ?? 0) }
    var frameCount: Int { starts.count }

    static func load(_ url: URL) throws -> RasterDocument {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { throw BakeError("\(url.lastPathComponent): unreadable") }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw BakeError("\(url.lastPathComponent): no frames") }

        var starts: [Double] = []
        var durations: [Double] = []
        var clock = 0.0
        for index in 0..<count {
            let delay = Self.delay(of: source, at: index)
            starts.append(clock)
            durations.append(delay)
            clock += delay
        }
        return RasterDocument(
            name: url.deletingPathExtension().lastPathComponent,
            starts: starts, durations: durations, source: source, data: data
        )
    }

    /// ⚠️ The UNCLAMPED delay keys.
    ///
    /// `kCGImagePropertyGIFDelayTime` silently floors anything under 0.05 s at
    /// 0.1 s — a browser-compatibility rule from the 1990s baked into ImageIO.
    /// Reading it would turn every fast GIF into a 10 fps one and the bug would
    /// look like the artwork's fault. The unclamped key reports what the file
    /// actually says.
    ///
    /// GIF89a stores the delay in CENTISECONDS, so its representable rates are
    /// exactly 100/k — 100, 50, 33.3, 25, 20 … **60 is not among them, and
    /// neither is 30.** A GIF cannot be authored at either of the rates this
    /// product wants; resampling is not a nicety here, it is the only way a GIF
    /// joins a 30 fps catalogue at all.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else { return 0.1 }
        for (container, unclamped, clamped) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime,
             kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime,
             kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime,
             kCGImagePropertyWebPDelayTime)
        ] {
            guard let dictionary = properties[container] as? [CFString: Any] else { continue }
            if let value = dictionary[unclamped] as? Double, value > 0 { return value }
            if let value = dictionary[clamped] as? Double, value > 0 { return value }
        }
        return 0.1
    }

    /// The source frame showing at time `t`, held forward — which is what a
    /// container's own semantics are.
    func frame(at t: Double) -> CGImage? {
        var index = 0
        for (i, start) in starts.enumerated() where start <= t { index = i }
        return CGImageSourceCreateImageAtIndex(source, index, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
