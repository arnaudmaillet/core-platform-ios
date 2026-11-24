# core.camera: the owner's camera (#2458)

The owner's camera replaces the system's `camera` and `camera.fill` everywhere (the filters' `camera.filters` and `video.slash.fill` stay). It is traced from the owner's two 64 px drawings, `source/camera-owner.png` (outline) and `source/camera-fill-owner.png` (filled).

| Symbol | `AppSymbol` | Replaces |
|---|---|---|
| `core.camera` | `.camera` | `camera` |
| `core.camera.fill` | `.cameraFill` | `camera.fill` |

## How it is drawn (`source/gen-camera.swift`)
1. **The body is symmetric** about x 32: the drawing without its lens and flash, its 1 px nick in the bottom edge's middle filled, averaged with its mirror image, traced, and set to the set's 6.4 units. The hump is centred.
2. **The lens is a true circle** on the axis at (32, 34): the drawing's ring runs r 8 to r 12, so its centre line is r 10, stroked at the set's weight.
3. **The flash is a dot** at the top left, (16, 24), as wide as the stroke: the drawing's flash is a 4 px dot, not a dash.
4. **The fill is the body's silhouette with the lens's ring and the flash cleared exactly where the outline draws them.** The filled drawing's clear ring runs r 8 to 12 too, around a solid disc; its 2 px spur under the bottom edge goes with the outline's silhouette. Swapping never moves the glyph.
5. **Size: 1.6 units per drawing pixel.** At 12 pt semibold it is 14 pt tall, as `camera` (118 units at 100 pt against 114). It is narrower than the system's (122 units wide against 146): the owner's camera is squarer.

## Previews (`previews/`)
- `sheet.png`: the drawings, both symbols large, beside `camera` / `camera.fill` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `outline-over-fill.png`: the outline laid over the fill. `traced-over-*.png`: each over its drawing.
- `create-menu-row.png`: the camera and the gallery side by side, as in the Create menu, with the system's pair.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-camera.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
