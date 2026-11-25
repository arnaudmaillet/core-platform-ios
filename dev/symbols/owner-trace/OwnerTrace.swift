// OwnerTrace: the shared half of the owner's glyph generators (#2415, #2416,
// #2433, #2434, #2456–#2459). Each glyph's own `gen-<name>.swift` is a recipe
// that this file is prepended to (`dev/symbols/owner-trace/run.sh`).
//
// What it does, in the order a recipe calls it:
// 1. Reads a drawing's alpha (`Raster`), and makes it exact where the drawing
//    is meant to be: mirrored about an axis, averaged over n rotations, or
//    reflected about a diagonal (`mirrored`, `rotated`, `reflectedDiagonal`).
// 2. Traces the ink's edge at half coverage (marching squares, linear
//    interpolation), smooths it lightly and joins it by Catmull-Rom cubics
//    (`trace`). Nothing is upscaled: the curve comes from the 64 px samples.
// 3. Builds the rest from CoreGraphics' path booleans: the stroke set to the
//    set's 6.4 units (`setStroke`), silhouettes, gaps and cut-outs.
// 4. Writes each symbol as the set's template (head, three masters with one
//    outline, a 4-unit side margin, #1566; the box's middle on the cap
//    height's middle, `dev/symbols/gen.swift`) and a 160 px thumbnail.
//
// The template writer is gen-map.swift's (#2413).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Raster

/// A drawing's coverage, 0…1, y down, one sample per pixel.
struct Raster {
    let w: Int, h: Int
    var a: [Double]

    init(w: Int, h: Int, a: [Double]) { self.w = w; self.h = h; self.a = a }

    /// The alpha of a black-on-transparent PNG.
    init(png path: String) {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        w = img.width; h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = [Double](repeating: 0, count: w * h)
        // CGContext rows run bottom-up in memory order for this context: row 0 is the top.
        for y in 0..<h { for x in 0..<w { out[y * w + x] = Double(p[(y * w + x) * 4 + 3]) / 255 } }
        a = out
    }

    subscript(x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x < w, y < h else { return 0 }
        return a[y * w + x]
    }

