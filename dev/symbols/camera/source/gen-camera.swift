// Builds core.camera and core.camera.fill (#2458): the owner's camera, traced
// from their two 64 px drawings.
// usage: ../../owner-trace/run.sh gen-camera.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "camera-owner.png")
let drawingFill = Raster(png: "camera-fill-owner.png")

/// Measured on camera-owner.png (ink 54 × 48 px at (5, 7)): the axis, the
/// lens's centre and its ring's centre line (outer edge r 12, inner r 8), and
/// the flash, a 4 px dot at the top left.
let axis: CGFloat = 32
let lensCentre = pt(32, 34), lensR: CGFloat = 10
let flashCentre = pt(16, 24)

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.6
let sw: CGFloat = 6.4 / scale

/// The body: the drawing without its lens and flash, its 1 px nick in the
/// bottom edge's middle filled, made symmetric about the axis, at the set's
/// stroke.
let bodyOnly = drawing.patched(32, 51, 1).masked { p in
    hypot(p.x - lensCentre.x, p.y - lensCentre.y) > 13.5 && hypot(p.x - flashCentre.x, p.y - flashCentre.y) > 4
}
let body = setStroke(trace(bodyOnly.mirrored(axis: Double(axis))), to: sw)
/// The lens, a true circle on the axis, and the flash, a dot as wide as the stroke.
let lens = stroked(circle(lensCentre, lensR), sw)
let flash = circle(flashCentre, sw / 2)
let outline = body.union(lens).union(flash)

/// The fill: the body's silhouette, the lens's ring and the flash cleared
/// exactly where the outline draws them (the filled drawing's clear ring runs
/// r 8 to 12, as the outline's ring). The filled drawing's 2 px spur under
/// the bottom edge goes with its silhouette.
let filled = silhouette(body).subtracting(lens).subtracting(flash)

print("drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px")
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.camera", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.camera.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawing, [filled, outline], to: "\(previewDir)/outline-over-fill.png")
