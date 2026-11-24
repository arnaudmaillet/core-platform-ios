// Builds core.gallery and core.gallery.fill (#2458): the owner's two stacked
// photos, traced from their two 64 px drawings.
// usage: ../../owner-trace/run.sh gen-gallery.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "gallery-owner.png")
let drawingFill = Raster(png: "gallery-fill-owner.png")

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.52
let sw: CGFloat = 6.4 / scale

/// The front frame, measured on gallery-owner.png: x 0–49, y 4–49, symmetric
/// both ways about its middle (24.5, 26.5). Its band is cut out of the drawing
/// (the hill and the sun inside, the back frame outside), mirrored both ways,
/// traced, and set to the set's stroke.
let frameMid = pt(24.5, 26.5)
let frameOnly = drawing.masked { p in
    let inFront = p.x < 50 && p.y < 50 && !(p.x >= 49 && p.y < 18)
    let interior = p.x > 6 && p.x < 43 && p.y > 10 && p.y < 43
    return inFront && !interior
}
let front = setStroke(trace(frameOnly.mirrored(axis: Double(frameMid.x)).mirroredY(axis: Double(frameMid.y))), to: sw)
let frontSolid = silhouette(front)

/// The back frame is the same frame, 10 px right and 8 px down. Only what
/// lies past the set's gap round the front frame shows: its right and bottom.
let gap: CGFloat = 32.0 / 3 * 0.4 / scale
let backVisible = moved(front, 10, 8).subtracting(offset(frontSolid, gap))

/// The hill: a closed stroke, traced as drawn (smooth cubics), at the set's
/// stroke. The sun: a dot, 6 px across in the drawing, a true circle.
let hillOnly = drawing.masked { p in p.x > 6 && p.x < 43 && p.y > 10 && p.y < 43 && !(p.x >= 31 && p.y <= 20.5) }
let hill = setStroke(trace(hillOnly), to: sw)
let sun = circle(pt(35, 17), 3)

let outline = front.union(backVisible).union(hill).union(sun)
/// The fill: the front frame solid with the hill and the sun cut out where the
/// outline draws them (the hill's outer edge; the filled drawing clears the
/// same), and the same back band.
let filled = frontSolid.subtracting(silhouette(hill)).subtracting(sun).union(backVisible)

print("drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px")
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.gallery", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.gallery.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawing, [filled, outline], to: "\(previewDir)/outline-over-fill.png")
