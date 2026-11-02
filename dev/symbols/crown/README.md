# core.crown: the gems' glyph (#2071)

The owner's crown replaces the side-view gem (#1128) as the gems' glyph. It is traced from the owner's two 64 px drawings (`source/crown-owner.png`, `source/crown-fill-owner.png`).

| Symbol | `AppSymbol` | Layers |
|---|---|---|
| `core.crown` | `.crown` | 1: the crown and its band, each outlined at the owner's weight |
| `core.crown.fill` | `.crownFilled` (`GemSymbol.glyph`) | 0: the solid crown and band; 1 (`secondary`): a rim inside the edge |

`core.gem` and `core.gem.fill` are removed, together with their `AppSymbol` cases. Every reader goes through `GemSymbol`.

## How it is drawn (`source/gen-crown.swift`)
1. **One silhouette, the outline drawing's.** Where the two drawings disagree, the outline's proportions win, as #2071 asks. The silhouette is the outline drawing with every hole its stroke closes filled.
2. **Two parts: the crown and its band.** The outline's strokes touch between them, so the split is the fill drawing's emptiest row in that gap.
3. **Traced and mirrored.**
   - Each part is measured on rays every 0.25°. The crown's rays leave from low in its body, below the valleys between the peaks; the band's from its middle.
   - Left and right are averaged about the silhouette's axis, so the crown is exactly symmetric.
   - The result is smoothed lightly, then joined by Catmull-Rom cubics every 1°.
4. **The gap is kept.** It is what makes the glyph read as a crown at 12 pt. Its width is the fill drawing's, measured down its middle column (≈3 px), and it is carved out of the crown along the band's own curve.
5. **The outline** grows inward from the fill's edge, at the owner's measured stroke: about 4.8 px, 8.6 % of the width.
6. **Size and place.**
   - The crown takes the retired gem's **area** (`source/gem-fill-reference.svg`), then **×1.08**: at the gem's area it stood 13 pt tall at 12 pt semibold, against the system crown's 14.3, past `AppSymbolSizeTests`' 8 %. It now stands 14.
   - Its box's middle sits on the cap height's middle, as `gen.swift` places the set.
   - The template is the set's: head, three masters with one outline, and a 4-unit side margin (#1566).

## The colour on light grounds
The owner first saw (b) in a deep gold `9E8A00` and found it too dark (2026-11-03). Of six candidates (`previews/light-candidates.png`) they picked a bright gold, `F5C000`: 1.69:1 on white, so the crown always stands beside its amount, and Increased Contrast takes it to `A87C00` (3.79:1). The price text follows the same hue, `8A6400` (5.38:1).

The first round, for the record:
The yellow `FFE600` is 1.27:1 on white, so it cannot be the glyph there alone.
- **(b), shipped (now in the bright gold):** one colour, `Palette.gem`. It is a deep gold `9E8A00` on light grounds (3.45:1 on white) and `FFE600` on dark ones. Every reader that tints the symbol draws it right with no change.
- **(a):** the yellow crown with a deep-gold rim. It is the same symbol, drawn with a palette `[FFE600, 9E8A00]`, since the rim is layer 1. Shipping it means each reader draws `GemSymbol`'s palette instead of a tint.

`previews/rendered-compiled-a-b.png` shows both beside a price at 13, 17 and 22 pt, in light and dark, with a saved star beside a crown. It is rendered from the compiled catalogue by `source/render-compiled.swift`.

## Regenerate
```bash
cd source && swift gen-crown.swift template-head.svg crown-owner.png crown-fill-owner.png gem-fill-reference.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
- `previews/sim-wallet-shop-light-dark.png`: the wallet sheet and the Shop on the simulator, light then dark (option (b)).
