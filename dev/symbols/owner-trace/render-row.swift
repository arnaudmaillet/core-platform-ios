// Renders glyphs side by side in rows, from the compiled catalogue, at a few
// sizes, light and dark: a new symbol among the glyphs it sits beside (a bar,
// a card's action row, the tab bar), or beside the system glyph it replaces.
// usage: swift render-row.swift <dir holding c.bundle> <out.png> <title> <sizes, e.g. 12,17,22> <weight: regular|semibold> name…
//   a name is one of the app's (core.…) or, prefixed sys:, the system's.
import AppKit

let args = CommandLine.arguments
let bundle = Bundle(path: "\(args[1])/c.bundle")!
let outFile = args[2], title = args[3]
let sizes = args[4].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
let weight: NSFont.Weight = args[5] == "semibold" ? .semibold : .regular
let names = Array(args.dropFirst(6))

func image(_ n: String, _ pt: CGFloat, ink: NSColor) -> NSImage? {
    var cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
    cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [ink, ink]))
    if n.hasPrefix("sys:") {
        return NSImage(systemSymbolName: String(n.dropFirst(4)), accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    return NSImage(symbolName: n, bundle: bundle, variableValue: 1)?.withSymbolConfiguration(cfg)
}
func label(_ s: String, _ p: NSPoint, _ col: NSColor, _ size: CGFloat = 10) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: col])
}

let gap: CGFloat = 18
let rowH = (sizes.max() ?? 22) * 1.9 + 22
let column = max(78, (sizes.max() ?? 22) * 1.7 + gap)
let width: CGFloat = max(560, CGFloat(names.count) * column + 90)
let height = 30 + CGFloat(sizes.count) * 2 * rowH + 20
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 3), pixelsHigh: Int(height * 3), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
var top = height - 30
label(title, NSPoint(x: 10, y: top + 9), .black, 12)
for dark in [false, true] {
    for pt in sizes {
        top -= rowH
        (dark ? NSColor(white: 0.07, alpha: 1) : .white).setFill()
        NSRect(x: 0, y: top, width: width, height: rowH).fill()
        let ink: NSColor = dark ? .white : .black
        label("\(Int(pt)) pt", NSPoint(x: 10, y: top + rowH / 2 - 6), dark ? .lightGray : .darkGray)
        var x: CGFloat = 70
        for n in names {
            guard let img = image(n, pt, ink: ink) else { label("?\(n)", NSPoint(x: x, y: top + rowH / 2), .red); x += 60; continue }
            // Centred in the row, as a bar centres its items.
            img.draw(at: NSPoint(x: x, y: top + (rowH - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            if pt == sizes.first, !dark {
                label(n.replacingOccurrences(of: "sys:", with: "").replacingOccurrences(of: "core.", with: "core."), NSPoint(x: x, y: top + 3), n.hasPrefix("sys:") ? .systemBlue : .gray, 7)
            }
            x += column
        }
    }
}
label("Rendered from the compiled catalogue (actool) by dev/symbols/owner-trace/render-row.swift. Blue labels: the system's glyphs.", NSPoint(x: 10, y: 5), .darkGray, 8)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outFile))
print("wrote \(outFile)")