    /// Bilinear coverage at a pixel-centre coordinate.
    func sample(_ x: Double, _ y: Double) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        return self[x0, y0] * (1 - fx) * (1 - fy) + self[x0 + 1, y0] * fx * (1 - fy)
            + self[x0, y0 + 1] * (1 - fx) * fy + self[x0 + 1, y0 + 1] * fx * fy
    }

    /// Ink bounding box (coverage > 0.5), in pixel-edge coordinates.
    var inkBox: CGRect {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where self[x, y] > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Coverage-weighted centre, in pixel-centre coordinates (+0.5 = edge coords).
    var centroid: CGPoint {
        var sx = 0.0, sy = 0.0, s = 0.0
        for y in 0..<h { for x in 0..<w { let v = self[x, y]; sx += v * Double(x); sy += v * Double(y); s += v } }
        return CGPoint(x: sx / s + 0.5, y: sy / s + 0.5)
    }

    func map(_ f: (Double, Double) -> Double) -> Raster {
        var out = self
        for y in 0..<h { for x in 0..<w { out.a[y * w + x] = f(Double(x) + 0.5, Double(y) + 0.5) } }
        return out
    }

    /// Averaged with its mirror image about the vertical line x = axis
    /// (edge coordinates): left and right become exactly alike.
    func mirrored(axis: Double) -> Raster {
        map { x, y in (sample(x - 0.5, y - 0.5) + sample(2 * axis - x - 0.5, y - 0.5)) / 2 }
    }

    /// Averaged over `n` rotations about `c` (edge coordinates).
    func rotated(_ n: Int, about c: CGPoint) -> Raster {
        map { x, y in
            var s = 0.0
            for k in 0..<n {
                let t = 2 * Double.pi * Double(k) / Double(n)
                let dx = x - c.x, dy = y - c.y
                s += sample(c.x + dx * cos(t) - dy * sin(t) - 0.5, c.y + dx * sin(t) + dy * cos(t) - 0.5)
            }
            return s / Double(n)
        }
    }

    /// Averaged with its reflection about the line through `c` at 45°,
    /// running bottom left to top right (y down): (dx, dy) → (−dy, −dx).
    func reflectedDiagonal(about c: CGPoint) -> Raster {
        map { x, y in
            let dx = x - c.x, dy = y - c.y
            return (sample(x - 0.5, y - 0.5) + sample(c.x - dy - 0.5, c.y - dx - 0.5)) / 2
        }
    }

    /// Only the samples whose centre `keep` accepts.
    func masked(_ keep: (CGPoint) -> Bool) -> Raster {
        var out = self
        for y in 0..<h { for x in 0..<w where !keep(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { out.a[y * w + x] = 0 } }
        return out
    }
}

// MARK: - Tracing

/// The ink's edge at half coverage, as closed polylines in edge coordinates.
func isolines(_ r: Raster, level: Double = 0.5) -> [[CGPoint]] {
    // Sample grid: the pixel centres, padded with one ring of zeros.
    let W = r.w + 2, H = r.h + 2
    func v(_ i: Int, _ j: Int) -> Double { r[i - 1, j - 1] }
    // An edge point is keyed by its cell edge: horizontal edges (i, j)–(i+1, j)
    // and vertical edges (i, j)–(i, j+1).
    struct Key: Hashable { let i: Int, j: Int, vertical: Bool }
    func point(_ k: Key) -> CGPoint {
        let (i2, j2) = k.vertical ? (k.i, k.j + 1) : (k.i + 1, k.j)
        let a = v(k.i, k.j), b = v(i2, j2)
        let t = (level - a) / (b - a)
        let x = Double(k.i) + (Double(i2 - k.i)) * t, y = Double(k.j) + (Double(j2 - k.j)) * t
        return CGPoint(x: x - 0.5, y: y - 0.5) // grid index 1 is pixel centre 0.5
    }
    var next: [Key: Key] = [:]
    for j in 0..<(H - 1) {
        for i in 0..<(W - 1) {
            let tl = v(i, j) > level, tr = v(i + 1, j) > level, br = v(i + 1, j + 1) > level, bl = v(i, j + 1) > level
            let top = Key(i: i, j: j, vertical: false), bottom = Key(i: i, j: j + 1, vertical: false)
            let left = Key(i: i, j: j, vertical: true), right = Key(i: i + 1, j: j, vertical: true)
            // Segments oriented with the ink on their left (y down: clockwise outer loops).
            var segs: [(Key, Key)] = []
            let idx = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0)
            switch idx {
            case 0, 15: break
            case 1: segs = [(left, bottom)]
            case 2: segs = [(bottom, right)]
            case 3: segs = [(left, right)]
            case 4: segs = [(right, top)]
            case 6: segs = [(bottom, top)]
            case 7: segs = [(left, top)]
            case 8: segs = [(top, left)]
            case 9: segs = [(top, bottom)]
            case 11: segs = [(top, right)]
            case 12: segs = [(right, left)]
            case 13: segs = [(right, bottom)]
            case 14: segs = [(bottom, left)]
            case 5, 10:
                let centre = (v(i, j) + v(i + 1, j) + v(i + 1, j + 1) + v(i, j + 1)) / 4 > level
                if idx == 5 { segs = centre ? [(left, top), (right, bottom)] : [(left, bottom), (right, top)] }
                else { segs = centre ? [(top, right), (bottom, left)] : [(top, left), (bottom, right)] }
            default: break
            }
            for (a, b) in segs { next[a] = b }
        }
    }
    var loops: [[CGPoint]] = []
    var seen: Set<Key> = []
    for start in next.keys where !seen.contains(start) {
        var loop: [CGPoint] = []
        var k = start
        while !seen.contains(k), let n = next[k] {
            seen.insert(k); loop.append(point(k)); k = n
        }
        if loop.count > 3 { loops.append(loop) }
    }
    return loops
}

func length(_ p: [CGPoint]) -> Double {
    zip(p, p.dropFirst() + [p[0]]).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
}

