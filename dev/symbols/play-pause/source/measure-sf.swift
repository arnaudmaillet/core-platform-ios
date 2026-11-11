// Measures the system's play.fill and pause.fill, the glyphs core.play.fill
// and core.pause.fill stand in for (#2276), at 100 pt, small scale: the
// template's own units (its S masters are typeset at 100 points).
// usage: swift measure-sf.swift
//
// Prints, per symbol (and, for play.circle.fill, the knocked-out play's box
// and centroid inside the disc): the image's size (its width is the margin box), the
// alignment rect (its origin's y is the baseline, measured from the bottom),
// the ink's box (alpha ≥ 0.5, from the top) and the ink's centroid. The
// generator's constants are these numbers (macOS 27, SF Symbols 7).
import AppKit

let k: CGFloat = 4

func render(_ image: NSImage) -> NSBitmapImageRep {
    let size = image.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * k), pixelsHigh: Int(size.height * k),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The box of the inked pixels (alpha >= 0.5; clear ones for a `hole`) and
/// the weighted centroid, from the top left, in points; `within` keeps the
/// pixels inside a disc (centre, radius, in pixels).
func measure(_ rep: NSBitmapImageRep, hole: Bool = false, within: (CGPoint, CGFloat)? = nil) -> (ink: NSRect, centroid: NSPoint) {
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var sumX = 0.0, sumY = 0.0, sum = 0.0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let (c, r) = within, hypot(CGFloat(x) + 0.5 - c.x, CGFloat(y) + 0.5 - c.y) > r { continue }
            let alpha = Double(rep.colorAt(x: x, y: y)!.alphaComponent)
            let a = hole ? 1 - alpha : alpha
            sumX += Double(x) * a; sumY += Double(y) * a; sum += a
            if a >= 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    let ink = NSRect(x: CGFloat(minX) / k, y: CGFloat(minY) / k,
                     width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
    return (ink, NSPoint(x: sumX / sum / Double(k), y: sumY / sum / Double(k)))
}

for name in ["play.fill", "pause.fill", "play.circle.fill"] {
    let configuration = NSImage.SymbolConfiguration(pointSize: 100, weight: .regular, scale: .small)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
    let rep = render(image)
    let (ink, centroid) = measure(rep)
    print(name, "image", image.size, "alignment", image.alignmentRect, "ink", ink, "centroid", centroid)
    guard name == "play.circle.fill" else { continue }
    // The play knocked out of the disc: the clear pixels well inside it.
    let centre = CGPoint(x: ink.midX * k, y: ink.midY * k)
    let (play, playCentroid) = measure(rep, hole: true, within: (centre, ink.width / 2 * k * 0.9))
    print("  disc middle x \(ink.midX), its play: box", play, "box middle x \(play.midX), centroid", playCentroid)
}
