// Renders the map's previews from compiled-format symbolsets (#2413): the four
// variants large, the map beside core.chats and core.square.play at 17 pt, and
// the badge's corner close up. Reads each symbol's Regular-S master.
// usage: swift render-previews.swift <Symbols.xcassets> <map symbolsets dir> <out dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let catalog = args[1], mapDir = args[2], outDir = args[3]

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

// MARK: - Symbols

struct Symbol { let layers: [(CGPath, Int)]; let width: CGFloat }
/// The Regular-S master, in units from its left margin and the baseline.
func load(_ name: String) -> Symbol {
    let dir = FileManager.default.fileExists(atPath: "\(mapDir)/\(name).symbolset") ? mapDir : catalog
    let s = try! String(contentsOfFile: "\(dir)/\(name).symbolset/\(name).svg", encoding: .utf8)
    let g = s.range(of: "<g id=\"Regular-S\"")!
    let body = s[g.lowerBound...].prefix(while: { $0 != "/" || true })
    let end = body.range(of: "</g>")!
    let group = String(body[..<end.lowerBound])
    let re = try! NSRegularExpression(pattern: "class=\"monochrome-(\\d)[^\"]*\" d=\"([^\"]+)\"")
    let layers = re.matches(in: group, range: NSRange(group.startIndex..., in: group)).map {
        (parse(String(group[Range($0.range(at: 2), in: group)!])) as CGPath, Int(group[Range($0.range(at: 1), in: group)!])!)
    }
    let marginRE = try! NSRegularExpression(pattern: "left-margin-Regular-S\"[^>]*x1=\"([0-9.]+)\"")
    let rightRE = try! NSRegularExpression(pattern: "right-margin-Regular-S\"[^>]*x1=\"([0-9.]+)\"")
    func num(_ re: NSRegularExpression) -> CGFloat {
        let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))!
        return CGFloat(Double(s[Range(m.range(at: 1), in: s)!])!)
    }
    return Symbol(layers: layers, width: num(rightRE) - num(marginRE))
}

let paperWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let night = CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
let inkLight = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let inkDark = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let dim = CGColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)
let badgeTint = CGColor(red: 1, green: 0.075, blue: 0.345, alpha: 1)

func canvas(_ w: Int, _ h: Int, _ bg: CGColor) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    return ctx
}
/// Draws `sym` with its left margin at x and its baseline at y, `pt` points at @`px`.
func draw(_ ctx: CGContext, _ sym: Symbol, x: CGFloat, y: CGFloat, pt: CGFloat, px: CGFloat, ink: CGColor, badge: CGColor) {
    let k = pt / 100 * px
    for (path, layer) in sym.layers {
        var t = CGAffineTransform(translationX: x, y: y).scaledBy(x: k, y: k)
        ctx.addPath(path.copy(using: &t)!); ctx.setFillColor(layer == 0 ? ink : badge); ctx.fillPath()
    }
}
func save(_ ctx: CGContext, _ name: String) {
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    print("wrote \(name).png")
}

// 1. The four variants, large, light and dark.
let four = ["core.map", "core.map.fill", "core.map.badge", "core.map.badge.fill"].map(load)
do {
    let ctx = canvas(4 * 300, 2 * 260, paperWhite)
    ctx.setFillColor(night); ctx.fill(CGRect(x: 0, y: 260, width: 1200, height: 260))
    for (i, s) in four.enumerated() {
        draw(ctx, s, x: CGFloat(i) * 300 + 40, y: 200, pt: 100, px: 2.4, ink: inkLight, badge: badgeTint)
        draw(ctx, s, x: CGFloat(i) * 300 + 40, y: 460, pt: 100, px: 2.4, ink: inkDark, badge: badgeTint)
    }
    save(ctx, "four-variants")
}

// 2. Beside core.chats and core.square.play at 17 pt @3x, as a tab bar row:
// not selected, selected, badged, selected + badged; light and dark.
do {
    let rows: [(String, String, String, String)] = [
        ("core.square.play", "core.square.play.fill", "core.square.play.badge", "core.square.play.badge.fill"),
        ("core.map", "core.map.fill", "core.map.badge", "core.map.badge.fill"),
        ("core.chats", "core.chats.fill", "core.chats.badge", "core.chats.badge.fill"),
    ]
    let cell: CGFloat = 96, px: CGFloat = 3, pt: CGFloat = 17
    let ctx = canvas(Int(cell) * 3 * 2 + 40, Int(cell) * 4, paperWhite)
    ctx.setFillColor(night); ctx.fill(CGRect(x: cell * 3 + 40, y: 0, width: cell * 3, height: cell * 4))
    for (state, pick) in [\(String, String, String, String).0, \.1, \.2, \.3].enumerated() {
        for (col, row) in rows.enumerated() {
            let s = load(row[keyPath: pick])
            let w = s.width * pt / 100 * px
            for (side, (ink, x0)) in [(inkLight, CGFloat(0)), (inkDark, cell * 3 + 40)].enumerated() {
                let tint = state % 2 == 1 ? ink : (side == 0 ? dim : dim)
                draw(ctx, s, x: x0 + CGFloat(col) * cell + (cell - w) / 2, y: CGFloat(state) * cell + cell * 0.72,
                     pt: pt, px: px, ink: tint, badge: badgeTint)
            }
        }
    }
    save(ctx, "beside-chats-square-17pt")
}

// 3. The badge's corner close up (28 pt @3x, cropped to the top right).
do {
    let ctx = canvas(2 * 260, 2 * 200, paperWhite)
    ctx.setFillColor(night); ctx.fill(CGRect(x: 260, y: 0, width: 260, height: 400))
    for (i, s) in [four[2], four[3]].enumerated() {
        let y = CGFloat(i) * 200 + 230
        draw(ctx, s, x: -60, y: y, pt: 60, px: 3, ink: inkLight, badge: badgeTint)
        draw(ctx, s, x: 200, y: y, pt: 60, px: 3, ink: inkDark, badge: badgeTint)
    }
    save(ctx, "badge-corner")
}

// 4. The four at 17, 22 and 28 pt @3x.
do {
    let ctx = canvas(4 * 120, 3 * 120, paperWhite)
    for (r, pt) in [CGFloat(17), 22, 28].enumerated() {
        for (i, s) in four.enumerated() {
            let w = s.width * pt / 100 * 3
            draw(ctx, s, x: CGFloat(i) * 120 + (120 - w) / 2, y: CGFloat(r) * 120 + 90, pt: pt, px: 3, ink: inkLight, badge: badgeTint)
        }
    }
    save(ctx, "sizes-17-22-28pt")
}
