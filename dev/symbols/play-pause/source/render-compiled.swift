// Renders the before / after previews of #2276 from the COMPILED catalogue
// (actool's Assets.car, the shipped Symbols.xcassets and Widened.xcassets
// together), as AppKit draws them: every glyph centred in its cell, as a
// UIImageView with `.center` (or a button) centres it.
// usage: render-compiled <Sym.bundle> <out dir> <bright picture> <dark picture>
import AppKit

let bundle = Bundle(path: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let pictures = [NSImage(contentsOfFile: CommandLine.arguments[3])!, NSImage(contentsOfFile: CommandLine.arguments[4])!]

let sizes: [CGFloat] = [13, 16, 22, 56]
/// The columns: today's, then the owner's.
let columns: [(String, String)] = [
    ("play.fill", "SF ▶︎"), ("core.play.fill", "owner ▶︎"),
    ("pause.fill", "SF ❚❚"), ("core.pause.fill", "owner ❚❚ (shipped)"), ("core.pause.fill.wide", "owner ❚❚ widened"),
]

func symbol(_ name: String, _ pointSize: CGFloat, _ ink: NSColor) -> NSImage {
    // The sites' weight (the sheet, the timeline, the paused mark ask for
    // semibold; the custom glyphs have one weight), UIKit's default scale.
    var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold, scale: .medium)
    configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    let base = name.hasPrefix("core.")
        ? NSImage(symbolName: name, bundle: bundle, variableValue: 1)
        : NSImage(systemSymbolName: name, accessibilityDescription: nil)
    guard let image = base?.withSymbolConfiguration(configuration) else { fatalError("no symbol \(name)") }
    return image
}

func render(_ size: NSSize, _ draw: () -> Void) -> NSBitmapImageRep {
    let scale: CGFloat = 3
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    print("wrote \(name)")
}

func text(_ string: String, at point: NSPoint, _ color: NSColor, size: CGFloat = 11, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

/// The glyph centred on `centre`, with an optional shadow (a picture's).
func draw(_ image: NSImage, centredAt centre: NSPoint, shadow: CGFloat? = nil) {
    NSGraphicsContext.saveGraphicsState()
    if let shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.4)
        s.shadowBlurRadius = shadow
        s.shadowOffset = .zero
        s.set()
    }
    let origin = NSPoint(x: centre.x - image.size.width / 2, y: centre.y - image.size.height / 2)
    image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

/// The picture, aspect-filled into `rect`.
func fill(_ picture: NSImage, in rect: NSRect) {
    let s = max(rect.width / picture.size.width, rect.height / picture.size.height)
    let w = picture.size.width * s, h = picture.size.height * s
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: rect).addClip()
    picture.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

enum Ground {
    case panel(dark: Bool)
    case picture(Int)

    var title: String {
        switch self {
        case .panel(let dark): dark ? "Voice panel, dark" : "Voice panel, light"
        case .picture(let i): i == 0 ? "On a bright picture" : "On a dark picture"
        }
    }

    /// The played ink (#2274: the label at 0.7) or a picture's white mark
    /// (the paused mark's 0.85, with its shadow).
    var ink: NSColor {
        switch self {
        case .panel(let dark): (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.7)
        case .picture: NSColor.white.withAlphaComponent(0.85)
        }
    }

    var label: NSColor {
        switch self {
        case .panel(let dark): dark ? .white : .black
        case .picture: .white
        }
    }
}

let cell = NSSize(width: 104, height: 0)
let rowHeights: [CGFloat] = sizes.map { max(34, $0 * 1.5) }
let headerHeight: CGFloat = 40
let sideColumn: CGFloat = 52
let panelSize = NSSize(width: sideColumn + cell.width * CGFloat(columns.count) + 8,
                       height: headerHeight + rowHeights.reduce(0, +) + 10)

