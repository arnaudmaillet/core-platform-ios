import AppKit
let bundle = Bundle(path: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
func sym(_ name: String, _ pt: CGFloat, _ colors: [NSColor]?) -> NSImage {
    var cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .regular, scale: .large)
    if let colors { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: colors)) }
    else { cfg = cfg.applying(NSImage.SymbolConfiguration(hierarchicalColor: .black)) }
    guard let img = NSImage(symbolName: name, bundle: bundle, variableValue: 1)?.withSymbolConfiguration(cfg) else { fatalError(name) }
    return img
}
func render(_ size: NSSize, _ bg: NSColor, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill(); NSRect(origin: .zero, size: size).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ name: String) { try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)")) }
let pink = NSColor(red: 0xEC/255, green: 0x1C/255, blue: 0x75/255, alpha: 1)
// 1. The four, large: monochrome, then palette (ink + pink badge).
let names = ["core.square.play", "core.square.play.fill", "core.square.play.badge", "core.square.play.badge.fill"]
save(render(NSSize(width: 560, height: 300), .white) {
    for (i, n) in names.enumerated() {
        sym(n, 72, [.black]).draw(at: NSPoint(x: 20 + i * 135, y: 170), from: .zero, operation: .sourceOver, fraction: 1)
        sym(n, 72, [.black, pink]).draw(at: NSPoint(x: 20 + i * 135, y: 30), from: .zero, operation: .sourceOver, fraction: 1)
    }
}, "four-large.png")
// 2. The bar at 17 pt .large: Explore, For You, Messages, light and dark; For You selected or not, badged or not.
func bar(_ bg: NSColor, _ ink: NSColor, selected: Bool, badged: Bool) -> NSBitmapImageRep {
    render(NSSize(width: 230, height: 50), bg) {
        let fy = "core.square.play" + (badged ? ".badge" : "") + (selected ? ".fill" : "")
        let row = [("core.paperplane", false), (fy, badged), ("core.chats", false)]
        for (i, (n, b)) in row.enumerated() {
            let img = sym(n, 17, b ? [ink, pink] : [ink])
            let x = 30 + CGFloat(i) * 70 + (30 - img.size.width) / 2
            img.draw(at: NSPoint(x: x, y: (50 - img.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
var i = 0
for (bg, ink, mode) in [(NSColor.white, NSColor.black, "light"), (NSColor(white: 0.08, alpha: 1), NSColor.white, "dark")] {
    for (s, b) in [(false, false), (true, false), (false, true), (true, true)] {
        save(bar(bg, ink, selected: s, badged: b), "bar-\(mode)-\(i % 4)-sel\(s)-badge\(b).png"); i += 1
    }
}