/// Points every `step` along a closed polyline.
func resample(_ p: [CGPoint], step: Double) -> [CGPoint] {
    let total = length(p)
    let n = max(8, Int((total / step).rounded()))
    let ds = total / Double(n)
    var out: [CGPoint] = []
    var i = 0, acc = 0.0
    var a = p[0], b = p[1 % p.count]
    var seg = hypot(b.x - a.x, b.y - a.y)
    for k in 0..<n {
        let target = Double(k) * ds
        while acc + seg < target && i < p.count * 2 {
            acc += seg; i += 1
            a = p[i % p.count]; b = p[(i + 1) % p.count]
            seg = hypot(b.x - a.x, b.y - a.y)
        }
        let t = seg > 0 ? (target - acc) / seg : 0
        out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    return out
}

/// A light Gaussian smoothing of a closed polyline (sigma in pixels).
func smooth(_ p: [CGPoint], sigma: Double, step: Double) -> [CGPoint] {
    guard sigma > 0 else { return p }
    let n = p.count
    let radius = Int(ceil(3 * sigma / step))
    let weights = (-radius...radius).map { exp(-pow(Double($0) * step, 2) / (2 * sigma * sigma)) }
    let total = weights.reduce(0, +)
    return (0..<n).map { i in
        var x = 0.0, y = 0.0
        for (k, w) in weights.enumerated() {
            let q = p[((i + k - radius) % n + n) % n]
            x += q.x * w; y += q.y * w
        }
        return CGPoint(x: x / total, y: y / total)
    }
}

/// A closed Catmull-Rom path through `p`.
func closedCurve(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    let n = p.count
    path.move(to: p[0])
    for i in 0..<n {
        let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    path.closeSubpath()
    return path
}

/// An open Catmull-Rom path through `p` (ends repeated).
func openCurve(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    return path
}

/// The drawing's ink as a filled path: its half-coverage edge, smoothed by
/// `sigma` px and joined by a cubic every `node` px. Loops shorter than
/// `minLength` px (specks) are dropped.
func trace(_ r: Raster, sigma: Double = 0.7, node: Double = 1.6, minLength: Double = 4) -> CGPath {
    let path = CGMutablePath()
    for loop in isolines(r) where length(loop) >= minLength {
        let fine = resample(loop, step: 0.2)
        let soft = smooth(fine, sigma: sigma, step: 0.2)
        path.addPath(closedCurve(resample(soft, step: node)))
    }
    return path.normalized(using: .evenOdd)
}

// MARK: - Path helpers

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func pts(_ xy: [(CGFloat, CGFloat)]) -> [CGPoint] { xy.map { CGPoint(x: $0.0, y: $0.1) } }

func stroked(_ p: CGPath, _ w: CGFloat) -> CGPath {
    p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
}
func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
    let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}
/// Grown (k > 0) or shrunk (k < 0) by |k| all round, corners rounded.
func offset(_ p: CGPath, _ k: CGFloat) -> CGPath {
    if abs(k) < 1e-6 { return p }
    let band = stroked(p, 2 * abs(k))
    return k > 0 ? p.union(band) : p.subtracting(band)
}
func area(_ p: CGPath) -> Double {
    // Shoelace over a flattened copy (nonzero-normalised paths only).
    var total = 0.0
    var first = CGPoint.zero, last = CGPoint.zero
    var pts: [CGPoint] = []
    func flush() {
        guard pts.count > 2 else { pts = []; return }
        for i in 0..<pts.count { let a = pts[i], b = pts[(i + 1) % pts.count]; total += Double(a.x * b.y - b.x * a.y) / 2 }
        pts = []
    }
    p.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint: flush(); first = e.points[0]; last = first; pts.append(first)
        case .addLineToPoint: last = e.points[0]; pts.append(last)
        case .addQuadCurveToPoint:
            let c = e.points[0], q = e.points[1]
            for k in 1...8 { let t = CGFloat(k) / 8; pts.append(CGPoint(x: (1-t)*(1-t)*last.x + 2*(1-t)*t*c.x + t*t*q.x, y: (1-t)*(1-t)*last.y + 2*(1-t)*t*c.y + t*t*q.y)) }
            last = q
        case .addCurveToPoint:
            let c1 = e.points[0], c2 = e.points[1], q = e.points[2]
            for k in 1...12 {
                let t = CGFloat(k) / 12, u = 1 - t
                pts.append(CGPoint(x: u*u*u*last.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*q.x,
                                   y: u*u*u*last.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*q.y))
            }
            last = q
        case .closeSubpath: flush(); last = first
        @unknown default: break
        }
    }
    flush()
    return abs(total)
}
/// Perimeter of every contour (flattened).
func perimeter(_ p: CGPath) -> Double {
    var total = 0.0
    var first = CGPoint.zero, last = CGPoint.zero
    func add(_ q: CGPoint) { total += Double(hypot(q.x - last.x, q.y - last.y)); last = q }
    p.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint: first = e.points[0]; last = first
        case .addLineToPoint: add(e.points[0])
        case .addQuadCurveToPoint:
            let s = last, c = e.points[0], q = e.points[1]
            for k in 1...8 { let t = CGFloat(k) / 8; add(CGPoint(x: (1-t)*(1-t)*s.x + 2*(1-t)*t*c.x + t*t*q.x, y: (1-t)*(1-t)*s.y + 2*(1-t)*t*c.y + t*t*q.y)) }
        case .addCurveToPoint:
            let s = last, c1 = e.points[0], c2 = e.points[1], q = e.points[2]
            for k in 1...12 {
                let t = CGFloat(k) / 12, u = 1 - t
                add(CGPoint(x: u*u*u*s.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*q.x, y: u*u*u*s.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*q.y))
            }
        case .closeSubpath: add(first)
        @unknown default: break
        }
    }
    return total
}
/// A line drawing's stroke width: area over half the perimeter.
func strokeWidth(_ p: CGPath) -> Double { 2 * area(p) / perimeter(p) }

