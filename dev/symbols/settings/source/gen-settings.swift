// Builds core.settings and core.settings.fill (#2433): the owner's gear, six
// rounded lobes round a ring, traced from their two 64 px drawings.
// usage: ../../owner-trace/run.sh gen-settings.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "settings-owner.png")
let drawingFill = Raster(png: "settings-fill-owner.png")

/// The gear's centre: the middle of the outline's ink box (50 × 52 px at
/// (7, 6)); the ring's own centre agrees within 0.1 px.
let box0 = drawing.inkBox
let c = CGPoint(x: box0.midX, y: box0.midY)

/// The six lobes made identical and 60° apart: the drawing averaged over its
/// six rotations, then traced.
let even = drawing.rotated(6, about: c)
let traced = trace(even)

/// The ring and the lobed contour, apart: the ring's loops sit within 12 px
/// of the centre.
let parts = subpaths(traced)
func maxRadius(_ p: CGPath) -> CGFloat {
    let b = p.boundingBoxOfPath
    return max(abs(b.minX - c.x), abs(b.maxX - c.x), abs(b.minY - c.y), abs(b.maxY - c.y))
}
let ringLoops = parts.filter { maxRadius($0) < 12 }
let lobeLoops = parts.filter { maxRadius($0) >= 12 }
/// The ring's centre line: the mean of its outer and inner edge radii.
let ringRadii = ringLoops.map { $0.boundingBoxOfPath.width / 2 }.sorted()
let ringR = (ringRadii.first! + ringRadii.last!) / 2

/// Template units per drawing pixel (see the README: the gear stands as tall
/// as the system's gearshape within AppSymbolSizeTests' 8 %).
let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.52
let sw: CGFloat = 6.4 / scale

let lobes = setStroke(joined(lobeLoops), to: sw)
let ring = stroked(circle(c, ringR), sw)
let outline = lobes.union(ring)

/// The fill: the outline's silhouette, so selecting never moves or resizes
/// the gear, with the hole on the ring's centre line (r 8 px). That is the
/// filled drawing's own hole (r 7.9 px, measured below); the issue's "the
/// ring's outer edge" (r 10) would open it a quarter wider than drawn.
let filled = silhouette(lobes).subtracting(circle(c, ringR))

let fillHole = trace(drawingFill.rotated(6, about: c))
let holeR = subpaths(fillHole).map { maxRadius($0) }.min()!
print("centre \(fmt(c.x)), \(fmt(c.y)); drawing stroke \(fmt(strokeWidth(trace(drawing)))) px; ring r \(fmt(ringR)) px; fill drawing's hole r \(fmt(holeR)) px vs ring outer \(fmt(ringR + sw / 2))")

let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.settings", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.settings.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
/// The six lobes overlaid: the drawing's six rotations averaged (grey, sharp
/// where the owner's lobes agree), under the traced outline.
overlay(even, [outline], to: "\(previewDir)/six-lobes.png")
