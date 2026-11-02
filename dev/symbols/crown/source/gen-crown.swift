// Builds core.crown and core.crown.fill from the owner's crown (#2071), traced
// from the two 64 px drawings, as SF Symbol templates. The fill has two
// layers: the body (0) and an edge (1), so a palette can draw a yellow crown
// with a deep-gold rim (option (a)); one colour draws it solid (option (b)).
// Helpers are copied from ../star (#2074).
// usage: swift gen-crown.swift <template-head.svg> <crown-owner.png> <crown-fill-owner.png> <gem-fill-reference.svg> <out dir> <preview dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], outlinePNG = args[2], fillPNG = args[3], referenceSVG = args[4], outDir = args[5], previewDir = args[6]
var head = try! String(contentsOfFile: headPath, encoding: .utf8)

// MARK: - SVG path parsing (absolute + relative, arcs to cubics)

func tokens(_ d: String) -> [String] {
    var out: [String] = []
    var cur = ""
    func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
    var prev: Character = " "
    for ch in d {
        if ch.isLetter && ch != "e" && ch != "E" {
            flush(); out.append(String(ch))
        } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
            flush()
        } else if ch == "-" && !(prev == "e" || prev == "E") {
            flush(); cur.append(ch)
        } else if ch == "." && cur.contains(".") {
            flush(); cur.append(ch)
        } else {
            cur.append(ch)
        }
        prev = ch
    }
    flush()
    return out
}

func arcToCubics(_ p0: CGPoint, _ rxIn: CGFloat, _ ryIn: CGFloat, _ phiDeg: CGFloat,
                 _ large: Bool, _ sweep: Bool, _ p1: CGPoint, into path: CGMutablePath) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 { path.addLine(to: p1); return }
    let phi = phiDeg * .pi / 180
    let cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1 { rx *= sqrt(lam); ry *= sqrt(lam) }
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var coef = sqrt(max(0, num / den))
    if large == sweep { coef = -coef }
    let cxp = coef * (rx * y1p / ry), cyp = coef * -(ry * x1p / rx)
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var dtheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
    if sweep && dtheta < 0 { dtheta += 2 * .pi }
    let segs = Int(ceil(abs(dtheta) / (.pi / 2)))
    let delta = dtheta / CGFloat(segs)
    let t = 4.0 / 3.0 * tan(delta / 4)
    var th = theta1
    func pt(_ a: CGFloat) -> CGPoint {
        CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
    }
    func dpt(_ a: CGFloat) -> CGPoint {
        CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
    }
    for _ in 0..<segs {
        let a0 = th, a1 = th + delta
        let s = pt(a0), e = pt(a1), d0 = dpt(a0), d1 = dpt(a1)
        path.addCurve(to: e, control1: CGPoint(x: s.x + t * d0.x, y: s.y + t * d0.y),
                      control2: CGPoint(x: e.x - t * d1.x, y: e.y - t * d1.y))
        th = a1
    }
}

func parse(_ d: String) -> CGMutablePath {
    let path = CGMutablePath()
    let tk = tokens(d)
    var i = 0
    var cmd: Character = "M"
    var cur = CGPoint.zero, start = CGPoint.zero
    var lastCtrl: CGPoint? = nil
    var lastQ: CGPoint? = nil
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tk[i])!) }
    while i < tk.count {
        if let c = tk[i].first, c.isLetter, tk[i].count == 1 { cmd = c; i += 1 }
        let rel = cmd.isLowercase
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        switch cmd.uppercased().first! {
        case "M":
            let q = p(num(), num()); path.move(to: q); cur = q; start = q
            cmd = rel ? "l" : "L"; lastCtrl = nil; lastQ = nil
        case "L":
            let q = p(num(), num()); path.addLine(to: q); cur = q; lastCtrl = nil; lastQ = nil
        case "H":
            let x = num(); let q = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: q); cur = q; lastCtrl = nil; lastQ = nil
        case "V":
            let y = num(); let q = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: q); cur = q; lastCtrl = nil; lastQ = nil
        case "C":
            let c1 = p(num(), num()), c2 = p(num(), num()), e = p(num(), num())
            path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2; lastQ = nil
        case "S":
            let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = p(num(), num()), e = p(num(), num())
            path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2; lastQ = nil
        case "Q":
            let c = p(num(), num()), e = p(num(), num())
            path.addQuadCurve(to: e, control: c); cur = e; lastQ = c; lastCtrl = nil
        case "T":
            let c = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let e = p(num(), num()); path.addQuadCurve(to: e, control: c); cur = e; lastQ = c; lastCtrl = nil
        case "A":
            let rx = num(), ry = num(), rot = num(), la = num() != 0, sw = num() != 0
            let e = p(num(), num())
            arcToCubics(cur, rx, ry, rot, la, sw, e, into: path); cur = e; lastCtrl = nil; lastQ = nil
        case "Z":
            path.closeSubpath(); cur = start; lastCtrl = nil; lastQ = nil
        default:
            fatalError("unsupported \(cmd)")
        }
    }
    return path
}

