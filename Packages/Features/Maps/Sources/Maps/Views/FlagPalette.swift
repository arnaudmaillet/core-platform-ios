import UIKit

/// A country's flag as the map wears it: the ROUND flag as a picture (the
/// corner badge, the empty country's disc), and the colours a marker's border
/// is painted with.
///
/// The picture comes from `Resources/Flags/Flags.xcassets` — circle-flags
/// (MIT, `Resources/Flags/LICENSE`), pre-rendered to PNG at the disc's size by
/// `Scripts/import-circle-flags.py`, so no SVG is ever rasterised at run time.
/// Every `CountryAtlas` country has one. A code the catalog lacks (a post's
/// country outside the atlas) falls back to its EMOJI, drawn and trimmed;
/// `Entry.isRound` tells a view which of the two it holds.
///
/// ⚠️ **THE COLOURS COME FROM THE PICTURE ITSELF, NOT FROM A TABLE.** A table
/// of 237 flags is 237 chances to be wrong and goes stale with every new
/// country; the picture is what the badge right next to the border draws, so
/// reading the colours off it is what makes the two agree by construction. Its
/// interior is sampled (the round flag's anti-aliased rim, or the emoji's
/// rounded corners and gloss, stay out), quantised, and the 2–3 dominant
/// colours kept in the order they run across the flag — left to right for
/// France, top to bottom for Germany — so the border reads as the flag does.
/// The round flags are flat artwork, so their colours are the flag's own, not
/// an emoji's shaded ones.
///
/// Loaded once per country and cached for the life of the process.
///
/// ⚠️ **WARMED OFF THE MAIN THREAD.** One flag is a few hundred microseconds,
/// but the world zoom realises a disc for every country without posts at
/// once, and two hundred loads in one turn is a hitch the viewer sees.
/// `CountryLayer` warms every country on a background queue as soon as the
/// atlas is decoded (`warm`), so the map only ever reads the cache. Thread-safe
/// for that reason: `UIImage(named:in:compatibleWith:)`, UIKit's image renderer
/// and string drawing are, and the cache sits behind a lock.
enum FlagPalette {
    /// The colours a border wears, ordered along `axis`, and the flag picture.
    struct Entry: @unchecked Sendable {
        let colors: [UIColor]
        /// The direction the colours run across the flag — the border's
        /// gradient runs the same way.
        let axis: Axis
        /// The round flag, or the emoji drawn and trimmed to its glyph (nil
        /// when neither exists — never for a real ISO code).
        let image: UIImage?
        /// Whether `image` is the ROUND flag — a disc edge to edge, laid out to
        /// fill a circle — rather than the rectangular emoji, which sits inside
        /// one.
        let isRound: Bool
    }

    enum Axis: Equatable {
        /// Vertical bands, read left to right (France, Italy).
        case horizontal
        /// Horizontal bands, read top to bottom (Germany, Russia).
        case vertical
    }

    /// The rendered flags, and how many renders it took — the cache's own
    /// probe.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private(set) var renders = 0

