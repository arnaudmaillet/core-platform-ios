// Builds core.mic.fill and core.mic (#2459): the owner's microphone, traced
// from their 64 px filled drawing; the outline is derived from it.
// usage: ../../owner-trace/run.sh gen-mic.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "mic-fill-owner.png")
let axis = Double(drawing.inkBox.midX)
let even = drawing.mirrored(axis: axis)

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.66
let sw: CGFloat = 6.4 / scale

/// The capsule (y 8–49) with its three slots, and the cradle, a U-shaped arc
/// under it (no stand or foot: the owner's design). Mirrored about the axis,
/// so the outer slots are alike and the middle one keeps its extra length.
let capsuleFill = trace(even.masked { $0.y < 50 && $0.x > 13 && $0.x < 51 })
let cradle = setStroke(trace(even.masked { !($0.y < 50 && $0.x > 13 && $0.x < 51) }), to: sw)
let filled = capsuleFill.union(cradle)

/// The outline, derived as the megaphone's was (#2415): the capsule's
/// silhouette outlined inward at the set's stroke, its three slots as short
/// strokes on the drawing's slot centres (x 24, 32, 40; the middle one
/// longer), the cradle as it is.
let capsule = silhouette(capsuleFill)
let ring = capsule.subtracting(offset(capsule, -sw))
let slotStrokes = [stroked(line(pt(24, 26.5), pt(24, 31.5)), sw),
                   stroked(line(pt(32, 24.5), pt(32, 33.5)), sw),
                   stroked(line(pt(40, 26.5), pt(40, 31.5)), sw)]
let outline = slotStrokes.reduce(ring) { $0.union($1) }.union(cradle)

let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: filled.boundingBoxOfPath)
w.write("core.mic.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
w.write("core.mic", [Layer(path: outline, cls: primaryClass, preview: ink)])
overlay(drawing, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawing, [outline], to: "\(previewDir)/derived-outline-over-drawing.png")