func pathsIn(_ svgFile: String) -> [String] {
    let s = try! String(contentsOfFile: svgFile, encoding: .utf8)
    let re = try! NSRegularExpression(pattern: " d=\"([^\"]+)\"")
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
        String(s[Range($0.range(at: 1), in: s)!])
    }
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


// MARK: - Tracing

/// A drawing's alpha, 0…1, row 0 at the top.
func alphaOf(_ path: String) -> (w: Int, h: Int, a: [CGFloat]) {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, (0..<(w * h)).map { CGFloat(px[$0 * 4 + 3]) / 255 })
}

/// Bilinear alpha at a point (pixel centres on half units).
func sample(_ d: (w: Int, h: Int, a: [CGFloat]), _ p: CGPoint) -> CGFloat {
    let x = p.x - 0.5, y = p.y - 0.5
    let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
    func at(_ i: Int, _ j: Int) -> CGFloat { (i < 0 || j < 0 || i >= d.w || j >= d.h) ? 0 : d.a[j * d.w + i] }
    return at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy) + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy
}

/// The radius at which a ray from `c` at angle `t` leaves the shape (alpha
/// crosses 0.5), to a hundredth of a pixel. `from`: start that far out (to
/// skip a hollow).
func edge(_ d: (w: Int, h: Int, a: [CGFloat]), _ c: CGPoint, _ t: CGFloat, outermost: Bool = true) -> CGFloat {
    var last: CGFloat = 0
    var r: CGFloat = 0
    var inside = false
    while r < 40 {
        let v = sample(d, CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t)))
        if v >= 0.5 { inside = true; last = r }
        r += 0.01
    }
    return inside ? last : 0
}

/// The drawing's silhouette: its stroke as drawn, and every hole the stroke
/// closes filled — what the outline encloses. Alpha 0…1, row 0 at the top.
let drawing = alphaOf(outlinePNG)
let silhouette: (w: Int, h: Int, a: [CGFloat]) = {
    let w = drawing.w, h = drawing.h
    var outside = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    for i in 0..<w { stack.append(i); stack.append((h - 1) * w + i) }
    for j in 0..<h { stack.append(j * w); stack.append(j * w + w - 1) }
    while let p = stack.popLast() {
        guard !outside[p], drawing.a[p] < 0.5 else { continue }
        outside[p] = true
        let x = p % w, y = p / w
        if x > 0 { stack.append(p - 1) }; if x < w - 1 { stack.append(p + 1) }
        if y > 0 { stack.append(p - w) }; if y < h - 1 { stack.append(p + w) }
    }
    return (w, h, (0..<(w * h)).map { outside[$0] || drawing.a[$0] >= 0.5 ? drawing.a[$0] : 1 })
}()

