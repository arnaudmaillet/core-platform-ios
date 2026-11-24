// Builds core.search (#2456): the owner's magnifier, from search-owner.svg
// (Lucide's "search", ISC, see dev/symbols/LUCIDE-LICENSE). Nothing to trace:
// the drawing is a circle and a line on a 24-unit grid, taken as they are.
// usage: ../../owner-trace/run.sh gen-search.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

// The drawing (search-owner.svg): `circle cx=11 cy=11 r=8` and `m21 21-4.34-4.34`,
// stroke 2, round caps and joins. The handle starts on the lens's edge
// (11 + 8/√2 = 16.66) and runs 6.1 units at 45°.
let lensCentre = pt(11, 11), lensR: CGFloat = 8
let handleFrom = pt(16.66, 16.66), handleTo = pt(21, 21)

/// Template units per drawing unit: the magnifier stands as tall as the
/// system's `magnifyingglass` (AppSymbolSizeTests, within 8 %).
let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 3.9
/// The set's stroke, 6.4 units, not the drawing's 2 on 24.
let sw: CGFloat = 6.4 / scale

/// One contour: the ring and the handle welded (a union), round caps kept.
let glyph = stroked(circle(lensCentre, lensR), sw).union(stroked(line(handleFrom, handleTo), sw))
print("stroke \(fmt(sw)) drawing units (the drawing's: 2)")

let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: glyph.boundingBoxOfPath)
w.write("core.search", [Layer(path: glyph, cls: primaryClass, preview: ink)])