        func entry(for key: String, render: (String) -> Entry) -> Entry {
            lock.lock()
            if let cached = entries[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            // Rendered OUTSIDE the lock: a warm-up on a background queue must
            // never hold the main thread's read. Two racing renders of one
            // flag are identical; the first stored wins.
            let rendered = render(key)
            lock.lock()
            defer { lock.unlock() }
            renders += 1
            if let raced = entries[key] { return raced }
            entries[key] = rendered
            return rendered
        }

        var renderCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return renders
        }
    }

    private static let cache = Cache()

    #if DEBUG
    /// How many flags were actually rendered.
    static var renderCount: Int { cache.renderCount }
    #endif

    /// The palette for `code` (ISO 3166-1 alpha-2), loaded on first ask.
    static func entry(for code: String) -> Entry {
        cache.entry(for: code.uppercased(), render: render)
    }

    /// Loads every flag in `codes` that is not cached yet. Call it off the
    /// main thread.
    static func warm(_ codes: [String]) {
        for code in codes { _ = entry(for: code) }
    }

    static func colors(for code: String) -> [UIColor] { entry(for: code).colors }
    static func image(for code: String) -> UIImage? { entry(for: code).image }

    /// The round flag of `code` in the asset catalog, or nil. Thread-safe;
    /// nil traits pick the main screen's scale.
    static func roundFlag(for code: String) -> UIImage? {
        UIImage(named: code.uppercased(), in: .module, compatibleWith: nil)
    }

    /// The regional-indicator flag ("🇫🇷").
    static func emoji(for code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
            .map(String.init).joined()
    }

    // MARK: - Rendering

    private static func render(_ code: String) -> Entry {
        guard let flag = roundFlag(for: code), let cgImage = flag.cgImage, let pixels = Pixels(cgImage) else {
            return renderEmoji(code)
        }
        // Inside the circle, short of its anti-aliased rim.
        let frame = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        let reach = Double(min(pixels.width, pixels.height)) / 2 * 0.9
        let (cx, cy) = (Double(frame.midX), Double(frame.midY))
        let (colors, axis) = dominantColors(in: pixels, glyph: frame, sampling: frame) { x, y in
            let (dx, dy) = (Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
            return dx * dx + dy * dy <= reach * reach
        }
        return Entry(colors: fallback(colors), axis: axis, image: flag, isRound: true)
    }

    /// The emoji fallback's raster size. Big enough that the interior sample
    /// is a few thousand pixels and the badge picture stays sharp at 3x, small
    /// enough to cost nothing.
    private static let glyphPointSize: CGFloat = 48
    private static let scale: CGFloat = 2

    /// The emoji flag, drawn and trimmed to its glyph — for a code the catalog
    /// has no round flag for.
    private static func renderEmoji(_ code: String) -> Entry {
        let text = emoji(for: code) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: glyphPointSize)]
        let size = text.size(withAttributes: attributes)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let raster = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }
        guard let cgImage = raster.cgImage, let pixels = Pixels(cgImage) else {
            return Entry(colors: fallback([]), axis: .horizontal, image: nil, isRound: false)
        }
        guard let glyph = pixels.opaqueBounds() else {
            return Entry(colors: fallback([]), axis: .horizontal, image: nil, isRound: false)
        }
        let image = cgImage.cropping(to: glyph).map {
            UIImage(cgImage: $0, scale: scale, orientation: .up)
        }
        // The interior only: the emoji's rounded corners and its rim of
        // shading are not the flag's colours.
        let interior = glyph.insetBy(dx: glyph.width * 0.12, dy: glyph.height * 0.14)
        let (colors, axis) = dominantColors(in: pixels, glyph: glyph, sampling: interior) { _, _ in true }
        return Entry(colors: fallback(colors), axis: axis, image: image, isRound: false)
    }

    /// At least two colours, always: a border of one colour is a plain ring
    /// and says nothing about a flag. A flag that yields one (or none) is
    /// paired with white or near-black, whichever stands apart from it.
    private static func fallback(_ colors: [UIColor]) -> [UIColor] {
        switch colors.count {
        case 0: return [UIColor(white: 0.85, alpha: 1), UIColor(white: 0.35, alpha: 1)]
        case 1:
            var white: CGFloat = 0
            colors[0].getWhite(&white, alpha: nil)
            return colors + [white > 0.6 ? UIColor(white: 0.2, alpha: 1) : .white]
        default: return colors
        }
    }

    /// The 2–3 colours that cover most of the flag's interior, ordered along
    /// the axis they are most spread on.
    ///
    /// Quantised to 3 bits per channel, then merged greedily: a bin within
    /// `mergeDistance` of a colour already kept is the same colour under the
    /// emoji's shading (or an edge's anti-aliasing), and a colour under
    /// `minimumShare` of the interior is a detail (a star, a crest), not a
    /// band.
    ///
    /// Only the pixels of `sampling` that `includes` admits are read (the
    /// round flag's disc); positions are measured against `glyph`.
    private static func dominantColors(
        in pixels: Pixels, glyph: CGRect, sampling: CGRect, includes: (Int, Int) -> Bool
    ) -> ([UIColor], Axis) {
        struct Bin {
            var count = 0
            var r = 0, g = 0, b = 0
            var x = 0, y = 0
        }
        var bins: [Int: Bin] = [:]
        var sampled = 0
        for y in Int(sampling.minY)..<Int(sampling.maxY) {
            for x in Int(sampling.minX)..<Int(sampling.maxX) where includes(x, y) {
                let (r, g, b, a) = pixels.rgba(x: x, y: y)
                guard a > 250 else { continue }
                let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
                var bin = bins[key, default: Bin()]
                bin.count += 1
                bin.r += r; bin.g += g; bin.b += b
                bin.x += x; bin.y += y
                bins[key] = bin
                sampled += 1
            }
        }
        guard sampled > 0 else { return ([], .horizontal) }

        struct Kept { var r, g, b: Double; var count: Int; var x, y: Double }
        let distance = { (a: Kept, b: Kept) -> Double in
            let (dr, dg, db) = (a.r - b.r, a.g - b.g, a.b - b.b)
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        let mergeDistance = 90.0
        let minimumShare = 0.04
        var kept: [Kept] = []
        for bin in bins.values.sorted(by: { $0.count > $1.count }) {
            let n = Double(bin.count)
            let colour = Kept(
                r: Double(bin.r) / n, g: Double(bin.g) / n, b: Double(bin.b) / n,
                count: bin.count, x: Double(bin.x) / n, y: Double(bin.y) / n
            )
            if let index = kept.firstIndex(where: { distance($0, colour) < mergeDistance }) {
                // The same colour under the emoji's shading: it adds to the
                // band's weight and position, never to the colour itself.
                let total = Double(kept[index].count + bin.count)
                kept[index].x = (kept[index].x * Double(kept[index].count) + colour.x * n) / total
                kept[index].y = (kept[index].y * Double(kept[index].count) + colour.y * n) / total
                kept[index].count += bin.count
                continue
            }
            kept.append(colour)
        }
        let bands = kept
            .filter { Double($0.count) / Double(sampled) >= minimumShare }
            .sorted { $0.count > $1.count }
            .prefix(3)
        // Ordered the way the flag reads: along whichever axis the bands are
        // spread on (relative to the glyph's own proportions).
        let xs = bands.map { ($0.x - glyph.minX) / glyph.width }
        let ys = bands.map { ($0.y - glyph.minY) / glyph.height }
        let spread = { (values: [Double]) in (values.max() ?? 0) - (values.min() ?? 0) }
        let axis: Axis = spread(xs) >= spread(ys) ? .horizontal : .vertical
        let ordered = bands.sorted { axis == .horizontal ? $0.x < $1.x : $0.y < $1.y }
        let colors = ordered.map {
            UIColor(red: $0.r / 255, green: $0.g / 255, blue: $0.b / 255, alpha: 1)
        }
        return (colors, axis)
    }

}

/// An RGBA8 copy of a raster, un-premultiplied where it is opaque enough to
/// matter.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let (w, h) = (image.width, image.height)
        width = w
        height = h
        var raster = [UInt8](repeating: 0, count: w * h * 4)
        // ⚠️ R G B A, BYTE ORDER EXPLICIT. `premultipliedFirst` with a little
        // byte order is B G R A — alpha last — and reading it as RGBA yields a
        // palette of the wrong colours rather than an error.
        let drawn = raster.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        bytes = raster
    }

    /// Top-left origin, like the image.
    func rgba(x: Int, y: Int) -> (Int, Int, Int, Int) {
        let i = (y * width + x) * 4
        let a = Int(bytes[i + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        let unpremultiply = { (value: UInt8) in min(255, Int(value) * 255 / a) }
        return (unpremultiply(bytes[i]), unpremultiply(bytes[i + 1]), unpremultiply(bytes[i + 2]), a)
    }

    /// The rectangle holding every pixel that is more than faintly drawn — the
    /// glyph, without the text box's empty margins.
    func opaqueBounds() -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
