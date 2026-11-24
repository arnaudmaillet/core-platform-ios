# core.login: the guest's Sign in bubble (#2434)

The owner's door, a bracket with an arrow coming in, replaces the system's `person.crop.circle.badge.plus` on a guest's **Sign in** bubble (the tab bar's detached bubble, the "+" for a member). The other `person.crop.circle.badge.plus` uses ("add a person", "create an account") are unchanged. It is rebuilt from the owner's line drawing `source/login-owner.png` (512 px, despite its name). The older `login-icon.svg` in the owner's folder is not the source.

| Symbol | `AppSymbol` |
|---|---|
| `core.login` | `.login` (`CreateTabItem.signInSymbol`) |

One face: the bubble's selection is vetoed (it opens the sign-in), so it needs no outline / fill pair.

## How it is drawn (`source/gen-login.swift`)
1. **Centre lines, measured, then made exact**, stroked at the set's 6.4 units with round caps and joins (the drawing's own stroke is about 58 px, 11 %):
   - the bracket is symmetric top to bottom about y 256: its upright on x 412.5, its two ends curling back to the left to round caps at x 269;
   - the arrow's shaft is horizontal on y 256, the bracket's vertical middle, from its cap at x 97 to the chevron's tip at x 276; the chevron is symmetric about the shaft, its arms at 45°.
2. **The gap between the arrow's tip and the bracket** keeps the drawing's proportion: the centre lines stand 136.5 px apart, as drawn.
3. **The caps that touch the canvas's edges were not clipped**: the top cap's centre sits at y 30, the drawing's half stroke below the edge, and the ink in the top row is the cap's top, 11 px wide. Both caps are drawn whole, as round as the arrow's (`previews/centre-lines-over-drawing.png`, at the drawing's own weight).
4. **Size: 0.17 units per drawing pixel.** At 12 pt semibold it is 15 pt tall against `person.crop.circle.badge.plus`'s 16 (125 units at 100 pt against 127); `previews/tab-bubbles.png` shows it beside the "+" and the tab glyphs.

## Previews (`previews/`)
- `sheet.png`: the drawing, the symbol large, beside `person.crop.circle.badge.plus` at 12, 17, 22 and 34 pt and at three weights, light and dark.
- `tab-bubbles.png`: beside `person.crop.circle.badge.plus`, the "+" and the tab glyphs at 17 pt.
- `centre-lines-over-drawing.png`: the centre lines at the drawing's weight over the drawing, the arrow's tip and the bracket included.

## Regenerate
```bash
cd source
../../owner-trace/run.sh gen-login.swift ../../template-head.svg \
  ../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```
`previews/sheet.png` is rendered from the compiled catalogue by `../owner-trace/render-sheet.swift` (see `../owner-trace/README.md`).

## Known limits
- One outline, three masters, as the rest of the set: the stroke does not thicken with `.bold`.
- The owner judges it on a device after the merge.
