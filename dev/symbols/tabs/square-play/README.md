# core.square.play: custom SF Symbols

Four custom SF Symbols, in the same template format as the app's `Symbols.xcassets` (#1128 / #1184):

| Symbol | Layers |
|---|---|
| `core.square.play` | 1: square + play |
| `core.square.play.fill` | 1: filled square, play knocked out |
| `core.square.play.badge` | 2: square + play, notification badge |
| `core.square.play.badge.fill` | 2: filled square + knocked-out play, notification badge |

All four are placed by the plain square's box, so neither adding the badge nor filling the square moves the square. The badge sits on the 45° point of the corner's arc, with a 4-unit gap (on the 100 grid) to the square. The square's cut ends are round.

## Add to the app

Drop the four `.symbolset` folders into an asset catalog, e.g. `Packages/Core/DesignSystem/Sources/DesignSystem/Resources/Symbols.xcassets` (it exists on `feature/custom-icons-1184`).

## Two colours in UIKit

Layer 0 (square + play) is `hierarchical-0:primary`, layer 1 (badge) is `hierarchical-1:secondary`, so a palette maps the colours in that order:

```swift
let config = UIImage.SymbolConfiguration(paletteColors: [primaryColor, accentColor])
let image = UIImage(named: "core.square.play.badge", in: .module, with: config)
```

- **Palette**: square + play take the first colour, the badge takes the second.
- **Monochrome** (`tintColor` only): both layers take the tint.
- **Hierarchical**: the badge is drawn at the secondary opacity. Use palette when it must stand out.
- **Multicolor**: square = tint, badge = system red.

## Verified

`actool` compiles all four as vector glyphs. AppKit renders them with palette, hierarchical and bold configurations (`previews/rendered-palette-hierarchical-bold.png`).

## Known limits

- **One outline, three masters**, as in the rest of the set: Ultralight, Regular and Black carry the same outline. The glyph keeps one stroke weight whatever weight is asked for.
- No Draw-On annotations. Bounce and replace work.

## Regenerate

`source/` holds the generator (its helpers are copied from `dev/symbols/gen.swift`), Apple's template head, the play outline (`play.d`) and the flat 100-grid SVGs.

```bash
cd source && swift gen-square-play.swift template-head.svg play.d .. /tmp
```
