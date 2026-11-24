# owner-trace: the owner's drawings to SF Symbols

The shared half of the generators for the owner's glyphs: the gear (#2433), the magnifier (#2456), the bell (#2457), the send glyph (#2416), the camera and gallery (#2458), the bin, microphone and bookmark (#2459), the megaphone (#2415) and the login door (#2434). Each glyph's folder (`dev/symbols/<name>/`) holds its drawings in `source/`, a recipe `source/gen-<name>.swift`, a README and its previews. The map (#2413, `dev/symbols/tabs/map`) was the first one, traced by hand; these follow its rules with a shared tracer.

## What the tracer does (`OwnerTrace.swift`)
1. **Reads the drawing's coverage** (`Raster`), black on transparent, one sample per pixel. Nothing is upscaled.
2. **Makes it exact where the drawing means it to be**, before tracing:
   - `mirrored(axis:)` / `mirroredY(axis:)`: averaged with its mirror image, so left and right (or top and bottom) are exactly alike;
   - `rotated(n, about:)`: averaged over n rotations (the gear's six lobes);
   - `reflectedDiagonal(about:)`: averaged with its reflection about a 45° line (the send glyph's fold).
3. **Traces the ink's edge at half coverage** (marching squares, linear interpolation), smooths it lightly (a Gaussian of 0.7 px along the edge) and joins it with a Catmull-Rom cubic every 1.6 px. No pixel step survives.
4. **Sets the set's stroke**: `setStroke` measures a line drawing's stroke (twice its area over its perimeter) and grows or shrinks it all round to 6.4 template units, the weight of `core.heart`, `core.star`, `core.chats` and `core.map`.
5. **Builds the rest from CoreGraphics' path booleans**: silhouettes (`silhouette`), true circles and straight lines where the recipe makes them exact, gaps and cut-outs (`offset`, `crossed` for a slash).
6. **Writes each symbol in the set's template** (`TemplateWriter`): `dev/symbols/template-head.svg`, three masters with one outline, a 4-unit side margin (#1566), the box's middle on the cap height's middle (`dev/symbols/gen.swift`). Every symbol of a family is placed by one box, so a swap between them never moves the glyph.

## The scale
Each recipe's `scale` (template units per drawing pixel) is chosen so the glyph stands as tall as the system glyph it replaces, as `AppSymbolSizeTests` checks (heights within max(1 pt, 8 %) at 12 pt semibold). `size-check.swift` runs the same comparison on the Mac against the compiled catalogue; the DesignSystem suite is the one that decides.

## Tools
| File | What it does |
|---|---|
| `run.sh` | Runs a recipe with `OwnerTrace.swift` prepended (Swift runs top-level code from one file only). |
| `compile.sh` | Compiles a catalogue with `actool` into a bundle, for the size check and the renderers. |
| `size-check.swift` | Each custom symbol beside the system glyph it replaces, at 12 pt semibold. |
| `render-sheet.swift` | A family's preview sheet from the compiled catalogue: the owner's drawings, each symbol large, then beside the system glyph at 12, 17, 22 and 34 pt and at ultralight, regular and black, light and dark, with hierarchical and palette renders. |
| `render-row.swift` | Glyphs side by side in rows at a few sizes, light and dark: a new symbol among the glyphs it sits beside, or beside the system glyph it replaces. |

## Regenerate a family
```bash
cd dev/symbols/<name>/source
../../owner-trace/run.sh gen-<name>.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
cd ../../owner-trace
./compile.sh ../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets /tmp/symbols
swift size-check.swift /tmp/symbols core.<name>=<system name>
swift render-sheet.swift /tmp/symbols ../<name>/previews/sheet.png "core.<name>" \
  drawing=../<name>/source/<name>-owner.png pair=core.<name>:<system name>
```

## Known limits
- **One outline, three masters**, as the rest of the set: the stroke does not thicken with `.bold`.
- No Draw-On annotations.