/// A line drawing re-weighted to `target` px: grown or shrunk by half the
/// difference, all round.
func setStroke(_ p: CGPath, to target: CGFloat) -> CGPath {
    offset(p, (target - CGFloat(strokeWidth(p))) / 2)
}

/// The subpaths of a path, each as its own path.
func subpaths(_ p: CGPath) -> [CGPath] {
    var out: [CGMutablePath] = []
    p.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint: out.append(CGMutablePath()); out[out.count - 1].move(to: e.points[0])
        case .addLineToPoint: out[out.count - 1].addLine(to: e.points[0])
        case .addQuadCurveToPoint: out[out.count - 1].addQuadCurve(to: e.points[1], control: e.points[0])
        case .addCurveToPoint: out[out.count - 1].addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
        case .closeSubpath: out[out.count - 1].closeSubpath()
        @unknown default: break
        }
    }
    return out
}

/// Everything the outer contours enclose: the shape with its holes filled.
func silhouette(_ p: CGPath) -> CGPath {
    let loops = subpaths(p)
    var result = CGMutablePath() as CGPath
    for (i, loop) in loops.enumerated() {
        let probe = loop.currentPoint
        let inside = loops.enumerated().contains { j, other in
            j != i && other.boundingBoxOfPath.contains(loop.boundingBoxOfPath) && other.contains(probe, using: .evenOdd)
        }
        if !inside { result = result.union(loop) }
    }
    return result
}

func transformed(_ p: CGPath, _ t: CGAffineTransform) -> CGPath {
    var t = t
    return p.copy(using: &t)!
}
/// Mirrored about the vertical line x = axis.
func flippedX(_ p: CGPath, axis: CGFloat) -> CGPath {
    transformed(p, CGAffineTransform(translationX: 2 * axis, y: 0).scaledBy(x: -1, y: 1))
}
func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGPath {
    CGPath(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), transform: nil)
}

// MARK: - Output

func fmt(_ v: CGFloat) -> String {
    let r = (v * 1000).rounded() / 1000
    var s = String(format: "%.3f", Double(r))
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

func svgData(_ path: CGPath) -> String {
    var out = ""
    path.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint: out += "M\(fmt(e.points[0].x)) \(fmt(e.points[0].y))"
        case .addLineToPoint: out += "L\(fmt(e.points[0].x)) \(fmt(e.points[0].y))"
        case .addQuadCurveToPoint:
            out += "Q\(fmt(e.points[0].x)) \(fmt(e.points[0].y)) \(fmt(e.points[1].x)) \(fmt(e.points[1].y))"
        case .addCurveToPoint:
            out += "C\(fmt(e.points[0].x)) \(fmt(e.points[0].y)) \(fmt(e.points[1].x)) \(fmt(e.points[1].y)) \(fmt(e.points[2].x)) \(fmt(e.points[2].y))"
        case .closeSubpath: out += "Z"
        @unknown default: break
        }
    }
    return out
}

struct Layer { let path: CGPath; let cls: String; let preview: CGColor }
let primaryClass = "monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000"
let badgeClass = "monochrome-1 multicolor-1:systemRedColor hierarchical-1:secondary SFSymbolsPreviewFF3B30"
let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let red = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)

/// Writes symbolsets in the set's template. `scale` is template units per
/// drawing pixel; every symbol of a family is placed by one `box` (drawing
/// px), so a swap between them never moves the glyph.
struct TemplateWriter {
    let head: String
    let outDir: String
    let previewDir: String
    let scale: CGFloat
    let box: CGRect