func panel(_ ground: Ground) -> NSBitmapImageRep {
    render(panelSize) {
        let rect = NSRect(origin: .zero, size: panelSize)
        switch ground {
        case .panel(let dark):
            // The page, then the panel: the played ink at 0.06 (light) or
            // 0.12 (dark) over it (`VoiceView.Inks.panel`).
            (dark ? NSColor.black : NSColor.white).setFill(); rect.fill()
            (dark ? NSColor.white.withAlphaComponent(0.7 * 0.12) : NSColor.black.withAlphaComponent(0.7 * 0.06)).setFill()
            rect.fill()
        case .picture(let i):
            fill(pictures[i], in: rect)
            NSColor.black.withAlphaComponent(0.15).setFill(); rect.fill(using: .sourceOver)
        }
        text(ground.title, at: NSPoint(x: 8, y: panelSize.height - 18), ground.label, bold: true)
        for (i, column) in columns.enumerated() {
            text(column.1, at: NSPoint(x: sideColumn + CGFloat(i) * cell.width + 4, y: panelSize.height - headerHeight + 4), ground.label, size: 10)
        }
        var top = panelSize.height - headerHeight
        for (row, size) in sizes.enumerated() {
            let h = rowHeights[row]
            let y = top - h / 2
            text("\(Int(size)) pt", at: NSPoint(x: 8, y: y - 6), ground.label, size: 10)
            for (i, column) in columns.enumerated() {
                let x = sideColumn + CGFloat(i) * cell.width + cell.width / 2
                let shadow: CGFloat? = if case .picture = ground { max(2, size * 0.1) } else { nil }
                draw(symbol(column.0, size, ground.ink), centredAt: NSPoint(x: x, y: y), shadow: shadow)
            }
            top -= h
        }
    }
}

save(panel(.panel(dark: false)), "compare-panel-light.png")
save(panel(.panel(dark: true)), "compare-panel-dark.png")
save(panel(.picture(0)), "compare-picture-bright.png")
save(panel(.picture(1)), "compare-picture-dark.png")

// THE OPTICAL CENTRE: the conversation video's disc (34 pt, white at 0.9,
// the picture through the knocked-out play), SF's and the owner's; then
// the bare play centred in a drawn circle with a cross through its middle.
let discSize = NSSize(width: 520, height: 300)
save(render(discSize) {
    fill(pictures[1], in: NSRect(origin: .zero, size: discSize))
    text("play.circle.fill → core.play.circle.fill (34 pt and 72 pt, the conversation's video)", at: NSPoint(x: 8, y: discSize.height - 18), .white, bold: true)
    let names = ["play.circle.fill", "core.play.circle.fill"]
    for (i, name) in names.enumerated() {
        for (j, size) in [CGFloat(34), 72].enumerated() {
            let centre = NSPoint(x: 70 + CGFloat(i) * 260 + CGFloat(j) * 110, y: 200)
            draw(symbol(name, size, NSColor.white.withAlphaComponent(0.9)), centredAt: centre)
        }
        text(name, at: NSPoint(x: 40 + CGFloat(i) * 260, y: 140), .white, size: 10)
    }
    text("The bare play centred in a circle (56 pt): SF's, the owner's", at: NSPoint(x: 8, y: 116), .white, bold: true)
    for (i, name) in ["play.fill", "core.play.fill"].enumerated() {
        let centre = NSPoint(x: 130 + CGFloat(i) * 260, y: 56)
        let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 46, y: centre.y - 46, width: 92, height: 92))
        NSColor.white.withAlphaComponent(0.25).setFill(); ring.fill()
        draw(symbol(name, 40, NSColor.white), centredAt: centre)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: centre.x - 50, y: centre.y)); cross.line(to: NSPoint(x: centre.x + 50, y: centre.y))
        cross.move(to: NSPoint(x: centre.x, y: centre.y - 50)); cross.line(to: NSPoint(x: centre.x, y: centre.y + 50))
        cross.lineWidth = 0.5
        NSColor.systemPink.setStroke(); cross.stroke()
    }
}, "optical-centre.png")

// THE SWAP DOESN'T MOVE THE GLYPH: play and pause drawn over each other
// in the shared box, at 56 pt, with the box outlined.
let overlaySize = NSSize(width: 360, height: 130)
save(render(overlaySize) {
    NSColor.white.setFill(); NSRect(origin: .zero, size: overlaySize).fill()
    for (i, pair) in [("play.fill", "pause.fill"), ("core.play.fill", "core.pause.fill")].enumerated() {
        let centre = NSPoint(x: 90 + CGFloat(i) * 180, y: 60)
        let play = symbol(pair.0, 56, NSColor.systemBlue.withAlphaComponent(0.5))
        let pause = symbol(pair.1, 56, NSColor.systemPink.withAlphaComponent(0.5))
        for image in [play, pause] {
            let box = NSRect(x: centre.x - image.size.width / 2, y: centre.y - image.size.height / 2, width: image.size.width, height: image.size.height)
            let outline = NSBezierPath(rect: box); outline.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.4).setStroke(); outline.stroke()
            draw(image, centredAt: centre)
        }
        text("\(pair.0) over \(pair.1)", at: NSPoint(x: centre.x - 70, y: 112), .black, size: 10)
    }
}, "swap-box-overlay.png")
