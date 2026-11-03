import AppKit
let dir = CommandLine.arguments[1]
let b = Bundle(path: CommandLine.arguments[2])!
func c(_ hex: UInt32) -> NSColor { NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }
func sym(_ n: String, _ pt: CGFloat, _ colors: [NSColor], bundle: Bundle?) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: colors))
    let img = bundle == nil ? NSImage(systemSymbolName: n, accessibilityDescription: nil)! : NSImage(symbolName: n, bundle: bundle!, variableValue: 1)!
    return img.withSymbolConfiguration(cfg)!
}
func lum(_ h: UInt32) -> Double {
    func ch(_ v: UInt32) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch((h >> 16) & 0xFF) + 0.7152 * ch((h >> 8) & 0xFF) + 0.0722 * ch(h & 0xFF)
}
func ratio(_ a: UInt32, _ bg: UInt32) -> Double { let x = lum(a), y = lum(bg); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
let rows: [(String, UInt32, UInt32)] = [
    ("1 · today (b)  9E8A00", 0x9E8A00, 0x9E8A00),
    ("2 · warm gold  E0A800", 0xE0A800, 0xE0A800),
    ("3 · bright gold  F5C000", 0xF5C000, 0xF5C000),
    ("4 · the star's gold  FFC53D", 0xFFC53D, 0xFFC53D),
    ("5 · yellow + gold rim  FFE600/C9A400", 0xFFE600, 0xC9A400),
    ("6 · the brand yellow  FFE600", 0xFFE600, 0xFFE600),
]
let W: CGFloat = 900, rowH: CGFloat = 96, H = rowH * CGFloat(rows.count) + 40
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W / 2, height: H).fill()
c(0xF2F2F7).setFill(); NSRect(x: W / 2, y: 0, width: W / 2, height: H).fill()
func label(_ s: String, _ p: NSPoint, _ col: NSColor, _ size: CGFloat, _ wgt: NSFont.Weight = .regular) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: wgt), .foregroundColor: col])
}
label("on white", NSPoint(x: 12, y: H - 28), .gray, 12); label("on grouped grey F2F2F7", NSPoint(x: W / 2 + 12, y: H - 28), .gray, 12)
for (i, r) in rows.enumerated() {
    let y = H - 40 - rowH * CGFloat(i + 1)
    for (half, bg) in [(CGFloat(0), UInt32(0xFFFFFF)), (W / 2, UInt32(0xF2F2F7))] {
        let big = sym("core.crown.fill", 44, [c(r.1), c(r.2)], bundle: b)
        big.draw(in: NSRect(x: half + 14, y: y + 30, width: big.size.width, height: big.size.height))
        let small = sym("core.crown.fill", 15, [c(r.1), c(r.2)], bundle: b)
        small.draw(in: NSRect(x: half + 90, y: y + 44, width: small.size.width, height: small.size.height))
        label("1,200", NSPoint(x: half + 90 + small.size.width + 4, y: y + 41), c(0x7A6A00), 15, .semibold)
        let star = sym("star.fill", 15, [c(0xFFC53D)], bundle: nil)
        star.draw(in: NSRect(x: half + 190, y: y + 44, width: star.size.width, height: star.size.height))
        label(String(format: "%.2f:1", ratio(r.1, bg)), NSPoint(x: half + 225, y: y + 43), .gray, 11)
        label(r.0, NSPoint(x: half + 14, y: y + 8), .black, 12, .medium)
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/crown-light-candidates.png"))