    static let capMid: CGFloat = -70.459 / 2 + 2.2
    static let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]
    static let sideMargin: CGFloat = 4

    init(headPath: String, outDir: String, previewDir: String, scale: CGFloat, box: CGRect) {
        head = try! String(contentsOfFile: headPath, encoding: .utf8)
        self.outDir = outDir; self.previewDir = previewDir; self.scale = scale; self.box = box
    }

    /// The transform from drawing px to the template's glyph coordinates.
    var placement: CGAffineTransform {
        CGAffineTransform(translationX: -box.minX * scale, y: Self.capMid - box.midY * scale).scaledBy(x: scale, y: scale)
    }

    func write(_ name: String, _ layers: [Layer]) {
        let t = placement
        let placed = layers.map { Layer(path: transformed($0.path, t), cls: $0.cls, preview: $0.preview) }
        let minX = min(0, placed.map { $0.path.boundingBoxOfPath.minX }.min()!)
        let maxX = placed.map { $0.path.boundingBoxOfPath.maxX }.max()!
        let shift = CGAffineTransform(translationX: -minX, y: 0)
        let shifted = placed.map { Layer(path: transformed($0.path, shift), cls: $0.cls, preview: $0.preview) }
        let width = maxX - minX
        var guides = head
        let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
        guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
        var margins = "", symbols = ""
        for (weight, centre) in Self.columns {
            let left = centre - width / 2
            let l = left - Self.sideMargin, r = left + width + Self.sideMargin
            margins += "  <line id=\"left-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(l))\" x2=\"\(fmt(l))\" y1=\"600.785\" y2=\"720.121\"/>\n"
            margins += "  <line id=\"right-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(r))\" x2=\"\(fmt(r))\" y1=\"600.785\" y2=\"720.121\"/>\n"
            symbols += "  <g id=\"\(weight)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n"
            for l in shifted { symbols += "   <path class=\"\(l.cls)\" d=\"\(svgData(l.path))\"/>\n" }
            symbols += "  </g>\n"
        }
        guides = guides.replacingOccurrences(of: " </g>\n \n", with: "")
        if let r = guides.range(of: " </g>", options: .backwards) {
            guides.replaceSubrange(r, with: margins + " </g>")
        }
        guides = guides.replacingOccurrences(of: "Generated from badge.plus", with: "core-platform \(name)")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
         <!--glyph: "", point size: 100.0, template writer version: "101"-->
         <style>.monochrome-0 {fill:#000000}
        .monochrome-1 {fill:#000000}
        .multicolor-0:tintColor {fill:#007AFF}
        .multicolor-1:systemRedColor {fill:#FF3B30}
        .hierarchical-0:primary {fill:#212121}
        .hierarchical-1:secondary {fill:#8E8E8E}
        .SFSymbolsPreview000000 {fill:#000000;opacity:1.0}
        .SFSymbolsPreviewFF3B30 {fill:#FF3B30;opacity:1.0}
        </style>
         \(guides)
         <g id="Symbols">
        \(symbols) </g>
        </svg>
        """
        let dir = "\(outDir)/\(name).symbolset"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! svg.write(toFile: "\(dir)/\(name).svg", atomically: true, encoding: .utf8)
        let contents = """
        {
          "info" : {
            "author" : "xcode",
            "version" : 1
          },
          "symbols" : [
            {
              "filename" : "\(name).svg",
              "idiom" : "universal"
            }
          ]
        }
        """
        try! contents.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
        let ext = shifted.map { $0.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
        print("wrote \(name): \(fmt(width)) × \(fmt(ext.height)) units, top \(fmt(ext.minY)) bottom \(fmt(ext.maxY))")
        thumbnail(name, shifted)
    }

    func thumbnail(_ name: String, _ layers: [Layer]) {
        let px = 160
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.translateBy(x: 20, y: CGFloat(px) - 20); ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: 80)
        for l in layers { ctx.addPath(l.path); ctx.setFillColor(l.preview); ctx.fillPath() }
        try? FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }
}

/// A debug overlay: the traced path (red, translucent) over the drawing,
/// `zoom` px per drawing px. Used for the README's "traced over the drawing".
func overlay(_ r: Raster, _ paths: [CGPath], zoom: Int = 8, to file: String) {
    let W = r.w * zoom, H = r.h * zoom
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for y in 0..<r.h { for x in 0..<r.w where r[x, y] > 0 {
        ctx.setFillColor(CGColor(gray: 1 - 0.55 * r[x, y], alpha: 1))
        ctx.fill(CGRect(x: x * zoom, y: (r.h - 1 - y) * zoom, width: zoom, height: zoom))
    } }
    ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: CGFloat(zoom), y: -CGFloat(zoom))
    let colours = [CGColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.45), CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 0.45)]
    for (i, p) in paths.enumerated() {
        ctx.addPath(p); ctx.setFillColor(colours[i % 2]); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(colours[i % 2].copy(alpha: 1)!); ctx.setLineWidth(1.5 / CGFloat(zoom)); ctx.strokePath()
    }
    let url = URL(fileURLWithPath: file)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

/// Loops (from `subpaths`) joined back into one even-odd shape.
func joined(_ loops: [CGPath]) -> CGPath {
    let p = CGMutablePath()
    for l in loops { p.addPath(l) }
    return p.normalized(using: .evenOdd)
}

// MARK: - The slash (#2457), shared by every crossed-out glyph

/// The slash a crossed-out drawing adds to its plain one: the ink in `crossed`
/// farther than `clear` px from any ink in `plain`, fitted by a 45° line
/// (top left to bottom right, y down). Returns its centre line's two ends:
/// the ink's extent along the line, less the drawing's half stroke.
func slashLine(crossed: Raster, plain: Raster, clear: Int = 3, halfStroke: CGFloat = 2) -> (CGPoint, CGPoint) {
    var b = 0.0, n = 0.0, lo = Double.infinity, hi = -Double.infinity
    for y in 0..<crossed.h { for x in 0..<crossed.w where crossed[x, y] > 0.5 {
        var near = false
        for dy in -clear...clear { for dx in -clear...clear where plain[x + dx, y + dy] > 0.2 { near = true } }
        if near { continue }
        let fx = Double(x) + 0.5, fy = Double(y) + 0.5
        b += fy - fx; n += 1
        lo = min(lo, (fx + fy) / 2); hi = max(hi, (fx + fy) / 2)
    } }
    b /= n
    let d = halfStroke / sqrt(2)
    // On y = x + b, a point whose (x + y) / 2 is s sits at x = s - b/2.
    return (pt(lo - b / 2 + d, lo + b / 2 + d), pt(hi - b / 2 - d, hi + b / 2 - d))
}

/// `shape` crossed by the slash `a`–`b`: the slash stroked at `sw`, and, when
/// `gap` > 0, a clear band that wide cut along its upper-right side only,
/// as the owner's filled drawings have it. The band runs past both ends.
func crossed(_ shape: CGPath, _ a: CGPoint, _ b: CGPoint, sw: CGFloat, gap: CGFloat) -> CGPath {
    let slash = stroked(line(a, b), sw)
    guard gap > 0 else { return shape.union(slash) }
    let len = hypot(b.x - a.x, b.y - a.y)
    let u = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
    let n = CGPoint(x: u.y, y: -u.x) // upper right, y down
    let o = sw / 2 + gap / 2
    let a2 = pt(a.x + n.x * o - u.x * gap, a.y + n.y * o - u.y * gap), b2 = pt(b.x + n.x * o + u.x * gap, b.y + n.y * o + u.y * gap)
    let band = line(a2, b2).copy(strokingWithWidth: gap, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    // Round the band's ends with the slash's caps, so the cut follows them.
    let ends = stroked(line(a, b), sw + 2 * gap).subtracting(stroked(line(a, b), sw))
    let cut = band.union(ends.intersection(offset(band, gap)))
    return shape.subtracting(cut).union(slash)
}

extension Raster {
    /// Averaged with its mirror image about the horizontal line y = axis.
    func mirroredY(axis: Double) -> Raster {
        map { x, y in (sample(x - 0.5, y - 0.5) + sample(x - 0.5, 2 * axis - y - 0.5)) / 2 }
    }
    /// One pixel set by hand (a drawing's 1 px nick, filled before tracing).
    func patched(_ x: Int, _ y: Int, _ v: Double) -> Raster {
        var out = self; out.a[y * w + x] = v; return out
    }
}
func moved(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath { transformed(p, CGAffineTransform(translationX: dx, y: dy)) }
