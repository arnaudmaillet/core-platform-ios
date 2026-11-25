// Builds core.bell, .fill, .slash, .slash.fill and .badge (#2457): the owner's
// bell, traced from their four 64 px drawings; the badge is derived.
// usage: ../../owner-trace/run.sh gen-bell.swift <template-head.svg> <Symbols.xcassets> <previews dir>
let args = CommandLine.arguments
let headPath = args[1], outDir = args[2], previewDir = args[3]

let drawing = Raster(png: "bell-owner.png")
let drawingFill = Raster(png: "bell-fill-owner.png")
let drawingSlash = Raster(png: "bell-slash-owner.png")
let drawingSlashFill = Raster(png: "bell-slash-fill-owner.png")

/// The bell is symmetric: each drawing is averaged with its mirror image
/// about the outline's axis, the middle of its ink box (52 px wide at x 6).
let axis = Double(drawing.inkBox.midX)

/// Template units per drawing pixel: as tall as the system's `bell`
/// (AppSymbolSizeTests, within 8 %).
let scale: CGFloat = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1.53
let sw: CGFloat = 6.4 / scale

/// The outline: dome, knob and lip in one stroke, the clapper a cup hanging
/// from the lip, at the set's stroke.
let outline = setStroke(trace(drawing.mirrored(axis: axis)), to: sw)

/// The lip's lowest edge, measured beside the cup (11 px off the axis); the
/// cup hangs below it.
let lipBottom: CGFloat = {
    let body = silhouette(outline)
    var y: CGFloat = 40
    while body.contains(pt(CGFloat(axis) + 11, y + 0.05)) { y += 0.05 }
    return y
}()
/// The filled drawing's knob ends above y 8 and its clapper starts below y 50.
let tracedFill = trace(drawingFill.mirrored(axis: axis))
let outlineBox = outline.boundingBoxOfPath
/// Both stand inside the outline's box, so the fill's image is the outline's
/// size and a swap never moves the bell: the knob is lowered by the 1 px it
/// stands above the outline's, and the half-disc is fitted between the set's
/// gap under the lip and the cup's bottom.
let rawKnob = tracedFill.intersection(rect(0, 0, 64, 8))
let fillKnob = transformed(rawKnob, CGAffineTransform(translationX: 0, y: outlineBox.minY - rawKnob.boundingBoxOfPath.minY))
let rawClapper = tracedFill.intersection(rect(0, 51, 64, 64)) // the filled drawing: lip to y 48, half-disc from y 53
let clapperTop = lipBottom + 32.0 / 3 * 0.4 / scale - 0.5
let cb = rawClapper.boundingBoxOfPath
let fillClapper = transformed(rawClapper, CGAffineTransform(translationX: 0, y: clapperTop)
    .scaledBy(x: 1, y: (outlineBox.maxY - clapperTop) / cb.height).translatedBy(x: 0, y: -cb.minY))
/// The fill: the outline's dome and lip, solid (so a swap never moves them),
/// with the filled drawing's wider knob and its separate half-disc clapper.
let filled = silhouette(outline).intersection(rect(0, 0, 64, lipBottom)).union(fillKnob).union(fillClapper)

/// The slash: measured on the crossed-out outline drawing, at 45°, at the
/// set's stroke with round caps. The same line in both crossed-out glyphs.
let (s0, s1) = slashLine(crossed: drawingSlash, plain: drawing)
/// The clear band along the filled slash's upper-right side: the system's
/// bell.slash.fill's, 5.6 units.
let slashGap: CGFloat = 5.6 / scale
let outlineSlash = crossed(outline, s0, s1, sw: sw, gap: 0)
let filledSlash = crossed(filled, s0, s1, sw: sw, gap: slashGap)

/// The badge, derived: the map's size and gap (r 11.6, gap 4.27 units), its
/// centre on the dome's shoulder, the bell cut away round it by a clear ring.
/// Layer 0 is the badge and layer 1 the bell, as the system's bell.badge,
/// so NotificationsBell's palette (badge tint, then the bell's ink) holds:
/// a palette's first colour goes to the primary layer, the badge.
let badgeR: CGFloat = 11.6 / scale, badgeGap: CGFloat = 32.0 / 3 * 0.4 / scale
let badgeCentre = pt(CGFloat(axis) + 15.5, 13.5)
let clearance = circle(badgeCentre, badgeR + badgeGap)
let opened = outline.subtracting(clearance)
let near = circle(badgeCentre, badgeR + badgeGap + 1.5 * sw)
/// The cut ends are rounded, as on the map's badge.
let rounded: CGPath = { let e = offset(opened, -sw * 0.47); return offset(e, sw * 0.47) }()
let badgedBell = opened.subtracting(near).union(rounded.intersection(near))

print("lip bottom \(fmt(lipBottom)); slash \(fmt(s0.x)),\(fmt(s0.y)) → \(fmt(s1.x)),\(fmt(s1.y)); drawing stroke \(fmt(strokeWidth(trace(drawing)))) px → \(fmt(sw)) px")

let w = TemplateWriter(headPath: headPath, outDir: outDir, previewDir: previewDir, scale: scale, box: outline.boundingBoxOfPath)
w.write("core.bell", [Layer(path: outline, cls: primaryClass, preview: ink)])
w.write("core.bell.fill", [Layer(path: filled, cls: primaryClass, preview: ink)])
w.write("core.bell.slash", [Layer(path: outlineSlash, cls: primaryClass, preview: ink)])
w.write("core.bell.slash.fill", [Layer(path: filledSlash, cls: primaryClass, preview: ink)])
let badgeFirst = "monochrome-0 multicolor-0:systemRedColor hierarchical-0:primary SFSymbolsPreviewFF3B30"
let bellSecond = "monochrome-1 multicolor-1:tintColor hierarchical-1:secondary SFSymbolsPreview000000"
w.write("core.bell.badge", [
    Layer(path: circle(badgeCentre, badgeR), cls: badgeFirst, preview: red),
    Layer(path: badgedBell, cls: bellSecond, preview: ink),
])
overlay(drawing, [outline], to: "\(previewDir)/traced-over-outline.png")
overlay(drawingFill, [filled], to: "\(previewDir)/traced-over-fill.png")
overlay(drawingSlash, [outlineSlash], to: "\(previewDir)/traced-over-slash.png")
overlay(drawingSlashFill, [filledSlash], to: "\(previewDir)/traced-over-slash-fill.png")
overlay(drawing, [filled, outline], to: "\(previewDir)/outline-over-fill.png")