/// The silhouette's two parts: the crown, then its band, split at the gap
/// between them. The outline drawing's strokes touch there; the fill
/// drawing shows the gap, so its emptiest row between them decides.
let fillDrawing = alphaOf(fillPNG)
let gapRow: Int = {
    let fill = fillDrawing
    let inked = (0..<fill.h).filter { y in (0..<fill.w).contains { fill.a[y * fill.w + $0] >= 0.5 } }
    let top = inked.min()!, bottom = inked.max()!
    let lo = top + (bottom - top) * 55 / 100, hi = top + (bottom - top) * 90 / 100
    return (lo...hi).min { a, b in
        (0..<fill.w).map { fill.a[a * fill.w + $0] }.reduce(0, +) < (0..<fill.w).map { fill.a[b * fill.w + $0] }.reduce(0, +)
    }!
}()
let parts: [[Int]] = {
    let inked = (0..<(silhouette.w * silhouette.h)).filter { silhouette.a[$0] >= 0.5 }
    return [inked.filter { $0 / silhouette.w < gapRow }, inked.filter { $0 / silhouette.w > gapRow }]
}()
/// The mirror axis: the whole silhouette's centre of mass, across.
let axis: CGFloat = {
    var sx: CGFloat = 0, sa: CGFloat = 0
    for p in parts.joined() { sx += CGFloat(p % silhouette.w) + 0.5; sa += 1 }
    return sx / sa
}()

/// One part, traced on rays from `centre` every 0.25°, mirrored about the
/// axis (left and right averaged), smoothed lightly, then joined by
/// Catmull-Rom cubics every 1°. Only this part's pixels count.
func trace(_ members: [Int], centreY: CGFloat) -> CGPath {
    let set = Set(members)
    let only: (w: Int, h: Int, a: [CGFloat]) = (silhouette.w, silhouette.h, (0..<(silhouette.w * silhouette.h)).map { i in
        // This part's pixels and their anti-aliased rim (the rim touches it).
        if set.contains(i) { return silhouette.a[i] }
        let x = i % silhouette.w, y = i / silhouette.w
        let near = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
            let nx = x + dx, ny = y + dy
            return nx >= 0 && ny >= 0 && nx < silhouette.w && ny < silhouette.h && set.contains(ny * silhouette.w + nx)
        }
        return near ? min(silhouette.a[i], 0.49) : 0
    })
    let c = CGPoint(x: axis, y: centreY)
    let raw: [CGFloat] = stride(from: 0 as CGFloat, to: 360, by: 0.25).map { edge(only, c, $0 * .pi / 180) }
    func r(_ deg: CGFloat) -> CGFloat {
        var i = deg / 0.25
        i = i.truncatingRemainder(dividingBy: CGFloat(raw.count)); if i < 0 { i += CGFloat(raw.count) }
        let i0 = Int(floor(i)) % raw.count, i1 = (i0 + 1) % raw.count, f = i - floor(i)
        return raw[i0] * (1 - f) + raw[i1] * f
    }
    // y runs down, so the mirror about a vertical axis maps θ to 180° − θ.
    let mirrored: [CGFloat] = stride(from: 0 as CGFloat, to: 360, by: 0.25).map { t in (r(t) + r(180 - t)) / 2 }
    let smooth: [CGFloat] = mirrored.indices.map { i in
        (-4...4).map { mirrored[(i + $0 + mirrored.count) % mirrored.count] }.reduce(0, +) / 9
    }
    let pts: [CGPoint] = stride(from: 0, to: smooth.count, by: 4).map { i in
        let a = CGFloat(i) * 0.25 * .pi / 180
        return CGPoint(x: c.x + smooth[i] * cos(a), y: c.y + smooth[i] * sin(a))
    }
    let path = CGMutablePath()
    path.move(to: pts[0])
    for i in 0..<pts.count {
        let p0 = pts[(i - 1 + pts.count) % pts.count], p1 = pts[i], p2 = pts[(i + 1) % pts.count], p3 = pts[(i + 2) % pts.count]
        path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    path.closeSubpath()
    return path
}
func rows(_ members: [Int]) -> (CGFloat, CGFloat) {
    let ys = members.map { CGFloat($0 / silhouette.w) }
    return (ys.min()!, ys.max()! + 1)
}
let (bodyTop, bodyBottom) = rows(parts[0]), (bandTop, bandBottom) = rows(parts[1])
// The crown's rays leave from low in its body, below the valleys between
// the peaks, so each ray crosses the edge once; the band's from its middle.
let body = trace(parts[0], centreY: bodyTop + (bodyBottom - bodyTop) * 0.62)
let band = trace(parts[1], centreY: (bandTop + bandBottom) / 2)
print("traced: axis x \(fmt(axis)); crown rows \(fmt(bodyTop))–\(fmt(bodyBottom)), band \(fmt(bandTop))–\(fmt(bandBottom)) px")

