# core.square.play: the owner's play squircle (#2070)

The For You tab's four custom SF Symbols, drawn from the owner's glyph (`source/play-squircle-owner.svg`, 64 grid, even-odd). They replace the rounded square of `../square-play` (#1191) **under the same names**, so `AppSymbol`, `TabGlyph` and the shell are untouched.

| Symbol | Layers | Drawing |
|---|---|---|
| `core.square.play` | 1 | the squircle stroked inward from the fill's edge, the play filled (at 0.85, below) |
| `core.square.play.fill` | 1 | the owner's glyph as drawn: the squircle, the play knocked out (a real hole) |
| `core.square.play.badge` | 2 | the outline, cut around the badge, its ends rounded |
| `core.square.play.badge.fill` | 2 | the fill, cut around the badge, its corners rounded |

## The decisions
- **Optical size.** The squircle is scaled so its **area** equals today's filled square's (66 × 66, corner radius 14, on the 100 grid): 1.434 from the 64 grid. Its box is then 68.8 on the 100 grid, against the square's 66, because a squircle fills less of its box. The glyph is drawn at `TabGlyph.symbolConfiguration` (`AppSymbol.fixed(17)`, `.large`), as before.
- **The stroke** is 6 on the 100 grid, the set's weight (Phosphor's 16 on 256). It grows **inward** from the fill's outer edge, so the glyph keeps its size between outline and fill.
- **The play in the outline is 0.85 of the fill's**, scaled about its own centre.
  - At the owner's size it stood 8 clear of the stroke's inner edge and crowded it; at 0.85 it stands 11 clear.
  - The fill keeps the owner's play as drawn.
- **The badge** is centred where the squircle's top-right diagonal meets the stroke's centre line (the squircle has no arc centre), with radius 11.
  - It is kept 4 clear of the shape, as today's.
  - In the outline, each cap ends 4 short of the badge.
  - Layer 1 is `hierarchical-1:secondary`, so `TabGlyph.badgeTint` draws it.
- **Placement:** every variant is placed by the plain squircle's box, so neither the fill nor the badge moves it. The template head, the margins and the three masters (one outline) are the set's.

## Previews
- `previews/rendered-compiled.png`: rendered by AppKit from the **compiled** catalogue (`actool`, then `source/render-compiled.swift`).
  - The four, monochrome and in palette (ink plus the pink badge).
  - Below them, Explore, For You and Messages at 17 pt `.large`, in light and dark: For You unselected, selected, badged, and badged and selected.
- `previews/sim-tab-bar.png`: the app's bar on the simulator, For You selected (dark Shots bar) and Explore selected (light).
- `previews/sim-selection-frames.png`: the bar's selection moving onto For You, outline to fill.
- `previews/core.square.play*.png`: the generator's flat previews.

## Regenerate
```bash
cd source && swift gen-play-squircle.swift template-head.svg play-squircle-owner.svg \
  ../../../../../Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets ../previews
```

Render the compiled previews (macOS):

```bash
mkdir -p /tmp/sym/Sym.bundle/Contents/Resources
xcrun actool <Symbols.xcassets> --compile /tmp/sym/Sym.bundle/Contents/Resources --platform macosx --minimum-deployment-target 14.0
# add a minimal Contents/Info.plist (CFBundleIdentifier), then:
swiftc source/render-compiled.swift -o /tmp/sym/render && /tmp/sym/render /tmp/sym/Sym.bundle /tmp/sym
```

## Verified
- `actool` compiles all four as **vector glyphs**.
- Monochrome and palette rendering both work.
