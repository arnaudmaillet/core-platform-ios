# core.mic: the owner's microphone (#2459)

The owner's microphone, a capsule with three slots on a U-shaped cradle and **no stand** (the owner's design), replaces the system's `mic` and `mic.fill` everywhere. It is traced from the owner's 64 px filled drawing, `source/mic-fill-owner.png`; there is no outline drawing, so the outline is derived, as the megaphone's was (#2415).

| Symbol | `AppSymbol` | Replaces | From |
|---|---|---|---|
| `core.mic.fill` | `.micFill` | `mic.fill` | the drawing |
| `core.mic` | `.mic` | `mic` | derived |

## How it is drawn (`source/gen-mic.swift`)
1. **Symmetric**: the drawing is averaged with its mirror image about x 32, so the outer slots are alike and the middle one keeps its extra length; then the capsule (with its slots) is traced as drawn and the cradle set to the set's 6.4 units.
2. **The outline, derived**: the capsule's silhouette outlined inward at the set's stroke, its three slots as short strokes on the drawing's slot centres (x 24, 32, 40; the middle one longer), and the same cradle. Same box as the fill.
3. **Size: 1.66 units per drawing pixel.** At 12 pt semibold it is 15 pt tall against `mic`'s 16 (125 units at 100 pt against 128). It is wider than the system's (117 units against 106): the owner's capsule is rounder and the cradle wider.

## Previews (`previews/`)
- `sheet.png`: the drawing, both symbols large, beside `mic` / `mic.fill` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `derived-faces.png`: the derived faces (`core.trash.fill`, `core.mic`, `core.bookmark.slash`) beside the drawn ones, at 17 and 22 pt, light and dark. If the owner rejects a derived face on the device, its sites take the drawn face (the bin's outline, the microphone's fill, the filled bookmark for Unpin).
- `traced-over-fill.png`, `derived-outline-over-drawing.png`.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-mic.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
