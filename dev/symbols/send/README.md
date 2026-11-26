# core.send: the owner's send glyph (#2416)

The owner's send glyph, a rounded plane pointing to the top right, replaces **every share and forward glyph**: the system's `arrowshape.turn.up.forward` and `.right`, Phosphor's export (`core.share`, retired) and the system's `square.and.arrow.up`. Share has one icon app-wide, and `PostActionSymbol.share` is its one name. It is traced from the owner's two 64 px drawings, `source/send-owner.png` (outline) and `source/send-fill-owner.png` (filled).

| Symbol | `AppSymbol` | Replaces |
|---|---|---|
| `core.send` | `.send` (`PostActionSymbol.share`) | `arrowshape.turn.up.forward`, `arrowshape.turn.up.right`, `square.and.arrow.up`, `core.share` |
| `core.send.fill` | `.sendFill` | (no site yet: for a glyph on a coloured disc or a selected state) |

## How it is drawn (`source/gen-send.swift`)
1. **Symmetric about its fold**: the drawing is averaged with its reflection about the line x + y = 64 (the fold's stroke centres all sit on it, measured row by row), through the pinch at the bottom left and the tip at the top right.
2. **The contour** (the drawing without its fold) is traced and set to the set's 6.4 units. The three corners keep the owner's rounding, and the pinch where the fold meets the contour stays: it is what makes it a plane.
3. **The fold is a straight line on the axis** with round ends, from inside the contour at the pinch to where the drawing's fold ends, short of the tip.
4. **The fill is the contour's silhouette** with the fold knocked out at the filled drawing's gap (3.4 px), from past the pinch to the fold's end, as drawn. Swapping one for the other never moves the glyph.
5. **Size: 1.6 units per drawing pixel.** At 12 pt semibold it is 14 pt tall, as `arrowshape.turn.up.forward`; at 100 pt it stands 114 units, between `core.heart` (110) and `core.star` / `core.repost` (120), so it reads the same size in a row with them. It is shorter than `square.and.arrow.up` (140), so no menu row or card line grows where it replaces that one.

## Previews (`previews/`)
- `sheet.png`: the drawings, both symbols large, then beside `arrowshape.turn.up.forward` and `square.and.arrow.up` at 12, 17, 22 and 34 pt and at three weights, light and dark, with hierarchical and palette renders.
- `row-heart-star-repost.png`: in a row with `core.heart`, `core.star` and `core.repost` at 12, 17 and 22 pt.
- `traced-over-*.png`, `outline-over-fill.png`: each symbol over its drawing, and the outline over the fill.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-send.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- **Alone in a round bubble it is drawn larger and moved (#2581, `ShareBubbleGlyph` in DesignSystem).** A diagonal plane fills less of its box than a heart, and its ink's centre of mass sits up and right of its box's centre. The template keeps the glyph centred by its box: a symbol image is as tall as its ink, so lowering the glyph in the template only moves its baseline, and the horizontal share (about 7 units) is past the 4-unit side margin. The bubbles (the action column, the composer's slot, the share sheet's chip) set the size and the move; bar items, menus and text draw the glyph as it is.
- The owner judges it on a device after the merge.
