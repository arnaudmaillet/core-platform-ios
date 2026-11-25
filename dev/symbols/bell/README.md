# core.bell: the owner's bell (#2457)

The owner's bell replaces the system's `bell` everywhere. It is traced from the owner's four 64 px drawings in `source/` (`bell-owner.png`, `bell-fill-owner.png`, `bell-slash-owner.png`, `bell-slash-fill-owner.png`); the badged bell is derived.

| Symbol | `AppSymbol` | Replaces | Layers |
|---|---|---|---|
| `core.bell` | `.bell` | `bell` | 0: the bell |
| `core.bell.fill` | `.bellFill` | `bell.fill` | 0 |
| `core.bell.slash` | `.bellSlash` | `bell.slash` | 0 |
| `core.bell.slash.fill` | `.bellSlashFill` | `bell.slash.fill` | 0 |
| `core.bell.badge` | `.bellBadge` | `bell.badge` | 0 (primary): the badge; 1 (secondary): the bell |

## How it is drawn (`source/gen-bell.swift`)
1. **Symmetric**: each drawing is averaged with its mirror image about the outline's axis (x 32), then traced.
2. **The outline** (dome, knob, lip, and the clapper as a cup hanging from the lip) is set to the set's 6.4 units.
3. **The fill shares the outline's dome and lip**: it is the outline's silhouette down to the lip's lowest edge (y 49.2, measured beside the cup), so a swap never moves them. The knob and the clapper keep the filled drawing's look: its wider knob, and its separate half-disc under a clear gap. Both are fitted into the outline's box (the knob lowered by the 1 px it stood above, the half-disc between the set's gap under the lip and the cup's bottom), so the fill's image is the outline's size.
4. **The slash** is measured on the crossed-out outline drawing: a 45° line from (10.4, 10.4) to (53.6, 53.6), stroked at the set's weight with round caps. The same line crosses both slashed glyphs.
   - On the outline it crosses over the contour, as drawn.
   - On the fill a clear band runs along its upper-right side only, as drawn, at the width of the system's `bell.slash.fill` gap (5.6 units at 100 pt).
5. **The badge is derived**: the map's size and gap (r 11.6, gap 4.27 units, #2413), its centre on the dome's top-right shoulder, the bell cut away round it with rounded ends. **The badge is layer 0 and primary, the bell layer 1**, as the system's `bell.badge`: `NotificationsBell`'s palette `[TabGlyph.badgeTint, .label]` puts the accent on the badge and the ink on the bell, unchanged.
6. **Size: 1.53 units per drawing pixel.** At 12 pt semibold the bell is 15 pt tall, as `bell` and `bell.fill`; the slashed and badged bells keep the plain bell's box (the system's grow by a point).

## Previews (`previews/`)
- `bar-row.png`: `core.search`, `core.bell`, `core.bell.badge` and `core.settings` beside the bar's other glyphs (`core.chats`, `core.map`, `ellipsis`) and the system glyphs they replace, at 17 and 22 pt.
- `sheet.png`: the four drawings, the five symbols large, each beside the system's at 12, 17, 22 and 34 pt and at three weights, light and dark, with hierarchical and palette renders.
- `outline-over-fill.png`: the outline laid over the fill.
- `traced-over-*.png`: each symbol over its drawing.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-bell.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
