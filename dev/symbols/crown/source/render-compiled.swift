import AppKit
let dir = CommandLine.arguments[1]
let b = Bundle(path: "\(dir)/c.bundle")!
func c(_ hex: UInt32) -> NSColor { NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }
let yellow = c(0xFFE600), deep = c(0x9E8A00), text = c(0x7A6A00), violet = c(0x9B5CFF), gold = c(0xFFC53D)
func sym(_ n: String, _ pt: CGFloat, _ colors: [NSColor], _ w: NSFont.Weight = .regular) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: w).applying(NSImage.SymbolConfiguration(paletteColors: colors))
    return NSImage(symbolName: n, bundle: b, variableValue: 1)!.withSymbolConfiguration(cfg)!
}
func render(_ size: NSSize, _ bg: NSColor, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill(); NSRect(origin: .zero, size: size).fill(); draw(); NSGraphicsContext.restoreGraphicsState(); return rep
}
func save(_ r: NSBitmapImageRep, _ n: String) { try! r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(n)")) }
func label(_ s: String, _ p: NSPoint, _ col: NSColor, _ size: CGFloat = 11, _ bold: Bool = false) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: col])
}
// 1. Large: outline, fill (mono), fill (a), fill (b), the owner's PNGs, today's gem.
let owner = NSImage(contentsOfFile: CommandLine.arguments[2])!, ownerFill = NSImage(contentsOfFile: CommandLine.arguments[3])!
save(render(NSSize(width: 820, height: 150), .white) {
    let items: [(NSImage, String)] = [
        (sym("core.crown", 70, [.black]), "core.crown"), (sym("core.crown.fill", 70, [.black, .black]), "core.crown.fill"),
        (sym("core.crown.fill", 70, [yellow, deep]), "(a) yellow + gold rim"), (sym("core.crown.fill", 70, [deep, deep]), "(b) solid deep gold"),
        (owner, "owner crown.png"), (ownerFill, "owner crown-fill.png"), (sym("core.gem.fill", 70, [violet]), "today's gem")]
    for (i, (img, t)) in items.enumerated() {
        let h: CGFloat = 84, w = img.size.width * h / img.size.height
        img.draw(in: NSRect(x: 10 + CGFloat(i) * 116 + (100 - w) / 2, y: 40, width: w, height: h))
        label(t, NSPoint(x: 10 + CGFloat(i) * 116, y: 12), .black)
    }
}, "large.png")
// 2. Beside a price at 13, 17, 22 pt: light (a), light (b), dark; and a saved star beside a crown price.
for (bg, glyph, ink, mode) in [(NSColor.white, [yellow, deep], text, "light-a"), (NSColor.white, [deep, deep], text, "light-b"),
                               (NSColor(white: 0.11, alpha: 1), [yellow, yellow], yellow, "dark")] {
    save(render(NSSize(width: 820, height: 54), bg) {
        label(mode == "dark" ? "dark" : (mode == "light-a" ? "light (a)" : "light (b)"), NSPoint(x: 8, y: 18), bg == .white ? .black : .white)
        var x: CGFloat = 110
        for pt in [13, 17, 22] as [CGFloat] {
            let img = sym("core.crown.fill", pt, glyph, .semibold)
            img.draw(at: NSPoint(x: x, y: (54 - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            x += img.size.width + 4
            let s = NSAttributedString(string: "1,250", attributes: [.font: NSFont.systemFont(ofSize: pt, weight: .semibold), .foregroundColor: ink])
            s.draw(at: NSPoint(x: x, y: (54 - s.size().height) / 2)); x += s.size().width + 40
        }
        let star = sym("core.star.fill", 17, [gold])
        star.draw(at: NSPoint(x: x + 20, y: (54 - star.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        let crown = sym("core.crown.fill", 17, glyph, .semibold)
        crown.draw(at: NSPoint(x: x + 50, y: (54 - crown.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        label("saved star · crown", NSPoint(x: x + 80, y: 18), bg == .white ? .gray : .lightGray)
    }, "price-\(mode).png")
}
