# core.megaphone: a channel's mark (#2415)

The owner's megaphone replaces the system's `megaphone` and `megaphone.fill` everywhere a channel is marked (#2215, #2230). It is traced from the owner's 64 px filled drawing, `source/megaphone-fill-owner.png`; there is no outline drawing, so the outline is built from the fill.

| Symbol | `AppSymbol` | From |
|---|---|---|
| `core.megaphone.fill` | `.megaphoneFill` | the drawing, traced |
| `core.megaphone` | `.megaphone` | built from the fill's silhouette |

The channel's glyph is named in one place, `AppSymbol.megaphoneFill`: the three string constants (`ChannelEmbedCopy.channelSymbol`, `ConversationRowView.channelBadgeSymbol`, `ConversationInfoHeader.channelSymbol`) are gone; `ChannelEmbedCopy` keeps a private alias of it for its unavailable-card switch.

## How it is drawn (`source/gen-megaphone.swift`)
1. **The fill is traced as drawn** (ink 60 × 48 px at (2, 10)): the horn opening to the right with its rounded mouth, the handle's open loop with its gap, and the separate cap on the left. **The gap between the cap and the horn is kept at the drawing's 4 px**, measured on the trace at the cap's middle row: it is what makes it read as a megaphone at 12 pt.
2. **The outline is built from the fill**: each part outlined inward at the set's 6.4 units. The cap (8 px across) and the handle's loop (a 4 px stroke already) are thinner than two strokes, so they stay as drawn; the horn becomes a contour. Both stand in the same box.
3. **Size: 1.7 units per drawing pixel.** At 12 pt semibold it is 15 pt tall, as `megaphone.fill` (122 units at 100 pt against 125).

## The outline, for the owner
Two sites draw an outline today: the "+" menu's New Channel and the empty Channels tab. `sheet.png` shows the outline beside the fill; if the outline doesn't hold, those two sites take the fill.

## Previews (`previews/`)
- `sheet.png`: the drawing, both symbols large, beside `megaphone` / `megaphone.fill` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `cap-gap.png`: the cap's gap close up, the trace over the drawing.
- `traced-over-fill.png`, `derived-outline-over-drawing.png`.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-megaphone.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
