// Builds core.chats{,.fill,.badge,.badge.fill} (Phosphor chats-teardrop, MIT, mirrored) as SF Symbol templates.
// Helpers (path parsing, SVG output) are copied from dev/symbols/gen.swift (#1128).
// usage: swift gen-square-play.swift <template-head.svg> <out dir> <preview dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]
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

// chats-teardrop rebuilt from its geometry (Phosphor: r 80 bubbles, 16 stroke,
// 16 tail corner, sharp inner corner), mirrored: the whole bubble on the right.
let r: CGFloat = 29, gap: CGFloat = 32.0 / 3
func circle(_ c: CGPoint, _ rad: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad), transform: nil) }
func rounded(_ a: CGPath, _ k: CGFloat) -> CGPath {
    let st = { (p: CGPath) in p.copy(strokingWithWidth: 2 * k, lineCap: .round, lineJoin: .round, miterLimit: 10) }
    let e = a.subtracting(st(a)); return e.union(st(e))
}
/// A teardrop bubble: a disc plus the quadrant towards its tail (sx = ±1),
/// whose far corner is rounded by `corner`.
func bubble(_ c: CGPoint, _ rad: CGFloat, tail sx: CGFloat, corner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x1 = c.x + sx * rad, y1 = c.y + rad
    p.move(to: c); p.addLine(to: CGPoint(x: x1, y: c.y))
    if corner > 0 {
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: c.x, y: y1), radius: corner)
    } else { p.addLine(to: CGPoint(x: x1, y: y1)) }
    p.addLine(to: CGPoint(x: c.x, y: y1)); p.closeSubpath()
    return p.union(circle(c, rad))
}
func icon(offset f: CGFloat) -> (line: CGPath, fill: CGPath, front: CGPoint) {
    // Phosphor's back bubble sits (-64, +48) from the front one; f scales that.
    let dx = 64 * f, dy = 48 * f
    let width = 160 + dx, height = 160 + dy
    let front = CGPoint(x: 128 + width / 2 - 80, y: 128 - height / 2 + 80)
    let back = CGPoint(x: front.x - dx, y: front.y + dy)
    let fOut = bubble(front, 80, tail: 1, corner: 16), fIn = bubble(front, 64, tail: 1, corner: 0)
    let bOut = bubble(back, 80, tail: -1, corner: 16), bIn = bubble(back, 64, tail: -1, corner: 0)
    let backRing = bOut.subtracting(bIn).subtracting(fOut)
    return (fOut.subtracting(fIn).union(backRing), fOut.union(backRing), front)
}
func cut(_ a: CGPath, _ c: CGPoint, _ k: CGFloat) -> CGPath {
    let opened = a.subtracting(circle(c, r + gap))
    let near = circle(c, r + gap + 3 * k)
    return opened.subtracting(near).union(rounded(opened, k).intersection(near))
}

// MARK: - Placement (same template conventions as gen.swift)

/// Phosphor's 256 grid on the S scale, as in gen.swift (16 stroke → 6.4).
let scale: CGFloat = 0.4
let capMid: CGFloat = -70.459 / 2 + 2.2
/// Every variant is placed by the plain icon's box, so adding the badge or
/// filling the bubble never moves the bubbles.
var box = CGRect.zero
let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]

struct Layer { let path: CGPath; let cls: String; let preview: CGColor }
let primaryClass = "monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000"
let badgeClass = "monochrome-1 multicolor-1:systemRedColor hierarchical-1:secondary SFSymbolsPreviewFF3B30"

func write(_ name: String, _ layers: [Layer]) {
    var t = CGAffineTransform(translationX: -box.minX * scale, y: capMid - box.midY * scale)
        .scaledBy(x: scale, y: scale)
    let placed = layers.map { Layer(path: $0.path.copy(using: &t)!, cls: $0.cls, preview: $0.preview) }
    let maxX = layers.map { $0.path.boundingBoxOfPath.maxX }.max()!
    let width = (maxX - box.minX) * scale
    var guides = head
    let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
    guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
    var margins = "", symbols = ""
    for (weight, centre) in columns {
        let left = centre - width / 2
        margins += "  <line id=\"left-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left))\" x2=\"\(fmt(left))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left + width))\" x2=\"\(fmt(left + width))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        symbols += "  <g id=\"\(weight)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n"
        for l in placed { symbols += "   <path class=\"\(l.cls)\" d=\"\(svgData(l.path))\"/>\n" }
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
    print("wrote \(name) width \(fmt(width))")
    let px = 160
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.translateBy(x: 30, y: CGFloat(px) - 30); ctx.scaleBy(x: 1.2, y: -1.2)
    ctx.translateBy(x: 0, y: 70)
    for l in placed { ctx.addPath(l.path); ctx.setFillColor(l.preview); ctx.fillPath() }
    let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}


// MARK: - The art (Phosphor's 256 grid, back bubble at 65 % of its offset)

let ic = icon(offset: 0.65)
box = ic.line.boundingBoxOfPath
let c = CGPoint(x: ic.front.x + 72 * sqrt(0.5), y: ic.front.y - 72 * sqrt(0.5))
let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let red = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)

write("core.chats", [Layer(path: ic.line, cls: primaryClass, preview: ink)])
write("core.chats.fill", [Layer(path: ic.fill, cls: primaryClass, preview: ink)])
write("core.chats.badge", [
    Layer(path: cut(ic.line, c, 7.5), cls: primaryClass, preview: ink),
    Layer(path: circle(c, r), cls: badgeClass, preview: red),
])
write("core.chats.badge.fill", [
    Layer(path: cut(ic.fill, c, 8), cls: primaryClass, preview: ink),
    Layer(path: circle(c, r), cls: badgeClass, preview: red),
])
