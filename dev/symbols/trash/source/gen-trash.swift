// Builds core.trash and core.trash.fill (#2459): the owner's bin, traced from
// their 64 px outline drawing; the fill is derived.
// usage: ../../owner-trace/run.sh gen-trash.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "trash-owner.png")
/// Symmetric about the middle of its ink box (44 px wide at x 10).
let axis = Double(drawing.inkBox.midX)

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.6
let sw: CGFloat = 6.4 / scale

/// The lid with its arched handle, the tub, and three slots, mirrored about
/// the axis (so the outer slots are alike and evenly spaced), at the set's
/// stroke.
let outline = setStroke(trace(drawing.mirrored(axis: axis)), to: sw)
/// The slots: the loops that lie inside the tub (x 19–45, y 24–47).
let slots = joined(subpaths(outline).filter {
    let b = $0.boundingBoxOfPath
    return b.minX > 19 && b.maxX < 45 && b.minY > 22 && b.maxY < 49
})

/// The fill, derived: the lid and the tub solid, the three slots cut out
/// where the outline draws them, the handle an open arch over the lid.
let tub = silhouette(outline.intersection(rect(0, 13, 64, 64)))
let filled = outline.union(tub).subtracting(slots)

print("drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px; slots \(subpaths(slots).count / 2)")
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.trash", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.trash.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawing, [filled, outline], to: "\(previewDir)/outline-over-fill.png")
