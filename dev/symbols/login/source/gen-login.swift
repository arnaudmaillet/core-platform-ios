// Builds core.login (#2434): the owner's door, a bracket with an arrow coming
// in, rebuilt from their 512 px line drawing as centre lines stroked at the
// set's weight. (login-icon.svg in the owner's folder is an older version and
// is not the source.)
// usage: ../../owner-trace/run.sh gen-login.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "login-owner.png")

/// Template units per drawing pixel (the drawing is 512 px).
let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 0.17
let sw: CGFloat = 6.4 / scale

// Centre lines, measured on login-owner.png (ink 374 × 512 px at (69, 0),
// stroke about 58 px), then made exact:
// - the bracket is symmetric top to bottom about y 256, its upright on
//   x 412.5, its two ends curling back to the left to round caps at x 269;
// - the arrow's shaft is horizontal on y 256, from its cap at x 97 to the
//   chevron's tip at x 276; the chevron's arms run at 45° to (193, 170) and
//   (193, 342).
// The top cap touches the canvas's edge (y 0): its centre sits at y 30, the
// drawing's 29 px half stroke below the edge, so it was not clipped (the
// ink at y 0 is the cap's top, 11 px wide); both caps are drawn whole.
let mid: CGFloat = 256
let upright: CGFloat = 412.5
let capX: CGFloat = 269, capY: CGFloat = 30
let bend: CGFloat = 170 // where the curl meets the upright
let bracket: CGPath = {
    let p = CGMutablePath()
    p.move(to: pt(capX, capY))
    p.addCurve(to: pt(upright, bend), control1: pt(capX + 100, capY), control2: pt(upright, capY + 30))
    p.addLine(to: pt(upright, 2 * mid - bend))
    p.addCurve(to: pt(capX, 2 * mid - capY), control1: pt(upright, 2 * mid - capY - 30), control2: pt(capX + 100, 2 * mid - capY))
    return p
}()
let tip = pt(276, mid)
let arrow: CGPath = {
    let p = CGMutablePath()
    p.move(to: pt(97, mid)); p.addLine(to: tip)
    p.move(to: pt(tip.x - 83, mid - 86)); p.addLine(to: tip); p.addLine(to: pt(tip.x - 83, mid + 86))
    return p
}()
let glyph = stroked(bracket, sw).union(stroked(arrow, sw))
/// The gap between the arrow's tip and the bracket, in the drawing's
/// proportion (79 px at 512 between the inks; centre lines 136.5 px apart).
print("stroke \(fmt(sw)) px (the drawing's ≈ 58); tip-to-bracket clear \(fmt(upright - tip.x - sw)) px")

/// For the overlay only: the same centre lines at the drawing's own stroke.
let atDrawingsWeight = stroked(bracket, 58).union(stroked(arrow, 58))
let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: glyph.boundingBoxOfPath)
w.write("core.login", [Layer(path: glyph, cls: primaryClass, preview: ink)])
overlay(drawing, [atDrawingsWeight], zoom: 1, to: "\(previewDir)/centre-lines-over-drawing.png")
