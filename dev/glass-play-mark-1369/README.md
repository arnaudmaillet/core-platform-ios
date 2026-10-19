# Glass play mark prototype (#1369)

DEBUG only, behind `-glass-play-mark [regular|clear|tinted]` (`PostGrid/Cells/GlassPlayMark.swift`).
Shot on the iPhone 18 Pro simulator (iOS 27), mock account, paused fullscreen posts
(`-open-feed -snap-start-index N -snap-start-paused`).

## Legibility (`legibility-grid.png`)
Columns, left to right: today's white glyph, glass `.clear`, glass `.regular`, glass `.regular` tinted white 22 %.
Rows, top to bottom: a bright frame (index 3, white dress), a dark frame (index 8), a busy frame (index 1, grid + caption text).

| Frame | Today | Clear | Regular | Tinted |
|---|---|---|---|---|
| Bright | clear | nearly invisible | legible (grey) | legible |
| Dark | very clear | faint | faint | faint, a little better |
| Busy | legible | refracts the text, outline readable | frosted, distinct | frosted, distinct |

## Motion
- `motion-disappear.png` / `motion-appear.png` (30 fps): the triangle scales out while the glass dematerialises (`Glass.identity`), and bounces in while it materialises. No flash, no pop, and no alpha on the glass.
- `motion-reduce-motion-*.png` (30 fps, `-display.reducesMotion YES`): it materialises and dematerialises in place, with no scale.
