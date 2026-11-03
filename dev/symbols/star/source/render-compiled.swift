import AppKit
// usage: render1 <dir> <variant> <label> — one bundle per process (AppKit caches symbols by name).
let dir = CommandLine.arguments[1], v = CommandLine.arguments[2], name = CommandLine.arguments[3]
let b = Bundle(path: "\(dir)/\(v).bundle")!
let gold = NSColor(red: 1, green: 0xC5/255.0, blue: 0x3D/255.0, alpha: 1)
func sym(_ n: String, _ pt: CGFloat, _ c: NSColor, _ w: NSFont.Weight = .regular) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: w).applying(NSImage.SymbolConfiguration(paletteColors: [c]))
    return NSImage(symbolName: n, bundle: b, variableValue: 1)!.withSymbolConfiguration(cfg)!
}
func render(_ size: NSSize, _ bg: NSColor, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill(); NSRect(origin: .zero, size: size).fill(); draw(); NSGraphicsContext.restoreGraphicsState(); return rep
}
func save(_ r: NSBitmapImageRep, _ n: String) { try! r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(n)")) }
func label(_ s: String, _ p: NSPoint, _ c: NSColor) { (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: c]) }
save(render(NSSize(width: 230, height: 130), .white) {
    for (i, n) in ["core.star", "core.star.fill"].enumerated() {
        let img = sym(n, 70, .black); img.draw(at: NSPoint(x: 10 + CGFloat(i) * 110, y: 30), from: .zero, operation: .sourceOver, fraction: 1)
    }
    label(name, NSPoint(x: 10, y: 6), .black)
}, "large-\(v).png")
for (bg, ink, mode) in [(NSColor.white, NSColor.black, "light"), (NSColor(white: 0.08, alpha: 1), NSColor.white, "dark")] {
    save(render(NSSize(width: 840, height: 60), bg) {
        label(name, NSPoint(x: 8, y: 22), ink)
        var x: CGFloat = 170
        for pt in [13, 15, 17, 22] as [CGFloat] {
            for (n, c) in [("core.heart", ink), ("core.repost", ink), ("core.star", ink), ("core.star.fill", gold)] {
                let img = sym(n, pt, c)
                img.draw(at: NSPoint(x: x, y: (60 - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                x += img.size.width + 8
            }
            x += 26
        }
    }, "family-\(mode)-\(v).png")
}
save(render(NSSize(width: 260, height: 60), .white) {
    var x: CGFloat = 10
    for w in [NSFont.Weight.regular, .semibold] { for n in ["core.heart", "core.star"] {
        let img = sym(n, 15, .black, w); img.draw(at: NSPoint(x: x, y: 20), from: .zero, operation: .sourceOver, fraction: 1); x += 40 }; x += 30 }
}, "weights-\(v).png")
