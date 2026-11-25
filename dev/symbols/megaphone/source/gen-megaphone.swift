// Builds core.megaphone.fill and core.megaphone (#2415): the owner's
// megaphone, traced from their 64 px filled drawing; the outline is derived.
// usage: ../../owner-trace/run.sh gen-megaphone.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "megaphone-fill-owner.png")

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.7
let sw: CGFloat = 6.4 / scale

/// The fill, traced as drawn (ink 60 × 48 px at (2, 10)): the horn opening
/// to the right with its rounded mouth, the handle's open loop with its gap
/// inside, and the separate cap on the left. The gap between the cap and the
/// horn is the drawing's (4 px, x 10–14), kept by the trace.
let filled = trace(drawing, sigma: 0.6)

/// The outline, built from the fill's silhouette: each part outlined inward at
/// the set's stroke. The cap (8 px across) and the handle's loop (a 4 px
/// stroke already) are thinner than two strokes, so they stay as they are;
/// the horn becomes a contour.
/// (What shrinking leaves of the cap is a hairline: dropped.)
let inner = joined(subpaths(offset(filled, -sw)).filter { area($0) > 4 })
let outline = filled.subtracting(inner)

/// The cap's gap, measured on the trace at the cap's middle row (y 32).
var x: CGFloat = 9, gapStart: CGFloat = 0
while filled.contains(pt(x, 32)) { x += 0.05 }
gapStart = x
while !filled.contains(pt(x, 32)) { x += 0.05 }
print("cap gap \(fmt(x - gapStart)) px at y 32 (the drawing's: 4)")

let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: filled.boundingBoxOfPath)
w.write("core.megaphone.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
w.write("core.megaphone", [Layer(path: outline, cls: primaryClass, preview: ink)])
overlay(drawing, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawing, [outline], to: "\(previewDir)/derived-outline-over-drawing.png")
