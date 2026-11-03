// Builds core.star and core.star.fill from the owner's plump star (#2074),
// traced from the two 64 px drawings, as SF Symbol templates.
// Helpers (path parsing, SVG output) are copied from tabs/square-play (#1191),
// itself from gen.swift (#1128).
// usage: swift gen-star.swift <template-head.svg> <star-fill-owner.png> <star-owner.png>
//        <today's core.star.fill.svg> <out dir> <preview dir>
// STROKE=owner draws the outline at the owner's weight (a); default: the
// set's (b), Phosphor's ratio.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], fillPNG = args[2], outlinePNG = args[3], todaysFill = args[4], outDir = args[5], previewDir = args[6]
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

let fill = alphaOf(fillPNG)
// The centre: the silhouette's centroid.
var sx: CGFloat = 0, sy: CGFloat = 0, sa: CGFloat = 0
for j in 0..<fill.h { for i in 0..<fill.w { let v = fill.a[j * fill.w + i]; sx += v * (CGFloat(i) + 0.5); sy += v * (CGFloat(j) + 0.5); sa += v } }
let centre = CGPoint(x: sx / sa, y: sy / sa)

/// r(θ), 0.25° apart; θ = 0 points right, −90° up (y down).
let step: CGFloat = 0.25
let raw: [CGFloat] = stride(from: 0, to: 360, by: step).map { edge(fill, centre, $0 * .pi / 180) }
func r(_ deg: CGFloat) -> CGFloat {
    let n = raw.count
    var i = deg / step
    i = i.truncatingRemainder(dividingBy: CGFloat(n)); if i < 0 { i += CGFloat(n) }
    let i0 = Int(floor(i)) % n, i1 = (i0 + 1) % n, f = i - floor(i)
    return raw[i0] * (1 - f) + raw[i1] * f
}
// The top tip: the axis near −90° that best matches the five-fold mirror.
var tipAxis: CGFloat = -90, bestErr = CGFloat.infinity
for a in stride(from: -100 as CGFloat, through: -80, by: 0.05) {
    var err: CGFloat = 0
    for t in stride(from: 0 as CGFloat, through: 36, by: 1) {
        let vals = (0..<5).flatMap { k in [r(a + CGFloat(k) * 72 + t), r(a + CGFloat(k) * 72 - t)] }
        let m = vals.reduce(0, +) / 10
        err += vals.map { ($0 - m) * ($0 - m) }.reduce(0, +)
    }
    if err < bestErr { bestErr = err; tipAxis = a }
}
/// The symmetric profile, tip (0°) to valley (36°): the mean of the ten
/// half-sectors, so no tip is a pixel off.
let profile: [CGFloat] = stride(from: 0 as CGFloat, through: 36, by: 0.25).map { t in
    (0..<5).map { k in r(tipAxis + CGFloat(k) * 72 + t) + r(tipAxis + CGFloat(k) * 72 - t) }.reduce(0, +) / 10
}
let spread = (0..<5).map { k in r(tipAxis + CGFloat(k) * 72) }
print("traced: centre \(fmt(centre.x)),\(fmt(centre.y)) axis \(fmt(tipAxis))°, tip \(fmt(profile.first!)) valley \(fmt(profile.last!)) px; the drawing's tips \(spread.map(fmt))")

// A smooth closed star from the profile: points every 2°, joined by
// Catmull-Rom cubics (on the 64 px grid, centred on 0).
func profileR(_ t: CGFloat) -> CGFloat {
    var u = abs(t).truncatingRemainder(dividingBy: 72); if u > 36 { u = 72 - u }
    let i = u / 0.25, i0 = min(Int(floor(i)), profile.count - 1), i1 = min(i0 + 1, profile.count - 1), f = i - floor(i)
    return profile[i0] * (1 - f) + profile[i1] * f
}
let pts: [CGPoint] = stride(from: 0 as CGFloat, to: 360, by: 2).map { t in
    let a = (-90 + t) * .pi / 180, rr = profileR(t)
    return CGPoint(x: rr * cos(a), y: rr * sin(a))
}
let star = CGMutablePath()
star.move(to: pts[0])
for i in 0..<pts.count {
    let p0 = pts[(i - 1 + pts.count) % pts.count], p1 = pts[i], p2 = pts[(i + 1) % pts.count], p3 = pts[(i + 2) % pts.count]
    star.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                  control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
}
star.closeSubpath()

// The owner's outline weight: the drawing's stroke, measured along the
// rays (outer edge minus inner edge), against the silhouette's width.
let line = alphaOf(outlinePNG)
var widths: [CGFloat] = []
for t in stride(from: 0 as CGFloat, to: 360, by: 3) {
    let a = t * .pi / 180
    var r0: CGFloat = 0
    while r0 < 40, sample(line, CGPoint(x: centre.x + r0 * cos(a), y: centre.y + r0 * sin(a))) < 0.5 { r0 += 0.01 }
    let outer = edge(line, centre, a)
    if outer > r0 { widths.append(outer - r0) }
}
let ownerStroke = widths.sorted()[widths.count / 2]
let starWidth = star.boundingBoxOfPath.width
print("the owner's stroke ≈ \(fmt(ownerStroke)) px, \(fmt(ownerStroke / starWidth * 100)) % of the star's width (\(fmt(starWidth)) px)")

