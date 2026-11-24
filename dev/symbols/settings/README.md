# core.settings: the owner's gear (#2433)

The owner's gear, six rounded lobes round a ring, replaces the system's `gearshape` and `gear` everywhere: one gear for the whole app, the rows that open the iPhone's own Settings included. It is traced from the owner's two 64 px drawings, `source/settings-owner.png` (outline) and `source/settings-fill-owner.png` (filled), by `source/gen-settings.swift` with the shared tracer (`../owner-trace`).

| Symbol | `AppSymbol` | Replaces |
|---|---|---|
| `core.settings` | `.settings` | `gearshape`, `gear` |
| `core.settings.fill` | `.settingsFill` | `gearshape.fill` |

## How it is drawn
1. **The six lobes are identical and 60° apart**: the outline drawing is averaged over its six rotations about the gear's centre (the middle of its 50 × 52 px ink box, (32, 32)), then traced.
2. **The ring is a true circle** on the gear's centre: its centre line is the mean of the traced ring's edges, r 8 px, stroked at the set's 6.4 units.
3. **The lobed contour is set to the set's stroke**: the drawing's 4.1 px becomes 4.2 px (6.4 units at 1.52 units per pixel).
4. **The fill is the outline's silhouette**, so selecting the tab never moves or resizes the gear, with the hole on the ring's centre line, r 8 px.
   - ⚠️ The issue asked for the hole at the ring's outer edge (r 10 px). The filled drawing's own hole measures r 7.9 px, the ring's centre line; the outer edge would open it a quarter wider than the owner drew. The drawing wins here; it is one line in the generator.
5. **Size: 1.52 units per drawing pixel.** At 12 pt semibold the gear is as tall as `gearshape` (15 pt each). In the tab bar (17 pt, large) it stands 27 pt, as `gearshape` did, beside the map's 24 (`TabFacesTests` allows 3). At 1.64 it matched `gearshape` at 100 pt but stood 4.3 pt above the map in the tab bar.

## Previews (`previews/`)
- `sheet.png`: the drawings, both symbols large, each beside `gearshape` / `gearshape.fill` at 12, 17, 22 and 34 pt and at three weights, light and dark, with hierarchical and palette renders.
- `six-lobes.png`: the six lobes overlaid, rotated onto one another.
- `traced-over-outline.png`, `traced-over-fill.png`: each symbol over the owner's drawing.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-settings.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
