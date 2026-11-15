# core.map: the Explore tab's glyph (#2413)

The owner's folded map in three panels, with a pin at its top right, replaces the paper plane (`core.paperplane`, Phosphor, #1191) as the Explore tab's glyph. It is traced from the owner's two 64 px drawings, `source/map-owner.png` (outline) and `source/map-fill-owner.png` (filled), as the crown was (#2071).

| Symbol | `AppSymbol` | Layers |
|---|---|---|
| `core.map` | `.map` | 0: outline |
| `core.map.fill` | `.mapFill` | 0: filled, fold lines and pin outline knocked out |
| `core.map.badge` | `.mapBadge` | 0: outline; 1: the badge |
| `core.map.badge.fill` | `.mapBadgeFill` | 0: filled; 1: the badge |

The paper plane's four symbolsets and `dev/symbols/tabs/paperplane/` are gone. `TabGlyph` was their only reader. The Phosphor licence stays with `core.chats` and `core.square.play`.

## How it is drawn (`source/gen-map.swift`)
1. **Measured, not upscaled.** Each stroke's centre is measured on `map-owner.png`, as the alpha-weighted middle of its run on every row (upright strokes) and every column (flat ones).
2. **Drawn as centre lines.** Each line is a Catmull-Rom cubic through a few of those centres, about one every 4 px, so no pixel step survives. There are five lines:
   - the contour, in two runs: the bottom edge turns sharply at the first fold's foot, the owner's corner;
   - the two folds, keeping the owner's curve;
   - the pin's head, a true circle (r 9 px about x = 51) with its dot (r 2.75 px);
   - the pin's tail, two lines tangent to the head that meet on its axis.
   The second fold is the tail's left line carried on down. The right edge ends on the tail's right line.
3. **The set's stroke.** Every line is stroked at 6.4 units, the weight of `core.chats` and `core.square.play`. The owner's 4 px weighs less: at this scale it would be 5.4 units.
4. **The filled map comes from the outline's geometry.** Its silhouette is the outline's outer edge, so selecting the tab never moves or resizes the map (the paper plane's "no jumps" rule).
   - The folds are knocked out as gaps, and each gap runs past the edge so the panels part cleanly.
   - The pin stands solid, with a hole the dot's size, cut from the map by a gap all round.
   - The gap is the filled drawing's, measured: 3.6 px.
   - Where the two drawings disagree, the outline wins. The filled drawing's folds stand 1.5 to 2.5 px further right.
5. **Size and place.**
   - One drawing pixel is **1.45 units**, so the map is 84.6 × 70.1 units. At 1.36 its filled ink matched `core.square.play.fill` (3,551 against 3,528 units²), but in the bar it stood 22.7 pt tall beside Messages' 25.7 and the gear's 26.7, outside the size guards (`AppSymbolSizeTests` against the system's `map`, `TabGlyphTests` against Messages, `TabFacesTests` against the gear). 1.45 meets the three: a wide glyph keeps a little less height than its neighbours, and a little more ink. At 1.3 it read smaller than both. `previews/beside-chats-square-17pt.png` shows the three in a tab bar row at 17 pt; the badge placement previews were drawn at 1.36.
   - The template is the set's: head, three masters with one outline, a 4-unit side margin (#1566), and the box's middle on the cap height's middle.
   - Every variant is placed by the plain map's box.

## The badge
- It has the same final size and gap as `core.chats.badge` and `core.square.play.badge` (r 11.6, gap 4.27 units). Layer 1 is `hierarchical-1:secondary`, drawn in `TabGlyph.badgeTint`. The cut ends are round.
- ⚠️ **Shipped `clear`, the owner's choice (2026-11-15)**, not the issue's 45° point of the pin head's stroke where the other tabs put theirs (`gen-map.swift … set`, the generator's default). At 17 pt the set's placement took the head and its dot and left a hook above the tail: the pin no longer read as a pin.
- `previews/badge-placement-options.png` (large) and `badge-placement-options-17pt.png` (in the bar) compare three placements, top to bottom:
  - **set**: the issue's placement;
  - **out**: pushed out along the same ray until the clearance spares the dot. The head becomes a "C" around it;
  - **clear**: pushed out until the clearance only touches the head. The pin stays whole. This is the closest placement where the pin still reads, and the one shipped (`previews/badge-corner.png`). Its cost is that the badged glyph is 18.3 units wider than the plain one, against 4.8 for `set` (the paper plane's grew 7.7).
- Each is one argument away: `swift gen-map.swift … set`, `… out` or `… clear`.

## Previews (`previews/`)
- `four-variants.png`: the four, large, light and dark.
- `beside-chats-square-17pt.png`: For You, Explore and Messages at 17 pt @3x, in four states (not selected, selected, badged, selected + badged), light and dark.
- `badge-corner.png`: the badged pair close up.
- `sizes-17-22-28pt.png`: the four at 17, 22 and 28 pt.
- `core.map*.png`: the generator's own thumbnails.

## Regenerate
```bash
cd source
swift gen-map.swift template-head.svg ../../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews clear
swift render-previews.swift ../../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets \
  ../../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```

## Verified
`actool` compiles all four as vector glyphs with hierarchical and multicolor layers, as it does `core.chats`.

## Known limits
- **One outline, three masters**: the stroke does not thicken with `.bold`.
- No Draw-On annotations.