/// The drawing's stroke, measured across: the narrowest run of stroke
/// pixels on each row through the crown's sides, the median of those.
let stroke: CGFloat = {
    var runs: [CGFloat] = []
    for y in Int(bodyTop + 6)..<Int(bodyBottom - 2) {
        var x = 0
        while x < drawing.w {
            if drawing.a[y * drawing.w + x] >= 0.5 {
                var len: CGFloat = 0
                let start = x
                while x < drawing.w, drawing.a[y * drawing.w + x] >= 0.5 { len += 1; x += 1 }
                let edges = (start > 0 ? drawing.a[y * drawing.w + start - 1] : 0) + (x < drawing.w ? drawing.a[y * drawing.w + x] : 0)
                if len < 9 { runs.append(len + edges) }
            }
            x += 1
        }
    }
    return runs.sorted()[runs.count / 2]
}()
let both = body.union(band)
print("the owner's stroke ≈ \(fmt(stroke)) px, \(fmt(stroke / both.boundingBoxOfPath.width * 100)) % of the crown's width (\(fmt(both.boundingBoxOfPath.width)) px)")

// MARK: - Placement: the gem's optical size and centre
let round: (CGPath, CGFloat) -> CGPath = { $0.copy(strokingWithWidth: $1, lineCap: .round, lineJoin: .round, miterLimit: 10) }
func eroded(_ a: CGPath, by d: CGFloat) -> CGPath { a.subtracting(round(a, 2 * d)) }


func area(_ path: CGPath) -> CGFloat {
    let r = path.boundingBoxOfPath, px = 8.0
    let w = Int(r.width * px) + 2, h = Int(r.height * px) + 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: px, y: px); ctx.translateBy(x: -r.minX, y: -r.minY)
    ctx.addPath(path); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
    let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var sum = 0
    for i in 0..<(w * h) { sum += Int(data[i]) }
    return CGFloat(sum) / 255 / (px * px)
}

/// The gem it replaces, as placed in its template's Regular master.
let reference: CGPath = {
    let s = try! String(contentsOfFile: referenceSVG, encoding: .utf8)
    let block = s.components(separatedBy: "<g id=\"Regular-S\"")[1]
    let re = try! NSRegularExpression(pattern: " d=\"([^\"]+)\"")
    let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block))!
    return parse(String(block[Range(m.range(at: 1), in: block)!]))
}()
/// ⚠️ THE OPTICAL SIZE: the crown takes the filled gem's AREA, then ×1.08
/// (`heightNudge`): at the gem's area it stood 13 pt tall at 12 pt semibold
/// against the system crown's 14.3, past `AppSymbolSizeTests`' 8 %.
let heightNudge: CGFloat = 1.08
let k = sqrt(area(reference) / area(both)) * heightNudge
/// Its box's middle on the cap height's middle, a touch below, as
/// `gen.swift` places the set (`capMid`): the system crown sits there, and
/// the gem's centroid sat it on the baseline.
let capMid: CGFloat = -70.459 / 2 + 2.2
let mine = CGPoint(x: both.boundingBoxOfPath.midX, y: both.boundingBoxOfPath.midY)
var place = CGAffineTransform(translationX: 0, y: capMid).scaledBy(x: k, y: k).translatedBy(x: -mine.x, y: -mine.y)
let placedBoth = both.copy(using: &place)!
var toZero = CGAffineTransform(translationX: -placedBoth.boundingBoxOfPath.minX, y: 0)
func placed(_ p: CGPath) -> CGPath { var t = place.concatenating(toZero); return p.copy(using: &t)! }
let bandFill = placed(band)
/// ⚠️ THE GAP between the crown and its band is what makes it read as a
/// crown at 12 pt (#2071). The outline drawing's strokes touch there, so
/// the gap is the fill drawing's, measured down its middle column, and
/// carved out of the crown along the band's own curve.
let gap: CGFloat = {
    let x = Int(axis)
    let column = (0..<fillDrawing.h).map { fillDrawing.a[$0 * fillDrawing.w + x] }
    var y = gapRow
    while y > 0, column[y - 1] < 0.5 { y -= 1 }
    var e = gapRow
    while e < fillDrawing.h - 1, column[e + 1] < 0.5 { e += 1 }
    // Sub-pixel: the clear rows plus the part of each edge row below 0.5.
    return CGFloat(e - y + 1) + (0.5 - column[y - 1]) + (0.5 - column[min(e + 1, fillDrawing.h - 1)])
}() * k
let crownFill = placed(body).subtracting(bandFill.union(round(bandFill, 2 * gap)))
let solid = crownFill.union(bandFill)
print("scale \(fmt(k)) (64 px → template), \(fmt(solid.boundingBoxOfPath.width)) × \(fmt(solid.boundingBoxOfPath.height)) against the gem's \(fmt(reference.boundingBoxOfPath.width)) × \(fmt(reference.boundingBoxOfPath.height))")

