// Builds core.play.fill and core.pause.fill from the owner's two drawings
// (#2276, 64 grid, one filled path each) as SF Symbol templates, and the
// widened pause the owner may pick instead (core.pause.fill.wide, previews
// only).
// Helpers (path parsing, SVG output) follow ../../tabs/play-squircle (#2070),
// itself from dev/symbols/gen.swift (#1128).
//
// usage: swift gen-play-pause.swift <template-head.svg> <play.svg> <pause.svg> \
//          <Symbols.xcassets> <preview dir> <Widened.xcassets>
// PAUSE=wide ships the widened pause as core.pause.fill.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let headPath = args[1], playPath = args[2], pausePath = args[3]
let outDir = args[4], previewDir = args[5], wideDir = args[6]
let head = try! String(contentsOfFile: headPath, encoding: .utf8)
let shipsWidePause = ProcessInfo.processInfo.environment["PAUSE"] == "wide"

// MARK: - SVG path parsing (M L H V C Z, absolute and relative)

func tokens(_ d: String) -> [String] {
    var out: [String] = []
    var cur = ""
    func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
    for ch in d {
        if ch.isLetter {
            flush(); out.append(String(ch))
        } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
            flush()
        } else if ch == "-" {
            flush(); cur.append(ch)
        } else if ch == "." && cur.contains(".") {
            flush(); cur.append(ch)
        } else {
            cur.append(ch)
        }
    }
    flush()
    return out
}

func parse(_ d: String) -> CGMutablePath {
    let path = CGMutablePath()
    let tk = tokens(d)
    var i = 0
    var cmd: Character = "M"
    var cur = CGPoint.zero, start = CGPoint.zero
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tk[i])!) }
    while i < tk.count {
        if let c = tk[i].first, c.isLetter { cmd = c; i += 1 }
        let rel = cmd.isLowercase
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        switch cmd.uppercased().first! {
        case "M":
            let q = p(num(), num()); path.move(to: q); cur = q; start = q
            cmd = rel ? "l" : "L"
        case "L":
            let q = p(num(), num()); path.addLine(to: q); cur = q
        case "H":
            let x = num(); let q = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: q); cur = q
        case "V":
            let y = num(); let q = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: q); cur = q
        case "C":
            let c1 = p(num(), num()), c2 = p(num(), num()), e = p(num(), num())
            path.addCurve(to: e, control1: c1, control2: c2); cur = e
        case "Z":
            path.closeSubpath(); cur = start
        default:
            fatalError("unsupported \(cmd)")
        }
    }
    return path
}

func pathIn(_ svgFile: String) -> String {
    let s = try! String(contentsOfFile: svgFile, encoding: .utf8)
    let re = try! NSRegularExpression(pattern: " d=\"([^\"]+)\"")
    let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))!
    return String(s[Range(match.range(at: 1), in: s)!])
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

/// A filled path's ink centroid, measured on a fine raster.
func centroid(_ path: CGPath) -> CGPoint {
    let r = path.boundingBoxOfPath, px: CGFloat = 16
    let w = Int(r.width * px) + 2, h = Int(r.height * px) + 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: px, y: px); ctx.translateBy(x: -r.minX, y: -r.minY)
    ctx.addPath(path); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
    let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var sx = 0.0, sy = 0.0, sum = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let a = Double(data[y * w + x])
            sx += (Double(x) + 0.5) * a; sy += (Double(y) + 0.5) * a; sum += a
        }
    }
    return CGPoint(x: r.minX + CGFloat(sx / sum) / px, y: r.minY + CGFloat(sy / sum) / px)
}

// MARK: - The system's glyphs, measured (`measure-sf.swift`, 100 pt, small)

/// play.fill's ink: 66.25 tall in an image 70 wide (pause.fill: 65.25 in 69).
let sfPlayHeight: CGFloat = 66.25
let sfPlayWidth: CGFloat = 70
/// play.circle.fill: a disc 78.75 across in an image 93 wide, its middle
/// 35.1 above the baseline; the play knocked out of it is 31.75 tall.
let sfDiscDiameter: CGFloat = 78.75
let sfCircleWidth: CGFloat = 93
let sfCircleCentre: CGFloat = 35.1
let sfCirclePlayHeight: CGFloat = 31.75
/// ⚠️ SF'S OPTICAL CENTRE FOR A PLAY IN A CIRCLE, measured on
/// play.circle.fill: the disc's middle is neither the knocked-out
/// triangle's box middle (its heavy back would look too far left) nor its
/// centroid (its point would look too far right), but between the two —
/// 0.337 of the way from the centroid (x 44.79) to the box's middle
/// (x 48.75); the disc's middle is at x 46.125. The owner's play follows
/// the same rule, measured on its own shape, and its image is centred
/// there: a view that centres it centres it as SF centres its play in a
/// disc. (play.fill's own image takes 0.524, a box drawn for text; a play
/// on a picture or in a disc is what #2276 asks to look centred.)
let sfOpticalShare: CGFloat = (46.125 - 44.79) / (48.75 - 44.79)
/// Both glyphs' ink stands centred this far above the baseline: play.fill's
/// sits at 35.9, pause.fill's at 35.4 (their alignment rects round to a
/// unit) — the cap height's middle (35.23), a hair above.
let centreAboveBaseline: CGFloat = 35.6

