# core.gallery: the owner's gallery (#2458)

The owner's two stacked photos replace the system's `photo.on.rectangle`, `photo.on.rectangle.angled` and `photo.badge.plus` everywhere. The single picture `photo` (one image, not a gallery) stays. It is traced from the owner's two 64 px drawings, `source/gallery-owner.png` (outline) and `source/gallery-fill-owner.png` (filled).

| Symbol | `AppSymbol` | Replaces |
|---|---|---|
| `core.gallery` | `.gallery` | `photo.on.rectangle`, `photo.on.rectangle.angled`, `photo.badge.plus` |
| `core.gallery.fill` | `.galleryFill` | (no site yet: a selected or prominent state) |

## How it is drawn (`source/gen-gallery.swift`)
1. **The front frame** (x 0–49, y 4–49) is symmetric both ways about its middle (24.5, 26.5): its band is cut out of the drawing, averaged with its mirror images left to right and top to bottom, traced and set to the set's 6.4 units.
2. **The back frame is the same frame**, 10 px right and 8 px down. Only what lies past the set's gap (4.27 units) round the front frame shows: its right and bottom edges.
3. **The hill** is traced as drawn (smooth cubics) and set to the set's stroke. **The sun is a true circle**, 6 px across: the drawing's sun is a solid dot, not a ring.
4. **The fill** is the front frame solid with the hill and the sun cut out where the outline draws them (the hill's outer edge; the filled drawing clears the same), and the same back band. Swapping never moves the glyph.
5. **Size: 1.52 units per drawing pixel**, taken on the height: at 12 pt semibold it is 15 pt tall, as `photo.on.rectangle` (123 units at 100 pt against 122). The drawing touched its file's left edge; the template's margins place it.

## Previews (`previews/`)
- `sheet.png`: the drawings, both symbols large, beside `photo.on.rectangle` and `.angled` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `outline-over-fill.png`: the outline laid over the fill. `traced-over-*.png`: each over its drawing.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-gallery.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
