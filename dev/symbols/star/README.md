# core.star: the owner's plump star (#2074)

The save star, `core.star` (outline, not saved) and `core.star.fill` (saved, in `SaveStar`'s gold). It is traced from the owner's two 64 px drawings (`source/star-owner.png`, `source/star-fill-owner.png`). It replaces Phosphor's `star` / `star-fill` (#1128) **under the same names**, so `SaveStar`, `AppSymbol` and every reader are untouched. `SymbolContractTests` keeps guarding them.

## How it is drawn (`source/gen-star.swift`)
1. **Traced, then made symmetric.**
   - The fill drawing's edge is measured along rays from its centroid, every 0.25°, to a hundredth of a pixel (alpha 0.5).
   - The five-fold axis is found (−90.05°: the top tip points up).
   - The ten half-sectors are averaged into one tip-to-valley profile, so no tip is a pixel off. The drawing's own tips varied from 26.2 to 27.4 px.
2. **Smooth.** The profile is sampled every 2° and joined by Catmull-Rom cubics, so the curve is smooth and closed, with no corners.
3. **One silhouette.** The fill is the traced shape. The outline is that shape with a stroke grown **inward** from its edge, so the outline's outer edge is the fill's, and a save never makes the star jump.
4. **Optical size.** The plump star fills more of its box than Phosphor's.
   - It is scaled to the **same area** as Phosphor's filled star, as that star was placed (`source/phosphor-star-fill-reference.svg`).
   - It is then made **×1.05** taller (`heightNudge`). At equal area it stood 13.7 pt tall at 12 pt semibold, against the system star's 15, past `AppSymbolSizeTests`' 8 %; it now stands about 14.3. That is ×1.602 from the 64 px drawing.
   - Its centroid sits on Phosphor's, so it stays on the text's line. The plump star is wider at the bottom, so centring its box would sit it high.
   - It ends 83.1 wide against Phosphor's 87.6, with 10 % more ink.
5. **The template.** The set's head, three masters with one outline, and a 4-unit side margin (#1566).

## The outline's weight: (a) or (b)
| | stroke / star width | in the template |
|---|---|---|
| **(b), shipped**: the set's weight, Phosphor's ratio (16 on 256) | 6.9 % | 5.73 |
| **(a)**: the owner's drawing, measured | 9.35 % | 7.77 |

`previews/rendered-compiled-a-b.png` shows today's star, (b) and (a) beside the heart and the repost, at 13, 15, 17 and 22 pt, in light and dark. It is rendered from the compiled catalogues.

To ship (a), regenerate with `STROKE=owner`:

```bash
cd source && STROKE=owner swift gen-star.swift template-head.svg star-fill-owner.png star-owner.png \
  phosphor-star-fill-reference.svg ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```

Drop `STROKE=owner` for (b).

## Known limits
- **One outline, three masters**, as in the rest of the set: the star does not follow `.semibold`. Its masters could be strokes of three widths on the same points, but CoreGraphics' stroking does not keep a point structure, so they would not interpolate. Nothing on screen needs it: the capsule's star at 15 pt semibold sits beside a heart that ignores the weight too.
- No small-size cut: at 13 pt the tips and the inner bows stay open (see the previews).

## Previews
- `previews/rendered-compiled-a-b.png`: from `actool`'s output via `source/render-compiled.swift`, one process per catalogue (AppKit caches custom symbols by name).
- `previews/sim-column-unsaved-saved.png`: the full-screen post's column on the simulator, before and after a save (the gold fill).
- `previews/core.star*.png`: the generator's flat previews.