/// The side margin each master keeps outside its outline (#1566).
let sideMargin: CGFloat = 4
let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.84), ("Black-S", 2933.4)]
let primaryClass = "monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000"

// MARK: - The art (64 grid)

let play = parse(pathIn(playPath))
let pause = parse(pathIn(pausePath))
let pauseBox = pause.boundingBoxOfPath
let playBox = play.boundingBoxOfPath
print("owner's play \(fmt(playBox.width)) × \(fmt(playBox.height)), pause \(fmt(pauseBox.width)) × \(fmt(pauseBox.height)) (64 grid)")

/// ⚠️ ONE BOX FOR BOTH (#2276): the pause's 48-unit height (8…56) is the
/// box's, and it is made as tall as play.fill's ink. The play (47.72 tall)
/// stands centred in it, so a swap never moves the line.
let boxMidY = pauseBox.midY
let k = sfPlayHeight / pauseBox.height
print("scale \(fmt(k)) (64 grid → template units): play \(fmt(playBox.height * k)) tall, pause \(fmt(pauseBox.height * k)); play.fill 66.25, pause.fill 65.25")

/// The pause is symmetric: its box's middle is the image's middle.
let axisX = pauseBox.midX

/// The play's optical centre, by SF's rule.
let playCentroid = centroid(play)
let playOptical = playCentroid.x + sfOpticalShare * (playBox.midX - playCentroid.x)
let playShift = axisX - playOptical
print("play: box middle \(fmt(playBox.midX)), centroid \(fmt(playCentroid.x)), optical centre \(fmt(playOptical)) (share \(fmt(sfOpticalShare))) → moved \(fmt(playShift)) right (64 grid)")
var shiftPlay = CGAffineTransform(translationX: playShift, y: 0)
let placedPlay = play.copy(using: &shiftPlay)!

/// THE WIDENED PAUSE (the owner picks, #2276): the drawn gap is 2.42 on
/// the 64 grid — 0.6 pt at 13 pt, one blob. Each oval is narrowed about its
/// OUTER edge, so the glyph keeps its width and the gap opens to `wideGap`.
let wideGap: CGFloat = 7
let ovalWidth = (pauseBox.width - (33.211 - 30.789)) / 2
let wideOvalWidth = (pauseBox.width - wideGap) / 2
let squeeze = wideOvalWidth / ovalWidth
let ownerPauseD = pathIn(pausePath)
let ovals = ownerPauseD.components(separatedBy: "Z").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
var leftSqueeze = CGAffineTransform(translationX: pauseBox.minX, y: 0).scaledBy(x: squeeze, y: 1).translatedBy(x: -pauseBox.minX, y: 0)
var rightSqueeze = CGAffineTransform(translationX: pauseBox.maxX, y: 0).scaledBy(x: squeeze, y: 1).translatedBy(x: -pauseBox.maxX, y: 0)
let widePause = CGMutablePath()
widePause.addPath(parse(ovals[0] + "Z").copy(using: &leftSqueeze)!)
widePause.addPath(parse(ovals[1] + "Z").copy(using: &rightSqueeze)!)
print("widened pause: ovals ×\(fmt(squeeze)) (\(fmt(ovalWidth)) → \(fmt(wideOvalWidth))), gap 2.42 → \(fmt(wideGap)) (64 grid)")

/// The box's width: both glyphs, centred on the axis, with the side margin;
/// never narrower than play.fill's, so a site sized round today's glyph
/// keeps its size.
let reach = [placedPlay.boundingBoxOfPath, pauseBox].map { max(axisX - $0.minX, $0.maxX - axisX) }.max()!
let fitted = 2 * (reach * k + sideMargin)
let width = max(fitted, sfPlayWidth)
print("box: \(fmt(width)) wide (fitted \(fmt(fitted)), play.fill 70, pause.fill 69)")

// MARK: - Templates

/// How a glyph is set on the template: its scale from the 64 grid, its
/// image's width, and how high its middle stands. The grid's (axisX,
/// boxMidY) lands on the image's middle at that height.
struct Placement {
    var scale: CGFloat
    var width: CGFloat
    var centre: CGFloat
}

