// Generates custom SF Symbol templates (#1128) from Phosphor SVG paths
// (fills) and the owner's gem (strokes), with CoreGraphics.
// usage: swift gen.swift <template-head.svg> <phosphor assets dir> <out dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], assets = args[2], outDir = args[3]
let previewDir = args.count > 4 ? args[4] : "/tmp"
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

/// Phosphor's 256 grid → the template's S scale: content x from 0, the
/// grid's middle on the cap height's middle.
let scale: CGFloat = 0.4
/// A touch below the cap height's middle, so a glyph's alignment insets
/// match the system's (measured against `heart.fill` at 12 pt: 2/3 pt above,
/// 1/3 pt below).
let capMid: CGFloat = -70.459 / 2 + 2.2

/// Per glyph, so each stands as tall as the system glyph it replaces
/// (measured at 12 pt semibold against `heart.fill`, `star`,
/// `ellipsis.message`, `arrow.trianglehead…`, `diamond.fill`, `ellipsis`,
/// `square.and.arrow.up`): a swap must not grow the line it sits on.
let fit: [String: CGFloat] = [
    "core.heart": 0.934, "core.heart.fill": 0.934,
    "core.star": 0.978, "core.star.fill": 0.978,
    "core.comment": 0.977, "core.comment.fill": 0.977,
    "core.repost": 1.0,
    "core.gem": 1.225, "core.gem.fill": 1.225,
    "core.more": 1.27,
    "core.share": 1.11,
]

/// The frame each glyph was placed in, so a filled variant takes its
/// outline's: an off / on pair is drawn in one box, or the glyph jumps when
/// a like or a save swaps one for the other.
var boxes: [String: CGRect] = [:]

func place(_ path: CGPath, _ name: String) -> (CGPath, CGFloat) {
    let outline = name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
    let box = boxes[outline] ?? path.boundingBoxOfPath
    boxes[name] = box
    let scale = scale * (fit[name] ?? 1)
    // The glyph's own middle on the cap height's middle.
    var t = CGAffineTransform(translationX: -box.minX * scale, y: capMid - box.midY * scale)
        .scaledBy(x: scale, y: scale)
    let placed = path.copy(using: &t)!
    return (placed, box.width * scale)
}

let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]

func write(_ name: String, _ path: CGPath) {
    let (placed, width) = place(path, name)
    let d = svgData(placed)
    var guides = head
    // Margins for this glyph's width, centred on each weight's column.
    let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
    guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
    var margins = ""
    var symbols = ""
    for (weight, centre) in columns {
        let left = centre - width / 2
        margins += "  <line id=\"left-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left))\" x2=\"\(fmt(left))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left + width))\" x2=\"\(fmt(left + width))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        symbols += "  <g id=\"\(weight)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n   <path class=\"monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000\" d=\"\(d)\"/>\n  </g>\n"
    }
    guides = guides.replacingOccurrences(of: " </g>\n \n", with: "")
    if let r = guides.range(of: " </g>", options: .backwards) {
        guides.replaceSubrange(r, with: margins + " </g>")
    }
    guides = guides.replacingOccurrences(of: "Generated from badge.plus", with: "core-platform \(name) (Phosphor MIT, #1128)")
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
    // A preview: the regular glyph, black on white, 160 px.
    let px = 160
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.translateBy(x: 20, y: CGFloat(px) - 20); ctx.scaleBy(x: 1.2, y: -1.2)
    ctx.translateBy(x: 0, y: 95)
    ctx.addPath(placed); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

func phosphor(_ file: String) -> CGPath {
    let combined = CGMutablePath()
    for d in pathsIn("\(assets)/\(file)") { combined.addPath(parse(d)) }
    return combined
}

// MARK: - The set

let set: [(String, String)] = [
    ("core.heart", "regular/heart.svg"),
    ("core.heart.fill", "fill/heart-fill.svg"),
    ("core.comment", "regular/chat-teardrop-text.svg"),
    ("core.comment.fill", "fill/chat-teardrop-text-fill.svg"),
    ("core.repost", "regular/arrows-clockwise.svg"),
    ("core.star", "regular/star.svg"),
    ("core.star.fill", "fill/star-fill.svg"),
    ("core.more", "regular/dots-three.svg"),
    ("core.share", "regular/export.svg"),
    // The full-screen post's remaining glyphs (#1184).
    ("core.sort", "regular/arrows-down-up.svg"),
    ("core.not.interested", "regular/thumbs-down.svg"),
    ("core.flag", "regular/flag.svg"),
    ("core.plus", "regular/plus.svg"),
    ("core.check", "regular/check.svg"),
    ("core.check.circle", "regular/check-circle.svg"),
    ("core.x.circle", "regular/x-circle.svg"),
    ("core.people", "regular/users.svg"),
    ("core.people.fill", "fill/users-fill.svg"),
    ("core.clock", "regular/clock.svg"),
    ("core.music.note", "regular/music-note.svg"),
    ("core.speaker.slash", "regular/speaker-simple-slash.svg"),
    ("core.speaker.slash.fill", "fill/speaker-simple-slash-fill.svg"),
    ("core.hand", "regular/hand.svg"),
    ("core.warning", "regular/warning.svg"),
    ("core.warning.circle.fill", "fill/warning-circle-fill.svg"),
    ("core.caret.down", "regular/caret-down.svg"),
    ("core.caret.up", "regular/caret-up.svg"),
    ("core.send.fill", "fill/arrow-circle-up-fill.svg"),
    ("core.waveform", "regular/waveform.svg"),
    ("core.globe", "regular/globe.svg"),
    ("core.pin", "regular/push-pin.svg"),
    ("core.pin.fill", "fill/push-pin-fill.svg"),
    ("core.smiley", "regular/smiley.svg"),
    ("core.keyboard", "regular/keyboard.svg"),
]
for (name, file) in set { write(name, phosphor(file)) }

// The gem: the owner's own art (#1128), stroked at 16 with round joins
// and caps; the filled one fills the outline and cuts the facets at 12.
let outline = parse("M98 52H158Q176 52 189 65L211 89Q224 104 212 119Q176 168 142 206Q128 222 114 206Q80 168 44 119Q32 104 45 89L67 65Q80 52 98 52Z")
let facets = parse("M40 104H216M106 104L128 60L150 104M106 104Q116 160 128 210Q140 160 150 104")
let gemOutline = outline.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 10)
    .union(facets.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 10))
write("core.gem", gemOutline)
let solid = outline.union(outline.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 10))
let cuts = facets.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 10)
write("core.gem.fill", solid.subtracting(cuts))
