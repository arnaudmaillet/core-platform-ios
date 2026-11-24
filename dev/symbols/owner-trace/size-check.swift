// The size guard, on the Mac (#2415, #2416, #2433, #2434, #2456–#2459): each
// custom symbol beside the system glyph it replaces, at 12 pt semibold, as
// AppSymbolSizeTests compares them (heights within max(1 pt, 8 %)). AppKit's
// symbol images size as UIKit's do; the test in the DesignSystem suite is the
// one that decides.
// usage: swift size-check.swift <dir holding c.bundle> core.x=system.x …
import AppKit
let b = Bundle(path: "\(CommandLine.arguments[1])/c.bundle")!
let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
let big = NSImage.SymbolConfiguration(pointSize: 100, weight: .semibold)
for pair in CommandLine.arguments.dropFirst(2) {
    let p = pair.split(separator: "=").map(String.init)
    guard let c = NSImage(symbolName: p[0], bundle: b, variableValue: 1)?.withSymbolConfiguration(cfg),
          let s = NSImage(systemSymbolName: p[1], accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
          let c100 = NSImage(symbolName: p[0], bundle: b, variableValue: 1)?.withSymbolConfiguration(big),
          let s100 = NSImage(systemSymbolName: p[1], accessibilityDescription: nil)?.withSymbolConfiguration(big) else { print("\(pair): missing"); continue }
    let ok = abs(c.size.height - s.size.height) <= max(1, s.size.height * 0.08)
    print(String(format: "%@ %@  12pt: %.2f vs %.2f   100pt: %.1f×%.1f vs %.1f×%.1f  (%+.1f%%)", ok ? "PASS" : "FAIL", pair, c.size.height, s.size.height,
                 c100.size.width, c100.size.height, s100.size.width, s100.size.height, (c100.size.height / s100.size.height - 1) * 100))
}