// MARK: - Placement: today's star's optical size and centre

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
func centroid(_ path: CGPath) -> CGPoint {
    let r = path.boundingBoxOfPath, px = 8.0
    let w = Int(r.width * px) + 2, h = Int(r.height * px) + 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: px, y: px); ctx.translateBy(x: -r.minX, y: -r.minY)
    ctx.addPath(path); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
    let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var X: CGFloat = 0, Y: CGFloat = 0, S: CGFloat = 0
    for j in 0..<h { for i in 0..<w {
        let v = CGFloat(data[j * w + i]) / 255
        // CGContext rows run bottom-up in memory order here: row j is y from the top of the flipped space.
        X += v * (CGFloat(i) + 0.5); Y += v * (CGFloat(h - 1 - j) + 0.5); S += v
    } }
    return CGPoint(x: r.minX + X / S / px, y: r.minY + Y / S / px)
}

/// Today's filled star, as placed in its template's Regular master (the
/// group's own coordinates: x from 0, y around the cap height's middle).
let todays: CGPath = {
    let s = try! String(contentsOfFile: todaysFill, encoding: .utf8)
    let block = s.components(separatedBy: "<g id=\"Regular-S\"")[1]
    let re = try! NSRegularExpression(pattern: " d=\"([^\"]+)\"")
    let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block))!
    return parse(String(block[Range(m.range(at: 1), in: block)!]))
}()
/// ⚠️ THE OPTICAL SIZE: the plump star fills more of its box than
/// Phosphor's, so it is scaled to the same AREA as today's filled star, and
/// its centroid put on today's (the plump one is wider at the bottom, so
/// centring its box would sit it high).
///
/// Then ×1.05 (`heightNudge`): at equal area it stood 13.7 pt tall at 12 pt
/// semibold against the system star's 15, past `AppSymbolSizeTests`' 8 %
/// (the line a glyph sits on); at ×1.05 it stands 14.3.
let heightNudge: CGFloat = 1.05
let k = sqrt(area(todays) / area(star)) * heightNudge
let target = centroid(todays), mine = centroid(star)
var place = CGAffineTransform(translationX: target.x, y: target.y).scaledBy(x: k, y: k).translatedBy(x: -mine.x, y: -mine.y)
let placedFill = star.copy(using: &place)!
// Every master starts its glyph at x = 0, so shift onto it.
let shift = placedFill.boundingBoxOfPath.minX
var toZero = CGAffineTransform(translationX: -shift, y: 0)
let fillGlyph = placedFill.copy(using: &toZero)!
print("scale \(fmt(k)) (64 px → template), width \(fmt(fillGlyph.boundingBoxOfPath.width)) against today's \(fmt(todays.boundingBoxOfPath.width)); area \(fmt(area(fillGlyph))), today's \(fmt(area(todays)))")

// The outline: the stroke grows INWARD from the fill's edge, so a save's
// outline ↔ fill swap never moves the star.
let round: (CGPath, CGFloat) -> CGPath = { $0.copy(strokingWithWidth: $1, lineCap: .round, lineJoin: .round, miterLimit: 10) }
func eroded(_ a: CGPath, by d: CGFloat) -> CGPath { a.subtracting(round(a, 2 * d)) }
/// (b), the default: Phosphor's ratio, 16 on its 256 grid ≈ 6.9 % of its
/// star's width — the heart's and the repost's weight. (a), STROKE=owner:
/// the drawing's own ≈ 9.6 %.
let phosphorRatio: CGFloat = 0.069
let ownerRatio = ownerStroke / starWidth
let useOwner = ProcessInfo.processInfo.environment["STROKE"] == "owner"
let weight = (useOwner ? ownerRatio : phosphorRatio) * fillGlyph.boundingBoxOfPath.width
let outlineGlyph = fillGlyph.subtracting(eroded(fillGlyph, by: weight))
print("outline \(useOwner ? "(a) the owner's" : "(b) Phosphor's") weight: \(fmt(weight)) in the template (\(fmt((useOwner ? ownerRatio : phosphorRatio) * 100)) %)")

// MARK: - Output

let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]
/// The side margin each master keeps outside its outline (#1566).
let sideMargin: CGFloat = 4

func write(_ name: String, _ glyph: CGPath) {
    let width = glyph.boundingBoxOfPath.maxX
    let d = svgData(glyph)
    var guides = head
    let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
    guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
    var margins = "", symbols = ""
    for (weightName, centre) in columns {
        let left = centre - width / 2
        let l = left - sideMargin, r = left + width + sideMargin
        margins += "  <line id=\"left-margin-\(weightName)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(l))\" x2=\"\(fmt(l))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weightName)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(r))\" x2=\"\(fmt(r))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        symbols += "  <g id=\"\(weightName)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n   <path class=\"monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000\" d=\"\(d)\"/>\n  </g>\n"
    }
    guides = guides.replacingOccurrences(of: " </g>\n \n", with: "")
    if let r = guides.range(of: " </g>", options: .backwards) { guides.replaceSubrange(r, with: margins + " </g>") }
    guides = guides.replacingOccurrences(of: "Generated from badge.plus", with: "core-platform \(name) (the owner's star, #2074)")
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "", point size: 100.0, template writer version: "101"-->
     <style>.monochrome-0 {fill:#000000}
    .multicolor-0:tintColor {fill:#007AFF}
    .hierarchical-0:primary {fill:#212121}
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
    ctx.addPath(glyph); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

write("core.star", outlineGlyph)
write("core.star.fill", fillGlyph)
