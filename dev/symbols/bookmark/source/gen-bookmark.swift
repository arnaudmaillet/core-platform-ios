// Builds core.bookmark, .fill and .slash (#2459): the owner's bookmark, traced
// from their two 64 px drawings; the slash is the bell's (#2457).
// usage: ../../owner-trace/run.sh gen-bookmark.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "bookmark-owner.png")
let drawingFill = Raster(png: "bookmark-fill-owner.png")
let axis = Double(drawing.inkBox.midX)

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.72
let sw: CGFloat = 6.4 / scale

/// The domed top, the straight sides and the soft notch, mirrored about the
/// axis, at the set's stroke.
let outline = setStroke(trace(drawing.mirrored(axis: axis)), to: sw)
/// The fill is the outline's silhouette (the two drawings share their ink
/// box; where they disagree, the outline wins), so a swap never moves it.
let filled = silhouette(outline)

/// The slash: the bell's (core.bell.slash, #2457), at 45° with the set's
/// stroke and round caps, as long as the bell's (43.2 px across) where the
/// box allows, centred on the bookmark's box.
let box = outline.boundingBoxOfPath
let half = min(43.2 / 2, box.width / 2 - sw / 2, box.height / 2 - sw / 2)
let slashed = crossed(outline, pt(box.midX - half, box.midY - half), pt(box.midX + half, box.midY + half), sw: sw, gap: 0)

print("drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px")
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: box)
w.write("core.bookmark", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.bookmark.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
w.write("core.bookmark.slash", [Layer(path: slashed, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
