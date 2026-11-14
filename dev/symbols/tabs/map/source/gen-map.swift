// Builds core.map{,.fill,.badge,.badge.fill} (#2413): the owner's folded map with
// its pin, traced from their two 64 px drawings, as SF Symbol templates.
// Output helpers and the template writer come from the paper plane's
// generator (#1191, removed with it) and dev/symbols/gen.swift (#1128).
// usage: swift gen-map.swift <template-head.svg> <out dir> <preview dir> [badge: set|out]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]
let badgeMode = args.count > 4 ? args[4] : "set"
var head = try! String(contentsOfFile: headPath, encoding: .utf8)

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
// MARK: - Placement (same template conventions as gen.swift)

/// The drawing's 64 px grid, in template units. Chosen so the map reads as
/// large as core.chats and core.square.play in the bar (previews/beside-chats-square-17pt.png):
/// within the size guards (AppSymbolSizeTests, TabGlyphTests, TabFacesTests).
let scale: CGFloat = 1.45
let capMid: CGFloat = -70.459 / 2 + 2.2
/// Every variant is placed by the plain map's box, so adding the badge or
/// filling the map never moves it.
var box = CGRect.zero
let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]
/// The side margin each master keeps outside its outline (#1566).
let sideMargin: CGFloat = 4

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
        let l = left - sideMargin, r = left + width + sideMargin
        margins += "  <line id=\"left-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(l))\" x2=\"\(fmt(l))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(r))\" x2=\"\(fmt(r))\" y1=\"600.785\" y2=\"720.121\"/>\n"
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

// MARK: - The art, on the drawings' 64 px grid (y down)
//
// Centre lines measured on `map-owner.png` (alpha-weighted stroke centres per
// row and per column), then drawn as Catmull-Rom cubics through a few points
// each. The owner's strokes are 4 px; the set's is 6.4 units, so every line
// is stroked at 6.4 / scale.

let sw: CGFloat = 6.4 / scale