let glyphPlacement = Placement(scale: k, width: width, centre: centreAboveBaseline)

@discardableResult
func write(_ name: String, _ art: CGPath, into dir: String, _ placement: Placement = glyphPlacement) -> CGPath {
    let width = placement.width
    var t = CGAffineTransform(translationX: width / 2, y: -placement.centre)
        .scaledBy(x: placement.scale, y: placement.scale)
        .translatedBy(x: -axisX, y: -boxMidY)
    let placed = art.copy(using: &t)!
    var guides = head
    let marginRE = try! NSRegularExpression(pattern: "<line id=\"(left|right)-margin-[^>]*/>\\n?")
    guides = marginRE.stringByReplacingMatches(in: guides, range: NSRange(guides.startIndex..., in: guides), withTemplate: "")
    var margins = "", symbols = ""
    for (weight, centre) in columns {
        let left = centre - width / 2
        margins += "  <line id=\"left-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left))\" x2=\"\(fmt(left))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        margins += "  <line id=\"right-margin-\(weight)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(left + width))\" x2=\"\(fmt(left + width))\" y1=\"600.785\" y2=\"720.121\"/>\n"
        symbols += "  <g id=\"\(weight)\" transform=\"matrix(1 0 0 1 \(fmt(left)) 696)\">\n"
        symbols += "   <path class=\"\(primaryClass)\" d=\"\(svgData(placed))\"/>\n"
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
    .multicolor-0:tintColor {fill:#007AFF}
    .hierarchical-0:primary {fill:#212121}
    .SFSymbolsPreview000000 {fill:#000000;opacity:1.0}
    </style>
     \(guides)
     <g id="Symbols">
    \(symbols) </g>
    </svg>
    """
    let folder = "\(dir)/\(name).symbolset"
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try! svg.write(toFile: "\(folder)/\(name).svg", atomically: true, encoding: .utf8)
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
    try! contents.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
    let b = placed.boundingBoxOfPath
    print("wrote \(name): ink x \(fmt(b.minX))…\(fmt(b.maxX)) of \(fmt(width)), \(fmt(-b.maxY))…\(fmt(-b.minY)) above the baseline")
    flatPreview(name, placed, width: width)
    return placed
}

/// The generator's flat preview: the glyph in its box, the margins and the
/// cap guides drawn, on the template's units ×2.
func flatPreview(_ name: String, _ placed: CGPath, width: CGFloat) {
    let s: CGFloat = 2, pad: CGFloat = 12
    let w = Int((width + 2 * pad) * s), h = Int((90 + 2 * pad) * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: pad, y: pad + 10)
    ctx.setStrokeColor(CGColor(red: 0, green: 0.68, blue: 0.94, alpha: 1)); ctx.setLineWidth(0.5)
    for y in [0, 70.459] { ctx.move(to: CGPoint(x: -pad, y: y)); ctx.addLine(to: CGPoint(x: width + pad, y: y)) }
    for x in [0, width] { ctx.move(to: CGPoint(x: x, y: -10)); ctx.addLine(to: CGPoint(x: x, y: 85)) }
    ctx.strokePath()
    ctx.scaleBy(x: 1, y: -1)
    ctx.addPath(placed); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    let url = URL(fileURLWithPath: "\(previewDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

write("core.play.fill", placedPlay, into: outDir)
write("core.pause.fill", shipsWidePause ? widePause : pause, into: outDir)

/// THE CONVERSATION VIDEO'S DISC (#2276): play.circle.fill's look — a disc
/// with the play knocked out — with the owner's play, as tall in the disc
/// as SF's knocked-out play, its optical centre (the rule above) on the
/// disc's middle. The disc and the image are play.circle.fill's.
let circleScale = sfCirclePlayHeight / playBox.height
let discRadius = sfDiscDiameter / 2 / circleScale
let disc = CGPath(ellipseIn: CGRect(x: axisX - discRadius, y: boxMidY - discRadius, width: 2 * discRadius, height: 2 * discRadius), transform: nil)
write("core.play.circle.fill", disc.subtracting(placedPlay), into: outDir,
      Placement(scale: circleScale, width: sfCircleWidth, centre: sfCircleCentre))

try! FileManager.default.createDirectory(atPath: wideDir, withIntermediateDirectories: true)
try! "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".write(toFile: "\(wideDir)/Contents.json", atomically: true, encoding: .utf8)
write("core.pause.fill.wide", widePause, into: wideDir)
print(shipsWidePause ? "shipped: the WIDENED pause" : "shipped: the pause as drawn")
