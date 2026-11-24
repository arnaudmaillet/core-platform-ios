// Builds core.send and core.send.fill (#2416): the owner's send glyph, a
// rounded plane pointing to the top right, traced from their two 64 px drawings.
// usage: ../../owner-trace/run.sh gen-send.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "send-owner.png")
let drawingFill = Raster(png: "send-fill-owner.png")

/// The plane is symmetric about its fold: the line x + y = 64 on the drawing
/// (the fold's stroke centres all sit on it, measured row by row), through
/// the pinch and short of the contour at the tip.at the bottom left and the tip at the top right.
let c = pt(32, 32)
let u = pt(sqrt(0.5), -sqrt(0.5)) // along the fold, toward the tip
func along(_ p: CGPoint) -> CGFloat { (p.x - c.x) * u.x + (p.y - c.y) * u.y }
func onAxis(_ d: CGFloat) -> CGPoint { pt(c.x + u.x * d, c.y + u.y * d) }
func offAxis(_ p: CGPoint) -> CGFloat { abs(p.x + p.y - 64) / sqrt(2) }

let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.6
let sw: CGFloat = 6.4 / scale

/// The fold, apart from the contour: the ink within 2.6 px of the axis, past
/// the pinch and short of the contour at the tip.
func isFold(_ p: CGPoint) -> Bool { offAxis(p) < 2.6 && along(p) > -2.3 && along(p) < 18 }
var foldEnd: CGFloat = -100
for y in 0..<drawing.h { for x in 0..<drawing.w where drawing[x, y] > 0.5 {
    let p = pt(CGFloat(x) + 0.5, CGFloat(y) + 0.5)
    if isFold(p) { foldEnd = max(foldEnd, along(p)) }
} }
/// The fold's centre line: from inside the contour at the pinch to its round
/// end, short of the tip as drawn (the ink's end, less half the drawing's
/// 4 px stroke and half a pixel).
let foldTop = onAxis(foldEnd + 0.5 - 2), foldFoot = onAxis(-4)

/// The contour: the drawing without its fold, made symmetric about the axis,
/// at the set's stroke, the three corners keeping the owner's rounding.
let contourOnly = drawing.masked { !isFold($0) }
let contour = setStroke(trace(contourOnly.reflectedDiagonal(about: c)), to: sw)
let fold = stroked(line(foldFoot, foldTop), sw)
let outline = contour.union(fold)

/// The fill: the contour's silhouette, the fold knocked out at the filled
/// drawing's gap (3.4 px across) from past the pinch to the fold's end.
let gapW: CGFloat = 3.4
let filled = silhouette(contour).subtracting(stroked(line(onAxis(-14), foldTop), gapW))

print("fold \(fmt(foldFoot.x)),\(fmt(foldFoot.y)) → \(fmt(foldTop.x)),\(fmt(foldTop.y)); drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px")
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.send", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.send.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawing, [filled, outline], to: "\(previewDir)/outline-over-fill.png")