/// The outline at the owner's weight, grown inward from the fill's edge.
let weight = stroke * k
let outline = crownFill.subtracting(eroded(crownFill, by: weight)).union(bandFill.subtracting(eroded(bandFill, by: weight)))
/// The fill's edge (layer 1): a rim inside the edge, the yellow's contrast on
/// white (option (a)). Half the outline's weight.
let rimWidth = weight * 0.55
let rim = crownFill.subtracting(eroded(crownFill, by: rimWidth)).union(bandFill.subtracting(eroded(bandFill, by: rimWidth)))
print("outline weight \(fmt(weight)), rim \(fmt(rimWidth)), gap \(fmt(gap)) in the template")

// MARK: - Output


let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]
/// The side margin each master keeps outside its outline (#1566).
let sideMargin: CGFloat = 4

func write(_ name: String, _ layers: [(CGPath, String)]) {
    let width = layers.map { $0.0.boundingBoxOfPath.maxX }.max()!
    var guides = head
    let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
    guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
    var margins = "", symbols = ""
    for (weightName, centre) in columns {
        let left = centre - width / 2
        let l = left - sideMargin, r = left + width + sideMargin
        margins += "  <line id=\"left-margin-\(weightName)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(l))\" x2=\"\(fmt(l))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weightName)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(r))\" x2=\"\(fmt(r))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        symbols += "  <g id=\"\(weightName)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n"
        for (path, cls) in layers { symbols += "   <path class=\"\(cls)\" d=\"\(svgData(path))\"/>\n" }
        symbols += "  </g>\n"
    }
    guides = guides.replacingOccurrences(of: " </g>\n \n", with: "")
    if let r = guides.range(of: " </g>", options: .backwards) { guides.replaceSubrange(r, with: margins + " </g>") }
    guides = guides.replacingOccurrences(of: "Generated from badge.plus", with: "core-platform \(name) (the owner's crown, #2071)")
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "", point size: 100.0, template writer version: "101"-->
     <style>.monochrome-0 {fill:#000000}
    .monochrome-1 {fill:#000000}
    .multicolor-0:tintColor {fill:#007AFF}
    .multicolor-1:tintColor {fill:#007AFF}
    .hierarchical-0:primary {fill:#212121}
    .hierarchical-1:secondary {fill:#8E8E8E}
    .SFSymbolsPreview000000 {fill:#000000;opacity:1.0}
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
    print("wrote \(name) width \(fmt(width))")
    let px = 160
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.translateBy(x: 20, y: CGFloat(px) - 20); ctx.scaleBy(x: 1.2, y: -1.2)
    ctx.translateBy(x: 0, y: 95)
    for (path, _) in layers { ctx.addPath(path) }; ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}


let base = "monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000"
/// The rim: layer 1 (`secondary`, the palette's second colour), drawn OVER
/// the whole solid crown (layer 0), so one colour shows no seam where they
/// meet; a palette paints it the yellow crown's deep-gold edge (option (a)).
let edgeLayer = "monochrome-1 multicolor-1:tintColor hierarchical-1:secondary SFSymbolsPreview000000"
write("core.crown", [(outline, base)])
write("core.crown.fill", [(solid, base), (rim, edgeLayer)])
