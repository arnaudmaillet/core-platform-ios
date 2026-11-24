# core.search: the owner's magnifier (#2456)

The owner's search glyph replaces the system's `magnifyingglass` everywhere, the search fields' leading glyph included (`SearchFieldStyle`). The drawing, `source/search-owner.svg`, is Lucide's "search" icon (ISC, see `../LUCIDE-LICENSE`).

| Symbol | `AppSymbol` | Replaces |
|---|---|---|
| `core.search` | `.search` | `magnifyingglass` |

One face: no site draws `magnifyingglass.fill`.

## How it is drawn (`source/gen-search.swift`)
1. **Nothing to trace.** The drawing is a circle (`cx 11, cy 11, r 8`) and a 45° line from the lens's edge (16.66, 16.66) to (21, 21), on a 24-unit grid. They are taken as they are.
2. **The set's stroke**, 6.4 units, not the drawing's 2 on 24 (that would be 7.8 units at this scale). The ring reads as thick as `core.settings`'s and `core.heart`'s.
3. **One contour**: the ring and the handle are stroked with round caps and welded by a union, so no seam shows where they meet.
4. **Size: 3.9 units per drawing unit.** At 12 pt semibold it is as tall as `magnifyingglass` (14 pt each; 117 units at 100 pt for both).

## Previews (`previews/`)
- `bar-row.png`: `core.search`, `core.bell`, `core.bell.badge` and `core.settings` beside the bar's other glyphs (`core.chats`, `core.map`, `ellipsis`) and the system glyphs they replace, at 17 and 22 pt.
- `sheet.png`: the drawing, the symbol large, and beside `magnifyingglass` at 12, 17, 22 and 34 pt and at three weights, light and dark.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-search.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
