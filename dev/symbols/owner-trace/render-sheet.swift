// Renders one family's preview sheet from the COMPILED catalogue (actool,
// `compile.sh`), as the app draws it (#2415, #2416, #2433, #2434, #2456–#2459):
// - the owner's drawings, then each new symbol large, light and dark;
// - each symbol beside the system glyph it replaces, at 12, 17, 22 and 34 pt
//   (regular), then at ultralight, regular and black (22 pt), light and dark;
// - hierarchical and palette renders.
// usage: swift render-sheet.swift <dir holding c.bundle> <out.png> <title>
//          drawing=<png or svg-rendered png> … pair=<core.x>:<system.x> …
import AppKit

let args = CommandLine.arguments
let bundle = Bundle(path: "\(args[1])/c.bundle")!
let outFile = args[2], title = args[3]
var drawings: [String] = [], pairs: [(String, String)] = []
for a in args.dropFirst(4) {
    if a.hasPrefix("drawing=") { drawings.append(String(a.dropFirst(8))) }
    if a.hasPrefix("pair=") {
        let p = a.dropFirst(5).split(separator: ":").map(String.init)
        pairs.append((p[0], p.count > 1 ? p[1] : ""))
    }
}

func custom(_ n: String, _ pt: CGFloat, _ w: NSFont.Weight, _ colors: [NSColor]? = nil, hierarchical: NSColor? = nil) -> NSImage? {
    var cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: w)
    if let colors { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: colors)) }
    if let hierarchical { cfg = cfg.applying(NSImage.SymbolConfiguration(hierarchicalColor: hierarchical)) }
    return NSImage(symbolName: n, bundle: bundle, variableValue: 1)?.withSymbolConfiguration(cfg)
}
func system(_ n: String, _ pt: CGFloat, _ w: NSFont.Weight, _ colors: [NSColor]? = nil, hierarchical: NSColor? = nil) -> NSImage? {
    var cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: w)
    if let colors { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: colors)) }
    if let hierarchical { cfg = cfg.applying(NSImage.SymbolConfiguration(hierarchicalColor: hierarchical)) }
    return NSImage(systemSymbolName: n, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}
func tinted(_ img: NSImage, _ c: NSColor) -> NSImage {
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    c.set(); NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}
func label(_ s: String, _ p: NSPoint, _ col: NSColor, _ size: CGFloat = 11, _ bold: Bool = false) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: col])
}

let pink = NSColor(red: 1, green: 0.075, blue: 0.345, alpha: 1)
let rowH: CGFloat = 64
let width: CGFloat = 1240
let headerH: CGFloat = 150
let height = 34 + 2 * headerH + CGFloat(pairs.count) * 2 * rowH + 24
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()

var top = height
func band(_ h: CGFloat, dark: Bool) -> CGFloat {
    top -= h
    (dark ? NSColor(white: 0.07, alpha: 1) : NSColor.white).setFill()
    NSRect(x: 0, y: top, width: width, height: h).fill()
    return top
}
_ = band(34, dark: false)
label(title, NSPoint(x: 12, y: top + 9), .black, 14, true)

// Header: the owner's drawings, then each symbol large.
for dark in [false, true] {
    let y = band(headerH, dark: dark)
    let ink: NSColor = dark ? .white : .black, sub: NSColor = dark ? .lightGray : .darkGray
    var x: CGFloat = 12
    for d in drawings {
        guard let img = NSImage(contentsOfFile: d) else { continue }
        let s: CGFloat = 96
        tinted(img, ink).draw(in: NSRect(x: x, y: y + 34, width: s * img.size.width / max(img.size.width, img.size.height), height: s * img.size.height / max(img.size.width, img.size.height)))
        label("owner: " + ((d as NSString).lastPathComponent), NSPoint(x: x, y: y + 12), sub, 9)
        x += 124
    }
    x += 12
    for (c, _) in pairs {
        guard let img = custom(c, 64, .regular) else { label("\(c) MISSING", NSPoint(x: x, y: y + 60), .red); x += 124; continue }
        let drawn = c.contains("badge") ? custom(c, 64, .regular, [pink, ink])! : tinted(img, ink)
        drawn.draw(at: NSPoint(x: x + (110 - img.size.width) / 2, y: y + 34 + (96 - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        label(c, NSPoint(x: x, y: y + 12), sub, 9)
        x += max(124, img.size.width + 14)
    }
}

// One light and one dark row per pair.
for (c, s) in pairs {
    for dark in [false, true] {
        let y = band(rowH, dark: dark)
        let ink: NSColor = dark ? .white : .black, sub: NSColor = dark ? .lightGray : .darkGray
        label(c, NSPoint(x: 12, y: y + 34), ink, 10, true)
        label(s.isEmpty ? "" : "vs \(s)", NSPoint(x: 12, y: y + 18), sub, 10)
        var x: CGFloat = 190
        func put(_ img: NSImage?, _ caption: String) {
            guard let img else { x += 40; return }
            let drawn = c.contains("badge") ? img : tinted(img, ink)
            drawn.draw(at: NSPoint(x: x, y: y + 22 + (36 - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            if !caption.isEmpty { label(caption, NSPoint(x: x, y: y + 4), sub, 8) }
            x += img.size.width + 6
        }
        func pal(_ n: String, _ pt: CGFloat, _ w: NSFont.Weight, isCustom: Bool) -> NSImage? {
            if c.contains("badge") || n.contains("badge") {
                return isCustom ? custom(n, pt, w, [pink, ink]) : system(n, pt, w, [pink, ink])
            }
            return isCustom ? custom(n, pt, w) : system(n, pt, w)
        }
        for pt in [12, 17, 22, 34] as [CGFloat] {
            put(pal(c, pt, .regular, isCustom: true), "\(Int(pt))")
            if !s.isEmpty { put(pal(s, pt, .regular, isCustom: false), "sys") }
            x += 14
        }
        x += 10
        for (w, n) in [(NSFont.Weight.ultraLight, "UL"), (.regular, "Reg"), (.black, "Blk")] {
            put(pal(c, 22, w, isCustom: true), n)
            if !s.isEmpty { put(pal(s, 22, w, isCustom: false), "sys") }
            x += 10
        }
        x += 10
        // Hierarchical (pink) and palette (pink + ink): drawn as given.
        if let h = custom(c, 22, .regular, hierarchical: pink) {
            h.draw(at: NSPoint(x: x, y: y + 22 + (36 - h.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            label("hier.", NSPoint(x: x, y: y + 4), sub, 8); x += h.size.width + 8
        }
        if let p = custom(c, 22, .regular, [pink, ink]) {
            p.draw(at: NSPoint(x: x, y: y + 22 + (36 - p.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            label("palette", NSPoint(x: x, y: y + 4), sub, 8)
        }
    }
}
_ = band(24, dark: false)
label("Rendered from the compiled catalogue (actool) by dev/symbols/owner-trace/render-sheet.swift. sys = the system glyph it replaces.", NSPoint(x: 12, y: top + 6), .darkGray, 9)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outFile))
print("wrote \(outFile)")