/// A smooth open curve through `p` (Catmull-Rom, ends repeated).
func curve(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: p[0])
    extend(path, p)
    return path
}
/// Continues `path` (which ends at p[0]) through the rest of `p`.
func extend(_ path: CGMutablePath, _ p: [CGPoint]) {
    for i in 0..<(p.count - 1) {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
}
func pts(_ xy: [(CGFloat, CGFloat)]) -> [CGPoint] { xy.map { CGPoint(x: $0.0, y: $0.1) } }
func stroked(_ p: CGPath, _ w: CGFloat = sw) -> CGPath {
    p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// The pin: a round head about its own axis, x = 51, and a short symmetric tail.
let head0 = CGPoint(x: 51, y: 17), headR: CGFloat = 9, dotR: CGFloat = 2.75
let tip = CGPoint(x: 51, y: 29.6)
/// Where the tail's two lines leave the head, tangent to it.
let tangentAngle = acos(headR / (tip.y - head0.y))
let tailLeft = CGPoint(x: head0.x - headR * sin(tangentAngle), y: head0.y + headR * cos(tangentAngle))
let tailRight = CGPoint(x: head0.x + headR * sin(tangentAngle), y: tailLeft.y)
let headRing = CGPath(ellipseIn: CGRect(x: head0.x - headR, y: head0.y - headR, width: 2 * headR, height: 2 * headR), transform: nil)
let tail: CGPath = {
    let p = CGMutablePath(); p.move(to: tailLeft); p.addLine(to: tip); p.addLine(to: tailRight); return p
}()
let dot = CGPath(ellipseIn: CGRect(x: head0.x - dotR, y: head0.y - dotR, width: 2 * dotR, height: 2 * dotR), transform: nil)

// The map's contour, in two runs: the bottom edge turns sharply at the first
// fold's foot (the owner's corner), everywhere else it is one smooth line.
let topLeftBottom = pts([
    (42.3, 19.4), (39.6, 17.6), (36, 15.4), (32, 13.7), (28, 12.6), (24, 12.2), (20, 12.3), (16, 12.8),
    (13, 13.9), (10.6, 16), (9, 18.8), (7.6, 22.5), (6.6, 27), (6.1, 31.5), (6.1, 36), (6.5, 40),
    (7.3, 44), (8.4, 47.5), (10.2, 50.4), (12.5, 51.6), (15, 51.1), (18, 49.5), (20.6, 47.9), (22.8, 46.4),
])
let bottomRight = pts([
    (22.8, 46.4), (25, 47.5), (28, 49.1), (32, 50.6), (36, 51.6), (40, 51.95), (44, 51.7), (48, 50.8),
    (51, 49.4), (53.3, 47.2), (55, 44.2), (56.3, 40.5), (57.2, 36.5), (57.9, 32.5), (58, 29.5), (57.6, 26.2),
    (tailRight.x, tailRight.y),
])
// The two folds: the first meets the top edge at its crest, the second is
// the pin's left tail line carried on down to the bottom.
let fold1 = pts([(21.9, 12.4), (21.3, 17), (20.6, 22), (20.15, 27), (20, 31), (20.3, 35), (21, 39), (21.9, 43), (22.8, 46.4)])
let fold2 = pts([(tailLeft.x, tailLeft.y), (44.2, 26.5), (43.8, 30), (43.95, 34), (43.85, 38), (43.5, 41), (43.1, 44), (42.5, 47), (42.1, 50), (42, 51.95)])

let lines: [CGPath] = [curve(topLeftBottom), curve(bottomRight), curve(fold1), curve(fold2), headRing, tail]
let outline: CGPath = lines.map { stroked($0) }.reduce(dot) { $0.union($1) }

// MARK: - The filled map, from the outline's geometry
//
// The same silhouette (the outline's outer edge), so selecting the tab never
// moves or resizes the map. The folds are knocked out as gaps, and the pin
// stands solid with a hole the dot's size, cut from the map by a gap all
// round. The gap is the filled drawing's, measured (`map-fill-owner.png`:
// 3.6 px across both folds and round the pin).
let gapW: CGFloat = 3.6
let pinSolid: CGPath = {
    let teardrop = CGMutablePath()
    teardrop.addPath(headRing)
    teardrop.move(to: tailLeft); teardrop.addLine(to: tip); teardrop.addLine(to: tailRight)
    teardrop.addArc(center: head0, radius: headR, startAngle: .pi / 2 - tangentAngle, endAngle: .pi / 2 + tangentAngle, clockwise: true)
    teardrop.closeSubpath()
    let solid = CGPath(ellipseIn: CGRect(x: head0.x - headR, y: head0.y - headR, width: 2 * headR, height: 2 * headR), transform: nil)
        .union(teardrop)
    return solid.union(stroked(solid))
}()
/// The contour as one closed loop: the two runs, then back over the head
/// from where the right edge meets it to where the top edge leaves it.
let region: CGPath = {
    let loop = CGMutablePath()
    loop.move(to: topLeftBottom[0])
    extend(loop, topLeftBottom)
    extend(loop, bottomRight)
    let from = atan2(tailRight.y - head0.y, tailRight.x - head0.x)
    let to = atan2(topLeftBottom[0].y - head0.y, topLeftBottom[0].x - head0.x)
    loop.addArc(center: head0, radius: headR, startAngle: from, endAngle: to, clockwise: true)
    loop.closeSubpath()
    return loop.normalized()
}()
let silhouette = outline.union(region).union(pinSolid)
let hole = CGPath(ellipseIn: CGRect(x: head0.x - dotR, y: head0.y - dotR, width: 2 * dotR, height: 2 * dotR), transform: nil)
let filled: CGPath = {
    var map = silhouette.subtracting(pinSolid.union(stroked(pinSolid, 2 * gapW)))
    // Each gap runs on past the silhouette's edge, so the panels part cleanly.
    func runOn(_ f: [CGPoint]) -> [CGPoint] {
        func ahead(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let d = hypot(a.x - b.x, a.y - b.y)
            return CGPoint(x: a.x + (a.x - b.x) / d * sw * 1.5, y: a.y + (a.y - b.y) / d * sw * 1.5)
        }
        return [ahead(f[0], f[1])] + f + [ahead(f[f.count - 1], f[f.count - 2])]
    }
    for f in [fold1, fold2] { map = map.subtracting(stroked(curve(runOn(f)), gapW)) }
    return map.union(pinSolid.subtracting(hole))
}()
box = outline.boundingBoxOfPath

// MARK: - The badge
//
// The same final size and gap as core.chats.badge and core.square.play.badge
// (r 11.6, gap 4.27 units). `set`: on the 45° point of the pin head's stroke,
// as the other tabs put it on their corner. `out`: pushed out along the same
// ray until the clearance spares the head's dot. `clear`: pushed out until
// the clearance only touches the head, so the pin stays whole.
let r: CGFloat = 11.6 / scale, gap: CGFloat = 32.0 / 3 * 0.4 / scale
let along: CGFloat = switch badgeMode {
case "out": r + gap + dotR + 1.2
case "clear": headR + sw / 2 + gap + r
default: headR
}
let c = CGPoint(x: head0.x + along * sqrt(0.5), y: head0.y - along * sqrt(0.5))
func circle(_ rad: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad), transform: nil) }
func rounded(_ a: CGPath, _ k: CGFloat) -> CGPath {
    let st = { (p: CGPath) in p.copy(strokingWithWidth: 2 * k, lineCap: .round, lineJoin: .round, miterLimit: 10) }
    let e = a.subtracting(st(a)); return e.union(st(e))
}
/// Cuts the clearance, then rounds the cut's ends only near the badge.
/// The head's dot is left out of the rounding, which would eat it, and put
/// back as the clearance leaves it.
func cut(_ a: CGPath, _ k: CGFloat) -> CGPath {
    let clearance = circle(r + gap)
    let opened = a.subtracting(dot).subtracting(clearance)
    let near = circle(r + gap + 3 * k)
    let body = opened.subtracting(near).union(rounded(opened, k).intersection(near))
    return a.contains(head0) ? body.union(dot.subtracting(clearance)) : body
}
let red = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
write("core.map", [Layer(path: outline, cls: primaryClass, preview: ink)])
write("core.map.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
write("core.map.badge", [
    Layer(path: cut(outline, sw * 0.47), cls: primaryClass, preview: ink),
    Layer(path: circle(r), cls: badgeClass, preview: red),
])
write("core.map.badge.fill", [
    Layer(path: cut(filled, sw / 2), cls: primaryClass, preview: ink),
    Layer(path: circle(r), cls: badgeClass, preview: red),
])
print("box \(fmt(box.width * scale)) × \(fmt(box.height * scale)) units, stroke \(fmt(sw)) px, badge centre (\(fmt(c.x)), \(fmt(c.y)))")
